-- 드릴 과목·단원을 원장·선생님이 직접 만들기 (2026-11-05)
-- apera_v2.sql을 이미 실행한 프로젝트에 이 파일만 추가로 실행하면 된다. 다시 실행해도 안전하다.
-- 하는 일: 드릴 문제(cards)의 단원을 '비문학 독해·문학·문법' 3개로만 막아 둔 규칙을 풀고,
--          '과목/단원' 이름(예: 수학/이차방정식)도 받게 한다. 기존 문제는 그대로 두며 국어 과목으로 보인다.

alter table public.cards drop constraint if exists cards_unit_check;
alter table public.cards add constraint cards_unit_check
  check (unit in ('read', 'lit', 'gram') or unit ~ '^[^/]{1,40}/[^/]{1,40}$');
