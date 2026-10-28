-- 숙제 배정·완료 확인, 학생별 선생님 메모. 기존 학생·문제·풀이·일정·카드 기록은 건드리지 않습니다.
-- schedule.sql을 먼저 실행한 상태여야 합니다(학생 입장 토큰을 같이 씁니다).
-- Supabase > SQL Editor에 전체를 붙여 넣고 한 번 실행하세요. 다시 실행해도 됩니다.
begin;

-- ① 숙제 ---------------------------------------------------------------
-- link: 학생 화면의 '바로 하기' 대상. {"type":"drill","unit":"gram"} 또는 {"type":"flash","deck":"<덱 id>"}
create table if not exists public.drill_homework (
 id uuid primary key default gen_random_uuid(),
 title text not null check (char_length(btrim(title)) between 1 and 100),
 due date not null,
 memo text not null default '' check (char_length(memo) <= 2000),
 link jsonb check (link is null or (link->>'type' in ('drill','flash'))),
 targets jsonb not null default '[]',
 created timestamptz not null default now()
);
create table if not exists public.drill_homework_recipients (
 homework_id uuid references public.drill_homework on delete cascade,
 student_id uuid references public.students on delete cascade,
 done_at timestamptz,
 primary key (homework_id, student_id)
);
create index if not exists drill_homework_student on public.drill_homework_recipients(student_id);

-- ② 학생별 메모 (선생님만 봄) -------------------------------------------
create table if not exists public.drill_student_notes (
 student_id uuid primary key references public.students on delete cascade,
 body text not null default '' check (char_length(body) <= 5000),
 updated_at timestamptz not null default now()
);

-- ③ 보안 규칙: 선생님만 직접 읽고 쓴다. 학생은 아래 함수로만. -------------
alter table public.drill_homework enable row level security;
alter table public.drill_homework_recipients enable row level security;
alter table public.drill_student_notes enable row level security;
revoke all on public.drill_homework, public.drill_homework_recipients, public.drill_student_notes from anon, authenticated;
grant select, insert, update, delete on public.drill_homework, public.drill_homework_recipients, public.drill_student_notes to authenticated;
drop policy if exists "teacher manages homework" on public.drill_homework;
create policy "teacher manages homework" on public.drill_homework for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher manages homework recipients" on public.drill_homework_recipients;
create policy "teacher manages homework recipients" on public.drill_homework_recipients for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher manages notes" on public.drill_student_notes;
create policy "teacher manages notes" on public.drill_student_notes for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

-- ④ 선생님: 숙제 내기 (받을 학생 id 목록은 앱에서 그룹·개인을 풀어서 보낸다)
create or replace function public.hw_publish(p_title text, p_due date, p_memo text, p_link jsonb, p_targets jsonb, p_students uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare hid uuid; n int;
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 if p_students is null or cardinality(p_students) = 0 then raise exception 'no_recipients'; end if;
 if exists (select 1 from unnest(p_students) x where not exists (select 1 from public.students where id = x)) then raise exception 'invalid_student'; end if;
 insert into public.drill_homework (title, due, memo, link, targets) values (btrim(p_title), p_due, coalesce(p_memo, ''), p_link, coalesce(p_targets, '[]'::jsonb)) returning id into hid;
 insert into public.drill_homework_recipients (homework_id, student_id) select hid, x from (select distinct unnest(p_students) x) a;
 get diagnostics n = row_count;
 return jsonb_build_object('id', hid, 'recipients', n);
end $$;

-- ⑤ 학생: 내 숙제 목록, 완료 표시 -----------------------------------------
create or replace function public.hw_student_list(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'title', h.title, 'due', h.due, 'memo', h.memo, 'link', h.link, 'created', h.created, 'done_at', r.done_at) order by h.due, h.created)
   from public.drill_homework h join public.drill_homework_recipients r on r.homework_id = h.id where r.student_id = sid), '[]'::jsonb);
end $$;

create or replace function public.hw_student_done(p_token uuid, p_homework uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 update public.drill_homework_recipients set done_at = case when p_done then coalesce(done_at, now()) else null end
 where homework_id = p_homework and student_id = sid;
 update public.students set last_seen = now() where id = sid;
end $$;

revoke all on function public.hw_publish(text, date, text, jsonb, jsonb, uuid[]), public.hw_student_list(uuid), public.hw_student_done(uuid, uuid, boolean) from public;
grant execute on function public.hw_publish(text, date, text, jsonb, jsonb, uuid[]) to authenticated;
grant execute on function public.hw_student_list(uuid), public.hw_student_done(uuid, uuid, boolean) to anon, authenticated;
commit;
