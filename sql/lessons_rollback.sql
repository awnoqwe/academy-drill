-- 출석부 · 수업 기록 기능을 없던 일로 되돌린다. lessons.sql이 만든 표 하나만 지운다.
-- ⚠ 그동안 적은 출결·시험·숙제·진도 기록도 함께 지워진다. 다른 표는 건드리지 않는다.
drop table if exists public.lesson_records;
