-- ============================================================================
-- 아페라: 카드 구성(항목) 기능 — 안키처럼 카드를 항목(표제어·뜻풀이·예문…)으로 나눠 적는다.
-- apera_v2.sql을 이미 실행한 곳에서 이 파일만 한 번 더 실행하면 된다. 다시 실행해도 안전하다.
-- 기존 카드·학생 기록은 그대로다(예전 '앞면/뒷면' 카드는 fields가 비어 있고, 예전 모양 그대로 보인다).
-- 실행: Supabase > SQL Editor 에 전체를 붙여 넣고 Run.
-- ============================================================================
begin;
-- 덱의 fields: [{id, n:항목 이름, s:'f'|'b'(앞/뒤), k:'h'|'t'|'s'(크게/보통/작게), l:true면 항목 이름도 보임}]
alter table public.flash_decks add column if not exists fields jsonb check (fields is null or (jsonb_typeof(fields) = 'array' and jsonb_array_length(fields) between 2 and 10));
-- 카드의 fields: {항목id: 글}. front·back 글은 앱이 항목에서 만들어 같이 저장한다(중복 검사·쪽지 시험·학부모 화면용).
alter table public.flash_cards add column if not exists fields jsonb check (fields is null or (jsonb_typeof(fields) = 'object' and pg_column_size(fields) < 16000));

-- 학생이 카드를 받을 때 덱·카드의 fields도 같이 받는다
-- 카드(학생)
create or replace function public.flash_student_load(p_token uuid, p_since timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sid uuid; g text; aid uuid;
begin
 select s.student_id, st.grade, st.academy_id into sid, g, aid from public.drill_student_sessions s join public.students st on st.id = s.student_id
 where s.token = p_token and s.expires_at > now();
 if sid is null then raise exception 'session_expired'; end if;
 return jsonb_build_object(
  'decks', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'new_per_day', d.new_per_day, 'fields', d.fields) order by d.sort, d.created_at)
   from public.flash_decks d where d.academy_id = aid and g = any (d.grades)), '[]'::jsonb),
  'cards', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'deck_id', c.deck_id, 'front', c.front, 'back', c.back, 'links', c.links, 'fields', c.fields) order by d.sort, c.sort, c.created_at)
   from public.flash_cards c join public.flash_decks d on d.id = c.deck_id where d.academy_id = aid and g = any (d.grades)), '[]'::jsonb),
  'states', coalesce((select jsonb_agg(jsonb_build_object('card_id', f.card_id, 'queue', f.queue, 'step', f.step, 'ivl', f.ivl, 'ease', f.ease, 'reps', f.reps, 'lapses', f.lapses, 'due', f.due,
    'stability', f.stability, 'difficulty', f.difficulty, 'last_review', f.last_review))
   from public.flash_states f where f.student_id = sid), '[]'::jsonb),
  'new_today', coalesce((select jsonb_agg(l.card_id) from public.flash_logs l where l.student_id = sid and l.kind = 'new' and l.reviewed_at >= p_since), '[]'::jsonb));
end $$;
commit;
