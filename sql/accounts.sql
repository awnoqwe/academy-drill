-- ⚠ 기록용 예전 파일입니다. 실행하지 마세요. 지금은 apera_v2.sql 하나만 씁니다.
--   apera_v2.sql을 적용한 뒤 이 파일을 다시 실행하면 학원 구분 없는 예전 권한 정책(is_teacher)이 되살아나
--   다른 학원의 카드·학생 데이터까지 고칠 수 있게 됩니다.
-- 가입 확인 · 선생님 승인 · 학생 합치기 · 선생님 이름.
-- schedule.sql을 먼저 실행한 상태여야 합니다. 이미 있는 학생은 모두 '승인됨'으로 유지됩니다.
-- Supabase > SQL Editor에 전체를 붙여 넣고 한 번 실행하세요. 다시 실행해도 됩니다.
begin;

-- ① 승인 여부 (이미 있는 학생은 true, 새로 가입하는 학생은 false로 들어온다)
alter table public.students add column if not exists approved boolean not null default true;
-- 선생님 이름 (화면 위 '선생님 | 이름 | 인원' 표시용)
alter table public.teachers add column if not exists name text check (name is null or char_length(btrim(name)) between 1 and 20);

-- ② 입장: 없는 학생은 바로 만들지 않고 'new'를 돌려준다 (앱이 확인 화면을 보여 준 뒤 student_signup 호출)
--    승인 전 학생은 'pending'. 다른 학년에 같은 닉네임이 있으면 알려 준다.
create or replace function public.student_enter(p_code text, p_nick text, p_grade text)
returns json language plpgsql security definer set search_path = public as $$
declare s public.students; t uuid;
begin
 if not exists (select 1 from public.settings where entry_code = p_code) then raise exception 'bad_code'; end if;
 select * into s from public.students where grade = p_grade and nick = btrim(p_nick);
 if s.id is null then
  return json_build_object('status', 'new', 'other_grades',
   coalesce((select json_agg(grade order by grade) from public.students where nick = btrim(p_nick) and approved), '[]'::json));
 end if;
 if not s.approved then return json_build_object('status', 'pending'); end if;
 update public.students set last_seen = now() where id = s.id returning * into s;
 delete from public.drill_student_sessions where student_id = s.id and expires_at < now();
 insert into public.drill_student_sessions (student_id) values (s.id) returning token into t;
 return json_build_object('status', 'ok',
  'student', json_build_object('id', s.id, 'nick', s.nick, 'grade', s.grade, 'cards', s.cards, 'queue', s.queue, 'last_seen', s.last_seen),
  'cards', coalesce((select json_agg(c order by c.sort, c.id) from public.cards c where p_grade = any (c.grades)), '[]'::json),
  'schedule_token', t);
end $$;

-- 확인 화면에서 '등록'을 누르면 승인 대기 학생으로 만든다
create or replace function public.student_signup(p_code text, p_nick text, p_grade text)
returns json language plpgsql security definer set search_path = public as $$
begin
 if not exists (select 1 from public.settings where entry_code = p_code) then raise exception 'bad_code'; end if;
 if (select count(*) from public.students where not approved and created_at > now() - interval '1 hour') >= 30 then raise exception 'too_many'; end if;
 insert into public.students (nick, grade, approved) values (btrim(p_nick), p_grade, false) on conflict (grade, nick) do nothing;
 return public.student_enter(p_code, p_nick, p_grade);
end $$;

-- 저장: 승인된 학생만
create or replace function public.student_save(p_code text, p_id uuid, p_cards jsonb, p_queue jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
 if not exists (select 1 from public.settings where entry_code = p_code) then raise exception 'bad_code'; end if;
 update public.students set cards = p_cards, queue = p_queue, last_seen = now() where id = p_id and approved;
end $$;

-- ③ 선생님: 승인 · 거절 · 합치기 · 이름 -----------------------------------
create or replace function public.student_approve(p_id uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 if p_ok then update public.students set approved = true where id = p_id;
 else delete from public.students where id = p_id and not approved; end if;
end $$;

-- p_from 학생의 모든 기록을 p_into 학생으로 옮기고 p_from을 지운다
create or replace function public.student_merge(p_from uuid, p_into uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.students; b public.students; merged jsonb; k text; v jsonb; w jsonb;
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 select * into a from public.students where id = p_from;
 select * into b from public.students where id = p_into;
 if a.id is null or b.id is null or a.id = b.id then raise exception 'invalid_student'; end if;
 -- 드릴 기록: 같은 문제는 횟수를 더하고, 최근 결과는 합칠 대상 쪽을 유지
 merged := b.cards;
 for k, v in select key, value from jsonb_each(a.cards) loop
  w := merged -> k;
  -- '_'로 시작하는 키는 공부한 날·하루 기록 같은 보조 정보: 합칠 대상에 없을 때만 옮긴다
  if left(k, 1) = '_' then
   if w is null then merged := merged || jsonb_build_object(k, v);
   elsif k = '_days' and jsonb_typeof(v) = 'array' and jsonb_typeof(w) = 'array' then
    merged := merged || jsonb_build_object(k, (select jsonb_agg(distinct x order by x) from (select jsonb_array_elements(w) x union select jsonb_array_elements(v)) z));
   elsif k = '_act' and jsonb_typeof(v) = 'object' and jsonb_typeof(w) = 'object' then
    merged := merged || jsonb_build_object(k, (select jsonb_object_agg(key, n) from (select key, sum(value::numeric)::int n from (select * from jsonb_each_text(w) union all select * from jsonb_each_text(v)) z where value ~ '^[0-9]+$' group by key) y));
   end if;
   continue;
  end if;
  if w is null or jsonb_typeof(v) <> 'object' or jsonb_typeof(w) <> 'object' then
   if w is null then merged := merged || jsonb_build_object(k, v); end if;
  else
   merged := merged || jsonb_build_object(k, w || jsonb_build_object(
    'seen', coalesce((w->>'seen')::int, 0) + coalesce((v->>'seen')::int, 0),
    'ok', coalesce((w->>'ok')::int, 0) + coalesce((v->>'ok')::int, 0),
    'blocked', coalesce((w->>'blocked')::int, 0) + coalesce((v->>'blocked')::int, 0)));
  end if;
 end loop;
 update public.students set cards = merged,
  queue = coalesce((select jsonb_agg(distinct x) from (select jsonb_array_elements(b.queue) x union select jsonb_array_elements(a.queue)) q), '[]'::jsonb),
  last_seen = greatest(a.last_seen, b.last_seen), approved = true
 where id = b.id;
 if to_regclass('public.questions') is not null then
  update public.questions set student_id = b.id where student_id = a.id;
 end if;
 insert into public.drill_group_members (group_id, student_id) select group_id, b.id from public.drill_group_members where student_id = a.id on conflict do nothing;
 insert into public.drill_event_recipients (event_id, student_id, read_at) select event_id, b.id, read_at from public.drill_event_recipients where student_id = a.id on conflict do nothing;
 delete from public.drill_student_sessions where student_id = a.id;
 if to_regclass('public.drill_push_subscriptions') is not null then
  update public.drill_push_subscriptions set student_id = b.id where student_id = a.id;
 end if;
 if to_regclass('public.flash_states') is not null then
  insert into public.flash_states select b.id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at from public.flash_states where student_id = a.id on conflict do nothing;
  update public.flash_logs set student_id = b.id where student_id = a.id;
 end if;
 if to_regclass('public.drill_homework_recipients') is not null then
  insert into public.drill_homework_recipients (homework_id, student_id, done_at) select homework_id, b.id, done_at from public.drill_homework_recipients where student_id = a.id
  on conflict (homework_id, student_id) do update set done_at = coalesce(drill_homework_recipients.done_at, excluded.done_at);
  insert into public.drill_student_notes (student_id, body)
  select b.id, n.body from public.drill_student_notes n where n.student_id = a.id
  on conflict (student_id) do update set body = left(drill_student_notes.body || E'\n\n' || excluded.body, 5000), updated_at = now();
 end if;
 delete from public.students where id = a.id;
end $$;

create or replace function public.teacher_set_name(p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 update public.teachers set name = nullif(btrim(p_name), '') where user_id = auth.uid();
end $$;

revoke all on function public.student_signup(text, text, text), public.student_approve(uuid, boolean), public.student_merge(uuid, uuid), public.teacher_set_name(text) from public;
grant execute on function public.student_enter(text, text, text), public.student_save(text, uuid, jsonb, jsonb), public.student_signup(text, text, text) to anon, authenticated;
grant execute on function public.student_approve(uuid, boolean), public.student_merge(uuid, uuid), public.teacher_set_name(text) to authenticated;
commit;
