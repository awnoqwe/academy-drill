-- ============================================================================
-- 아페라: 학생 카드 진행 현황 (선생님 학생 상세의 '플래시카드' 칸)
-- apera_v2.sql을 실행한 곳에서 이 파일만 한 번 더 실행하면 된다. 다시 실행해도 안전하다.
-- flash_admin_stats에 학생별로 아래 값을 더한다(기존 값은 그대로).
--   assigned  학년에 배정된 덱의 카드 수
--   seen      그중 한 번이라도 본 카드 수 (안 본 카드 = assigned - seen)
--   learn     배우는 중(처음 배우는 중 + 틀려서 다시 배우는 중)
--   young     복습 카드 중 간격 21일 미만
--   mature    복습 카드 중 간격 21일 이상 (안키의 '성숙' 기준)
--   today     오늘(서울 날짜) 넘긴 카드 수, today_new 그중 새 카드
-- ============================================================================
create or replace function public.flash_admin_stats(p_academy uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
 if not public.is_member(p_academy) then raise exception 'not_teacher'; end if;
 return jsonb_build_object(
  'students', coalesce((select jsonb_object_agg(s.id, jsonb_build_object(
    'due', (select count(*) from public.flash_states f join public.flash_cards c on c.id = f.card_id join public.flash_decks d on d.id = c.deck_id
            where f.student_id = s.id and f.due <= now() and s.grade = any (d.grades)),
    'started', (select count(*) from public.flash_states f where f.student_id = s.id),
    'assigned', (select count(*) from public.flash_cards c join public.flash_decks d on d.id = c.deck_id
                 where d.academy_id = s.academy_id and s.grade = any (d.grades)),
    'seen', m.seen, 'learn', m.learn, 'young', m.young, 'mature', m.mature,
    'today', (select count(*) from public.flash_logs l where l.student_id = s.id
              and l.reviewed_at >= ((now() at time zone 'Asia/Seoul')::date)::timestamp at time zone 'Asia/Seoul'),
    'today_new', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'new'
              and l.reviewed_at >= ((now() at time zone 'Asia/Seoul')::date)::timestamp at time zone 'Asia/Seoul'),
    'reviews30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.reviewed_at > now() - interval '30 days'),
    'review30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'review' and l.reviewed_at > now() - interval '30 days'),
    'kept30', (select count(*) from public.flash_logs l where l.student_id = s.id and l.kind = 'review' and l.rating > 1 and l.reviewed_at > now() - interval '30 days'),
    'last', (select max(l.reviewed_at) from public.flash_logs l where l.student_id = s.id)))
   from public.students s
   cross join lateral (select count(*) seen,
       count(*) filter (where f.queue <> 'review') learn,
       count(*) filter (where f.queue = 'review' and f.ivl < 21) young,
       count(*) filter (where f.queue = 'review' and f.ivl >= 21) mature
     from public.flash_states f join public.flash_cards c on c.id = f.card_id join public.flash_decks d on d.id = c.deck_id
     where f.student_id = s.id and d.academy_id = s.academy_id and s.grade = any (d.grades)) m
   where s.academy_id = p_academy), '{}'::jsonb),
  'cards', coalesce((select jsonb_agg(jsonb_build_object('card_id', x.card_id, 'n', x.n, 'again', x.again) order by x.again::float / x.n desc)
   from (select l.card_id, count(*) n, count(*) filter (where l.rating = 1) again from public.flash_logs l join public.flash_cards c on c.id = l.card_id
         where c.academy_id = p_academy and l.reviewed_at > now() - interval '30 days' group by l.card_id having count(*) >= 3) x), '[]'::jsonb));
end $$;
revoke all on function public.flash_admin_stats(uuid) from public, anon;
grant execute on function public.flash_admin_stats(uuid) to authenticated;
