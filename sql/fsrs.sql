-- FSRS로 바꾸기 (2026-11-05)
-- apera_v2.sql을 이미 실행한 프로젝트에 이 파일만 추가로 실행하면 된다. 다시 실행해도 안전하다.
-- 하는 일: flash_states에 FSRS 기억 상태 칸 3개(stability·difficulty·last_review)를 더하고,
--          카드 불러오기·복습 저장·학생 합치기 함수가 그 칸을 읽고 쓰게 한다. 기존 기록은 그대로 둔다.

alter table public.flash_states add column if not exists stability real, add column if not exists difficulty real, add column if not exists last_review timestamptz;

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
  'states', coalesce((select jsonb_agg(jsonb_build_object('card_id', f.card_id, 'queue', f.queue, 'step', f.step, 'ivl', f.ivl, 'ease', f.ease, 'reps', f.reps, 'lapses', f.lapses, 'due', f.due,
    'stability', f.stability, 'difficulty', f.difficulty, 'last_review', f.last_review))
   from public.flash_states f where f.student_id = sid), '[]'::jsonb),
  'new_today', coalesce((select jsonb_agg(l.card_id) from public.flash_logs l where l.student_id = sid and l.kind = 'new' and l.reviewed_at >= p_since), '[]'::jsonb));
end $$;

create or replace function public.flash_review(p_token uuid, p_log uuid, p_card uuid, p_rating int, p_kind text, p_ivl_before int, p_elapsed int, p_state jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sid uuid; n int; at_ts timestamptz;
begin
 select student_id into sid from public.drill_student_sessions where token = p_token and expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 if not exists (select 1 from public.flash_cards c join public.flash_decks d on d.id = c.deck_id join public.students st on st.id = sid
   where c.id = p_card and d.academy_id = st.academy_id and st.grade = any (d.grades)) then raise exception 'no_card'; end if;
 -- 오프라인에서 푼 카드는 나중에 한꺼번에 올라온다: 푼 시각(p_state.at)으로 기록한다(미래·60일 넘게 지난 값은 잘라 낸다)
 begin at_ts := (p_state->>'at')::timestamptz; exception when others then at_ts := null; end;
 at_ts := greatest(least(coalesce(at_ts, now()), now()), now() - interval '60 days');
 insert into public.flash_logs (id, student_id, card_id, rating, kind, ivl_before, ivl_after, ease_after, elapsed_ms, reviewed_at)
 values (p_log, sid, p_card, p_rating, p_kind, p_ivl_before, (p_state->>'log_ivl')::int, (p_state->>'ease')::int, least(greatest(coalesce(p_elapsed, 0), 0), 3600000), at_ts)
 on conflict (id) do nothing;
 get diagnostics n = row_count; if n = 0 then return; end if;
 insert into public.flash_states (student_id, card_id, queue, step, ivl, ease, reps, lapses, due, updated_at, stability, difficulty, last_review)
 values (sid, p_card, p_state->>'queue', (p_state->>'step')::int, (p_state->>'ivl')::int, (p_state->>'ease')::int, (p_state->>'reps')::int, (p_state->>'lapses')::int, (p_state->>'due')::timestamptz, now(),
  (p_state->>'stability')::real, (p_state->>'difficulty')::real, (p_state->>'last_review')::timestamptz)
 on conflict (student_id, card_id) do update set queue = excluded.queue, step = excluded.step, ivl = excluded.ivl, ease = excluded.ease,
  reps = excluded.reps, lapses = excluded.lapses, due = excluded.due, updated_at = now(),
  stability = excluded.stability, difficulty = excluded.difficulty, last_review = excluded.last_review;
 update public.students set last_seen = now() where id = sid;
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
