-- ============================================================================
-- 아페라: 개인정보 수집·이용 동의 (2026-11-06)
-- apera_v2.sql에 이미 들어 있는 내용만 따로 떼어 낸 파일입니다. 둘 중 하나만 실행하면 되고, 다시 실행해도 안전합니다.
-- - 학생 가입 신청에 동의(필수)를 받고, 예전 학생은 다음 입장 때 동의 화면이 먼저 나옵니다.
-- - 만 14세 미만(중학생이 직접 고름)은 원장·선생님이 '보호자 동의서 받음'을 눌러야 시작할 수 있습니다.
-- ============================================================================
begin;
-- ④-2 개인정보 수집·이용 동의 ----------------------------------------------------
-- 학생이 앱에서 동의한 판(consent_ver)·시각과, 만 14세 미만이면 원장·선생님이 종이 보호자 동의서를 받았다고 표시한 시각을 남긴다.
-- 동의 기록(student_consents)은 언제 누가 무엇에 동의했는지 증명하는 용도. 학생을 지우면 함께 지워진다(파기).
alter table public.students add column if not exists consent_ver int;
alter table public.students add column if not exists consent_at timestamptz;
alter table public.students add column if not exists under14 boolean;
alter table public.students add column if not exists guardian_at timestamptz;
alter table public.students add column if not exists guardian_by uuid;
create table if not exists public.student_consents (
 id bigint generated always as identity primary key,
 student_id uuid not null references public.students on delete cascade,
 academy_id uuid not null references public.academies on delete cascade,
 kind text not null check (kind in ('student','guardian','guardian_cancel')),
 version int, under14 boolean, by_user uuid, at timestamptz not null default now());
create index if not exists student_consents_student on public.student_consents(student_id);
-- 지금 받는 동의서 판. 문구를 바꾸면 숫자를 올리고 앱의 CONSENT_VER도 같이 올린다 → 모든 학생이 다시 동의.
create or replace function public.apera_consent_ver() returns int language sql immutable as $f$ select 1 $f$;
-- 선생님이 표를 직접 고쳐 동의 기록을 꾸밀 수 없게: 동의 칸은 서버 함수로만 바뀐다
create or replace function public.students_consent_guard() returns trigger language plpgsql as $f$
begin
 if current_user in ('authenticated', 'anon') then
  if tg_op = 'INSERT' then
   new.consent_ver := null; new.consent_at := null; new.under14 := null; new.guardian_at := null; new.guardian_by := null;
  elsif new.consent_ver is distinct from old.consent_ver or new.consent_at is distinct from old.consent_at or new.under14 is distinct from old.under14
     or new.guardian_at is distinct from old.guardian_at or new.guardian_by is distinct from old.guardian_by then
   raise exception 'consent_locked';
  end if;
 end if;
 return new;
end $f$;
drop trigger if exists students_consent_guard on public.students;
create trigger students_consent_guard before insert or update on public.students for each row execute function public.students_consent_guard();


alter table public.student_consents enable row level security;
revoke all on public.student_consents from anon, authenticated;
drop policy if exists "member reads consents" on public.student_consents;
grant select on public.student_consents to authenticated;
create policy "member reads consents" on public.student_consents for select to authenticated using (public.is_member(academy_id));


create or replace function public.student_enter(p_code text, p_nick text, p_grade text, p_phone text)
returns json language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code); s public.students; t uuid; ph text := public.apera_phone_digits(p_phone); legacy uuid[];
begin
 if aid is null then raise exception 'bad_code'; end if;
 if length(ph) not between 10 and 11 then raise exception 'bad_phone'; end if;
 select st.* into s from public.students st join public.student_contacts c on c.student_id = st.id
  where st.academy_id = aid and st.grade = p_grade and st.nick = btrim(p_nick) and public.apera_phone_digits(c.student_phone) = ph
  order by st.approved desc, st.created_at limit 1;
 if s.id is null then
  select array_agg(st.id) into legacy from public.students st left join public.student_contacts c on c.student_id = st.id
   where st.academy_id = aid and st.grade = p_grade and st.nick = btrim(p_nick) and coalesce(c.student_phone, '') = '';
  if cardinality(legacy) = 1 then
   insert into public.student_contacts (student_id, academy_id, student_phone) values (legacy[1], aid, public.apera_phone_fmt(ph))
    on conflict (student_id) do update set student_phone = excluded.student_phone, updated_at = now();
   select * into s from public.students where id = legacy[1];
  end if;
 end if;
 if s.id is null then
  return json_build_object('status', 'new', 'academy', (select json_build_object('name', name) from public.academies where id = aid), 'other_grades',
   coalesce((select json_agg(st.grade order by st.grade) from public.students st join public.student_contacts c on c.student_id = st.id
    where st.academy_id = aid and st.nick = btrim(p_nick) and st.approved and public.apera_phone_digits(c.student_phone) = ph), '[]'::json));
 end if;
 if not s.approved then return json_build_object('status', 'pending'); end if;
 -- 개인정보 동의 전(예전 학생·동의서 판이 바뀐 경우)이면 동의 화면부터
 if coalesce(s.consent_ver, 0) < public.apera_consent_ver() then
  return json_build_object('status', 'consent', 'under14', s.under14, 'academy', (select json_build_object('name', name) from public.academies where id = aid));
 end if;
 -- 만 14세 미만: 보호자 동의서(종이)를 원장·선생님이 받았다고 표시해야 시작
 if s.under14 and s.guardian_at is null then return json_build_object('status', 'guardian'); end if;
 update public.students set last_seen = now() where id = s.id returning * into s;
 delete from public.drill_student_sessions where student_id = s.id and expires_at < now();
 insert into public.drill_student_sessions (student_id) values (s.id) returning token into t;
 return json_build_object('status', 'ok',
  'academy', (select json_build_object('name', name) from public.academies where id = aid),
  'student', json_build_object('id', s.id, 'nick', s.nick, 'grade', s.grade, 'cards', s.cards, 'queue', s.queue, 'last_seen', s.last_seen),
  'cards', coalesce((select json_agg(c order by c.sort, c.id) from public.cards c where c.academy_id = aid and p_grade = any (c.grades)), '[]'::json),
  'schedule_token', t);
end $$;


drop function if exists public.student_signup(text, text, text, text);
-- 가입 신청: 개인정보 수집·이용 동의(p_consent = 동의한 판)가 있어야 받는다. 중학생은 만 14세 미만인지도 함께 받는다.
create or replace function public.student_signup(p_code text, p_nick text, p_grade text, p_phone text, p_consent int, p_under14 boolean)
returns json language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code); ph text := public.apera_phone_digits(p_phone); sid uuid;
 u14 boolean := case when p_grade like '고%' then false else p_under14 end;
begin
 if aid is null then raise exception 'bad_code'; end if;
 if length(ph) not between 10 and 11 then raise exception 'bad_phone'; end if;
 if coalesce(p_consent, 0) < public.apera_consent_ver() or u14 is null then raise exception 'need_consent'; end if;
 if (select count(*) from public.students where academy_id = aid and not approved and created_at > now() - interval '1 hour') >= 30 then raise exception 'too_many'; end if;
 if not exists (select 1 from public.students st join public.student_contacts c on c.student_id = st.id
  where st.academy_id = aid and st.grade = p_grade and st.nick = btrim(p_nick) and public.apera_phone_digits(c.student_phone) = ph) then
  insert into public.students (academy_id, nick, grade, approved) values (aid, btrim(p_nick), p_grade, false) returning id into sid;
  update public.students set consent_ver = p_consent, consent_at = now(), under14 = u14 where id = sid;
  insert into public.student_contacts (student_id, academy_id, student_phone) values (sid, aid, public.apera_phone_fmt(ph));
  insert into public.student_consents (student_id, academy_id, kind, version, under14) values (sid, aid, 'student', p_consent, u14);
 end if;
 return public.student_enter(p_code, p_nick, p_grade, p_phone);
end $$;

-- 이미 가입한 학생의 동의(예전 학생이거나 동의서 판이 바뀐 경우). 본인 확인은 입장과 같다(코드·이름·학년·전화번호).
create or replace function public.student_consent(p_code text, p_nick text, p_grade text, p_phone text, p_consent int, p_under14 boolean)
returns json language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code); ph text := public.apera_phone_digits(p_phone); sid uuid;
 u14 boolean := case when p_grade like '고%' then false else p_under14 end;
begin
 if aid is null then raise exception 'bad_code'; end if;
 if coalesce(p_consent, 0) < public.apera_consent_ver() or u14 is null then raise exception 'need_consent'; end if;
 select st.id into sid from public.students st join public.student_contacts c on c.student_id = st.id
  where st.academy_id = aid and st.grade = p_grade and st.nick = btrim(p_nick) and public.apera_phone_digits(c.student_phone) = ph
  order by st.approved desc, st.created_at limit 1;
 if sid is null then raise exception 'not_found'; end if;
 update public.students set consent_ver = p_consent, consent_at = now(), under14 = u14 where id = sid;
 insert into public.student_consents (student_id, academy_id, kind, version, under14) values (sid, aid, 'student', p_consent, u14);
 return public.student_enter(p_code, p_nick, p_grade, p_phone);
end $$;


-- 보호자 동의서(종이)를 받았다고 표시 / 표시 취소. 만 14세 미만 학생은 이 표시가 있어야 시작할 수 있다.
create or replace function public.student_guardian(p_id uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare aid uuid := (select academy_id from public.students where id = p_id);
begin
 if aid is null or not public.is_member(aid) then raise exception 'not_member'; end if;
 update public.students set guardian_at = case when p_ok then now() end, guardian_by = case when p_ok then auth.uid() end where id = p_id;
 insert into public.student_consents (student_id, academy_id, kind, by_user) values (p_id, aid, case when p_ok then 'guardian' else 'guardian_cancel' end, auth.uid());
end $$;


create or replace function public.student_merge(p_from uuid, p_into uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.students; b public.students; merged jsonb; k text; v jsonb; w jsonb;
begin
 select * into a from public.students where id = p_from;
 select * into b from public.students where id = p_into;
 if a.id is null or b.id is null or a.id = b.id or a.academy_id <> b.academy_id then raise exception 'invalid_student'; end if;
 if not public.is_member(a.academy_id) then raise exception 'not_member'; end if;
 merged := b.cards;
 for k, v in select key, value from jsonb_each(a.cards) loop
  w := merged -> k;
  if left(k, 1) = '_' then
   if w is null then merged := merged || jsonb_build_object(k, v);
   elsif k = '_days' and jsonb_typeof(v) = 'array' and jsonb_typeof(w) = 'array' then
    merged := merged || jsonb_build_object(k, (select jsonb_agg(distinct x order by x) from (select jsonb_array_elements(w) x union select jsonb_array_elements(v)) z));
   elsif k = '_act' and jsonb_typeof(v) = 'object' and jsonb_typeof(w) = 'object' then
    merged := merged || jsonb_build_object(k, (select jsonb_object_agg(key, n) from (select key, sum(value::numeric)::int n from
     (select * from jsonb_each_text(w) union all select * from jsonb_each_text(v)) z where value ~ '^[0-9]+$' group by key) y));
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
  last_seen = greatest(a.last_seen, b.last_seen), approved = true, class_id = coalesce(b.class_id, a.class_id), school = coalesce(b.school, a.school),
  consent_ver = coalesce(greatest(b.consent_ver, a.consent_ver), b.consent_ver, a.consent_ver),
  consent_at = case when coalesce(b.consent_ver, 0) >= coalesce(a.consent_ver, 0) then coalesce(b.consent_at, a.consent_at) else a.consent_at end,
  under14 = coalesce(b.under14, a.under14), guardian_at = coalesce(b.guardian_at, a.guardian_at), guardian_by = coalesce(b.guardian_by, a.guardian_by)
 where id = b.id;
 update public.student_consents set student_id = b.id where student_id = a.id;
 update public.questions set student_id = b.id where student_id = a.id;
 insert into public.drill_group_members (group_id, student_id) select group_id, b.id from public.drill_group_members where student_id = a.id on conflict do nothing;
 insert into public.drill_event_recipients (event_id, student_id, read_at) select event_id, b.id, read_at from public.drill_event_recipients where student_id = a.id on conflict do nothing;
 delete from public.drill_student_sessions where student_id = a.id;
 update public.drill_push_subscriptions set student_id = b.id where student_id = a.id;
 insert into public.flash_states (student_id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at, stability, difficulty, last_review)
  select b.id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at, stability, difficulty, last_review from public.flash_states where student_id = a.id on conflict do nothing;
 update public.flash_logs set student_id = b.id where student_id = a.id;
 insert into public.drill_homework_recipients (homework_id, student_id, done_at, academy_id) select homework_id, b.id, done_at, academy_id from public.drill_homework_recipients where student_id = a.id
 on conflict (homework_id, student_id) do update set done_at = coalesce(drill_homework_recipients.done_at, excluded.done_at);
 insert into public.drill_student_notes (student_id, body, academy_id) select b.id, n.body, n.academy_id from public.drill_student_notes n where n.student_id = a.id
 on conflict (student_id) do update set body = left(drill_student_notes.body || E'\n\n' || excluded.body, 5000), updated_at = now();
 insert into public.parent_children (code, student_id, academy_id) select code, b.id, academy_id from public.parent_children where student_id = a.id on conflict do nothing;
 insert into public.student_contacts (student_id, academy_id, student_phone, parent_phone, fee_amount, fee_day, memo)
  select b.id, academy_id, student_phone, parent_phone, fee_amount, fee_day, memo from public.student_contacts where student_id = a.id on conflict (student_id) do nothing;
 update public.fees f set student_id = b.id where f.student_id = a.id and not exists (select 1 from public.fees g where g.student_id = b.id and g.month = f.month);
 insert into public.notice_recipients (notice_id, student_id, academy_id) select notice_id, b.id, academy_id from public.notice_recipients where student_id = a.id on conflict do nothing;
 delete from public.students where id = a.id;
end $$;


do $$
declare f text;
begin
 foreach f in array array['student_signup(text,text,text,text,int,boolean)','student_consent(text,text,text,text,int,boolean)'] loop
  execute format('revoke all on function public.%s from public', f);
  execute format('grant execute on function public.%s to anon, authenticated', f);
 end loop;
 foreach f in array array['student_guardian(uuid,boolean)','student_merge(uuid,uuid)'] loop
  execute format('revoke all on function public.%s from public', f);
  execute format('grant execute on function public.%s to authenticated', f);
 end loop;
end $$;
commit;
