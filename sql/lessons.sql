-- ============================================================================
-- 아페라: 출석부 · 수업 기록 · 입학 상담 (선생님 화면 '오늘'·'출석' 탭, 학생 상세 '수업' 탭, 학부모 상담 신청 링크)
-- apera_v2.sql을 실행한 곳에서 이 파일만 한 번 더 실행하면 된다. 다시 실행해도 안전하다.
-- 기존 표(학생·문제·카드·숙제·시간표…)는 하나도 바꾸지 않는다. 새 표 lesson_records · consult_requests 와 상담 신청 함수 2개만 만든다.
-- 되돌리기: sql/lessons_rollback.sql 실행 (이 표만 지운다).
-- ============================================================================
begin;

-- 학생 한 명의 하루 수업 기록. 하루에 한 줄(학생·날짜가 같으면 덮어쓴다).
-- attend 출결 · test 시험 · hw 숙제(선생님이 고른 값. 비어 있으면 앱 숙제 완료 기록으로 자동 판단) · next_hw 다음 숙제 · content 진도·수업 내용
create table if not exists public.lesson_records (
 id uuid primary key default gen_random_uuid(),
 academy_id uuid not null references public.academies on delete cascade,
 student_id uuid not null references public.students on delete cascade,
 class_id uuid references public.classes on delete set null,
 day date not null,
 attend text check (attend is null or attend in ('출석','지각','결석','보강필요','보강완료')),
 test text check (test is null or test in ('통과','미통과','재시험')),
 hw text check (hw is null or hw in ('완료','일부','미완료')),
 next_hw text not null default '' check (char_length(next_hw) <= 200),
 content text not null default '' check (char_length(content) <= 500),
 updated_at timestamptz not null default now(),
 updated_by uuid default auth.uid(),
 unique (student_id, day)
);
create index if not exists lesson_records_academy_day on public.lesson_records(academy_id, day);

-- 보안: 그 학원 원장·선생님만 읽고 쓴다 (다른 표와 같은 규칙)
alter table public.lesson_records enable row level security;
revoke all on public.lesson_records from anon, authenticated;
grant select, insert, update, delete on public.lesson_records to authenticated;
drop policy if exists "academy member" on public.lesson_records;
create policy "academy member" on public.lesson_records for all to authenticated
 using (public.is_member(academy_id)) with check (public.is_member(academy_id));

-- 입학 상담 신청 ------------------------------------------------------------------
-- 학부모가 공개 링크(?consult=<학원 id>)로 신청한다. 링크에는 학생 입장 코드가 아니라 학원 id(추측 불가)가 들어간다.
-- status: 신청(새로 들어옴) → 확정(날짜 잡음) → 완료(상담함) → 등록(원생이 됨) / 취소
create table if not exists public.consult_requests (
 id uuid primary key default gen_random_uuid(),
 academy_id uuid not null references public.academies on delete cascade,
 student_name text not null check (char_length(btrim(student_name)) between 1 and 20),
 parent_phone text not null check (char_length(parent_phone) between 8 and 20),
 grade text not null default '' check (char_length(grade) <= 10),
 school text not null default '' check (char_length(school) <= 20),
 want_date date,
 want_time text not null default '' check (char_length(want_time) <= 20),
 memo text not null default '' check (char_length(memo) <= 1000),
 status text not null default '신청' check (status in ('신청','확정','완료','등록','취소')),
 scheduled_at timestamptz,
 staff_memo text not null default '' check (char_length(staff_memo) <= 2000),
 created timestamptz not null default now()
);
create index if not exists consult_requests_academy on public.consult_requests(academy_id, created);
alter table public.consult_requests enable row level security;
revoke all on public.consult_requests from anon, authenticated;
grant select, insert, update, delete on public.consult_requests to authenticated;
drop policy if exists "academy member" on public.consult_requests;
create policy "academy member" on public.consult_requests for all to authenticated
 using (public.is_member(academy_id)) with check (public.is_member(academy_id));

-- 신청 폼 머리에 학원 이름을 보여 준다 (운영 중인 학원만)
create or replace function public.consult_academy(p_academy uuid)
returns text language sql stable security definer set search_path = public as $$
 select name from public.academies where id = p_academy and active;
$$;
-- 학부모 신청 (로그인 없이). 한 학원에 한 시간 30건이 넘으면 막는다.
create or replace function public.consult_request(p_academy uuid, p_name text, p_phone text, p_grade text, p_school text, p_date date, p_time text, p_memo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text := public.apera_phone_digits(p_phone);
begin
 if not exists (select 1 from public.academies where id = p_academy and active) then raise exception 'no_academy'; end if;
 if char_length(d) not between 9 and 11 then raise exception 'bad_phone'; end if;
 if (select count(*) from public.consult_requests where academy_id = p_academy and created > now() - interval '1 hour') >= 30 then raise exception 'too_many'; end if;
 insert into public.consult_requests (academy_id, student_name, parent_phone, grade, school, want_date, want_time, memo)
 values (p_academy, btrim(p_name), public.apera_phone_fmt(d), left(coalesce(p_grade,''),10), left(btrim(coalesce(p_school,'')),20), p_date, left(coalesce(p_time,''),20), left(coalesce(p_memo,''),1000));
 return jsonb_build_object('ok', true);
end $$;
revoke all on function public.consult_academy(uuid), public.consult_request(uuid, text, text, text, text, date, text, text) from public;
grant execute on function public.consult_academy(uuid), public.consult_request(uuid, text, text, text, text, date, text, text) to anon, authenticated;

commit;
