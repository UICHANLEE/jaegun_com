# Master v3 요구사항 반영·차이점 및 단계별 실행 계획

기준일: 2026-10-14. 첨부된 Master v3 전체 문서와 현재 저장소 소스를 대조했다. 이 문서는 구현·배포 완료 보고서가 아니다. 아래의 ‘구현’은 소스에서 확인한 범위이며, 운영 DB 적용·실기기 성공·부하 시험·스토어 심사 통과를 뜻하지 않는다. 첨부 DDL을 실행하지 않았고 회원 정보도 조회하지 않았다.

## 우선 확정할 제품 기준

- iPhone은 `apps/ios-native/`의 순수 SwiftUI, 웹은 `apps/web/`의 React/Vite를 유지한다. 첨부의 Next.js/PWA 전면 교체는 채택하지 않는다. 웹 홈 화면 설치와 App Store 네이티브 배포는 서로 다른 제품·심사 과정이다.
- 기존 `총회 → 노회 → 교회`와 교회 내 고정 4개 부서의 매트릭스를 유지한다. 부서를 교회 위 부모 조직으로 끼우거나 기존 실제 노회·교회를 첨부 예시 5개로 교체하지 않는다. 연합부서 신규 범위는 권한·회원 자격 설계 후 별도 확장한다.
- 기본 역할(`member`, `minister`, `executive`)과 연도·조직·부서별 직책을 분리한다. 부서 임원, 채널 소유자, 행사 스태프가 회원 승인·회계·상위 조직 권한을 얻지 않는다.
- 기존 웹의 clean feed B·실제 로고·6개 회원 목적지를 네이티브에서도 유지한다. 통독/QT는 기능성 홈 위젯으로 더하고 기존 공지·피드·모임·일정을 없애지 않는다.
- 만 14세 이상 확인, 5종 버전 동의, 최신 동의 이전의 보호 데이터 차단, 조직 범위 RLS, 민감 행위의 최근 Google 재인증과 감사 기록을 유지한다.
- 비밀 채팅 감시와 최고 관리자 원본 무조건 조회를 구현하지 않는다. 신고된 대상에 한해 공개된 운영 정책, 제한된 담당 권한, 필수 열람 사유·감사 기록·최소 증거 보존으로 조사한다. 신고 검토는 새 대화방 회원권이나 일반 DM 열람권을 만들지 않는다.

## 최신 요청: 로그인과 회원가입 분리

- [ ] 비로그인 최초 화면은 ‘로그인’이다. 이메일 로그인·비밀번호 찾기·Google 로그인·별도 ‘회원가입’ 링크를 제공한다. 최초 화면에 회원가입 동의 체크박스를 함께 배치하지 않는다.
- [ ] Google 버튼은 먼저 시스템 OAuth를 실행한다. 인증 전에 이메일 존재 여부를 외부에 노출하는 계정 조회 API를 만들지 않는다.
- [ ] 인증 후 서버의 실제 계정·동의 상태로 분기한다. 기존 계정+유효 동의는 홈/기존 승인 대기 상태로, 신규 계정은 동의→14세 이상 확인→가입 정보·교회 선택→가입 신청으로 이동한다.
- [ ] 기존 계정이라도 필수 문서 버전이 바뀌었으면 재동의가 필요하다. ‘신규만 동의’ UI 개선을 최신 동의 백엔드 게이트 제거로 해석하지 않는다.
- [ ] 이메일 회원가입은 별도 페이지에서 현재 문서 동의를 검증한 뒤 Auth 제출한다. Google 신규 사용자의 미동의 인증 상태는 최소 자기 계정/법적 문서만 허용하고 공동체 자료를 보여주지 않는다.
- [ ] OAuth 취소·실패는 로그인 화면에 오류만 표시하며 가입/동의 상태를 다른 계정에 전이하지 않는다. 뒤로 가기·중복 클릭·기존/신규·재동의·승인 대기·계정 연결·세션 만료를 웹과 iPhone에서 각각 테스트한다.

현재 변경 기준 소스: `apps/web/src/pages/AuthPages.tsx`, `EmailAuthPages.tsx`, `apps/web/src/data/AppDataProvider.tsx`, `apps/ios-native/Sources/NativeRootView.swift`, `NativeSession.swift`, `supabase/migrations/20261014053015_google_auth_consent_rollout.sql`.

이번 적용에서 확인한 범위: `/auth` 로그인은 동의 체크박스 없이 Google→이메일→별도 회원가입으로 표시되며 `/signup`은 별도 이메일 가입 화면이다. 순수 SwiftUI에서도 로그인→별도 회원가입→뒤로 가기를 실제 시뮬레이터에서 확인했다. OAuth 콜백은 서비스 동의를 자동 기록하지 않는다. 네이티브 동의 저장은 정확한 문서 식별자·버전 5개와 14세 이상 확인을 다시 검사한다. 웹 410개·네이티브 42개 단위/회귀 테스트, production build/no-demo bundle·보안 검사·보호 runtime 검사를 통과했다. 로컬 브라우저 로그인/가입 이동·새로고침과 콘솔 오류 없음도 확인했다. 실제 기존/신규 Google 계정의 iPhone 인증·동의 완료는 사용자가 직접 확인해야 한다. 위 전체 기능 체크리스트는 아직 완료 선언이 아니다.

## 전체 기능 대조표

상태: **구현**=해당 기존 기능의 소스 있음, **부분**=요구 중 일부만 있음, **대기**=사용 가능한 해당 기능 소스 미확인, **대체**=위험한 원안을 안전한 범위로 변경. 표의 상태와 `[ ]`는 전체 요구의 완료 여부를 구분한다.

| 요구 | 체크 | 웹 / 백엔드 확인 범위 | SwiftUI 확인 범위 | 추가 작업과 근거 경로 |
| --- | --- | --- | --- | --- |
| REQ-HOM-01 정적 성경·오프라인 | [ ] 대기 | 정적 성경 본문·판본 라이선스·오프라인 본문 패키지 미확인 | 성경 뷰어 미확인 | 배포/오프라인/수정 허용이 확인된 판본만 도입. `apps/web/src/pages/MemberHomePage.tsx`, `apps/ios-native/Sources/NativeWebAlignedViews.swift`는 기존 홈 기반이며 성경 구현 증거가 아님 |
| REQ-HOM-02 진도·연속 일수·랭킹 | [ ] 대기 | 서버 진도·중복 체크·집계 계약 미확인 | 진도 체크 미확인 | 서버 한국 날짜, 장 범위 검증·고유 체크·멱등 쓰기, 옵트인 조직 집계 및 작은 집단 비식별 필요. `apps/web/src/serviceTime.ts`의 서버시계 패턴 재사용 |
| REQ-HOM-03 QT·아멘·AI 연결 | [ ] 부분 | 기도/나눔 게시판·AI 템플릿은 있음. 날짜·구절별 QT와 아멘 고유 반응·AI 실제 답변 없음 | 게시글 열람·AI 초안은 있음. QT 작성 없음 | `apps/web/src/pages/FeedPages.tsx`, `AIAssistantPage.tsx`, `apps/ios-native/Sources/NativeCommunityViews.swift`, `NativeWebAlignedViews.swift` |
| REQ-ORG-01 조직 트리·부서 | [ ] 부분 | 총회/노회/교회 트리와 교회 고정 4개 부서 구현. 첨부의 연합부서 소속 모델은 없음 | 소속 노회→교회 선택·부서 직책 신청 있음. 전체 조직 관리/명단 기능 동등성 미완 | `apps/web/src/pages/OrganizationAdministrationPage.tsx`, `DepartmentOfficerManagementPage.tsx`, `supabase/migrations/202608230009_hierarchical_governance.sql`, `202608270014_church_department_offices.sql`, `apps/ios-native/Sources/NativeOnboardingView.swift` |
| REQ-ORG-02 범위별 연도 임원·이력 | [ ] 부분 | 3계층+교회 부서 연도 직책·위임·직책 신청 있음. 연합부서 추가 범위 대기 | 범위별 신청·신청 심사 있음. 전체 역대 임원 관리 UI 미완 | `apps/web/src/pages/SignupScopedOfficePicker.tsx`, `apps/ios-native/Sources/NativeSignupOfficeRequests.swift`, `supabase/migrations/20261014090403_signup_scoped_office_requests.sql` 및 조직/부서 마이그레이션 |
| REQ-AUTH-01 총관리자·목사 지정 | [ ] 부분 | 플랫폼 관리자, 사역자/임원 승인, 명시적 pastor 연도 임명 있음. 자유 조직 개설 UI는 별도 검증 필요 | 관리자 가입 심사·직책 심사 있음. 임의 조직 개설 UI 미확인 | `apps/web/src/pages/ProfilePages.tsx`, `OrganizationAdministrationPage.tsx`, `apps/ios-native/Sources/NativeApprovalOperations.swift`; `profiles.system_role` 직접 변경 방식은 사용 안 함 |
| REQ-AUTH-02 성도 승인·위임·스태프 | [ ] 부분 | 같은 교회 사역자/임원 회원 승인, 명시적 pastor/회장 범위 위임 있음. 포괄 STAFF 기본 역할 없음 | 같은 교회 회원 승인 있음. 일반 위임·행사 스태프 관리 화면 미완 | `apps/web/src/pages/ProfilePages.tsx`, `OrganizationAdministrationPage.tsx`, `apps/ios-native/Sources/NativeApprovalOperations.swift`; 행사별 만료 권한만 별도 설계 |
| REQ-EVT-01 참석·출발지·차량 설문 | [ ] 부분 | 반복 일정·참석/미정/불참/대기·정원 있음. 부분참석 시간·출발지·운전 지원 자가 설문은 없음 | 일정 생성/수정/취소 있음. 회원 RSVP·차량 설문 동등성 미완 | `apps/web/src/pages/EventPages.tsx`, `apps/web/src/data/events.ts`, `apps/ios-native/Sources/NativeEventEditor.swift`, `supabase/migrations/202608270012_events_calendar.sql` |
| REQ-EVT-02 조·차량·숙소 배정 | [ ] 부분 | 조/차량 추가·운전자 포함 좌석 제한·균등 순환 조·좌석 기반 자동 배정·수동 선택·revision 저장 있음. 숙소·드래그·교회 묶음·인구통계 기반 편성 없음 | 조/차량 배정 UI 없음 | `apps/web/src/pages/EventLogisticsPanel.tsx`, `supabase/migrations/20261014000100_event_logistics.sql`. 나이/성별/부서 추론 금지; 필요 시 명시적 자가 입력·동의 검토 |
| REQ-EVT-03 다중 시트 xlsx | [ ] 대기 | 행사별 엑셀 내보내기 미확인 | 행사 내보내기 미확인 | 권한 재확인·최소 필드·수식 삽입 방어·명단 내려받기 감사와 보존 안내. `EventLogisticsPanel.tsx`의 최소 roster 계약 기반 확장 |
| REQ-EVT-04 QR 명찰·출석·납부 | [ ] 대기 | 행사별 서명/만료 QR·스캔·중복 출석·납부 계약 미확인 | QR 표시/카메라 스캔 미확인 | UUID 원문 QR 대신 짧은 서버 검증 토큰, 행사/회차/회원 바인딩, 재사용 방지·오프라인 동기화 정책·스태프 범위·카메라 권한 추가 |
| REQ-MIN-01 계층별 회의록·AI 요약 | [ ] 부분 | 교회 임원 연도별 회의록·직책 쓰기 권한 있음. 상위/행사별 회의록·실제 AI 자동 요약 없음 | 실제 회의록 작성 화면 없음 | `apps/web/src/pages/ExecutiveOperationsPages.tsx`, `supabase/migrations/202608050007_executive_operations.sql`, `apps/web/src/data/aiAssistant.ts`. AI 결과는 초안이며 사용자가 검토/확정 |
| REQ-MIN-02 Jitsi 인앱 회의 | [ ] 대기 | Jitsi SDK·회의 서버·입장 토큰 미확인 | Jitsi 네이티브 회의 미확인 | 회의 생성/참석/종료 권한·대기실·추측 불가 room·녹화 동의·카메라/마이크·장애 복귀 검증. React SDK를 SwiftUI 화면으로 간주하지 않음 |
| REQ-FIN-01 독립 장부·회비 자동 연동 | [ ] 부분 | 교회 임원 연도별 수입/지출 장부·직책 쓰기 권한 있음. 조직/행사 독립 장부·회비 자동 전표 없음 | 실제 장부 작성 화면 없음 | `apps/web/src/pages/ExecutiveOperationsPages.tsx`, `supabase/migrations/202608050007_executive_operations.sql`. 납부 수정/취소는 감사 가능한 역분개, 멱등 전표·금액 검증 필요 |
| REQ-FIN-02 영수증·결산서 | [ ] 대기 | 일반 미디어 직접 업로드는 있으나 회계 영수증/R2/100KB WebP/결산 xlsx 아님 | 영수증 촬영·첨부 없음 | `apps/web/src/data/mediaUpload.ts`, `docs/operations/media-quarantine-runbook.md`. 100KB는 품질 목표로 처리하고 판독 불가 영수증 강제 압축 금지; 회계 비공개 권한·삭제/보존 계약 필요 |
| REQ-COM-01 기도·익명·공문 | [ ] 부분 | 공지/기도/나눔/미디어 글·댓글·신고·차단 있음. 익명 Q&A·기도 고유 반응·공문 수신 확인·경조사 전용 구조 없음 | 게시글 열람 있음. 작성/댓글/신고 전체 동등성 미완 | `apps/web/src/pages/FeedPages.tsx`, `SafetyPrivacyPages.tsx`, `apps/web/src/components/SafetyControls.tsx`, `apps/ios-native/Sources/NativeCommunityViews.swift` |
| REQ-COM-02 채널·비공개·DM | [ ] 부분 | 회원 생성 공개/초대 비공개 채널, DM, 스레드/멘션/반응/전달/미디어·Realtime 있음. 교회 범위 밖 공개 채널은 없음 | 교회 채널 목록·텍스트 송수신 있음. 채널 생성·DM·리치메시지·Realtime 동등성 미완 | `apps/web/src/pages/ChannelPages.tsx`, `ChatPages.tsx`, `apps/web/src/data/channels.ts`, `supabase/migrations/20260904223543_community_channels.sql`, `20260909135418_channel_rich_messages.sql`, `20260913022919_channel_realtime_threads_notifications.sql`, `apps/ios-native/Sources/NativeCommunityViews.swift` |
| REQ-COM-03 실제 AI 사역·쿼터 | [ ] 부분 | 연결 준비 템플릿·메모리 초안만 있음. 실제 모델 호출·일일 서버 쿼터 없음 | 연결 준비 템플릿만 있음 | `apps/web/src/pages/AIAssistantPage.tsx`, `apps/ios-native/Sources/NativeWebAlignedViews.swift`, `docs/architecture/ai-assistant-integration.md`. 서버 키·동의·분당/일일/전체예산·비용 차단 필요 |
| REQ-COM-04 교회 YouTube 라이브 | [ ] 대기 | 방송 상태·배너·검증 URL·플레이어·주보 동시 화면 없음 | 라이브 플레이어 없음 | `docs/architecture/ADR-001-managed-livestreaming.md`는 제안/게이트 문서이지 구현 아님. 공개 YouTube를 비공개 교회 스트림으로 표시하지 않음 |
| REQ-ADM-01 사용량 관제 | [ ] 대기 | 역할 맞춤 관리자 홈은 있음. 실제 공급자 DB/AI/quota 관제 미확인 | 사용량 관제 없음 | `apps/web/src/pages/ManagerDashboardPage.tsx`는 요금·인프라 모니터 증거 아님. 서버 인증 공급자 API·실측·수집시각·누락 상태·경보 설계 |
| REQ-ADM-02 감사·90일 비우기 | [ ] 부분 | 민감 RPC 감사 기록 있음. 전체 IP 수집·검색/백업/90일 삭제 UI는 없음 | 사용자 감사 조회 화면 없음 | `supabase/migrations/202608030002_security.sql`, 조직/행사/채널/신고 마이그레이션의 `private.write_audit`. 백업 복구·보존/법적 보류·삭제 권한 확정 전 삭제 작업 금지 |
| REQ-ADM-03 익명 추적·제재 | [ ] 대체 | 기존 신고 사건·이유 있는 제재 있음. 익명 게시판은 추가 설계 | 신고·제재 동등성 미완 | `apps/web/src/pages/SafetyPrivacyPages.tsx`, `supabase/migrations/202608300015_launch_legal_disclosures.sql`, `20260909135418_channel_rich_messages.sql`. 원본 프리패스 대신 신고 사건에 필요한 최소 증거·권한·열람 감사 |
| REQ-ADM-04 스텔스 DM 감시 | [ ] 대체 | 원안은 채택하지 않음. 신고자가 제출한 대상 메시지 증거에 한정된 검토 기반 있음 | 스텔스 감시 없음/추가하지 않음 | `apps/web/src/data/safetyPrivacy.ts`, 위 신고 마이그레이션. 참여자 아닌 관리자의 모든 DM 구독·삭제 원문 무기한 보존·몰래 검색은 구현하지 않음 |

전체 요구를 구현했다고 주장하려면 각 행의 남은 범위와 SwiftUI 동등성을 별도로 완료해야 한다. 기존 `docs/releases/v1.0-feature-matrix.md`는 2026-09-02의 이전 네이티브 배포 기준을 포함하므로 현재 순수 SwiftUI 기능 동등성 증거로 재사용하지 않는다.

## 첨부 SQL을 그대로 적용하지 않는 이유

1. **즉시 실행 오류:** 랭킹 뷰가 `profiles.presbytery_id`를 참조하지만 첨부 `profiles` 정의에 그 컬럼이 없다. 기존 `profiles`, `events`, `posts`, `meeting_minutes` 이름과 충돌해 CREATE TABLE 단계부터 실패할 수 있다. 반쯤 실행된 DDL은 기존 운영 모델을 보장하지 않는다.
2. **RLS 누락:** 17개 테이블 중 `posts`, `audit_logs`, `chat_rooms`, `chat_messages` 4개만 활성화한다. 프로필·가입 승인·임원·진도·QT·참가자·회계·chat_members에는 필요한 정책과 명시적 grants/revokes가 없다. 공개 스키마 grant 상태에 따라 미승인·다른 교회 데이터에 접근할 위험이 생긴다.
3. **View 경계 불명확:** 익명/랭킹 뷰에 `security_invoker`와 호출자 조직·최신 동의 조건이 없다. 원본을 숨기는 CASE만으로 행 권한/멤버십을 보장하지 않는다. 인보커 뷰로 바꿔도 하위 테이블 정책·컬럼 grants 또는 안전한 redacting RPC가 함께 필요하다. [Supabase RLS 공식 설명](https://supabase.com/docs/guides/database/postgres/row-level-security)
4. **권한 데이터 신뢰 오류:** `profiles.system_role`, `is_approved`, `is_banned`, officers의 boolean을 신청자가 수정할 수 없도록 하는 보호와 audited grant가 없다. 자기 프로필 수정 정책을 단순 추가하면 SUPER_ADMIN 자가 승격이 가능해질 수 있다. 기존 actor/session/조직·서비스 연도 기반 RPC로 관리한다.
5. **동의·범위·세션 누락:** 공개 채널 조회 조건은 `room_type='PUBLIC_CHANNEL'`일 뿐 교회 범위·최신 동의·활성 회원·익명 Auth 여부가 없다. 관리자 조건은 모든 DM을 포괄한다. 삭제·퇴회·초대 취소·기존 초대 재활성화도 고려하지 않는다.
6. **특권 함수 공개:** `get_db_size_mb()`는 SECURITY DEFINER인데 고정 search_path·actor/role 검증·PUBLIC execute revoke가 없다. 관리자 화면용 함수도 서버가 검증한 정확한 권한과 최소 정보만 반환해야 한다.
7. **정합성·경쟁 누락:** scope_type과 참조 ID들의 정확한 조합/유일성, 유효 직책·금액 양수·날짜 순서·좌석 정원·계정 정지·회원 자격·revision/멱등성·감사 쓰기 제약이 빠져 있다. 기기 시계의 CURRENT_DATE는 한국 서비스 날짜 경계 계약을 대체하지 않는다.
8. **집계 위변조·중복:** read_chapters 중복/범위·total_count 일치·연속일 조작·amen_count/기도 중복 반응·AI 사용량 원자적 quota 차감이 없다. 사용자별 고유 반응·서버 계산/원자적 예약이 필요하다.
9. **민감정보 과수집·보존:** 성별/출생연도/전화/IP를 일괄 필수화하거나 삭제된 DM을 감시용 영구 보존하지 않는다. 감사 로그 90일 자동 비우기는 복구 시험·보존 기간/법적 보류·별도 승인 없이 추가하지 않는다.

실행 방식: 기존 마이그레이션 위에 작은 확장 마이그레이션을 만들고, 익명/미동의/다른 교회/일반 회원/임원/목사/위임 만료/플랫폼 관리자 및 경쟁·재시도 pgTAP를 먼저 통과시킨다. 첨부의 17개 테이블을 교체 스키마로 적용하지 않는다.

## 무료·용량·권리 가정 수정

- 월 0원 영구 운영·300명 무조건 수용·0.05초 응답은 보장하지 않는다. 실제 플랜, 재접속·다중 기기, WebSocket 연결·메시지, DB/Storage/egress/함수/이메일, 백업과 외부 공급자 비용을 별도 실측한다. 기존 `docs/operations/realtime-load-test.md`는 안전한 staging 시험 절차이며 합격 결과가 아니다. [Supabase 요금과 한도](https://supabase.com/pricing)
- Gemini 일 1,500회/분 15회 값을 고정 보장하지 않는다. 공식 안내상 모델·프로젝트·tier별 제한이며 실제 한도는 AI Studio에서 확인해야 한다. 사용자 10회/일만으로 전체 프로젝트 비용을 제한할 수 없으므로 전역 예산·동시성·RPM/TPM도 필요하다. [Gemini rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- R2의 egress 무료와 모든 비용 무료는 다르다. 저장량뿐 아니라 Class A/B 요청 요금·무료 할당이 존재한다. 신규 공급자 도입은 비공개 파일의 actor-bound 인증·국외이전 검토·서명 URL 만료·삭제 계약도 요구한다. [R2 공식 요금](https://developers.cloudflare.com/r2/pricing/)
- Jitsi의 오픈소스 SDK만으로 공용 호스팅의 무제한 인원·무료 운영 SLA를 약속하지 않는다. 선택한 호스트의 정책·인증·최대 부하·품질·운영 비용을 먼저 검증한다. [Jitsi FAQ](https://jitsi.org/user-faq/)
- 개역한글이라는 이름만으로 본문/전자 파일/폰트/배포 권리가 허용되었다고 판단하지 않는다. 도입 파일의 출처·판본·권리자·이용 조건·앱 내 재배포/오프라인 권리를 확인하고 근거·저작권 표시를 보관한다. 확인 전 본문을 다운로드하거나 패키징하지 않는다.
- PWA의 설치와 Apple Developer Program/App Store 배포는 다르다. 계정 요금·비영리 면제 자격·심사·TestFlight·개인정보 표시·실제 네이티브 기능은 별도 출시 게이트다. 이 문서에서 무료 스토어 등록을 보장하지 않는다. [Apple 가입 안내](https://developer.apple.com/programs/enroll/)
- 무료 프로젝트 휴면 방지용 무조건 ping을 출시 신뢰성 대책으로 넣지 않는다. 이용약관·실제 플랜·백업/장애 복구·운영 관측을 먼저 확인하고 공급자 정책 변경을 감춘 keep-alive로 대신하지 않는다.

## 실행 순서와 완료 기준

### A. 이번 인증 UX 변경 — 최우선

- [x] 웹·SwiftUI 로그인/회원가입 분리와 기존 서버 동의 상태 분기 소스·회귀 테스트 확인. 재동의 예외 유지.
- [ ] Auth 트리거가 신규 Google 사용자의 미동의 계정을 어떤 최소 상태로 생성하는지 검증; 공동체 RLS는 동의 전 fail-closed 유지.
- [x] 취소·에러·계정/PKCE 목적 제한·중복 클릭·현재 동의 버전 회귀 테스트. 로컬 브라우저 새로고침·가입/로그인 이동과 시뮬레이터 뒤로 가기 확인. 실제 다계정 인증은 아래 실기기 게이트에 남김.
- [ ] 실제 iPhone 로그인→계정 선택→앱 복귀, 기존 회원 홈, 신규 동의/가입을 본인이 검증한 뒤 배포.

### B. 일상 홈과 공동체 기본 동등성

2026-10-14 단계 B-1 검증:

- [x] 웹·SwiftUI의 개인 통독 위젯, 서버 한국 날짜/연도 기반 장별 진도와 연속 일수, 비공개 QT 저장·삭제를 추가했다. 본문은 미배포하며 사실적인 66권/1,189장 참조만 제공한다.
- [x] 선택 동의 문서의 정확한 버전/hash와 본인 확인 이후만 기록 접근을 허용한다. 기존 5종 필수 동의와 이력은 그대로 유지했다. 철회 시 개인 진도·QT·요청 해시를 삭제하는 최소 자기 서비스 경로를 제공한다.
- [x] 운영 DB 확장 마이그레이션 `20261014101836_faith_reading_private_qt` 적용과 private 4개 테이블 RLS/직접 조회 금지, 공개 RPC 8개 anon 실행 금지 및 고정 search_path를 확인했다. 운영 사용자 대신 동의하거나 실제 개인 기록을 생성하지 않았다.
- [x] SwiftUI의 교회 공개/초대 전용 채널 생성, 참여·초대 수락, 채널 텍스트 메시지, 1:1 대화 시작·텍스트 전송, 행사 참석/미정/불참 응답을 기존 scoped RPC에 연결했다. 안정된 요청 UUID와 세션 변경 시 오래된 응답 폐기를 유지한다.
- [x] 웹 51개 파일/424개 테스트, iOS 47개 테스트, 격리 로컬 DB pgTAP 60개 통과. 웹 production build·비밀/법적 문서/SQL lint·Edge 보안 36개·보호 런타임 28개 점검 통과. iPhone 개발용 빌드 설치·프로세스 실행 확인.
- [ ] 실사용자가 직접 선택 동의·개인 QT·채널 생성·메시지·일정 응답을 완료한 실기기 end-to-end 증거는 아직 필요하다. 본인 대신 동의/공유/실제 행사 응답을 수행하지 않는다.
- [ ] SwiftUI 메시지 미디어·실시간 갱신·이모지/멘션/전달·private 초대 관리, QT 게시판 공유·더 보기·아멘과 조직 랭킹은 미완료이다. 웹 QT 공유만 기존 게시판에 명시적 확인 후 사본 생성한다. 전체 단계 B 완료로 표시하지 않는다.

운영 Supabase advisors의 새 private 테이블 정책 없음(INFO)은 RPC-only/direct grants 없음의 의도된 fail-closed 설계이며, authenticated SECURITY DEFINER 경고는 actor/현재 동의/정확한 회원권/고정 search_path/anon revoke 검증으로 제한한다. 별개 기존 Cashlog 익명 trigger 실행 경고와 유출 비밀번호 보호 비활성 경고는 이 단계에서 다른 서비스의 설정을 바꾸지 않았으며 별도 운영 검토가 필요하다. [Supabase advisory 설명](https://supabase.com/docs/guides/database/database-linter)

- [ ] 본문 권리 확인, 데이터 모델/RLS 합의 후 통독/QT 기능성 위젯·진도·개인 streak·고유 반응을 개발. 허가 본문 없을 때 실제 말씀 텍스트/AI 해설을 꾸며 표시하지 않음.
- [ ] 조직 랭킹은 옵트인·집계 최소 표본·본인 공개 선택으로 설계; 미성년자 이름·개인 읽기 이력의 무단 전사 공개 금지.
- [ ] SwiftUI 채널 생성·DM·글/댓글/신고·일정 RSVP·권한 명단의 실제 기능을 웹과 맞춤. 빈/실패/오프라인/가장 긴 한국어/VoiceOver/44px 터치 검증.

### C. 행사 현장 운영

- [ ] 현재 event/occurrence·rsvp·logistics 모델 위에 부분 참석·운전 지원·출발지 최소 필드를 추가.
- [ ] 숙소·자동 편성 설정·일괄 미리보기·수동 조정과 revision 충돌 해결을 개발. 실제 입력과 동의 없이 연령·성별 배정 금지.
- [ ] 권한 기반 xlsx, 안전한 행사 QR·스태프 만료·멱등 체크인, 참가 취소/정지/재동의 시 토큰 차단 검증.
- [ ] 회비 납부의 권한·환불·역분개·중복 처리와 감사 기록을 먼저 구현하고 장부 연동.

### D. AI·회의·회계·라이브 외부 연계

- [ ] 공급자·예산·보존·국외이전/문서·사용자 허용 데이터 경계를 승인받은 후 AI 서버 프록시·쿼터·초안 검토 흐름 구현.
- [ ] 회의록/장부의 조직·행사 범위를 정확히 확장하고 SwiftUI 작성·첨부·결산 기능 개발. 부서 직책에 임원 장부 권한을 자동 부여하지 않음.
- [ ] Jitsi 실제 호스팅 정책과 네이티브 SDK 검증 후 제한된 파일럿. YouTube URL 검증·교회 방송 권한·권리/촬영 안내·중단 버튼 검증 후 라이브 파일럿.

### E. 공개된 운영 관제와 출시

- [ ] 실제 공급자 사용량 수집·수집 실패 표시·시간·예산 경보, 최소 가입/접속 집계 개발. 개인정보가 필요한 개별 접속 추적은 별도 정책 검토.
- [ ] 사건 기반 신고 검토·열람 사유·감사 검색·이의제기, 백업 복구와 보존 정책 확정. 스텔스 감시·원본 프리패스·자동 90일 삭제는 제외.
- [ ] staging 300 동시 사용자+다중 연결·재접속·메시지 fan-out·권한 철회 시험, 현장 QR 혼선/중복·API 실패 및 비용 계측.
- [ ] Release Archive·실기기·TestFlight·심사 계정·탈퇴·UGC 운영·개인정보/권한 문구·스토어 메타데이터를 검증한 후 App Store 제출. 개발 기기 설치와 배포 가능한 출시본을 구분.

8주/영구 무료/전 기능 완료를 고정 약속하지 않고 위 단계별 검증 산출물로 완료 여부를 판단한다.
