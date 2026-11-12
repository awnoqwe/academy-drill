-- 출석부 · 수업 기록 · 입학 상담 기능을 없던 일로 되돌린다. lessons.sql이 만든 표 2개와 함수 3개만 지운다.
-- ⚠ 그동안 적은 출결·시험·숙제·진도 기록과 입학 상담 신청도 함께 지워진다. 다른 표는 건드리지 않는다.
drop function if exists public.parent_lessons(text);
drop function if exists public.consult_request(uuid, text, text, text, text, date, text, text);
drop function if exists public.consult_academy(uuid);
drop table if exists public.consult_requests;
drop table if exists public.lesson_records;
