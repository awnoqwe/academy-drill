-- Web Push 구독·키·중복 방지. 기존 일정과 학생 데이터 보존.
begin;
create table if not exists public.drill_push_config(id int primary key check(id=1), public_key text not null, private_key text not null);
create table if not exists public.drill_push_subscriptions(
 id uuid primary key default gen_random_uuid(), student_id uuid not null references public.students on delete cascade,
 endpoint text not null unique check(char_length(endpoint)<2048), p256dh text not null, auth text not null,
 active boolean not null default true, updated_at timestamptz not null default now());
create index if not exists drill_push_student on public.drill_push_subscriptions(student_id) where active;
create table if not exists public.drill_push_deliveries(
 event_id uuid references public.drill_events on delete cascade, subscription_id uuid references public.drill_push_subscriptions on delete cascade,
 status text not null check(status in ('sending','sent','failed','expired')), updated_at timestamptz not null default now(), primary key(event_id,subscription_id));
alter table public.drill_push_config enable row level security;
alter table public.drill_push_subscriptions enable row level security;
alter table public.drill_push_deliveries enable row level security;
revoke all on public.drill_push_config,public.drill_push_subscriptions,public.drill_push_deliveries from anon,authenticated;
grant all on public.drill_push_config,public.drill_push_subscriptions,public.drill_push_deliveries to service_role;

create or replace function public.drill_push_public_key(p_token uuid)
returns text language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.drill_student_sessions where token=p_token and expires_at>now()) then raise exception 'session_expired'; end if;
 return (select public_key from public.drill_push_config where id=1);
end $$;
create or replace function public.drill_push_subscribe(p_token uuid,p_subscription jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare sid uuid; ep text:=p_subscription->>'endpoint'; pk text:=p_subscription->'keys'->>'p256dh'; ak text:=p_subscription->'keys'->>'auth'; result uuid;
begin
 select student_id into sid from public.drill_student_sessions where token=p_token and expires_at>now();
 if sid is null then raise exception 'session_expired'; end if;
 if ep is null or ep !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/' or char_length(ep)>=2048
 or pk is null or pk !~ '^[A-Za-z0-9_-]{87}$' or ak is null or ak !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'invalid_subscription'; end if;
 if not exists(select 1 from public.drill_push_subscriptions where endpoint=ep) and (select count(*) from public.drill_push_subscriptions where student_id=sid and active)>=10 then raise exception 'too_many_devices'; end if;
 insert into public.drill_push_subscriptions(student_id,endpoint,p256dh,auth) values(sid,ep,pk,ak)
 on conflict(endpoint) do update set student_id=excluded.student_id,p256dh=excluded.p256dh,auth=excluded.auth,active=true,updated_at=now() returning id into result;
 return result;
end $$;
create or replace function public.drill_push_unsubscribe(p_token uuid,p_endpoint text)
returns void language plpgsql security definer set search_path=public as $$
declare sid uuid;
begin
 select student_id into sid from public.drill_student_sessions where token=p_token and expires_at>now();
 if sid is null then raise exception 'session_expired'; end if;
 update public.drill_push_subscriptions set active=false,updated_at=now() where student_id=sid and endpoint=p_endpoint;
end $$;
create or replace function public.drill_push_claim(p_event uuid,p_subscription uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare claimed int;
begin
 insert into public.drill_push_deliveries(event_id,subscription_id,status) values(p_event,p_subscription,'sending')
 on conflict(event_id,subscription_id) do update set status='sending',updated_at=now()
 where drill_push_deliveries.status='failed' or (drill_push_deliveries.status='sending' and drill_push_deliveries.updated_at<now()-interval '2 minutes');
 get diagnostics claimed=row_count; return claimed=1;
end $$;
revoke all on function public.drill_push_public_key(uuid),public.drill_push_subscribe(uuid,jsonb),public.drill_push_unsubscribe(uuid,text),public.drill_push_claim(uuid,uuid) from public;
grant execute on function public.drill_push_public_key(uuid),public.drill_push_subscribe(uuid,jsonb),public.drill_push_unsubscribe(uuid,text) to anon,authenticated;
revoke all on function public.drill_push_claim(uuid,uuid) from anon,authenticated;
grant execute on function public.drill_push_claim(uuid,uuid) to service_role;

create or replace function public.drill_schedule_publish(p_rows jsonb,p_type text,p_groups uuid[],p_students uuid[],p_all boolean,p_attachment jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare recipients uuid[]; labels jsonb; item jsonb; eid uuid; n int:=0; eids uuid[]:='{}';
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
 insert into public.drill_event_recipients(event_id,student_id) select eid,unnest(recipients); n:=n+1; eids:=array_append(eids,eid);
 end loop;
 return jsonb_build_object('count',n,'recipients',cardinality(recipients),'event_ids',eids);
end $$;

commit;
