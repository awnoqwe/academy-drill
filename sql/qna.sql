-- 학원 트리거 드릴: Q&A 게시판 추가
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여 넣고 Run 을 누르세요. 한 번만 실행하면 됩니다.

-- 질문 (학년 통합). 답변은 선생님만 단다.
create table if not exists public.questions (
  id bigint generated always as identity primary key,
  student_id uuid not null references public.students (id) on delete cascade,
  card_id text references public.cards (id) on delete set null,
  body text not null check (char_length(body) between 2 and 500),
  answer text check (answer is null or char_length(answer) <= 2000),
  answered_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists questions_created_idx on public.questions (created_at desc);

alter table public.questions enable row level security;

-- 선생님: 전체 보기, 답변 달기, 지우기
drop policy if exists "teacher reads questions" on public.questions;
create policy "teacher reads questions" on public.questions for select to authenticated using (public.is_teacher());
drop policy if exists "teacher answers questions" on public.questions;
create policy "teacher answers questions" on public.questions for update to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "teacher deletes questions" on public.questions;
create policy "teacher deletes questions" on public.questions for delete to authenticated using (public.is_teacher());

-- 학생: 질문 목록 (모든 학년, 최근 200개)
create or replace function public.qna_list(p_code text, p_student uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.settings where entry_code = p_code) then
    raise exception 'bad_code';
  end if;
  return coalesce((
    select json_agg(x order by x.created_at desc) from (
      select q.id, q.body, q.answer, q.created_at, q.answered_at,
             s.nick, s.grade, c.tag as card_tag, c.unit as card_unit,
             (q.student_id = p_student) as mine
      from public.questions q
      join public.students s on s.id = q.student_id
      left join public.cards c on c.id = q.card_id
      order by q.created_at desc
      limit 200
    ) x
  ), '[]'::json);
end $$;

-- 학생: 질문 올리기 (하루 10개까지)
create or replace function public.qna_post(p_code text, p_student uuid, p_body text, p_card text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.settings where entry_code = p_code) then
    raise exception 'bad_code';
  end if;
  if not exists (select 1 from public.students where id = p_student) then
    raise exception 'no_student';
  end if;
  if (select count(*) from public.questions where student_id = p_student and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too_many';
  end if;
  insert into public.questions (student_id, card_id, body)
  values (p_student, (select id from public.cards where id = p_card), btrim(p_body));
end $$;

revoke all on function public.qna_list(text, uuid) from public;
revoke all on function public.qna_post(text, uuid, text, text) from public;
grant execute on function public.qna_list(text, uuid) to anon, authenticated;
grant execute on function public.qna_post(text, uuid, text, text) to anon, authenticated;
