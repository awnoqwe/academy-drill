-- 일정·그룹·앱 내 알림 추가. 기존 학생·문제·풀이 기록은 삭제하지 않습니다.
-- Supabase > SQL Editor에서 전체를 한 번 실행하세요. 재실행 가능합니다.
begin;
create table if not exists public.drill_groups (
 id uuid primary key default gen_random_uuid(), name text not null unique check(char_length(btrim(name)) between 1 and 30)
);
create table if not exists public.drill_group_members (
 group_id uuid references public.drill_groups on delete cascade,
 student_id uuid references public.students on delete cascade,
 primary key(group_id,student_id)
);
create table if not exists public.drill_events (
 id uuid primary key default gen_random_uuid(), type text not null check(type in ('exam','academy')),
 title text not null check(char_length(btrim(title)) between 1 and 100), date date not null,
 memo text not null default '' check(char_length(memo)<=5000), targets jsonb not null default '[]',
 attachment jsonb check(attachment is null or (octet_length(attachment::text)<=1500000 and attachment->>'data' ~ '^data:(application/pdf|image/png|image/jpeg);base64,' and char_length(attachment->>'name') between 1 and 255)),
 created timestamptz not null default now(), created_by uuid references auth.users
);
create table if not exists public.drill_event_recipients (
 event_id uuid references public.drill_events on delete cascade,
 student_id uuid references public.students on delete cascade, read_at timestamptz,
 primary key(event_id,student_id)
);
create index if not exists drill_recipient_student on public.drill_event_recipients(student_id);
create table if not exists public.drill_student_sessions (
 token uuid primary key default gen_random_uuid(), student_id uuid not null references public.students on delete cascade,
 expires_at timestamptz not null default now()+interval '7 days'
);
create index if not exists drill_session_student on public.drill_student_sessions(student_id);
alter table public.drill_groups enable row level security;
alter table public.drill_group_members enable row level security;
alter table public.drill_events enable row level security;
alter table public.drill_event_recipients enable row level security;
alter table public.drill_student_sessions enable row level security;
revoke all on public.drill_groups,public.drill_group_members,public.drill_events,public.drill_event_recipients,public.drill_student_sessions from anon,authenticated;

-- 기존 입장 계약을 유지하면서 일정 전용 세션을 추가합니다.
create or replace function public.student_enter(p_code text,p_nick text,p_grade text)
returns json language plpgsql security definer set search_path=public as $$
declare s public.students; t uuid;
begin
 if not exists(select 1 from public.settings where entry_code=p_code) then raise exception 'bad_code'; end if;
 insert into public.students(nick,grade) values(btrim(p_nick),p_grade)
 on conflict(grade,nick) do update set last_seen=now() returning * into s;
 delete from public.drill_student_sessions where student_id=s.id and expires_at<now();
 insert into public.drill_student_sessions(student_id) values(s.id) returning token into t;
 return json_build_object('student',json_build_object('id',s.id,'nick',s.nick,'grade',s.grade,'cards',s.cards,'queue',s.queue,'last_seen',s.last_seen),
 'cards',coalesce((select json_agg(c order by c.sort,c.id) from public.cards c where p_grade=any(c.grades)),'[]'::json),'schedule_token',t);
end $$;

create or replace function public.drill_schedule_student(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare sid uuid; es jsonb; rd jsonb;
begin
 select student_id into sid from public.drill_student_sessions where token=p_token and expires_at>now();
 if sid is null then raise exception 'session_expired'; end if;
 select coalesce(jsonb_agg(x order by x->>'date'),'[]') into es from
 (select jsonb_build_object('id',e.id,'type',e.type,'title',e.title,'date',e.date,'memo',e.memo,'attachment',e.attachment,'created',e.created,'targets','[]'::jsonb,'recipients',jsonb_build_array(sid)) x
 from public.drill_events e join public.drill_event_recipients r on r.event_id=e.id where r.student_id=sid) a;
 select coalesce(jsonb_agg(event_id),'[]') into rd from public.drill_event_recipients where student_id=sid and read_at is not null;
 return jsonb_build_object('events',es,'groups','[]'::jsonb,'reads',jsonb_build_object(sid::text,rd));
end $$;

create or replace function public.drill_schedule_read(p_token uuid,p_events uuid[])
returns void language plpgsql security definer set search_path=public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token=p_token and expires_at>now();
 if sid is null then raise exception 'session_expired'; end if;
 update public.drill_event_recipients set read_at=coalesce(read_at,now()) where student_id=sid and event_id=any(p_events);
end $$;

create or replace function public.drill_schedule_admin()
returns jsonb language plpgsql security definer set search_path=public as $$
declare gs jsonb; es jsonb; rd jsonb;
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'members',coalesce((select jsonb_agg(m.student_id) from public.drill_group_members m where m.group_id=g.id),'[]')) order by g.name),'[]') into gs from public.drill_groups g;
 select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('recipients',coalesce((select jsonb_agg(r.student_id) from public.drill_event_recipients r where r.event_id=e.id),'[]')) order by e.created),'[]') into es from public.drill_events e;
 select coalesce(jsonb_object_agg(student_id::text,ids),'{}') into rd from
 (select student_id,jsonb_agg(event_id) ids from public.drill_event_recipients where read_at is not null group by student_id) a;
 return jsonb_build_object('groups',gs,'events',es,'reads',rd);
end $$;

create or replace function public.drill_group_save(p_id uuid,p_name text,p_members uuid[])
returns uuid language plpgsql security definer set search_path=public as $$
declare gid uuid;
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 if char_length(btrim(p_name)) not between 1 and 30 or p_name is null then raise exception 'invalid_name'; end if;
 if exists(select 1 from unnest(p_members) x where not exists(select 1 from public.students where id=x)) then raise exception 'invalid_student'; end if;
 if p_id is null then insert into public.drill_groups(name) values(btrim(p_name)) returning id into gid;
 else update public.drill_groups set name=btrim(p_name) where id=p_id returning id into gid;
 if gid is null then raise exception 'no_group'; end if; end if;
 delete from public.drill_group_members where group_id=gid;
 insert into public.drill_group_members select gid,x from (select distinct unnest(p_members) x) a;
 return gid;
end $$;

create or replace function public.drill_schedule_publish(p_rows jsonb,p_type text,p_groups uuid[],p_students uuid[],p_all boolean,p_attachment jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare recipients uuid[]; labels jsonb; item jsonb; eid uuid; n int:=0;
begin
 if not public.is_teacher() then raise exception 'not_teacher'; end if;
 if p_type is null or p_type not in ('exam','academy') or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 100 then raise exception 'invalid_events'; end if;
 if exists(select 1 from unnest(p_groups) x where not exists(select 1 from public.drill_groups where id=x)) then raise exception 'invalid_group'; end if;
 if exists(select 1 from unnest(p_students) x where not exists(select 1 from public.students where id=x)) then raise exception 'invalid_student'; end if;
 select array_agg(distinct s.id) into recipients from public.students s where coalesce(p_all,false) or s.id=any(p_students) or exists(select 1 from public.drill_group_members m where m.student_id=s.id and m.group_id=any(p_groups));
 if coalesce(cardinality(recipients),0)=0 then raise exception 'no_recipients'; end if;
 select coalesce(jsonb_agg(label),'[]') into labels from
 (select '전체 학생'::text label where coalesce(p_all,false)
 union all select name from public.drill_groups where id=any(p_groups)
 union all select nick||' · '||grade from public.students where id=any(p_students)) a;
 for item in select value from jsonb_array_elements(p_rows) loop
 insert into public.drill_events(type,title,date,memo,targets,attachment,created_by)
 values(p_type,btrim(item->>'title'),(item->>'date')::date,coalesce(item->>'memo',''),labels,p_attachment,auth.uid()) returning id into eid;
 insert into public.drill_event_recipients(event_id,student_id) select eid,unnest(recipients); n:=n+1;
 end loop;
 return jsonb_build_object('count',n,'recipients',cardinality(recipients));
end $$;
revoke all on function public.drill_schedule_student(uuid),public.drill_schedule_read(uuid,uuid[]),public.drill_schedule_admin(),public.drill_group_save(uuid,text,uuid[]),public.drill_schedule_publish(jsonb,text,uuid[],uuid[],boolean,jsonb) from public;
grant execute on function public.drill_schedule_student(uuid),public.drill_schedule_read(uuid,uuid[]) to anon,authenticated;
grant execute on function public.drill_schedule_admin(),public.drill_group_save(uuid,text,uuid[]),public.drill_schedule_publish(jsonb,text,uuid[],uuid[],boolean,jsonb) to authenticated;
-- student_enter의 기존 실행 권한은 유지됩니다.
commit;
