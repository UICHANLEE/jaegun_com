# 재건 공동체 출시 차단 QA 보고서

검증일: 2026-08-05 (Asia/Seoul)
대상: `apps/web/`, Supabase migrations/seed, GitHub `main`, Vercel `jaegun-com`

## 출시 판정

**BLOCKED — 현재 운영 배포에는 Supabase 운영 연결이 없어 실제 회원가입·로그인·게시판·채팅·업로드·승인 데이터를 저장할 수 없다.**

코드에서 발견한 P0/P1 결함은 모두 수정하고 회귀 검증했다. 다만 운영 Vercel 프로젝트에 공개 Supabase URL/anon key를 연결하고, 마이그레이션·seed·Auth 메일·최초 플랫폼 관리자를 실제 프로젝트에 적용하기 전에는 출시 승인하지 않는다. 설정이 빠진 운영 빌드는 가짜 데모를 노출하지 않고 안전한 준비 상태로 닫히도록 변경했다.

## 심각도 기준

- P0 치명적: 핵심 서비스 전체 불가, 개인정보·권한 경계 붕괴, 즉시 출시 차단
- P1 높음: 주요 사용자 흐름 실패, 데이터 손실·중복·교차 계정 노출 가능성
- P2 보통: 복구 가능한 실패지만 문의·오조작·비용·접근성 문제로 이어짐
- P3 낮음: 기능을 막지 않는 표현·운영 정리 문제

## 발견 및 조치

### P0 — 남은 외부 출시 차단 조건

1. **운영 Supabase 미연결**
   - 현재 운영 번들에 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`가 포함되지 않는다.
   - 실제 Auth/Postgres/Storage/Realtime 경로가 작동하지 않으므로 출시 불가다.
   - 코드 조치: 운영 환경에서 로컬 데모와 가짜 관리 데이터를 fail-closed 처리했다.

### P1 — 수정

1. 일반 로그인 세션에서도 비밀번호 변경 경로를 직접 실행할 수 있던 복구 세션 검증 결함
2. 로그아웃 직후 재로그인, 느린 초기 조회, 이전 Realtime 이벤트가 다른 사용자의 화면에 늦게 반영될 수 있던 세션 경쟁 조건
3. 긴 채팅 업로드 중 A가 로그아웃하고 B가 로그인하면 A의 내용이 B 발신으로 저장될 수 있던 인증 주체 전환 결함
4. 응답 유실 뒤 다른 계정의 RLS 빈 결과를 미커밋으로 오판해, 이미 게시글·메시지가 참조하는 첨부를 삭제할 수 있던 조정 결함
5. 게시글 게시 실패 뒤 사용자가 사진 A를 삭제·교체했는데 재시도에서 A가 공개될 수 있던 민감 미디어 결함
6. 실패한 게시글 미디어 정리 큐가 나중에 성공한 게시글의 새 첨부까지 삭제할 수 있던 정리 순서 결함
7. 채팅 상대나 같은 교회 관리자가 Storage object 이름을 알면 다른 발신자의 첨부를 수정·삭제할 수 있던 소유권 결함
8. 회계장부·회의록 저장 응답 유실 후 중복되거나, 삭제된 항목을 같은 작업 UUID 재시도로 되살릴 수 있던 무결성 결함
9. 게시글 `author_label`, 고정 공지, 발행 시각을 클라이언트가 위조할 수 있고 채팅 다중 전송이 부분 저장될 수 있던 DB 경계 결함
10. TUS 대용량 업로드가 동일 파일 지문 때문에 다른 Storage 경로의 이전 업로드를 잘못 이어받을 수 있던 결함

### P2 — 수정

1. 잘못된 URL을 홈으로 조용히 돌려보내던 동작을 실제 404와 복구 버튼으로 교체
2. 게시글 직접 URL 새로고침 시 목록에 없다는 이유로 즉시 “없음” 처리하던 deep-link 결함
3. 전역 렌더 오류, 빈 데이터, 로딩 지연, API 실패에 대한 오류 경계·재시도·명시 상태 부족
4. 채팅 모달의 포커스·Escape·배경 스크롤·복귀 포커스, 작성 폼의 뒤로 가기/새로고침 초안 보호 결함
5. 느린 전송 중 새로 입력한 채팅 초안이 이전 요청 완료와 함께 지워지던 결함
6. 깨진 이미지/아바타, 긴 문자열, 가짜 반응 수·고정 행사 문구, 작은 화면 overflow 문제
7. 모바일 주요 화면의 작은 텍스트 색상 대비 미달과 가입 교회 검색 입력의 접근 가능한 이름 누락
8. Storage 정리 재시도 순서·내구성, signed URL 영구 대기, 중첩 새로고침에서 최신 이벤트를 놓칠 수 있던 복구 결함

### P2 — 운영 활성화 후 추적

1. 댓글·가입신청·승인·회원상태·알림 읽음 등 일부 짧은 mutation은 공통 `expected_actor` 계약이 없어 극히 짧은 교차 탭 계정 전환 창이 남는다. 채팅·게시글의 긴 작업은 서버에서 차단했으며, 나머지도 같은 계약으로 통일한다.
2. 댓글·가입신청·승인·회의록/장부 삭제는 서버 commit 직후 HTTP 응답만 유실되면 실제 성공을 실패로 보여줄 수 있다. 생성·수정 중복/부활은 차단했지만 사용자 메시지 조정이 더 필요하다.
3. signed URL UI timeout은 실제 하위 HTTP를 취소하지 못해 반복 새로고침에서 일시적인 중첩 요청이 생길 수 있다.
4. 전체 snapshot 조회 직후 댓글 작성·알림 읽음이 겹치면 늦은 snapshot이 잠시 이전 상태를 덮을 수 있다. 다음 Realtime/refresh에서 복구되지만 domain revision 병합이 필요하다.
5. 채팅은 최근 100개만 조회하고 과거 메시지 pagination이 없어 장기 대화의 이전 기록을 화면에서 열 수 없다.
6. 브라우저가 실패 파일 정리 기록까지 닫히면 서버 TTL/sweeper가 없어 Storage orphan이 남을 수 있다. 클라이언트 재로그인 정리 외 서버 정기 정리가 필요하다.
7. 게시 완료 응답 유실 뒤 새 탭 재시도는 authoritative 게시글/미디어 전체를 즉시 합성하지 못해 refresh 전 미디어가 비어 보일 수 있다.
8. 회의록·장부의 생성 operation ID는 `sessionStorage`에 있어 탭 종료와 응답 유실이 동시에 발생한 뒤 수동 재입력하면 별도 장부 행이 생길 수 있다.
9. React Router audit 2건은 현재 앱이 사용하지 않는 unstable RSC API 경로의 공지다. 해당 API 사용은 0건이지만 upstream 패치가 나오면 즉시 올린다.

### P3 — 운영 정리

1. 같은 GitHub 저장소를 자동 배포하는 Vercel 프로젝트가 두 개라 빌드 비용과 운영 혼선 위험이 있다. 주 프로젝트 `jaegun-com`만 남기는 정리가 필요하다.
2. 전송 직후 대화 갱신 오류가 계정 전환 뒤 새 계정의 공용 오류 배너에 표시될 수 있다.
3. 같은 임원직 설정을 재호출하면 실제 권한 변화가 없어도 알림·감사 로그가 중복될 수 있다.

수정 완료된 정보 정확성 항목: 온라인 presence 데이터가 없는데 보이던 “접속 가능” 표시, 고정 교회명·날짜는 제거하고 실제 조직·역할·메시지 날짜를 표시한다.

## 실제 검증 근거

### 반응형·상호작용

- 320×568, 390×844, 768×1024, 1440×900에서 로그인·성도 홈·관리 홈·게시판·채팅·교회·프로필·가입·404를 직접 렌더링했다.
- 각 대표 화면의 `documentElement.scrollWidth`가 viewport width와 같아 가로 overflow가 없었다.
- 320px 성도 홈과 임원 회계 입력 폼에서 보이는 주요 링크·버튼의 유효 터치 영역이 44px 이상이었다. 라디오의 실제 클릭 영역은 67px 높이 label이다.
- 회원/사역자/임원(서기·회계, 부회장)/플랫폼 관리자 분기가 서로 다른 내비게이션과 서버 권한 범위를 표시했다.
- 채팅 dialog는 `aria-modal`, 최초 포커스, Escape 닫기, 배경 inert/scroll lock, 닫은 뒤 호출 버튼 포커스 복귀를 확인했다.
- BrowserRouter 실제 뒤로 가기에서 초안 취소 시 URL·폼·입력값·history 길이가 유지되고 승인 시 한 번만 이동했다.

### 입력·상태·오류

- 로그인 빈 값, 잘못된 이메일, 8자 미만 비밀번호, 회원가입 공백 이름, 비밀번호 불일치를 거부했다.
- 비밀번호 찾기는 계정 존재 여부를 노출하지 않는 성공 문구를 사용하며, 정상 로그인 세션은 reset 권한을 얻지 못한다.
- 로그아웃 후 새로고침해도 이전 교회명·게시글·채팅·알림·회원 데이터가 다시 나타나지 않았다.
- 긴 제목 80자, 공백 없는 본문 2,400자, 이미지 없음/깨짐, 빈 검색 결과, 없는 게시글·교회·채팅, 잘못된 URL을 확인했다.
- API 지연·영구 pending·응답 유실·실패 후 재시도·계정 전환을 mock한 Provider 회귀 테스트를 실행했다.
- 사진 A 게시 실패 뒤 B로 교체하는 재시도에서 A 경로가 정리되고 B의 새 경로만 게시 RPC에 전달되는 것을 확인했다.

### 접근성

- landmark, heading, form label, alt text, dialog 이름, `aria-live` 오류 상태를 DOM 접근성 snapshot으로 확인했다.
- 키보드 포커스는 3px 가시 outline을 표시하고 모달 포커스가 배경으로 빠지지 않는다.
- 대표 회원·가입·관리 화면의 직접 텍스트 대비를 계산해 발견한 미달 항목을 수정했으며 재검사 결과 0건이었다.

### 빌드·DB·보안·배포

- Vitest **19개 파일 / 72개 테스트**, TypeScript 검사, production build(4,699 modules), `git diff --check`가 모두 통과했다.
- 보호된 레거시 모바일 런타임 **28개 파일**의 무결성 검사가 통과했다.
- PostgreSQL **16.12**에서 migrations 001~008 fresh 적용과 핵심 smoke를 통과했다. 008 SHA-256은 `6cccb48dcf8919d97f5ae841da5426e28e53790746fc4e742937aa58bddf4a7e`다.
- DB smoke는 expected-sender 채팅 batch/rollback, suspended 본인-only reconciliation, 계정 전환 거부, 게시글 exact-media/분류 재생성, Storage owner RLS, 회의록·장부 tombstone 비부활을 포함하며 최종 출력은 `ALL P1 RECONCILIATION, TOMBSTONE, AND STORAGE SCENARIOS PASSED`였다.
- 루트 `npm audit --omit=dev`는 취약점 0건이다. 웹 앱의 React Router audit 2건은 소스에서 unstable RSC API 사용이 0건임을 확인했다: https://github.com/advisories/GHSA-qwww-vcr4-c8h2
- 브라우저 번들에 service-role key, 비밀키, 실제 Supabase 운영 URL이 노출되지 않았고, 잘못된 Supabase URL도 React mount 전 crash하지 않고 fail-closed 처리한다.
- CSP, frame 차단, MIME sniff 방지, referrer/permissions 정책은 `vercel.json`에 추가했으며 푸시 후 운영 응답에서 다시 확인한다.

### 시각 증거

- `qa-audit-2026-08-05/10-mobile-member-home-final.png` — 390×844 성도 홈
- `qa-audit-2026-08-05/11-desktop-manager-final.png` — 1440×900 임원 운영 홈
- `qa-audit-2026-08-05/reference-vs-fixed-mobile-home.png` — 선택한 Option 1 기준과 수정본 비교

## 운영 활성화 게이트

다음 작업을 하나의 운영 활성화 변경으로 완료하고 실제 계정 E2E를 다시 통과해야 출시 승인할 수 있다.

1. Supabase 프로젝트 연결 및 migrations 001~008 + 36개 교회 seed 적용
2. 이메일 확인/SMTP와 `https://jaegun-com.vercel.app/reset-password` Auth redirect 설정
3. 본인 실제 계정 생성 후 감사 로그를 포함한 최초 `platform_admin` bootstrap
4. Vercel Production/Preview에 공개 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`만 등록 후 재배포
5. 본인 관리자 + 사역자 + 임원 + 일반 회원 계정으로 승인·게시글·채팅·사진/영상·회의록·회계장부 E2E 재검증
