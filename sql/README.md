# 아페라 서버 설정

## 지금 쓰는 파일: `apera_v2.sql` 하나

여러 학원이 함께 쓰는 구조와 원장 업무(반·연락처·시간표·학원비·알림장)까지 모두 들어 있습니다.
예전 파일을 몇 개 실행했든 상관없이 이 파일만 실행하면 최신 구조가 되고, 다시 실행해도 안전합니다.

1. Supabase > Database > Backups 에서 백업이 있는지 확인
2. Supabase > SQL Editor 에 `apera_v2.sql` 전체를 붙여 넣고 Run
3. 기존 데이터는 '1호 학원'으로 옮겨지고, 기존 선생님 계정은 1호 학원 원장 + 운영자가 됩니다

예전 파일(`setup.sql`, `qna.sql`, `schedule.sql`, `push.sql`, `flash.sql`, `teacher_tools.sql`, `accounts.sql`, `parents.sql`)은
기록용으로 남겨 둔 것입니다. **실행하지 마세요.** v2 적용 뒤에 다시 실행하면 학원 구분 없는 예전 권한 정책이 되살아납니다.

### v2 권한이 제대로 적용됐는지 확인

SQL Editor에서 아래를 실행해 `policyname`이 `academy member`(또는 `academy owner`)만 나오면 정상입니다. `teacher manages …`가 보이면 `apera_v2.sql`을 다시 실행하세요.

```sql
select tablename, policyname from pg_policies
where schemaname = 'public' and tablename in ('flash_cards','flash_decks','cards','students','questions')
order by 1, 2;
```

## 푸시 서버 다시 배포

일정·시간표·알림장 알림을 학생과 학부모에게 보내려면 `supabase/functions/drill-push`를 다시 배포해야 합니다.

```
supabase functions deploy drill-push --project-ref clorhqiyjtutvzacumyk
```

## 새 학원 받기 (운영자)

1. 원장님이 앱의 선생님 화면 → '계정 만들기'로 계정을 만든다
2. 운영자 계정으로 로그인 → 학원 선택 화면의 '새 학원 만들기'에 학원 이름 · 입장 코드 · 원장 이메일 입력
3. 원장님은 원장 업무 → 계정 탭에서 선생님 계정을 추가한다

## 2026-10-30 변경: 학생 로그인에 전화번호 추가

학생은 이제 **입장 코드 · 이름 · 전화번호 · 학년**으로 들어옵니다. 이름이 같은 학생도 전화번호로 구분해 따로 가입할 수 있습니다.
전화번호는 원장 화면의 학생 연락처(학생 전화번호)에 저장됩니다.

- 반드시 `apera_v2.sql`을 다시 실행해야 새 앱이 동작합니다 (예전 3칸짜리 로그인 함수를 지우고 4칸짜리로 바꿈).
- 예전 학생은 처음 들어올 때 넣은 번호가 그 학생 번호로 저장되고 기록이 그대로 이어집니다. 단, 같은 학년에 같은 이름이면서 번호가 없는 학생이 두 명 이상이면 자동으로 연결하지 않으니, 원장 화면에서 학생 전화번호를 먼저 넣어 주세요.
- 원장이 학생 전화번호를 바꾸면 그 학생은 다음부터 바뀐 번호로 들어와야 합니다.
