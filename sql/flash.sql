-- 플래시카드(안키 방식) 추가. 기존 학생·문제·풀이·일정 기록은 건드리지 않습니다.
-- schedule.sql을 먼저 실행한 상태여야 합니다(학생 입장 토큰을 같이 씁니다).
-- Supabase > SQL Editor에 전체를 붙여 넣고 한 번 실행하세요. 다시 실행해도 됩니다.
begin;

-- ① 테이블 -------------------------------------------------------------
-- 덱: 선생님이 만들고 학년별로 배정. 하루 새 카드 수는 덱마다 정한다.
create table if not exists public.flash_decks (
 id uuid primary key default gen_random_uuid(),
 name text not null check (char_length(btrim(name)) between 1 and 40),
 grades text[] not null check (cardinality(grades) > 0 and grades <@ array['중1','중2','중3','고1','고2','고3']),
 new_per_day int not null default 20 check (new_per_day between 0 and 200),
 sort int not null default 0,
 created_at timestamptz not null default now()
);

-- 카드: 앞면·뒷면 + 연결된 트리거 드릴 문제 id(cards.id)
create table if not exists public.flash_cards (
 id uuid primary key default gen_random_uuid(),
 deck_id uuid not null references public.flash_decks on delete cascade,
 front text not null check (char_length(btrim(front)) between 1 and 2000),
 back text not null check (char_length(btrim(back)) between 1 and 4000),
 links text[] not null default '{}' check (cardinality(links) <= 20),
 sort int not null default 0,
 created_at timestamptz not null default now()
);
create index if not exists flash_cards_deck on public.flash_cards(deck_id);

-- 학생별 카드 상태 (안키 방식). 한 번도 안 본 카드는 줄이 없다.
-- queue: learn 처음 배우는 중 / review 복습 / relearn 틀려서 다시 배우는 중
-- ivl: 복습 간격(일), ease: 난이도 배수 ×1000 (2500 = 250%)
create table if not exists public.flash_states (
 student_id uuid references public.students on delete cascade,
 card_id uuid references public.flash_cards on delete cascade,
 queue text not null check (queue in ('learn','review','relearn')),
 step int not null default 0 check (step between 0 and 20),
 ivl int not null default 0 check (ivl between 0 and 36500),
 ease int not null default 2500 check (ease between 1300 and 9999),
 reps int not null default 0,
 lapses int not null default 0,
 due timestamptz not null,
 updated_at timestamptz not null default now(),
 primary key (student_id, card_id)
);
create index if not exists flash_states_due on public.flash_states(student_id, due);

-- 복습 기록: 나중에 FSRS로 바꿀 때 이 기록으로 학생별 파라미터를 맞춘다.
-- rating은 안키 번호를 그대로 쓴다: 1 다시, 3 알맞음, 4 쉬움 (2 어려움은 쓰지 않음)
-- ivl_before/ivl_after: 양수는 일, 음수는 초(학습 단계) — 안키 revlog와 같은 규칙
create table if not exists public.flash_logs (
 id uuid primary key,
 student_id uuid not null references public.students on delete cascade,
 card_id uuid not null references public.flash_cards on delete cascade,
 rating smallint not null check (rating in (1,3,4)),
 kind text not null check (kind in ('new','learn','review','relearn')),
 ivl_before int not null,
 ivl_after int not null,
 ease_after int not null,
 elapsed_ms int not null check (elapsed_ms between 0 and 3600000),
 reviewed_at timestamptz not null default now()
);
create index if not exists flash_logs_student on public.flash_logs(student_id, reviewed_at);

-- ② 보안 규칙 -----------------------------------------------------------
-- 학생 앱은 테이블에 직접 접근하지 않고 아래 함수로만 읽고 쓴다.
alter table public.flash_decks enable row level security;
alter table public.flash_cards enable row level security;
alter table public.flash_states enable row level security;
alter table public.flash_logs enable row level security;
revoke all on public.flash_decks, public.flash_cards, public.flash_states, public.flash_logs from anon, authenticated;
grant select, insert, update, delete on public.flash_decks, public.flash_cards to authenticated;
grant select on public.flash_states, public.flash_logs to authenticated;

drop policy if exists "teacher manages flash decks" on public.flash_decks;
create policy "teacher manages flash decks" on public.flash_decks for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher manages flash cards" on public.flash_cards;
create policy "teacher manages flash cards" on public.flash_cards for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher reads flash states" on public.flash_states;
create policy "teacher reads flash states" on public.flash_states for select to authenticated using (public.is_teacher());
drop policy if exists "teacher reads flash logs" on public.flash_logs;
create policy "teacher reads flash logs" on public.flash_logs for select to authenticated using (public.is_teacher());

-- ③ 학생용 함수 (입장 토큰으로 확인) -------------------------------------

-- 불러오기: 학년에 배정된 덱·카드, 내 카드 상태, 오늘(p_since 이후) 새로 배운 카드
create or replace function public.flash_student_load(p_token uuid, p_since timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; g text;
begin
 select s.student_id, st.grade into sid, g
 from public.drill_student_sessions s join public.students st on st.id = s.student_id
 where s.token = p_token and s.expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 return jsonb_build_object(
  'decks', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'new_per_day', d.new_per_day) order by d.sort, d.created_at)
                     from public.flash_decks d where g = any (d.grades)), '[]'::jsonb),
  'cards', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'deck_id', c.deck_id, 'front', c.front, 'back', c.back, 'links', c.links) order by d.sort, c.sort, c.created_at)
                     from public.flash_cards c join public.flash_decks d on d.id = c.deck_id where g = any (d.grades)), '[]'::jsonb),
  'states', coalesce((select jsonb_agg(jsonb_build_object('card_id', f.card_id, 'queue', f.queue, 'step', f.step, 'ivl', f.ivl, 'ease', f.ease, 'reps', f.reps, 'lapses', f.lapses, 'due', f.due))
                      from public.flash_states f where f.student_id = sid), '[]'::jsonb),
  'new_today', coalesce((select jsonb_agg(l.card_id) from public.flash_logs l
                         where l.student_id = sid and l.kind = 'new' and l.reviewed_at >= p_since), '[]'::jsonb)
 );
end $$;

-- 답 저장: 기록 한 줄 + 카드 상태. 같은 p_log로 다시 보내면 무시한다(재전송 안전).
create or replace function public.flash_review(p_token uuid, p_log uuid, p_card uuid, p_rating int, p_kind text, p_ivl_before int, p_elapsed int, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; n int;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 if not exists (select 1 from public.flash_cards c join public.flash_decks d on d.id = c.deck_id join public.students st on st.id = sid
                where c.id = p_card and st.grade = any (d.grades)) then raise exception 'no_card'; end if;
 insert into public.flash_logs (id, student_id, card_id, rating, kind, ivl_before, ivl_after, ease_after, elapsed_ms)
 values (p_log, sid, p_card, p_rating, p_kind, p_ivl_before, (p_state->>'log_ivl')::int, (p_state->>'ease')::int, least(greatest(coalesce(p_elapsed, 0), 0), 3600000))
 on conflict (id) do nothing;
 get diagnostics n = row_count;
 if n = 0 then return; end if;
 insert into public.flash_states (student_id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at)
 values (sid, p_card, p_state->>'queue', (p_state->>'step')::int, (p_state->>'ivl')::int, (p_state->>'ease')::int,
         (p_state->>'reps')::int, (p_state->>'lapses')::int, (p_state->>'due')::timestamptz, now())
 on conflict (student_id, card_id) do update set queue = excluded.queue, step = excluded.step, ivl = excluded.ivl, ease = excluded.ease,
   reps = excluded.reps, lapses = excluded.lapses, due = excluded.due, updated_at = now();
 update public.students set last_seen = now() where id = sid;
end $$;

-- ④ 선생님용 현황 ---------------------------------------------------------
-- 학생별: 지금 밀린 카드, 시작한 카드, 30일 복습 수, 복습 유지율(복습 카드 중 다시가 아닌 비율), 마지막 복습
-- 카드별: 30일 '다시' 비율 (자주 틀리는 카드)
create or replace function public.flash_admin_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 return jsonb_build_object(
  'students', coalesce((select jsonb_object_agg(s.id, jsonb_build_object(
     'due', (select count(*) from public.flash_states f join public.flash_cards c on c.id = f.card_id join public.flash_decks d on d.id = c.deck_id
             where f.student_id = s.id and f.due <= now() and s.grade = any (d.grades)),
     'started', (select count(*) from public.flash_states f where f.student_id = s.id),
     'reviews30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.reviewed_at > now() - interval '30 days'),
     'review30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'review' and l.reviewed_at > now() - interval '30 days'),
     'kept30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'review' and l.rating > 1 and l.reviewed_at > now() - interval '30 days'),
     'last', (select max(l.reviewed_at) from public.flash_logs l where l.student_id = s.id)))
   from public.students s), '{}'::jsonb),
  'cards', coalesce((select jsonb_agg(jsonb_build_object('card_id', x.card_id, 'n', x.n, 'again', x.again) order by x.again::float / x.n desc)
   from (select l.card_id, count(*) n, count(*) filter (where l.rating = 1) again from public.flash_logs l
         where l.reviewed_at > now() - interval '30 days' group by l.card_id having count(*) >= 3) x), '[]'::jsonb)
 );
end $$;

revoke all on function public.flash_student_load(uuid, timestamptz), public.flash_review(uuid, uuid, uuid, int, text, int, int, jsonb), public.flash_admin_stats() from public;
grant execute on function public.flash_student_load(uuid, timestamptz), public.flash_review(uuid, uuid, uuid, int, text, int, int, jsonb) to anon, authenticated;
grant execute on function public.flash_admin_stats() to authenticated;
commit;
