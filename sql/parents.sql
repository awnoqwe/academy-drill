-- 학부모 화면: 가족 코드(자녀 여러 명 연결) · 학부모에게 보이는 선생님 한마디.
-- schedule.sql을 먼저 실행한 상태여야 합니다. 기존 기록은 건드리지 않습니다.
-- Supabase > SQL Editor에 전체를 붙여 넣고 한 번 실행하세요. 다시 실행해도 됩니다.
begin;

-- ① 가족 코드: 코드 하나에 자녀 여러 명을 연결할 수 있다 (8자리, 헷갈리는 0·O·1·I 제외)
create table if not exists public.parent_codes (
 code text primary key check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
 label text not null default '' check (char_length(label) <= 30),
 created timestamptz not null default now()
);
create table if not exists public.parent_children (
 code text references public.parent_codes on delete cascade on update cascade,
 student_id uuid references public.students on delete cascade,
 primary key (code, student_id)
);
-- 학부모에게 보이는 선생님 한마디 (선생님만 보는 메모와 따로)
create table if not exists public.parent_comments (
 student_id uuid primary key references public.students on delete cascade,
 body text not null default '' check (char_length(body) <= 1000),
 updated_at timestamptz not null default now()
);

alter table public.parent_codes enable row level security;
alter table public.parent_children enable row level security;
alter table public.parent_comments enable row level security;
revoke all on public.parent_codes, public.parent_children, public.parent_comments from anon, authenticated;
grant select, insert, update, delete on public.parent_codes, public.parent_children, public.parent_comments to authenticated;
drop policy if exists "teacher manages parent codes" on public.parent_codes;
create policy "teacher manages parent codes" on public.parent_codes for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher manages parent children" on public.parent_children;
create policy "teacher manages parent children" on public.parent_children for all to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher manages parent comments" on public.parent_comments;
create policy "teacher manages parent comments" on public.parent_comments for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

-- ② 학부모: 코드로 자녀들의 기록 보기 (읽기 전용)
-- 공부한 날은 새벽 4시 기준(앱과 같음). Q&A·선생님 비공개 메모·다른 학생 정보는 돌려주지 않는다.
create or replace function public.parent_view(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text := upper(replace(btrim(coalesce(p_code, '')), '-', '')); s public.students; kids jsonb := '[]'; fl jsonb; hw jsonb; ev jsonb; cm text; lb text;
begin
 select label into lb from public.parent_codes where code = c;
 if not found then raise exception 'bad_code'; end if;
 for s in select st.* from public.students st join public.parent_children pc on pc.student_id = st.id where pc.code = c order by st.grade, st.nick loop
  fl := '[]';
  if to_regclass('public.flash_logs') is not null then
   select coalesce(jsonb_agg(jsonb_build_object('day', d, 'n', n)), '[]') into fl from
    (select to_char((reviewed_at at time zone 'Asia/Seoul') - interval '4 hours', 'YYYY-MM-DD') d, count(*) n
     from public.flash_logs where student_id = s.id and reviewed_at > now() - interval '15 days' group by 1) x;
  end if;
  hw := '[]';
  if to_regclass('public.drill_homework') is not null then
   select coalesce(jsonb_agg(jsonb_build_object('title', h.title, 'due', h.due, 'done_at', r.done_at) order by h.due desc), '[]') into hw
   from public.drill_homework h join public.drill_homework_recipients r on r.homework_id = h.id
   where r.student_id = s.id and h.due >= current_date - 14;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('type', e.type, 'title', e.title, 'date', e.date, 'memo', e.memo) order by e.date), '[]') into ev
  from public.drill_events e join public.drill_event_recipients r on r.event_id = e.id
  where r.student_id = s.id and e.date >= current_date - 3 and e.date <= current_date + 45;
  select body into cm from public.parent_comments where student_id = s.id;
  kids := kids || jsonb_build_array(jsonb_build_object(
   'id', s.id, 'nick', s.nick, 'grade', s.grade, 'last_seen', s.last_seen, 'cards', s.cards,
   'units', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'unit', k.unit)) from public.cards k where s.grade = any (k.grades)), '[]'),
   'flash_days', fl, 'homework', hw, 'events', ev, 'comment', coalesce(cm, '')));
 end loop;
 return jsonb_build_object('label', lb, 'kids', kids);
end $$;

revoke all on function public.parent_view(text) from public;
grant execute on function public.parent_view(text) to anon, authenticated;
commit;
