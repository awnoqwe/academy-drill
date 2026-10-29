-- ============================================================================
-- 아페라 v2: 여러 학원이 함께 쓰는 구조 + 역할(원장·선생님·운영자) + 원장 업무(반·연락처·시간표·학원비·알림장)
--
-- 이 파일 하나로 최신 구조가 됩니다. 예전 SQL(setup·qna·schedule·push·flash·teacher_tools·accounts·parents)을
-- 일부만 실행했든 전부 실행했든 상관없고, 다시 실행해도 안전합니다.
-- 이미 있는 데이터(학생·문제·풀이·일정·카드·숙제·학부모 코드)는 지우지 않고 '1호 학원'으로 옮깁니다.
-- 기존 선생님 계정은 1호 학원의 원장 + 운영자(모든 학원 관리)로 옮겨집니다.
--
-- 실행 전에: Supabase > Database > Backups 에서 백업이 있는지 확인하세요.
-- 실행: Supabase > SQL Editor 에 전체를 붙여 넣고 Run.
-- ============================================================================
begin;

-- ① 학원 · 구성원 · 운영자 -----------------------------------------------------
create table if not exists public.academies (
 id uuid primary key default gen_random_uuid(),
 name text not null check (char_length(btrim(name)) between 1 and 40),
 code text not null unique check (char_length(code) between 4 and 20),
 active boolean not null default true,
 created timestamptz not null default now()
);
-- 역할: owner 원장(학원 전체 · 연락처 · 학원비), teacher 선생님(수업·문제·숙제)
-- alias: 시간표 칸에 적히는 이름(예: 김, 박성진). 쉼표로 여러 개.
create table if not exists public.academy_members (
 academy_id uuid references public.academies on delete cascade,
 user_id uuid references auth.users on delete cascade,
 role text not null check (role in ('owner','teacher')),
 name text check (name is null or char_length(btrim(name)) between 1 and 20),
 alias text not null default '' check (char_length(alias) <= 40),
 created timestamptz not null default now(),
 primary key (academy_id, user_id)
);
create index if not exists academy_members_user on public.academy_members(user_id);
-- 운영자(앱 개발자): 모든 학원에 들어가 문제를 고칠 수 있다. 들어갈 때마다 기록을 남긴다.
create table if not exists public.platform_admins (user_id uuid primary key references auth.users on delete cascade);
create table if not exists public.admin_access_log (
 id bigint generated always as identity primary key,
 user_id uuid not null, academy_id uuid not null, at timestamptz not null default now()
);

-- 예전 단일 학원 데이터가 있으면 '1호 학원'을 만든다
do $$
declare c text; aid uuid; has_students boolean := false;
begin
 if not exists (select 1 from public.academies) then
  if to_regclass('public.settings') is not null then execute 'select entry_code from public.settings where id = 1' into c; end if;
  if to_regclass('public.students') is not null then execute 'select exists (select 1 from public.students)' into has_students; end if;
  if c is not null or has_students then
   insert into public.academies (name, code) values ('1호 학원', coalesce(c, '0000')) returning id into aid;
   if to_regclass('public.teachers') is not null then
    execute 'insert into public.academy_members (academy_id, user_id, role) select $1, t.user_id, ''owner'' from public.teachers t on conflict do nothing' using aid;
    execute 'insert into public.platform_admins (user_id) select user_id from public.teachers on conflict do nothing';
    -- 예전 선생님 이름 옮기기 (accounts.sql을 실행했다면)
    if exists (select 1 from information_schema.columns where table_schema='public' and table_name='teachers' and column_name='name') then
     execute 'update public.academy_members m set name = t.name from public.teachers t where t.user_id = m.user_id and m.academy_id = $1' using aid;
    end if;
   end if;
  end if;
 end if;
end $$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
 select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;
create or replace function public.is_member(p_academy uuid)
returns boolean language sql stable security definer set search_path = public as $$
 select public.is_admin() or exists (select 1 from public.academy_members where academy_id = p_academy and user_id = auth.uid());
$$;
create or replace function public.is_owner(p_academy uuid)
returns boolean language sql stable security definer set search_path = public as $$
 select public.is_admin() or exists (select 1 from public.academy_members where academy_id = p_academy and user_id = auth.uid() and role = 'owner');
$$;
-- 예전 함수 이름 유지(어느 학원이든 구성원이면 true)
create or replace function public.is_teacher()
returns boolean language sql stable security definer set search_path = public as $$
 select public.is_admin() or exists (select 1 from public.academy_members where user_id = auth.uid());
$$;

-- ② 기존 테이블 (없으면 만들고, 있으면 그대로 둔다) ---------------------------------
create table if not exists public.students (
 id uuid primary key default gen_random_uuid(),
 nick text not null check (char_length(nick) between 2 and 12),
 grade text not null check (grade in ('중1','중2','중3','고1','고2','고3')),
 cards jsonb not null default '{}'::jsonb check (pg_column_size(cards) < 200000),
 queue jsonb not null default '[]'::jsonb check (pg_column_size(queue) < 20000),
 last_seen timestamptz not null default now(),
 created_at timestamptz not null default now()
);
alter table public.students add column if not exists approved boolean not null default true;
create table if not exists public.cards (
 id text primary key, grades text[] not null, unit text not null check (unit in ('read','lit','gram')), tag text not null,
 stem text not null, passage text not null default '', poem boolean not null default false, opts jsonb not null, ans jsonb not null,
 explain text not null default '', sort int not null default 0, created_at timestamptz not null default now()
);
create table if not exists public.questions (
 id bigint generated always as identity primary key,
 student_id uuid not null references public.students (id) on delete cascade,
 card_id text references public.cards (id) on delete set null,
 body text not null check (char_length(body) between 2 and 500),
 answer text check (answer is null or char_length(answer) <= 2000),
 answered_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists public.drill_groups (id uuid primary key default gen_random_uuid(), name text not null check (char_length(btrim(name)) between 1 and 30));
create table if not exists public.drill_group_members (
 group_id uuid references public.drill_groups on delete cascade, student_id uuid references public.students on delete cascade, primary key (group_id, student_id));
create table if not exists public.drill_events (
 id uuid primary key default gen_random_uuid(), type text not null check (type in ('exam','academy')),
 title text not null check (char_length(btrim(title)) between 1 and 100), date date not null,
 memo text not null default '' check (char_length(memo) <= 5000), targets jsonb not null default '[]',
 attachment jsonb check (attachment is null or (octet_length(attachment::text) <= 1500000 and attachment->>'data' ~ '^data:(application/pdf|image/png|image/jpeg);base64,' and char_length(attachment->>'name') between 1 and 255)),
 created timestamptz not null default now(), created_by uuid references auth.users);
create table if not exists public.drill_event_recipients (
 event_id uuid references public.drill_events on delete cascade, student_id uuid references public.students on delete cascade,
 read_at timestamptz, primary key (event_id, student_id));
create table if not exists public.drill_student_sessions (
 token uuid primary key default gen_random_uuid(), student_id uuid not null references public.students on delete cascade,
 expires_at timestamptz not null default now() + interval '7 days');
create index if not exists drill_session_student on public.drill_student_sessions(student_id);
create table if not exists public.drill_push_config (id int primary key check (id = 1), public_key text not null, private_key text not null);
create table if not exists public.drill_push_subscriptions (
 id uuid primary key default gen_random_uuid(), student_id uuid not null references public.students on delete cascade,
 endpoint text not null unique check (char_length(endpoint) < 2048), p256dh text not null, auth text not null,
 active boolean not null default true, updated_at timestamptz not null default now());
create table if not exists public.flash_decks (
 id uuid primary key default gen_random_uuid(), name text not null check (char_length(btrim(name)) between 1 and 40),
 grades text[] not null check (cardinality(grades) > 0 and grades <@ array['중1','중2','중3','고1','고2','고3']),
 new_per_day int not null default 20 check (new_per_day between 0 and 200), sort int not null default 0, created_at timestamptz not null default now());
create table if not exists public.flash_cards (
 id uuid primary key default gen_random_uuid(), deck_id uuid not null references public.flash_decks on delete cascade,
 front text not null check (char_length(btrim(front)) between 1 and 2000), back text not null check (char_length(btrim(back)) between 1 and 4000),
 links text[] not null default '{}' check (cardinality(links) <= 20), sort int not null default 0, created_at timestamptz not null default now());
create table if not exists public.flash_states (
 student_id uuid references public.students on delete cascade, card_id uuid references public.flash_cards on delete cascade,
 queue text not null check (queue in ('learn','review','relearn')), step int not null default 0 check (step between 0 and 20),
 ivl int not null default 0 check (ivl between 0 and 36500), ease int not null default 2500 check (ease between 1300 and 9999),
 reps int not null default 0, lapses int not null default 0, due timestamptz not null, updated_at timestamptz not null default now(),
 primary key (student_id, card_id));
create table if not exists public.flash_logs (
 id uuid primary key, student_id uuid not null references public.students on delete cascade, card_id uuid not null references public.flash_cards on delete cascade,
 rating smallint not null check (rating in (1,3,4)), kind text not null check (kind in ('new','learn','review','relearn')),
 ivl_before int not null, ivl_after int not null, ease_after int not null, elapsed_ms int not null check (elapsed_ms between 0 and 3600000),
 reviewed_at timestamptz not null default now());
create index if not exists flash_logs_student on public.flash_logs(student_id, reviewed_at);
create table if not exists public.drill_homework (
 id uuid primary key default gen_random_uuid(), title text not null check (char_length(btrim(title)) between 1 and 100), due date not null,
 memo text not null default '' check (char_length(memo) <= 2000), link jsonb check (link is null or (link->>'type' in ('drill','flash'))),
 targets jsonb not null default '[]', created timestamptz not null default now());
create table if not exists public.drill_homework_recipients (
 homework_id uuid references public.drill_homework on delete cascade, student_id uuid references public.students on delete cascade,
 done_at timestamptz, primary key (homework_id, student_id));
create table if not exists public.drill_student_notes (
 student_id uuid primary key references public.students on delete cascade, body text not null default '' check (char_length(body) <= 5000),
 updated_at timestamptz not null default now());
create table if not exists public.parent_codes (
 code text primary key check (code ~ '^[A-HJ-NP-Z2-9]{8}$'), label text not null default '' check (char_length(label) <= 30), created timestamptz not null default now());
create table if not exists public.parent_children (
 code text references public.parent_codes on delete cascade on update cascade, student_id uuid references public.students on delete cascade, primary key (code, student_id));
create table if not exists public.parent_comments (
 student_id uuid primary key references public.students on delete cascade, body text not null default '' check (char_length(body) <= 1000),
 updated_at timestamptz not null default now());

-- ③ 모든 학원 데이터에 '어느 학원 것인지'를 붙인다 -------------------------------
do $$
declare t text; aid uuid := (select id from public.academies order by created limit 1);
begin
 foreach t in array array['students','cards','questions','drill_groups','drill_events','flash_decks','flash_cards','drill_homework',
   'drill_homework_recipients','drill_student_notes','parent_codes','parent_children','parent_comments'] loop
  execute format('alter table public.%I add column if not exists academy_id uuid references public.academies on delete cascade', t);
  if aid is not null then execute format('update public.%I set academy_id = $1 where academy_id is null', t) using aid; end if;
  execute format('alter table public.%I alter column academy_id set not null', t);
  execute format('create index if not exists %I on public.%I(academy_id)', t||'_academy', t);
 end loop;
end $$;
-- 학원마다 같은 닉네임·그룹 이름을 쓸 수 있게
alter table public.students drop constraint if exists students_grade_nick_key;
create unique index if not exists students_academy_grade_nick on public.students(academy_id, grade, nick);
alter table public.drill_groups drop constraint if exists drill_groups_name_key;
create unique index if not exists drill_groups_academy_name on public.drill_groups(academy_id, name);

-- ④ 원장 업무: 반 · 학교 · 연락처 · 시간표 · 학원비 · 알림장 -----------------------
create table if not exists public.classes (
 id uuid primary key default gen_random_uuid(), academy_id uuid not null references public.academies on delete cascade,
 name text not null check (char_length(btrim(name)) between 1 and 20), sort int not null default 0,
 unique (academy_id, name));
alter table public.students add column if not exists class_id uuid references public.classes on delete set null;
alter table public.students add column if not exists school text check (school is null or char_length(btrim(school)) between 1 and 20);
-- 연락처·학원비 기본값은 원장만 본다
create table if not exists public.student_contacts (
 student_id uuid primary key references public.students on delete cascade, academy_id uuid not null references public.academies on delete cascade,
 student_phone text check (student_phone is null or student_phone ~ '^[0-9-]{9,14}$'),
 parent_phone text check (parent_phone is null or parent_phone ~ '^[0-9-]{9,14}$'),
 fee_amount int check (fee_amount is null or fee_amount between 0 and 10000000),
 fee_day int check (fee_day is null or fee_day between 1 and 31),
 memo text not null default '' check (char_length(memo) <= 500),
 updated_at timestamptz not null default now());
-- 시간표: weekly(요일 고정, weekday 0=월…6=일) 또는 dated(날짜 범위, 고정 시간표를 그 기간만 덮어씀)
-- slots: [{"start":"16:40","end":"17:30"}, …] 시간표마다 교시를 따로 정한다
-- cells: {"<반 id>": ["", "국어김", "남중-영어오\n대청-국어김", …]} 교시 순서대로
create table if not exists public.timetables (
 id uuid primary key default gen_random_uuid(), academy_id uuid not null references public.academies on delete cascade,
 kind text not null check (kind in ('weekly','dated')),
 weekday int check (weekday between 0 and 6),
 date_from date, date_to date,
 title text not null default '' check (char_length(title) <= 40),
 slots jsonb not null default '[]' check (jsonb_typeof(slots) = 'array' and jsonb_array_length(slots) <= 20),
 cells jsonb not null default '{}' check (jsonb_typeof(cells) = 'object' and octet_length(cells::text) <= 200000),
 updated_at timestamptz not null default now(),
 check ((kind = 'weekly' and weekday is not null) or (kind = 'dated' and date_from is not null and date_to is not null and date_to >= date_from and date_to - date_from <= 62)));
create index if not exists timetables_academy on public.timetables(academy_id, kind);
create table if not exists public.fees (
 id uuid primary key default gen_random_uuid(), academy_id uuid not null references public.academies on delete cascade,
 student_id uuid not null references public.students on delete cascade,
 month text not null check (month ~ '^[0-9]{4}-[0-9]{2}$'),
 amount int not null check (amount between 0 and 10000000),
 due date not null, paid_at date, method text not null default '' check (char_length(method) <= 20),
 memo text not null default '' check (char_length(memo) <= 200),
 created timestamptz not null default now(), unique (student_id, month));
create index if not exists fees_academy_month on public.fees(academy_id, month);
create table if not exists public.notices (
 id uuid primary key default gen_random_uuid(), academy_id uuid not null references public.academies on delete cascade,
 title text not null check (char_length(btrim(title)) between 1 and 100), body text not null default '' check (char_length(body) <= 3000),
 targets jsonb not null default '[]', created timestamptz not null default now(), created_by uuid references auth.users);
create table if not exists public.notice_recipients (
 notice_id uuid references public.notices on delete cascade, student_id uuid references public.students on delete cascade,
 academy_id uuid not null references public.academies on delete cascade, primary key (notice_id, student_id));
-- 학부모 기기 알림 (가족 코드 단위)
create table if not exists public.parent_push_subscriptions (
 id uuid primary key default gen_random_uuid(), code text not null references public.parent_codes on delete cascade on update cascade,
 endpoint text not null check (char_length(endpoint) < 2048), p256dh text not null, auth text not null,
 active boolean not null default true, updated_at timestamptz not null default now(), unique (code, endpoint));
-- 알림 중복 발송 방지 (일정·시간표·알림장 공통)
create table if not exists public.push_sent (
 message text not null, sub_kind text not null check (sub_kind in ('student','parent')), sub_id uuid not null,
 status text not null check (status in ('sending','sent','failed','expired')), updated_at timestamptz not null default now(),
 primary key (message, sub_kind, sub_id));

-- ⑤ 보안 규칙 -------------------------------------------------------------------
do $$
declare r record; t text;
begin
 -- 예전 정책을 모두 지우고 학원 단위로 다시 만든다
 for r in select tablename, policyname from pg_policies where schemaname = 'public' and tablename in
  ('settings','teachers','students','cards','questions','drill_groups','drill_events','flash_decks','flash_cards','flash_states','flash_logs',
   'drill_homework','drill_homework_recipients','drill_student_notes','parent_codes','parent_children','parent_comments',
   'academies','academy_members','platform_admins','classes','student_contacts','timetables','fees','notices','notice_recipients') loop
  execute format('drop policy %I on public.%I', r.policyname, r.tablename);
 end loop;
 foreach t in array array['academies','academy_members','platform_admins','admin_access_log','students','cards','questions','drill_groups','drill_group_members',
   'drill_events','drill_event_recipients','drill_student_sessions','drill_push_config','drill_push_subscriptions','flash_decks','flash_cards','flash_states','flash_logs',
   'drill_homework','drill_homework_recipients','drill_student_notes','parent_codes','parent_children','parent_comments','classes','student_contacts',
   'timetables','fees','notices','notice_recipients','parent_push_subscriptions','push_sent'] loop
  execute format('alter table public.%I enable row level security', t);
  execute format('revoke all on public.%I from anon, authenticated', t);
 end loop;
 -- 학원 구성원(원장·선생님)이 직접 읽고 쓰는 표
 foreach t in array array['students','cards','questions','drill_groups','drill_events','flash_decks','flash_cards','drill_homework','drill_homework_recipients',
   'drill_student_notes','parent_codes','parent_children','parent_comments','classes','timetables','notices','notice_recipients'] loop
  execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  execute format('create policy "academy member" on public.%I for all to authenticated using (public.is_member(academy_id)) with check (public.is_member(academy_id))', t);
 end loop;
 -- 원장만 (연락처 · 학원비)
 foreach t in array array['student_contacts','fees'] loop
  execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  execute format('create policy "academy owner" on public.%I for all to authenticated using (public.is_owner(academy_id)) with check (public.is_owner(academy_id))', t);
 end loop;
end $$;
grant select, update on public.academies to authenticated;
create policy "member reads academy" on public.academies for select to authenticated using (public.is_member(id));
create policy "owner renames academy" on public.academies for update to authenticated using (public.is_owner(id)) with check (public.is_owner(id));
grant select on public.academy_members, public.platform_admins to authenticated;
create policy "member reads members" on public.academy_members for select to authenticated using (user_id = auth.uid() or public.is_member(academy_id));
create policy "admin reads self" on public.platform_admins for select to authenticated using (user_id = auth.uid());
grant select on public.flash_states, public.flash_logs to authenticated;
create policy "member reads flash states" on public.flash_states for select to authenticated using (exists (select 1 from public.students s where s.id = student_id and public.is_member(s.academy_id)));
create policy "member reads flash logs" on public.flash_logs for select to authenticated using (exists (select 1 from public.students s where s.id = student_id and public.is_member(s.academy_id)));
grant all on public.drill_push_config, public.drill_push_subscriptions, public.parent_push_subscriptions, public.push_sent to service_role;
grant select on public.drill_events, public.drill_event_recipients, public.students, public.timetables, public.notices, public.notice_recipients,
 public.parent_children, public.academy_members, public.platform_admins, public.classes to service_role;

-- ⑥ 예전 단일 학원 함수 정리 (학원을 받는 새 함수로 바뀜) ---------------------------
drop function if exists public.drill_schedule_admin();
drop function if exists public.drill_group_save(uuid, text, uuid[]);
drop function if exists public.drill_schedule_publish(jsonb, text, uuid[], uuid[], boolean, jsonb);
drop function if exists public.flash_admin_stats();
drop function if exists public.hw_publish(text, date, text, jsonb, jsonb, uuid[]);
drop function if exists public.teacher_set_name(text);

-- ⑦ 학생 함수 (입장 코드 = 학원) ---------------------------------------------------
create or replace function public.academy_by_code(p_code text)
returns uuid language sql stable security definer set search_path = public as $$
 select id from public.academies where code = btrim(coalesce(p_code, '')) and active;
$$;
revoke all on function public.academy_by_code(text) from public, anon, authenticated;

create or replace function public.student_enter(p_code text, p_nick text, p_grade text)
returns json language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code); s public.students; t uuid;
begin
 if aid is null then raise exception 'bad_code'; end if;
 select * into s from public.students where academy_id = aid and grade = p_grade and nick = btrim(p_nick);
 if s.id is null then
  return json_build_object('status', 'new', 'other_grades',
   coalesce((select json_agg(grade order by grade) from public.students where academy_id = aid and nick = btrim(p_nick) and approved), '[]'::json));
 end if;
 if not s.approved then return json_build_object('status', 'pending'); end if;
 update public.students set last_seen = now() where id = s.id returning * into s;
 delete from public.drill_student_sessions where student_id = s.id and expires_at < now();
 insert into public.drill_student_sessions (student_id) values (s.id) returning token into t;
 return json_build_object('status', 'ok',
  'academy', (select json_build_object('name', name) from public.academies where id = aid),
  'student', json_build_object('id', s.id, 'nick', s.nick, 'grade', s.grade, 'cards', s.cards, 'queue', s.queue, 'last_seen', s.last_seen),
  'cards', coalesce((select json_agg(c order by c.sort, c.id) from public.cards c where c.academy_id = aid and p_grade = any (c.grades)), '[]'::json),
  'schedule_token', t);
end $$;

create or replace function public.student_signup(p_code text, p_nick text, p_grade text)
returns json language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code);
begin
 if aid is null then raise exception 'bad_code'; end if;
 if (select count(*) from public.students where academy_id = aid and not approved and created_at > now() - interval '1 hour') >= 30 then raise exception 'too_many'; end if;
 insert into public.students (academy_id, nick, grade, approved) values (aid, btrim(p_nick), p_grade, false) on conflict do nothing;
 return public.student_enter(p_code, p_nick, p_grade);
end $$;

create or replace function public.student_save(p_code text, p_id uuid, p_cards jsonb, p_queue jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code);
begin
 if aid is null then raise exception 'bad_code'; end if;
 update public.students set cards = p_cards, queue = p_queue, last_seen = now() where id = p_id and academy_id = aid and approved;
end $$;

create or replace function public.qna_list(p_code text, p_student uuid)
returns json language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code);
begin
 if aid is null then raise exception 'bad_code'; end if;
 return coalesce((select json_agg(x order by x.created_at desc) from (
  select q.id, q.body, q.answer, q.created_at, q.answered_at, s.nick, s.grade, c.tag as card_tag, c.unit as card_unit, (q.student_id = p_student) as mine
  from public.questions q join public.students s on s.id = q.student_id left join public.cards c on c.id = q.card_id
  where q.academy_id = aid order by q.created_at desc limit 200) x), '[]'::json);
end $$;

create or replace function public.qna_post(p_code text, p_student uuid, p_body text, p_card text)
returns void language plpgsql security definer set search_path = public as $$
declare aid uuid := public.academy_by_code(p_code);
begin
 if aid is null then raise exception 'bad_code'; end if;
 if not exists (select 1 from public.students where id = p_student and academy_id = aid and approved) then raise exception 'no_student'; end if;
 if (select count(*) from public.questions where student_id = p_student and created_at > now() - interval '1 day') >= 10 then raise exception 'too_many'; end if;
 insert into public.questions (academy_id, student_id, card_id, body)
 values (aid, p_student, (select id from public.cards where id = p_card and academy_id = aid), btrim(p_body));
end $$;

-- 일정(학생): 토큰 → 학생 → 받은 일정만. 학원 구분은 받는 학생으로 자연히 나뉜다.
create or replace function public.drill_schedule_student(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; es jsonb; rd jsonb;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 select coalesce(jsonb_agg(x order by x->>'date'), '[]') into es from
  (select jsonb_build_object('id', e.id, 'type', e.type, 'title', e.title, 'date', e.date, 'memo', e.memo, 'attachment', e.attachment, 'created', e.created,
    'targets', '[]'::jsonb, 'recipients', jsonb_build_array(sid)) x
   from public.drill_events e join public.drill_event_recipients r on r.event_id = e.id where r.student_id = sid) a;
 select coalesce(jsonb_agg(event_id), '[]') into rd from public.drill_event_recipients where student_id = sid and read_at is not null;
 return jsonb_build_object('events', es, 'groups', '[]'::jsonb, 'reads', jsonb_build_object(sid::text, rd));
end $$;
create or replace function public.drill_schedule_read(p_token uuid, p_events uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 update public.drill_event_recipients set read_at = coalesce(read_at, now()) where student_id = sid and event_id = any (p_events);
end $$;

-- 카드(학생)
create or replace function public.flash_student_load(p_token uuid, p_since timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; g text; aid uuid;
begin
 select s.student_id, st.grade, st.academy_id into sid, g, aid from public.drill_student_sessions s join public.students st on st.id = s.student_id
 where s.token = p_token and s.expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 return jsonb_build_object(
  'decks', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'new_per_day', d.new_per_day) order by d.sort, d.created_at)
   from public.flash_decks d where d.academy_id = aid and g = any (d.grades)), '[]'::jsonb),
  'cards', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'deck_id', c.deck_id, 'front', c.front, 'back', c.back, 'links', c.links) order by d.sort, c.sort, c.created_at)
   from public.flash_cards c join public.flash_decks d on d.id = c.deck_id where d.academy_id = aid and g = any (d.grades)), '[]'::jsonb),
  'states', coalesce((select jsonb_agg(jsonb_build_object('card_id', f.card_id, 'queue', f.queue, 'step', f.step, 'ivl', f.ivl, 'ease', f.ease, 'reps', f.reps, 'lapses', f.lapses, 'due', f.due))
   from public.flash_states f where f.student_id = sid), '[]'::jsonb),
  'new_today', coalesce((select jsonb_agg(l.card_id) from public.flash_logs l where l.student_id = sid and l.kind = 'new' and l.reviewed_at >= p_since), '[]'::jsonb));
end $$;
create or replace function public.flash_review(p_token uuid, p_log uuid, p_card uuid, p_rating int, p_kind text, p_ivl_before int, p_elapsed int, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; n int;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 if not exists (select 1 from public.flash_cards c join public.flash_decks d on d.id = c.deck_id join public.students st on st.id = sid
   where c.id = p_card and d.academy_id = st.academy_id and st.grade = any (d.grades)) then raise exception 'no_card'; end if;
 insert into public.flash_logs (id, student_id, card_id, rating, kind, ivl_before, ivl_after, ease_after, elapsed_ms)
 values (p_log, sid, p_card, p_rating, p_kind, p_ivl_before, (p_state->>'log_ivl')::int, (p_state->>'ease')::int, least(greatest(coalesce(p_elapsed, 0), 0), 3600000))
 on conflict (id) do nothing;
 get diagnostics n = row_count; if n = 0 then return; end if;
 insert into public.flash_states (student_id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at)
 values (sid, p_card, p_state->>'queue', (p_state->>'step')::int, (p_state->>'ivl')::int, (p_state->>'ease')::int, (p_state->>'reps')::int, (p_state->>'lapses')::int, (p_state->>'due')::timestamptz, now())
 on conflict (student_id, card_id) do update set queue = excluded.queue, step = excluded.step, ivl = excluded.ivl, ease = excluded.ease,
  reps = excluded.reps, lapses = excluded.lapses, due = excluded.due, updated_at = now();
 update public.students set last_seen = now() where id = sid;
end $$;

-- 숙제(학생)
create or replace function public.hw_student_list(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'title', h.title, 'due', h.due, 'memo', h.memo, 'link', h.link, 'created', h.created, 'done_at', r.done_at) order by h.due, h.created)
  from public.drill_homework h join public.drill_homework_recipients r on r.homework_id = h.id where r.student_id = sid), '[]'::jsonb);
end $$;
create or replace function public.hw_student_done(p_token uuid, p_homework uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 update public.drill_homework_recipients set done_at = case when p_done then coalesce(done_at, now()) else null end where homework_id = p_homework and student_id = sid;
 update public.students set last_seen = now() where id = sid;
end $$;

-- 시간표(학생): 내 반·학교·학년과 시간표들. 내 수업 고르기는 앱에서 한다.
create or replace function public.tt_student(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.students;
begin
 select s.* into st from public.drill_student_sessions x join public.students s on s.id = x.student_id where x.token = p_token and x.expires_at > now();
 if st.id is null then raise exception 'session_expired'; end if;
 return jsonb_build_object('class_id', st.class_id, 'class', (select name from public.classes where id = st.class_id), 'school', st.school, 'grade', st.grade,
  'timetables', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'weekday', t.weekday, 'date_from', t.date_from, 'date_to', t.date_to,
     'title', t.title, 'slots', t.slots, 'cell', t.cells -> st.class_id::text, 'updated_at', t.updated_at))
   from public.timetables t where t.academy_id = st.academy_id and st.class_id is not null and t.cells ? st.class_id::text
     and (t.kind = 'weekly' or t.date_to >= current_date - 1)), '[]'::jsonb));
end $$;

-- 푸시(학생 기기): 키·구독은 예전과 같다
create or replace function public.drill_push_public_key(p_token uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
 if not exists (select 1 from public.drill_student_sessions where token = p_token and expires_at > now()) then raise exception 'session_expired'; end if;
 return (select public_key from public.drill_push_config where id = 1);
end $$;
create or replace function public.drill_push_subscribe(p_token uuid, p_subscription jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; ep text := p_subscription->>'endpoint'; pk text := p_subscription->'keys'->>'p256dh'; ak text := p_subscription->'keys'->>'auth'; result uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 if ep is null or ep !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/' or char_length(ep) >= 2048
  or pk is null or pk !~ '^[A-Za-z0-9_-]{87}$' or ak is null or ak !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'invalid_subscription'; end if;
 if not exists (select 1 from public.drill_push_subscriptions where endpoint = ep) and (select count(*) from public.drill_push_subscriptions where student_id = sid and active) >= 10 then raise exception 'too_many_devices'; end if;
 insert into public.drill_push_subscriptions (student_id, endpoint, p256dh, auth) values (sid, ep, pk, ak)
 on conflict (endpoint) do update set student_id = excluded.student_id, p256dh = excluded.p256dh, auth = excluded.auth, active = true, updated_at = now() returning id into result;
 return result;
end $$;
create or replace function public.drill_push_unsubscribe(p_token uuid, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 update public.drill_push_subscriptions set active = false, updated_at = now() where student_id = sid and endpoint = p_endpoint;
end $$;

-- ⑧ 학부모 함수 ------------------------------------------------------------------
create or replace function public.parent_view(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text := upper(replace(btrim(coalesce(p_code, '')), '-', '')); pc public.parent_codes; s public.students; kids jsonb := '[]'; fee jsonb; ym text := to_char(current_date, 'YYYY-MM');
begin
 select * into pc from public.parent_codes where code = c;
 if pc.code is null then raise exception 'bad_code'; end if;
 for s in select st.* from public.students st join public.parent_children x on x.student_id = st.id where x.code = c and st.academy_id = pc.academy_id order by st.grade, st.nick loop
  select jsonb_build_object('month', f.month, 'amount', f.amount, 'due', f.due, 'paid', f.paid_at is not null) into fee from public.fees f where f.student_id = s.id and f.month = ym;
  kids := kids || jsonb_build_array(jsonb_build_object(
   'id', s.id, 'nick', s.nick, 'grade', s.grade, 'school', s.school, 'class', (select name from public.classes where id = s.class_id), 'last_seen', s.last_seen, 'cards', s.cards,
   'units', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'unit', k.unit)) from public.cards k where k.academy_id = s.academy_id and s.grade = any (k.grades)), '[]'),
   'flash_days', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'n', n)) from
     (select to_char((reviewed_at at time zone 'Asia/Seoul') - interval '4 hours', 'YYYY-MM-DD') d, count(*) n from public.flash_logs
      where student_id = s.id and reviewed_at > now() - interval '15 days' group by 1) x), '[]'),
   'homework', coalesce((select jsonb_agg(jsonb_build_object('title', h.title, 'due', h.due, 'done_at', r.done_at) order by h.due desc)
     from public.drill_homework h join public.drill_homework_recipients r on r.homework_id = h.id where r.student_id = s.id and h.due >= current_date - 14), '[]'),
   'events', coalesce((select jsonb_agg(jsonb_build_object('type', e.type, 'title', e.title, 'date', e.date, 'memo', e.memo) order by e.date)
     from public.drill_events e join public.drill_event_recipients r on r.event_id = e.id where r.student_id = s.id and e.date between current_date - 3 and current_date + 45), '[]'),
   'notices', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'body', n.body, 'created', n.created) order by n.created desc)
     from public.notices n join public.notice_recipients r on r.notice_id = n.id where r.student_id = s.id and n.created > now() - interval '45 days'), '[]'),
   'fee', fee,
   'timetables', coalesce((select jsonb_agg(jsonb_build_object('kind', t.kind, 'weekday', t.weekday, 'date_from', t.date_from, 'date_to', t.date_to, 'title', t.title, 'slots', t.slots, 'cell', t.cells -> s.class_id::text, 'updated_at', t.updated_at))
     from public.timetables t where t.academy_id = s.academy_id and s.class_id is not null and t.cells ? s.class_id::text and (t.kind = 'weekly' or t.date_to >= current_date - 1)), '[]'),
   'comment', coalesce((select body from public.parent_comments where student_id = s.id), '')));
 end loop;
 return jsonb_build_object('label', pc.label, 'academy', (select name from public.academies where id = pc.academy_id), 'kids', kids);
end $$;
create or replace function public.parent_push_public_key(p_code text)
returns text language plpgsql security definer set search_path = public as $$
begin
 if not exists (select 1 from public.parent_codes where code = upper(replace(btrim(coalesce(p_code, '')), '-', ''))) then raise exception 'bad_code'; end if;
 return (select public_key from public.drill_push_config where id = 1);
end $$;
create or replace function public.parent_push_subscribe(p_code text, p_subscription jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare c text := upper(replace(btrim(coalesce(p_code, '')), '-', '')); ep text := p_subscription->>'endpoint'; pk text := p_subscription->'keys'->>'p256dh'; ak text := p_subscription->'keys'->>'auth'; result uuid;
begin
 if not exists (select 1 from public.parent_codes where code = c) then raise exception 'bad_code'; end if;
 if ep is null or ep !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/' or char_length(ep) >= 2048
  or pk is null or pk !~ '^[A-Za-z0-9_-]{87}$' or ak is null or ak !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'invalid_subscription'; end if;
 if (select count(*) from public.parent_push_subscriptions where code = c and active) >= 10 and not exists (select 1 from public.parent_push_subscriptions where code = c and endpoint = ep) then raise exception 'too_many_devices'; end if;
 insert into public.parent_push_subscriptions (code, endpoint, p256dh, auth) values (c, ep, pk, ak)
 on conflict (code, endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, active = true, updated_at = now() returning id into result;
 return result;
end $$;
create or replace function public.parent_push_unsubscribe(p_code text, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
 update public.parent_push_subscriptions set active = false, updated_at = now() where code = upper(replace(btrim(coalesce(p_code, '')), '-', '')) and endpoint = p_endpoint;
end $$;

-- ⑨ 원장·선생님 함수 (학원을 받는다) ------------------------------------------------
-- 내 학원 목록: 운영자는 모든 학원
create or replace function public.my_academies()
returns jsonb language sql stable security definer set search_path = public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'code', a.code, 'active', a.active,
   'role', coalesce(m.role, case when public.is_admin() then 'owner' end), 'member', m.user_id is not null, 'name_me', m.name, 'alias', m.alias) order by a.created), '[]'::jsonb)
 from public.academies a left join public.academy_members m on m.academy_id = a.id and m.user_id = auth.uid()
 where m.user_id is not null or public.is_admin();
$$;
create or replace function public.admin_open(p_academy uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
 if not public.is_member(p_academy) then raise exception 'not_member'; end if;
 if public.is_admin() and not exists (select 1 from public.academy_members where academy_id = p_academy and user_id = auth.uid()) then
  insert into public.admin_access_log (user_id, academy_id) values (auth.uid(), p_academy);
 end if;
end $$;
-- 운영자: 학원 만들기 (원장은 먼저 앱에서 계정을 만들어 두어야 한다)
create or replace function public.admin_create_academy(p_name text, p_code text, p_owner_email text)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare aid uuid; uid uuid;
begin
 if not public.is_admin() then raise exception 'not_admin'; end if;
 select id into uid from auth.users where lower(email) = lower(btrim(p_owner_email));
 if uid is null then raise exception 'no_user'; end if;
 insert into public.academies (name, code) values (btrim(p_name), btrim(p_code)) returning id into aid;
 insert into public.academy_members (academy_id, user_id, role) values (aid, uid, 'owner');
 return aid;
end $$;
-- 원장: 선생님 추가·삭제·목록
create or replace function public.member_add(p_academy uuid, p_email text, p_role text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare uid uuid;
begin
 if not public.is_owner(p_academy) then raise exception 'not_owner'; end if;
 if p_role not in ('owner','teacher') then raise exception 'bad_role'; end if;
 select id into uid from auth.users where lower(email) = lower(btrim(p_email));
 if uid is null then raise exception 'no_user'; end if;
 insert into public.academy_members (academy_id, user_id, role) values (p_academy, uid, p_role) on conflict (academy_id, user_id) do update set role = excluded.role;
end $$;
create or replace function public.member_remove(p_academy uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
 if not public.is_owner(p_academy) then raise exception 'not_owner'; end if;
 if (select role from public.academy_members where academy_id = p_academy and user_id = p_user) = 'owner'
  and (select count(*) from public.academy_members where academy_id = p_academy and role = 'owner') <= 1 then raise exception 'last_owner'; end if;
 delete from public.academy_members where academy_id = p_academy and user_id = p_user;
end $$;
create or replace function public.member_list(p_academy uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
 if not public.is_member(p_academy) then raise exception 'not_member'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'role', m.role, 'name', m.name, 'alias', m.alias,
   'email', case when public.is_owner(p_academy) or m.user_id = auth.uid() then u.email end) order by m.role desc, m.created)
  from public.academy_members m join auth.users u on u.id = m.user_id where m.academy_id = p_academy), '[]'::jsonb);
end $$;
-- 내 이름·시간표 이름(별칭) 바꾸기
create or replace function public.member_set_me(p_academy uuid, p_name text, p_alias text)
returns void language plpgsql security definer set search_path = public as $$
begin
 if not public.is_member(p_academy) then raise exception 'not_member'; end if;
 if public.is_admin() and not exists (select 1 from public.academy_members where academy_id = p_academy and user_id = auth.uid()) then return; end if;
 update public.academy_members set name = nullif(btrim(coalesce(p_name, '')), ''), alias = left(btrim(coalesce(p_alias, '')), 40)
 where academy_id = p_academy and user_id = auth.uid();
end $$;

create or replace function public.student_approve(p_id uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare aid uuid := (select academy_id from public.students where id = p_id);
begin
 if aid is null or not public.is_member(aid) then raise exception 'not_member'; end if;
 if p_ok then update public.students set approved = true where id = p_id;
 else delete from public.students where id = p_id and not approved; end if;
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
  last_seen = greatest(a.last_seen, b.last_seen), approved = true, class_id = coalesce(b.class_id, a.class_id), school = coalesce(b.school, a.school)
 where id = b.id;
 update public.questions set student_id = b.id where student_id = a.id;
 insert into public.drill_group_members (group_id, student_id) select group_id, b.id from public.drill_group_members where student_id = a.id on conflict do nothing;
 insert into public.drill_event_recipients (event_id, student_id, read_at) select event_id, b.id, read_at from public.drill_event_recipients where student_id = a.id on conflict do nothing;
 delete from public.drill_student_sessions where student_id = a.id;
 update public.drill_push_subscriptions set student_id = b.id where student_id = a.id;
 insert into public.flash_states select b.id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at from public.flash_states where student_id = a.id on conflict do nothing;
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

-- 일정(선생님)
create or replace function public.drill_schedule_admin(p_academy uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gs jsonb; es jsonb; rd jsonb;
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'members', coalesce((select jsonb_agg(m.student_id) from public.drill_group_members m where m.group_id = g.id), '[]')) order by g.name), '[]')
 into gs from public.drill_groups g where g.academy_id = p_academy;
 select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('recipients', coalesce((select jsonb_agg(r.student_id) from public.drill_event_recipients r where r.event_id = e.id), '[]')) order by e.created), '[]')
 into es from public.drill_events e where e.academy_id = p_academy;
 select coalesce(jsonb_object_agg(student_id::text, ids), '{}') into rd from
  (select r.student_id, jsonb_agg(r.event_id) ids from public.drill_event_recipients r join public.drill_events e on e.id = r.event_id
   where e.academy_id = p_academy and r.read_at is not null group by r.student_id) a;
 return jsonb_build_object('groups', gs, 'events', es, 'reads', rd);
end $$;
create or replace function public.drill_group_save(p_academy uuid, p_id uuid, p_name text, p_members uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 30 then raise exception 'invalid_name'; end if;
 if exists (select 1 from unnest(p_members) x where not exists (select 1 from public.students where id = x and academy_id = p_academy)) then raise exception 'invalid_student'; end if;
 if p_id is null then insert into public.drill_groups (academy_id, name) values (p_academy, btrim(p_name)) returning id into gid;
 else update public.drill_groups set name = btrim(p_name) where id = p_id and academy_id = p_academy returning id into gid;
  if gid is null then raise exception 'no_group'; end if; end if;
 delete from public.drill_group_members where group_id = gid;
 insert into public.drill_group_members select gid, x from (select distinct unnest(p_members) x) a;
 return gid;
end $$;
create or replace function public.drill_schedule_publish(p_academy uuid, p_rows jsonb, p_type text, p_groups uuid[], p_students uuid[], p_all boolean, p_attachment jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare recipients uuid[]; labels jsonb; item jsonb; eid uuid; n int := 0; eids uuid[] := '{}';
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 if p_type is null or p_type not in ('exam','academy') or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) not between 1 and 100 then raise exception 'invalid_events'; end if;
 if exists (select 1 from unnest(p_groups) x where not exists (select 1 from public.drill_groups where id = x and academy_id = p_academy)) then raise exception 'invalid_group'; end if;
 if exists (select 1 from unnest(p_students) x where not exists (select 1 from public.students where id = x and academy_id = p_academy)) then raise exception 'invalid_student'; end if;
 select array_agg(distinct s.id) into recipients from public.students s where s.academy_id = p_academy and s.approved and (coalesce(p_all, false) or s.id = any (p_students)
  or exists (select 1 from public.drill_group_members m where m.student_id = s.id and m.group_id = any (p_groups)));
 if coalesce(cardinality(recipients), 0) = 0 then raise exception 'no_recipients'; end if;
 select coalesce(jsonb_agg(label), '[]') into labels from
  (select '전체 학생'::text label where coalesce(p_all, false)
   union all select name from public.drill_groups where id = any (p_groups)
   union all select nick || ' · ' || grade from public.students where id = any (p_students)) a;
 for item in select value from jsonb_array_elements(p_rows) loop
  insert into public.drill_events (academy_id, type, title, date, memo, targets, attachment, created_by)
  values (p_academy, p_type, btrim(item->>'title'), (item->>'date')::date, coalesce(item->>'memo', ''), labels, p_attachment, auth.uid()) returning id into eid;
  insert into public.drill_event_recipients (event_id, student_id) select eid, unnest(recipients); n := n + 1; eids := array_append(eids, eid);
 end loop;
 return jsonb_build_object('count', n, 'recipients', cardinality(recipients), 'event_ids', eids);
end $$;

-- 카드 현황(선생님)
create or replace function public.flash_admin_stats(p_academy uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 return jsonb_build_object(
  'students', coalesce((select jsonb_object_agg(s.id, jsonb_build_object(
    'due', (select count(*) from public.flash_states f join public.flash_cards c on c.id = f.card_id join public.flash_decks d on d.id = c.deck_id
            where f.student_id = s.id and f.due <= now() and s.grade = any (d.grades)),
    'started', (select count(*) from public.flash_states f where f.student_id = s.id),
    'reviews30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.reviewed_at > now() - interval '30 days'),
    'review30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'review' and l.reviewed_at > now() - interval '30 days'),
    'kept30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'review' and l.rating > 1 and l.reviewed_at > now() - interval '30 days'),
    'last', (select max(l.reviewed_at) from public.flash_logs l where l.student_id = s.id)))
   from public.students s where s.academy_id = p_academy), '{}'::jsonb),
  'cards', coalesce((select jsonb_agg(jsonb_build_object('card_id', x.card_id, 'n', x.n, 'again', x.again) order by x.again::float / x.n desc)
   from (select l.card_id, count(*) n, count(*) filter (where l.rating = 1) again from public.flash_logs l join public.flash_cards c on c.id = l.card_id
         where c.academy_id = p_academy and l.reviewed_at > now() - interval '30 days' group by l.card_id having count(*) >= 3) x), '[]'::jsonb));
end $$;

-- 숙제 내기(선생님)
create or replace function public.hw_publish(p_academy uuid, p_title text, p_due date, p_memo text, p_link jsonb, p_targets jsonb, p_students uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare hid uuid; n int;
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 if p_students is null or cardinality(p_students) = 0 then raise exception 'no_recipients'; end if;
 if exists (select 1 from unnest(p_students) x where not exists (select 1 from public.students where id = x and academy_id = p_academy)) then raise exception 'invalid_student'; end if;
 insert into public.drill_homework (academy_id, title, due, memo, link, targets) values (p_academy, btrim(p_title), p_due, coalesce(p_memo, ''), p_link, coalesce(p_targets, '[]'::jsonb)) returning id into hid;
 insert into public.drill_homework_recipients (homework_id, student_id, academy_id) select hid, x, p_academy from (select distinct unnest(p_students) x) a;
 get diagnostics n = row_count;
 return jsonb_build_object('id', hid, 'recipients', n);
end $$;

-- 알림장 쓰기(원장·선생님): 받을 학생을 정하면 그 학부모에게 간다
create or replace function public.notice_publish(p_academy uuid, p_title text, p_body text, p_targets jsonb, p_students uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare nid uuid; n int;
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 if p_students is null or cardinality(p_students) = 0 then raise exception 'no_recipients'; end if;
 if exists (select 1 from unnest(p_students) x where not exists (select 1 from public.students where id = x and academy_id = p_academy)) then raise exception 'invalid_student'; end if;
 insert into public.notices (academy_id, title, body, targets, created_by) values (p_academy, btrim(p_title), coalesce(p_body, ''), coalesce(p_targets, '[]'::jsonb), auth.uid()) returning id into nid;
 insert into public.notice_recipients (notice_id, student_id, academy_id) select nid, x, p_academy from (select distinct unnest(p_students) x) a;
 get diagnostics n = row_count;
 return jsonb_build_object('id', nid, 'recipients', n);
end $$;

-- 학원비: 이번 달 청구 한꺼번에 만들기 (학생별 기본 금액·납부일 기준, 이미 있는 달은 건너뜀)
create or replace function public.fee_generate(p_academy uuid, p_month text)
returns int language plpgsql security definer set search_path = public as $$
declare n int; first date := to_date(p_month || '-01', 'YYYY-MM-DD');
begin
 if not public.is_owner(p_academy) then raise exception 'not_owner'; end if;
 if p_month !~ '^[0-9]{4}-[0-9]{2}$' then raise exception 'bad_month'; end if;
 insert into public.fees (academy_id, student_id, month, amount, due)
 select p_academy, s.id, p_month, c.fee_amount,
  first + (least(coalesce(c.fee_day, 1), extract(day from (first + interval '1 month - 1 day'))::int) - 1)
 from public.students s join public.student_contacts c on c.student_id = s.id
 where s.academy_id = p_academy and s.approved and c.fee_amount is not null
 on conflict (student_id, month) do nothing;
 get diagnostics n = row_count; return n;
end $$;

-- 알림 중복 방지 (푸시 서버가 쓴다)
create or replace function public.push_claim(p_message text, p_kind text, p_sub uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare claimed int;
begin
 insert into public.push_sent (message, sub_kind, sub_id, status) values (p_message, p_kind, p_sub, 'sending')
 on conflict (message, sub_kind, sub_id) do update set status = 'sending', updated_at = now()
 where push_sent.status = 'failed' or (push_sent.status = 'sending' and push_sent.updated_at < now() - interval '2 minutes');
 get diagnostics claimed = row_count; return claimed = 1;
end $$;

-- ⑩ 실행 권한 ---------------------------------------------------------------------
do $$
declare f text;
begin
 foreach f in array array[
  'student_enter(text,text,text)','student_signup(text,text,text)','student_save(text,uuid,jsonb,jsonb)','qna_list(text,uuid)','qna_post(text,uuid,text,text)',
  'drill_schedule_student(uuid)','drill_schedule_read(uuid,uuid[])','flash_student_load(uuid,timestamptz)','flash_review(uuid,uuid,uuid,int,text,int,int,jsonb)',
  'hw_student_list(uuid)','hw_student_done(uuid,uuid,boolean)','tt_student(uuid)','drill_push_public_key(uuid)','drill_push_subscribe(uuid,jsonb)','drill_push_unsubscribe(uuid,text)',
  'parent_view(text)','parent_push_public_key(text)','parent_push_subscribe(text,jsonb)','parent_push_unsubscribe(text,text)'] loop
  execute format('revoke all on function public.%s from public', f);
  execute format('grant execute on function public.%s to anon, authenticated', f);
 end loop;
 foreach f in array array[
  'my_academies()','admin_open(uuid)','admin_create_academy(text,text,text)','member_add(uuid,text,text)','member_remove(uuid,uuid)','member_list(uuid)','member_set_me(uuid,text,text)',
  'student_approve(uuid,boolean)','student_merge(uuid,uuid)','drill_schedule_admin(uuid)','drill_group_save(uuid,uuid,text,uuid[])',
  'drill_schedule_publish(uuid,jsonb,text,uuid[],uuid[],boolean,jsonb)','flash_admin_stats(uuid)','hw_publish(uuid,text,date,text,jsonb,jsonb,uuid[])',
  'notice_publish(uuid,text,text,jsonb,uuid[])','fee_generate(uuid,text)'] loop
  execute format('revoke all on function public.%s from public', f);
  execute format('grant execute on function public.%s to authenticated', f);
 end loop;
 execute 'revoke all on function public.push_claim(text,text,uuid) from public, anon, authenticated';
 execute 'grant execute on function public.push_claim(text,text,uuid) to service_role';
end $$;
commit;
