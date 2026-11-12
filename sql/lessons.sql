-- ============================================================================
-- 아페라: 출석부 · 수업 기록 (선생님 화면 '출석부' 탭, 학생 상세 '수업 기록' 탭)
-- apera_v2.sql을 실행한 곳에서 이 파일만 한 번 더 실행하면 된다. 다시 실행해도 안전하다.
-- 기존 표(학생·문제·카드·숙제·시간표…)는 하나도 바꾸지 않는다. 새 표 lesson_records 하나만 만든다.
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

commit;
