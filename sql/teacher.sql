-- 선생님 지정: 아래 이메일을 Authentication 에서 만든 선생님 계정 이메일로 바꾼 뒤 실행하세요.
insert into public.teachers (user_id)
select id from auth.users where email = '여기에_선생님_이메일'
on conflict do nothing;

-- 입장 코드 바꾸기 (원하는 코드로 바꿔서 실행, 4자 이상)
-- update public.settings set entry_code = '새코드' where id = 1;
