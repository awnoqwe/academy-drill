-- ============================================================================
-- 아페라: 학생 접속 잔디 · 하루 카드 복습 수 (선생님 학생 상세 화면)
-- apera_v2.sql을 실행한 곳에서 이 파일만 한 번 더 실행하면 된다. 다시 실행해도 안전하다.
-- ============================================================================
begin;
-- 학생 접속 날짜(잔디): students.last_seen이 바뀔 때마다 그날(서울 날짜)을 한 줄 남긴다. 하루에 한 줄.
create table if not exists public.student_days (
 student_id uuid not null references public.students on delete cascade, day date not null, primary key (student_id, day));
alter table public.student_days enable row level security;
grant select on public.student_days to authenticated;
drop policy if exists "member reads student days" on public.student_days;
create policy "member reads student days" on public.student_days for select to authenticated using (exists (select 1 from public.students s where s.id = student_id and public.is_member(s.academy_id)));
create or replace function public.student_days_mark()
returns trigger language plpgsql security definer set search_path = public as $$
begin
 insert into public.student_days (student_id, day) values (new.id, (new.last_seen at time zone 'Asia/Seoul')::date) on conflict do nothing;
 return new;
end $$;
drop trigger if exists student_days_mark on public.students;
create trigger student_days_mark after insert or update of last_seen on public.students for each row execute function public.student_days_mark();
-- 지금까지의 마지막 접속일도 한 번 채워 둔다
insert into public.student_days (student_id, day) select id, (last_seen at time zone 'Asia/Seoul')::date from public.students on conflict do nothing;

-- 선생님: 학생 한 명의 최근 26주 접속 날짜와 날짜별 카드 복습 수
create or replace function public.student_activity(p_student uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare aid uuid;
begin
 select academy_id into aid from public.students where id = p_student;
 if aid is null or not public.is_member(aid) then raise exception 'not_teacher'; end if;
 return jsonb_build_object(
  'seen', coalesce((select jsonb_agg(to_char(day, 'YYYY-MM-DD') order by day) from public.student_days where student_id = p_student and day >= current_date - 190), '[]'::jsonb),
  'flash', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'n', n)) from
    (select to_char(reviewed_at at time zone 'Asia/Seoul', 'YYYY-MM-DD') d, count(*) n from public.flash_logs
     where student_id = p_student and reviewed_at > now() - interval '191 days' group by 1) x), '[]'::jsonb));
end $$;
revoke all on function public.student_activity(uuid) from public;
grant execute on function public.student_activity(uuid) to authenticated;
commit;
