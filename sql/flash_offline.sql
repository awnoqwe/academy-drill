-- 플래시카드 오프라인 기록: 나중에 올라온 복습도 "푼 시각"으로 남긴다 (선생님 화면의 하루 복습 수·잔디가 맞게 찍힘).
-- Supabase SQL Editor에서 한 번 실행. 실행 전에도 앱은 그대로 동작하고, 그때는 올라온 시각으로 기록된다.
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
