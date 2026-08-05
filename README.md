# 재건 공동체

교회별 소식, 게시판, 1:1 채팅, 사진·영상 업로드와 역할 기반 가입 승인을 제공하는 반응형 커뮤니티 서비스입니다. 프로덕션 웹 앱은 `apps/web`, Supabase 데이터베이스·보안 정책은 `supabase`에 있습니다.

## 주요 기능

- 이메일 로그인과 신규 가입, 교회·역할 선택 온보딩
- 엑셀 명단에서 **교회명만** 추출한 36개 초기 조직
- 공지·나눔·기도·사진/영상 게시판과 댓글
- 비공개 1:1 채팅
- 교회별 소개, 예배 안내, 조직 상태 표시
- 플랫폼 관리자: 사역자·임원 승인
- 교회 사역자/임원: 자신의 교회 일반 회원 승인
- 권한별 모바일 화면: 성도 참여 홈, 사역자 사역 홈, 임원 운영 홈·내비게이션 분리
- 임원 직책(회장·부회장·총무·서기·회계) 복수 선택과 연도별 직책 배정
- 플랫폼 관리자용 교회별 임원직 연도 갱신(현재·차년도)과 변경 감사 기록
- 임원직·회의록·회계장부의 연도 경계는 서버가 계산한 한국시간(`Asia/Seoul`) 기준을 클라이언트와 공유
- 임원 전용 연도별 회의록·회계장부, 직책별 작성 권한과 실제 수입·지출·잔액 집계
- 집사·권사·장로·전도사·목사 직분을 권한과 분리해 표시·승인
- 15MB 사진과 500MB 영상, 대용량 재개 가능 업로드

승인 권한은 화면 표시, 교회 직분, 임원 직책이 아니라 `platform_admin`과 `minister | executive | member` 역할로 결정됩니다. 회의록·회계장부의 세부 작성 권한은 승인된 연도별 임원 직책을 함께 검사하며, 두 단계 모두 Supabase RLS·보안 RPC로 강제됩니다. 브라우저에는 서비스 역할 키를 넣지 않습니다.

## 로컬 실행

```bash
npm ci --prefix apps/web
npm run dev:web
```

환경 변수가 없으면 실제 서비스와 동일한 화면·상호작용을 확인하는 명시적 데모 모드로 실행됩니다. 실제 인증과 저장을 연결하려면 다음 파일을 만듭니다.

```bash
cp apps/web/.env.example apps/web/.env.local
```

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_OR_PUBLISHABLE_KEY
```

## Supabase 적용

1. Supabase 프로젝트를 생성합니다.
2. `supabase/migrations`의 마이그레이션을 순서대로 적용합니다.
3. `supabase/seed.sql`을 적용해 36개 교회를 생성합니다.
4. 첫 운영자 계정을 만든 뒤 `supabase/README.md`의 절차로 `platform_admin` 권한을 부여합니다.
5. 위 공개 URL/키를 로컬과 Vercel 환경 변수에 등록합니다.

세부 스키마, RLS 정책, 승인 흐름과 운영자 부트스트랩은 `supabase/README.md`를 참고하세요.

## 검증

```bash
npm run typecheck:web
npm run test:web
npm run build:web
```

GitHub Actions에서도 같은 검사 후 Vercel이 `apps/web/dist`를 배포합니다.

## Vercel 배포

저장소 `git@github.com:UICHANLEE/jaegun_com.git`의 루트 `vercel.json`을 사용합니다. `main` 푸시는 프로덕션 배포, 그 외 브랜치와 PR은 미리보기 배포가 됩니다.

Vercel 프로젝트에는 다음 공개 환경 변수만 등록합니다.

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

`SUPABASE_SERVICE_ROLE_KEY`나 데이터베이스 비밀번호를 Vite 환경 변수로 등록하면 안 됩니다.

## 저장소 구조

```text
apps/web/                  프로덕션 React/Vite 앱
supabase/                  스키마, RLS, RPC, 조직 시드
design/                    선택한 1안 시각 기준
src/                       이전 모바일 시안 런타임(보존)
.github/workflows/         타입 검사·테스트·빌드 CI
```
