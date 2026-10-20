-- 학원 트리거 드릴: DB 설정
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여 넣고 Run 을 누르세요. 한 번만 실행하면 됩니다.

-- ① 테이블 -------------------------------------------------------------

-- 입장 코드 (한 줄만 존재)
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  entry_code text not null check (char_length(entry_code) >= 4)
);
insert into public.settings (id, entry_code) values (1, '0000') on conflict (id) do nothing;

-- 선생님 (Supabase 로그인 계정 중 선생님으로 지정한 사람)
create table if not exists public.teachers (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- 학생: 닉네임 + 학년만 저장, 풀이 기록은 cards(JSON)
create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  nick text not null check (char_length(nick) between 2 and 12),
  grade text not null check (grade in ('중1','중2','중3','고1','고2','고3')),
  cards jsonb not null default '{}'::jsonb check (pg_column_size(cards) < 200000),
  queue jsonb not null default '[]'::jsonb check (pg_column_size(queue) < 20000),
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (grade, nick)
);

-- 문제
create table if not exists public.cards (
  id text primary key,
  grades text[] not null,
  unit text not null check (unit in ('read','lit','gram')),
  tag text not null,
  stem text not null,
  passage text not null default '',
  poem boolean not null default false,
  opts jsonb not null,
  ans jsonb not null,
  explain text not null default '',
  sort int not null default 0,
  created_at timestamptz not null default now()
);

-- ② 보안 규칙 (RLS) -----------------------------------------------------
-- 학생 앱(공개 키)은 테이블을 직접 읽거나 쓸 수 없다. 아래 ③의 함수로만 입장·저장한다.
-- 선생님으로 지정된 로그인 계정만 전체 기록과 문제를 직접 볼 수 있다.

alter table public.settings enable row level security;
alter table public.teachers enable row level security;
alter table public.students enable row level security;
alter table public.cards    enable row level security;

create or replace function public.is_teacher()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.teachers where user_id = auth.uid());
$$;

drop policy if exists "teacher reads self" on public.teachers;
create policy "teacher reads self" on public.teachers for select to authenticated using (user_id = auth.uid());

drop policy if exists "teacher reads students" on public.students;
create policy "teacher reads students" on public.students for select to authenticated using (public.is_teacher());
drop policy if exists "teacher deletes students" on public.students;
create policy "teacher deletes students" on public.students for delete to authenticated using (public.is_teacher());

drop policy if exists "teacher manages cards" on public.cards;
create policy "teacher manages cards" on public.cards for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

drop policy if exists "teacher manages settings" on public.settings;
create policy "teacher manages settings" on public.settings for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

-- ③ 학생용 함수 (입장 코드가 맞을 때만 동작) -----------------------------

-- 입장: 학생을 만들거나 불러오고, 그 학년 문제를 돌려준다
create or replace function public.student_enter(p_code text, p_nick text, p_grade text)
returns json language plpgsql security definer set search_path = public as $$
declare s public.students;
begin
  if not exists (select 1 from public.settings where entry_code = p_code) then
    raise exception 'bad_code';
  end if;
  insert into public.students (nick, grade) values (btrim(p_nick), p_grade)
  on conflict (grade, nick) do update set last_seen = now()
  returning * into s;
  return json_build_object(
    'student', json_build_object('id', s.id, 'nick', s.nick, 'grade', s.grade, 'cards', s.cards, 'queue', s.queue, 'last_seen', s.last_seen),
    'cards', coalesce((select json_agg(c order by c.sort, c.id) from public.cards c where p_grade = any (c.grades)), '[]'::json)
  );
end $$;

-- 저장: 풀이 기록을 덮어쓴다
create or replace function public.student_save(p_code text, p_id uuid, p_cards jsonb, p_queue jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.settings where entry_code = p_code) then
    raise exception 'bad_code';
  end if;
  update public.students set cards = p_cards, queue = p_queue, last_seen = now() where id = p_id;
end $$;

revoke all on function public.student_enter(text, text, text) from public;
revoke all on function public.student_save(text, uuid, jsonb, jsonb) from public;
grant execute on function public.student_enter(text, text, text) to anon, authenticated;
grant execute on function public.student_save(text, uuid, jsonb, jsonb) to anon, authenticated;

-- ④ 예시 문제 10개 (나중에 실제 문제로 교체) ------------------------------
insert into public.cards (id, grades, unit, tag, stem, passage, poem, opts, ans, explain, sort) values
  ('g1', array['중1','중2'], 'gram', '기본형·품사', '밑줄 친 말의 기본형과 품사를 쓰시오.', '동생이 사과를 [먹었다].', false, '["어간과 어미를 나눠 기본형(어간+-다) 찾기","품사 분류 기준(형태·기능·의미) 적용하기","문장 성분(주어·목적어·서술어) 나누기","음운 변동 규칙 적용하기"]'::jsonb, '[0,1]'::jsonb, '활용형에서 어간 ''먹-''을 떼어 기본형 ''먹다''를 찾고, 형태가 변하고 동작을 나타내므로 동사로 분류한다.', 0),
  ('g2', array['중3','고1','고2','고3'], 'gram', '음운 변동', '''국물''이 [궁물]로 발음되는 까닭을 설명하시오.', '', false, '["음운 변동의 종류(교체·탈락·첨가·축약) 구분하기","비음화 조건(받침 ㄱ·ㄷ·ㅂ 뒤에 ㄴ·ㅁ) 확인하기","사잇소리 현상 떠올리기","품사 분류 기준 적용하기"]'::jsonb, '[0,1]'::jsonb, '받침 ㄱ이 뒤의 비음 ㅁ 앞에서 비음 ㅇ으로 바뀌는 교체, 곧 비음화다.', 1),
  ('g3', array['중2','중3','고1'], 'gram', '홑문장·겹문장', '다음 문장이 홑문장인지 겹문장인지 판단하고, 그 근거를 쓰시오.', '나는 비가 오기를 기다렸다.', false, '["주어-서술어 관계가 몇 번 나오는지 세기","안긴문장의 종류(명사절·관형절·부사절 등) 확인하기","높임법 실현 방식 찾기","시제 선어말 어미 찾기"]'::jsonb, '[0,1]'::jsonb, '''비가 오-''와 ''나는 기다렸다'' 두 번의 주술 관계가 있고, ''비가 오기''가 명사절로 안겨 있는 겹문장이다.', 2),
  ('r1', array['중1','중2','중3'], 'read', '중심 내용', '윗글의 중심 내용으로 가장 적절한 것은?', '꿀벌은 먹이를 찾으면 벌집으로 돌아와 춤을 춘다. 원을 그리는 춤은 먹이가 가까이 있다는 뜻이고, 8자를 그리며 꼬리를 흔드는 춤은 먹이가 멀리 있다는 뜻이다. 8자 춤에서 몸을 기울이는 각도는 해를 기준으로 한 먹이의 방향을, 꼬리를 흔드는 시간은 거리를 알려 준다. 이처럼 꿀벌의 춤은 동료에게 먹이의 위치를 전달하는 정교한 의사소통 수단이다.', false, '["여러 번 반복되는 핵심어 찾기","문단의 첫 문장·끝 문장에서 글쓴이의 정리 찾기","선지의 낱말이 지문에 있는지만 확인하기","글쓴이의 감정이 드러난 표현 찾기"]'::jsonb, '[0,1]'::jsonb, '반복되는 ''꿀벌의 춤''과 끝 문장의 ''이처럼'' 정리가 중심 내용을 알려 준다. 낱말만 맞춰 보는 방식은 세부 내용 선지에 걸리기 쉽다.', 3),
  ('r2', array['중1','중2','중3','고1'], 'read', '전개 방식', '윗글의 서술 방식으로 가장 적절한 것은?', '종이책은 손으로 넘기는 감각과 여백에 메모하는 즐거움이 있지만, 무겁고 보관할 자리를 차지한다. 전자책은 수백 권을 기기 하나에 담을 수 있고 글자 크기도 바꿀 수 있지만, 화면을 오래 보면 눈이 쉽게 피로해진다.', false, '["글의 전개 방식(비교·대조, 인과, 예시 등) 파악하기","두 대상의 공통점과 차이점 표시하기","낯선 어휘의 뜻 추론하기","화자의 정서 변화 따라가기"]'::jsonb, '[0,1]'::jsonb, '종이책과 전자책의 장단점을 나란히 놓는 비교·대조 구조다. 두 대상의 차이를 표시하면 선지를 빠르게 거를 수 있다.', 4),
  ('r3', array['고1','고2','고3'], 'read', '추론(적절하지 않은)', '윗글을 읽고 추론한 내용으로 적절하지 않은 것은?', '도시의 가로수는 여름철 그늘을 만들어 보행자의 체감 온도를 낮춘다. 또한 잎이 미세먼지를 붙잡아 공기를 맑게 하는 데 도움을 준다. 그러나 가로수의 뿌리가 보도블록을 들어 올리거나, 가을철 낙엽이 배수구를 막는 문제도 생긴다.', false, '["발문의 ''적절하지 않은''에 표시하고 고를 기준 정하기","선지마다 지문의 근거 문장 찾아 대응하기","글쓴이의 주장이 옳은지 내 생각으로 판단하기","지문에서 가장 긴 문장부터 읽기"]'::jsonb, '[0,1]'::jsonb, '추론 문제도 근거는 지문 안에 있다. 발문 조건을 먼저 표시하고, 선지마다 근거 문장을 찾아 맞는지 확인한다.', 5),
  ('l1', array['중1','중2','중3','고1'], 'lit', '화자의 정서', '윗글의 화자의 정서와 태도로 가장 적절한 것은?', '불 꺼진 교실 창가에
누군가 두고 간 우산 하나
비는 그쳤는데
나는 아직 집에 가지 못한다', true, '["시적 상황(누가, 어디서, 무슨 일) 정리하기","정서가 드러난 시어·행 찾기","운율을 이루는 요소 세기","글의 전개 방식(비교·대조 등) 파악하기"]'::jsonb, '[0,1]'::jsonb, '비가 그친 뒤에도 남아 있는 화자의 상황을 먼저 잡고, ''아직 집에 가지 못한다''에서 머뭇거림과 쓸쓸함을 읽어 낸다.', 6),
  ('l2', array['중1','중2','중3','고1','고2','고3'], 'lit', '표현상 특징', '윗글의 표현상 특징으로 적절한 것은?', '바람이 골목을 쓸고 가면
담장은 등을 기대어 졸고
바람이 골목을 쓸고 가면
빨랫줄은 낮은 목소리로 운다', true, '["반복·대구·의인법 등 표현법 찾기","표현법이 만드는 효과(운율, 분위기) 연결하기","서술자의 시점 파악하기","지문의 중심 화제 찾기"]'::jsonb, '[0,1]'::jsonb, '같은 행의 반복으로 운율을 만들고, 담장과 빨랫줄을 사람처럼 표현했다. 표현법은 찾는 데서 그치지 말고 효과까지 연결해야 선지를 고를 수 있다.', 7),
  ('l3', array['중2','중3','고1','고2','고3'], 'lit', '서술상 특징', '윗글의 서술상 특징으로 가장 적절한 것은?', '그날 아침 나는 일부러 늦게 일어났다. 형이 떠나는 모습을 보고 싶지 않았기 때문이다. 부엌에서 어머니가 그릇을 내려놓는 소리가 유난히 크게 들렸다.', false, '["서술자의 위치(작품 안/밖)와 시점 판단하기","''나''가 주인공인지 관찰자인지 확인하기","작품의 운율 요소 찾기","<보기>의 관점을 작품에 적용하기"]'::jsonb, '[0,1]'::jsonb, '작품 안의 ''나''가 자신의 속마음을 직접 말하므로 1인칭 주인공 시점이다.', 8),
  ('l4', array['고1','고2','고3'], 'lit', '<보기> 감상', '<보기>를 바탕으로 윗글을 감상한 내용으로 적절하지 않은 것은?', '<보기>
이 작품은 산업화로 고향을 떠난 사람들이 도시에서 느끼는 소외감을 그리고 있다. 작품 속 공간은 인물의 내면을 비추는 장치로 쓰인다.', false, '["<보기>를 먼저 읽고 감상 기준(주제·공간의 의미) 세우기","기준을 작품의 구체적 장면에 적용해 선지 확인하기","작가의 생애를 외워 둔 대로 떠올리기","선지의 낯선 낱말부터 지우기"]'::jsonb, '[0,1]'::jsonb, '<보기>가 감상의 기준이다. 기준을 먼저 세운 뒤, 선지가 작품 장면과 기준 모두에 맞는지 확인한다.', 9)
on conflict (id) do nothing;
