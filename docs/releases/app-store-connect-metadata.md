# App Store Connect 1.0 메타데이터 초안

기준일: 2026-08-31
대상: `apps/web` 번들 자산을 포함한 Capacitor iOS 앱 `재건 공동체`

이 문서는 App Store Connect 입력용 작업지이다. 출시 가능 여부와 보안 게이트의 기준은 [iOS App Store 1.0 출시 게이트](ios-app-store-1.0.md)이며, 이 문서의 문구만으로 심사 준비가 완료되었다고 판단하지 않는다. 비밀번호, TOTP 비밀값, 복구 코드와 실제 회원 정보는 이 저장소에 기록하지 않고 App Store Connect의 App Review Information에만 입력한다.

## 제출 전 반드시 확정할 값

| 항목 | 현재 초안 | 제출 전 조치 |
| --- | --- | --- |
| 개발자 계정 | 법인·기관 명의 조직 계정 권고 | **TODO:** 종교 소속 민감정보를 처리하는 실제 서비스 운영 법인으로 등록했는지, D-U-N-S·조직 도메인 이메일·계약 권한자를 확인한다. 개인 계정으로 제출하지 않는다. |
| 앱 이름 | `재건 공동체` | 상표·기관 명칭 사용 권한 확인 |
| 영문 이름 | `Jaegun Community` 후보 | **TODO:** 브랜드 영문 표기 승인. 승인 전에는 영문 현지화를 만들지 않는다. |
| Bundle ID | 로컬 임시값 `com.uichanlee.jaegun` | **TODO:** 조직 계정에서 최종 ID를 확정하고 Team ID, Associated Domains와 AASA를 함께 갱신. `capacitor.config.ts`, Xcode project, JS 복구 키와 Swift Keychain service·설치 marker namespace를 한 묶음으로 검토하고, 기존 namespace 유지 또는 명시적 migration을 결정 |
| SKU | 미정 | **TODO:** 외부에 노출되지 않는 불변값 결정. 예: `JAEGUN-IOS-1` |
| 버전 | `1.0` / build `1` 후보 | signed Archive에서 최종 확인 |
| 저작권 | 미정 | **TODO:** `2026 <법인 정식명칭>` 입력. Apple이 © 표시는 자동으로 붙인다. |
| 기본 언어 | 한국어 | 한국어 UI만 제공하는 1.0의 기본 언어로 확정 |
| 가격·구매 | 무료, IAP 없음 후보 | **TODO:** 유료 기능·후원·외부 결제 유도가 실제로 없는지 제품 책임자 확인 |
| 배포 방식 | Unlisted App 우선 후보 | **TODO:** 공개 검색 배포와 Unlisted 중 기관이 승인. Unlisted여도 링크 보유자는 설치할 수 있으므로 서버 회원 승인을 유지한다. |
| 판매 지역 | 대한민국 우선 후보 | **TODO:** 실제 운영·지원 가능한 국가만 선택하고 대한민국 조직 배포 정보 입력 |
| 지원 연락처 | 공개 이메일 설정 및 `/support` 코드 구현 완료 | **TODO:** 배포 후 비로그인 HTTP 200, 문의 링크와 필요한 법적 연락 정보의 실제 표시를 검수 |
| 심사 연락처 | 미정 | **TODO:** 실명, 조직 이메일, `+82` 국제 형식 전화번호와 심사 기간 응답 담당자 지정 |

## 권장 App Store 분류

- 기본 언어: 한국어
- 주 카테고리: `Social Networking`
- 보조 카테고리: `Lifestyle`
- Made for Kids: `No`
- 목표 글로벌 연령등급: `16+` 상향 지정
- 앱 유형: 무료 비공개 회원 커뮤니티, 광고 없음, IAP 없음 후보

게시판, 댓글과 1:1 채팅이 핵심 경험이므로 `Social Networking`이 실제 기능을 가장 잘 설명한다. 교회 공동체 운영이라는 주제는 보조 카테고리 `Lifestyle`로 표현한다. 종교 앱이라는 이유만으로 `Reference`, `Education` 또는 `News`를 선택하지 않는다.

## 한국어 현지화

### 이름

```text
재건 공동체
```

### 부제

30자 제한 내 초안:

```text
승인된 교회 구성원을 위한 소통 공간
```

### 홍보 문구

170자 제한 내 초안:

```text
교회 소식, 게시판, 1:1 채팅, 일정, 교회·노회·총회 조직 정보를 한곳에서 확인하세요. 역할별 승인과 신고·차단 기능으로 공동체를 안전하게 운영합니다.
```

### 설명

```text
재건 공동체는 승인된 교회 구성원이 소식과 일정을 나누고 조직을 운영하는 비공개 커뮤니티입니다.

교회·노회·총회 계층에 맞춰 필요한 정보만 보여 주고, 소속과 역할은 관리자 승인 후 활성화됩니다.

주요 기능
• 우리 교회의 공지와 최근 소식 확인
• 교회 구성원 게시판과 댓글
• 승인된 구성원 간 1:1 채팅
• 총회·노회·교회 일정과 참석 응답
• 교회 소개와 권한 범위에 따른 명단 확인
• 사역자와 임원을 위한 회원 승인 및 조직 운영
• 연도별 임원, 회의록, 회계장부와 부서 임원 관리

안전과 개인정보
• 게시글, 댓글, 메시지와 사용자 신고
• 사용자 차단과 차단 목록 관리
• 프로필 공개 범위와 필수 동의 관리
• 보안센터, 로그아웃과 앱 안에서 시작하는 계정 삭제

가입과 로그인은 교회 구성원의 게시물, 대화와 조직 자료를 보호하기 위해 필요합니다. 가입자는 노회와 교회를 선택하고 승인을 받아야 공동체 기능을 이용할 수 있습니다. 역할과 조직 범위에 따라 사용할 수 있는 관리 기능이 달라집니다.
```

### 키워드

공백 없이 쉼표로 구분한 93바이트 초안이다. 앱 이름과 같은 `재건`, `공동체`는 반복하지 않는다.

```text
교회소식,교인명단,교회일정,교회게시판,개인채팅,노회조직,회계장부
```

## 영어 현지화 초안

1.0의 화면 언어가 한국어뿐이므로 영문 현지화 활성화는 제품 책임자의 별도 결정이 필요하다. 영문 스토어 정보를 제공한다면 설명에서 한국어 UI임을 숨기지 않는다.

### Name

브랜드 승인 전 후보:

```text
Jaegun Community
```

### Subtitle

30-character limit draft:

```text
Private Church Community
```

### Promotional text

170-character limit draft:

```text
News, boards, direct chat, events, and church governance for approved members—backed by role-based access, reporting, and blocking.
```

### Description

```text
Jaegun Community is a private community where approved church members share news and events and support church operations.

Information is organized by church, presbytery, and general assembly. Membership and role-based access become active only after approval.

Key features
• Official church updates and recent community news
• Member boards and comments
• One-to-one chat between approved members
• Events and attendance responses
• Church profiles and permission-scoped rosters
• Member approval and organization tools for authorized ministers and officers
• Year-based officer assignments, meeting minutes, accounting ledgers, and ministry department officers

Safety and privacy
• Reporting for posts, comments, messages, and users
• User blocking and blocked-user management
• Profile visibility and consent controls
• Security center, sign-out, and in-app account deletion

Sign-in is required to protect private posts, conversations, and organization records. New users select their presbytery and church and must be approved before accessing community features. Administrative tools vary by role and organization scope.

The app interface is currently available in Korean.
```

### Keywords

82-byte draft:

```text
church,members,bulletin,chat,events,presbytery,assembly,ministry,governance,roster
```

## URL과 정책 입력

| App Store Connect 필드 | 값 또는 후보 | 상태 |
| --- | --- | --- |
| Privacy Policy URL | `https://jaegun-com.vercel.app/legal/privacy/2026-08-30` | 제출 직전 HTTP 200, 문서 해시·현재 필수 버전과 일치 확인 |
| Support URL | `https://jaegun-com.vercel.app/support` | 코드 구현 완료. **TODO:** 프로덕션 배포 후 비로그인 HTTP 200과 문의 링크·콘텐츠 확인 |
| Marketing URL | 공개 제품 소개 페이지 후보 | **TODO:** 로그인 화면을 마케팅 URL로 사용하지 않는다. 준비되지 않으면 선택 필드를 비운다. |
| User Privacy Choices URL | 선택 입력 | 앱 안 `/app/privacy`는 로그인 필요. 공개 선택 페이지가 없으면 1.0에서는 비우고 인앱 경로를 심사노트에 안내 |
| Age Suitability URL | 선택 입력 | 전용 공개 안내 페이지가 없으면 비운다. 이용약관 URL을 연령 적합성 페이지라고 오표기하지 않는다. |
| Terms of Service | `https://jaegun-com.vercel.app/legal/terms/2026-08-30` | Review Notes 참고 링크로 사용 |
| Community Guidelines | `https://jaegun-com.vercel.app/legal/community/2026-08-30` | Review Notes 참고 링크로 사용 |
| Account Deletion 안내 | `https://jaegun-com.vercel.app/account-deletion` | 로그인 전 접근과 실제 인앱 삭제 경로 확인 |

App Privacy 항목은 이 문서에서 별도로 재정의하지 않는다. [출시 게이트의 App Privacy 선언 초안](ios-app-store-1.0.md#app-privacy-선언-초안)을 Archive Privacy Report, Supabase 운영 로그와 대조해 그대로 입력한다. iOS 1.0부터 회계장부는 `Other Financial Info`, actor 연결 감사 로그는 `Other Usage Data`, 이메일 문의는 `Customer Support`, 호스팅·백엔드 요청 로그는 `Coarse Location`과 `Other Diagnostic Data`로 공개하며 모두 보수적으로 `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`로 입력한다. 서비스에 저장된 기존 미디어를 iOS에서 열람하므로 `Photos or Videos`도 같은 방식으로 공개한다. 제출 전 Vercel·Supabase의 실제 요금제별 보존기간, Log Drain 사용 여부와 운영자 접근 범위를 확인해 개인정보처리방침과 일치시킨다. 외부 SDK가 없다는 이유만으로 자동 수집 로그를 누락하지 않는다. iOS 1.0에서 수집하지 않는 APNs 토큰과 광고 ID는 편의를 위해 선택하지 않는다.

## 연령등급 설문 답변 초안

연령등급은 실제 기능을 숨기지 않고 답한 뒤 `Override to Higher Age Rating`으로 글로벌 `16+`를 선택한다. App Store 연령등급은 가입자의 신원을 확인하는 수단이 아니며, 현재 서비스의 만 14세 이상 자기확인 정책을 대신하지 않는다. 한국 스토어에는 지역 등급이 별도로 표시될 수 있으므로 저장 후 App Store Connect가 계산한 대한민국 등급을 캡처해 승인받는다.

| 문항 | 초안 | 근거·주의 |
| --- | --- | --- |
| Parental Controls | No | 보호자가 자녀 기능을 관리하는 도구는 없음 |
| Age Assurance | No 후보 — **TODO 확인** | 가입 시 만 14세 이상 자기확인은 있지만 Declared Age Range API, 신분증 확인 또는 연령 추정은 구현하지 않음. 제출 당시 App Store Connect가 단순 자기확인을 이 문항에 포함하는지 최종 확인 |
| Unrestricted Web Access | No | 외부 이동은 허용 목록의 법적 문서뿐이며 자유 웹 탐색을 제공하지 않음 |
| User-Generated Content | Yes | 게시글, 댓글과 사용자 프로필 콘텐츠 |
| Social Media | Yes | 승인된 조직 범위의 게시판·댓글·피드에서 UGC를 여러 구성원이 발견하고 상호작용 |
| Social Media Disabled for Users Under 13 | No | 만 14세 미만 가입은 막지만 Apple이 요구하는 Declared Age Range API 기반 전환은 없음. 이 문항을 연령 자기확인만으로 Yes 처리하지 않음 |
| Messaging and Chat | Yes | 승인된 구성원 간 1:1 텍스트 채팅 |
| Advertising | No | 광고 SDK와 유료 홍보 없음 |
| Profanity or Crude Humor | Infrequent | 금지·필터·신고 대상이지만 UGC에서 위반 표현을 완전히 배제할 수 없음을 보수적으로 반영 |
| Horror/Fear Themes | None | 의도된 콘텐츠 없음 |
| Alcohol, Tobacco, or Drug Use or References | None | 의도된 콘텐츠 없음 |
| Medical or Treatment Information | None 후보 — **TODO 표본 확인** | 기도 제목에서 질병이 언급될 수 있어도 진단·치료 지침을 제공하는 서비스가 아님. 실제 운영 콘텐츠 표본이 다르면 즉시 수정 |
| Health or Wellness Topics | No | 건강·웰니스 조언 서비스가 아님 |
| Mature or Suggestive Themes | None | 의도된 콘텐츠 없음 |
| Sexual Content or Nudity | None | 금지 콘텐츠이며 의도된 콘텐츠 없음 |
| Graphic Sexual Content and Nudity | None | 금지 콘텐츠이며 의도된 콘텐츠 없음 |
| Cartoon or Fantasy Violence | None | 의도된 콘텐츠 없음 |
| Realistic Violence | None | 의도된 콘텐츠 없음 |
| Prolonged Graphic or Sadistic Realistic Violence | None | 금지 콘텐츠이며 의도된 콘텐츠 없음 |
| Guns or Other Weapons | None | 의도된 콘텐츠 없음 |
| Simulated Gambling | None | 기능 없음 |
| Gambling | No | 기능 없음 |
| Contests | None | 순위·보상 경쟁 기능 없음 |
| Loot Boxes | No | 기능·구매 없음 |
| Made for Kids | No | 어린이 대상 앱이 아니며 만 14세 미만 가입 불가 |
| Age Category and Override | Override to Higher Age Rating → `16+` | 설문 답변은 바꾸지 않고 보수적으로 상향 |

제출 직전 다음을 다시 확인한다.

- [ ] App Store Connect의 최신 문항명과 선택지가 표와 같은지 확인
- [ ] 합성 시드와 심사 계정 데이터에 위 표와 다른 성인·폭력·의료·도박 콘텐츠가 없는지 확인
- [ ] 글로벌 `16+`와 대한민국 지역 표시 결과를 캡처하고 제품 책임자 승인
- [ ] 만 14세 이상 가입 정책과 16+ 스토어 표시가 서로 다른 목적임을 고객지원 문서에서 혼동 없이 설명
- [ ] 향후 iOS 공식 클라이언트의 사진·영상 업로드, 라이브, 자유 외부 링크 또는 건강 정보 기능을 켤 때 설문을 다시 제출

## 스크린샷 캡처 매트릭스

iOS 1.0 Xcode 대상은 iPhone 세로 전용(`TARGETED_DEVICE_FAMILY = 1`, portrait-only)이다. 검증되지 않은 iPad 네이티브 지원, 가로 회전과 iPad 스크린샷은 이번 버전에 포함하지 않는다. 세로 화면 기준 권장 원본은 iPhone 6.9형 `1320 × 2868`(iPhone 16 Pro Max 계열)이며, Simulator가 만드는 실제 픽셀이 Apple 허용 규격과 일치하는지 업로드 전 다시 확인한다. 각 현지화당 1~10장을 올릴 수 있으며, 아래 8장 구성을 권장한다.

| 순서 | 화면·경로 | 계정 상태 | 준비할 합성 데이터 | 한국어 캡션 후보 | English caption draft |
| --- | --- | --- | --- | --- | --- |
| 1 | 회원 홈 `/app/home` | 승인된 일반 회원 | 심사용 교회명, 환영 공지, 최근 게시글과 일정 | 우리 교회의 소식을 한눈에 | Your church at a glance |
| 2 | 게시판 `/app/posts` 또는 상세 | 승인된 일반 회원 | 개인정보 없는 공지·나눔·댓글, 신고 메뉴가 보이는 상태 | 함께 나누는 공동체 게시판 | A board for your community |
| 3 | 1:1 채팅 `/app/chats/:conversationId` | 승인된 일반 회원 2명 | 합성 대화, 사용자 차단·메시지 신고 진입점 | 승인된 구성원끼리 1:1 대화 | One-to-one chat for members |
| 4 | 교회 목록·상세 `/app/churches` | 승인된 일반 회원 | 가상 교회 이름·소개와 노회 필터. 명단 또는 총회 관리 화면을 이 경로에 합성하지 않음 | 교회 정보와 소속 공동체 탐색 | Discover church profiles |
| 5 | 일정 `/app/events` | 승인된 일반 회원 | 가상 예배·회의 일정과 참석 응답 | 공동체 일정과 참석 응답 | Events and attendance responses |
| 6 | 운영 홈 또는 승인 `/manage/home` | 심사용 사역자 | 합성 가입 신청, 역할별 작업 카드 | 역할에 맞춘 회원·조직 운영 | Role-aware community operations |
| 7 | 조직·부서 임원 `/manage/organization`, `/manage/departments` | 현재 연도 명시적 담임목사 심사 계정 | 같은 교회의 활성 합성 회원과 부서별 직책 | 교회와 부서의 연도별 임원 관리 | Year-based church and department officers |
| 8 | 회의록·회계 `/manage/minutes`, `/manage/ledger` | 현재 연도 서기·회계 직책이 명시된 임원 심사 계정 | 실제 인명·금액이 아닌 명백한 합성 연도 자료 | 권한에 맞춘 회의록과 회계장부 | Office-scoped minutes and accounting |
| 선택 | 개인정보·안전 `/app/profile`, `/app/blocked-users`, `/app/account` | 승인된 일반 회원 | 차단 사용자 1명 또는 삭제 미예약 상태 | 신고·차단·개인정보를 직접 관리 | Reporting, blocking, and privacy |

### 캡처 규칙

- [ ] 브라우저 목업이 아니라 최종 Release 후보 앱을 해당 Simulator에서 직접 실행해 캡처
- [ ] 최종 iPhone Release 후보에서 동일한 기능 순서와 세로 방향을 유지하고 작은 화면·큰 화면 크기를 각각 검수
- [ ] 실명, 실제 교회 내부자료, 이메일, 전화번호, 계좌, 실제 회계 금액, 실제 채팅과 신고 증거를 사용하지 않음
- [ ] 모든 이름·교회·게시글·대화·회의록·회계 값은 심사용 합성 데이터임을 데이터 준비표에 기록
- [ ] iOS 1.0 공식 클라이언트에 없는 파일 선택·촬영 흐름, 카메라·사진·마이크 권한 요청과 APNs 알림 허용 화면을 보여 주지 않음. 기존 미디어를 캡처하면 합성 자료만 사용하고 신고 가능한 UGC임을 검수
- [ ] `알림` 화면을 캡처할 경우 APNs 푸시가 아니라 앱 안 활동 내역임을 캡션에서 오해시키지 않음
- [ ] 빈 화면, 로딩 스피너, 오류 토스트, 디버그 메뉴, 데모 배지, 개발 서버 주소와 개인정보 동의 미완료 상태를 제외
- [ ] 원본을 임의 확대·왜곡하지 않고 허용된 JPEG/JPG/PNG로 저장하며 알파 채널·투명도 제거
- [ ] 현지화별 캡션과 앱 화면 언어가 일치하는지 확인. 한국어 UI만 제공하는 1.0에서 영어 UI처럼 보이게 합성하지 않음
- [ ] 관리 화면은 실제 권한으로 로그인해 촬영하고 일반 회원에게 해당 권한이 있는 것처럼 표현하지 않음
- [ ] 첫 3장은 홈, 게시판, 채팅으로 일반 회원의 핵심 가치를 먼저 전달

## App Review Notes 입력 초안

다음 텍스트의 `<TODO_...>`만 App Store Connect에서 채운다. 기본 계정 비밀번호는 Sign-in required 필드에, 추가 계정과 MFA 시험 정보는 reviewer에게만 보이는 App Review Notes에 입력한다. 어느 값도 Git에 커밋하지 않는다.

한국어 블록은 내부 검토용이고 영어 블록이 제출 기본안이다. 두 블록을 한 Notes 필드에 함께 붙이지 않는다.

### 한국어 참고본

```text
재건 공동체는 승인된 교회 구성원만 사용하는 비공개 커뮤니티입니다. 로그인은 교회 명단, 게시글, 1:1 채팅, 회의록과 회계 자료를 보호하기 위해 필요합니다.

기본 심사 계정
- 이메일: App Review의 Sign-in required 필드 참고
- 비밀번호: App Review의 Sign-in required 필드 참고
- 소속: <TODO_SYNTHETIC_REVIEW_CHURCH>
- 상태: 이메일 확인, 필수 동의와 회원 승인이 완료된 합성 데이터 계정

주요 확인 경로
1. 홈: 로그인 후 홈
2. 게시판 신고: 게시판 > 합성 게시글 상세 > 신고
3. 사용자 차단: 1:1 대화 > 상대방 안전 메뉴 > 사용자 차단
4. 차단 목록: 내 정보 > 차단한 사용자
5. 개인정보: 내 정보 > 개인정보와 동의
6. 계정 삭제: 아래 전용 삭제 심사 계정으로 다시 로그인한 뒤 내 정보 > 계정 삭제로 이동합니다. 현재 비밀번호와 필요한 경우 MFA로 본인 확인하고 ‘계정 삭제’를 입력하면 14일 유예 예약이 생성되며 유예기간 안에 취소할 수 있습니다. 기본 심사 계정에서는 삭제를 실행하지 말아 주세요.

계정 삭제 전용 심사 계정
- 이메일: <TODO_REVIEW_DELETION_EMAIL>
- 비밀번호·MFA 방법: App Review Information의 reviewer 전용 Notes 참고
- 상태: 이메일 확인, 필수 동의와 회원 승인이 완료된 합성 데이터 계정

역할별 관리 기능을 확인할 추가 계정과 경로
- 사역자: <TODO_REVIEW_MINISTER_EMAIL> / 운영 > 회원 승인
- 임원: <TODO_REVIEW_EXECUTIVE_EMAIL> / 현재 연도 서기·회계 직책 명시 / 운영 > 회의록·회계
- 담임목사: <TODO_REVIEW_PASTOR_EMAIL> / 현재 연도 해당 교회 담임목사 직책 명시 / 운영 > 조직·부서 임원
추가 계정의 비밀번호와 MFA 시험 방법은 App Store Connect의 reviewer 전용 App Review Information에만 제공합니다. MFA는 심사를 위해 우회하지 않습니다.

iOS 1.0 안내
- 공식 iOS 클라이언트는 사진·영상 업로드 UI를 제공하지 않아 카메라, 사진 보관함과 마이크 권한을 요청하지 않습니다. 서비스에 이미 저장된 사진·영상은 승인된 구성원이 열람할 수 있으며 App Privacy 공개와 신고·삭제 정책의 적용을 받습니다.
- APNs 푸시를 포함하지 않으며 알림 권한을 요청하지 않습니다. 앱의 알림 화면은 로그인 후 확인하는 인앱 활동 내역입니다.
- 자유 웹 브라우징은 없고 운영 도메인의 버전 고정 법적 문서만 외부 브라우저 화면으로 엽니다.
- 광고, 인앱 구매, 구독과 라이브 스트리밍은 없습니다.

기본·사역자·임원·담임목사 심사 계정은 실제 회원 정보가 없는 합성 데이터만 포함하고 자동 만료되지 않으며 가입 승인과 이메일 확인이 완료되어 있습니다. 삭제 전용 계정만 삭제 기능 시험에 사용하며, 기본 계정은 심사와 이의제기 기간 내내 유지합니다.

개인정보처리방침: https://jaegun-com.vercel.app/legal/privacy/2026-08-30
공동체 운영정책: https://jaegun-com.vercel.app/legal/community/2026-08-30
계정 삭제 안내: https://jaegun-com.vercel.app/account-deletion
지원: https://jaegun-com.vercel.app/support
```

### English submission draft

```text
Jaegun Community is a private community for approved church members. Sign-in is required to protect church rosters, posts, one-to-one conversations, meeting minutes, and accounting records.

Primary review account
- Email: See the Sign-in required field in App Review Information
- Password: See the Sign-in required field in App Review Information
- Organization: <TODO_SYNTHETIC_REVIEW_CHURCH>
- State: Email confirmed, required consents completed, and membership pre-approved; synthetic data only

Main review paths
1. Home: Sign in and open Home.
2. Report a post: Board > open the synthetic review post > Report.
3. Block a user: One-to-one conversation > the other user's safety menu > Block User.
4. Manage blocked users: My Info > Blocked Users.
5. Privacy controls: My Info > Privacy and Consent.
6. Delete an account: Sign out and use the dedicated deletion account below, then go to My Info > Account Deletion. Reauthenticate with the current password and MFA when required, enter the Korean confirmation phrase “계정 삭제”, and confirm. This creates a 14-day deletion grace period that can be canceled in the app. Please do not delete the primary review account.

Dedicated account-deletion review account
- Email: <TODO_REVIEW_DELETION_EMAIL>
- Password and MFA instructions: See the reviewer-only Notes in App Review Information
- State: Email confirmed, required consents completed, and membership pre-approved; synthetic data only

Additional role accounts and paths
- Minister: <TODO_REVIEW_MINISTER_EMAIL> / Operations > Member Approvals
- Executive officer: <TODO_REVIEW_EXECUTIVE_EMAIL> / explicit current-year secretary and accountant offices / Operations > Meeting Minutes or Accounting
- Church pastor: <TODO_REVIEW_PASTOR_EMAIL> / explicit current-year pastor office for the review church / Operations > Organization or Department Officers
Passwords and MFA test instructions for additional accounts are provided only in the reviewer-only App Review Information in App Store Connect. MFA is not bypassed for review.

iOS 1.0 notes
- The official iOS client does not offer photo or video upload UI and does not request Camera, Photo Library, or Microphone permission. Authorized members can view existing photos and videos stored by the service; these remain covered by the privacy disclosure and the reporting and removal policy.
- This version does not include APNs push notifications and does not request notification permission. The Notifications screen is an in-app activity inbox.
- The app does not offer unrestricted web browsing. Only versioned legal documents on the service domain open in the system browser view.
- There are no ads, in-app purchases, subscriptions, or live streaming features.
- The interface is currently in Korean.

The primary, minister, executive, and pastor review accounts contain synthetic data only, are email-confirmed and pre-approved, and do not expire automatically. Only the dedicated deletion account is used to test account deletion. The primary account remains active throughout review and any appeal period.

Privacy policy: https://jaegun-com.vercel.app/legal/privacy/2026-08-30
Community guidelines: https://jaegun-com.vercel.app/legal/community/2026-08-30
Account deletion information: https://jaegun-com.vercel.app/account-deletion
Support: https://jaegun-com.vercel.app/support
```

## 심사 제출 체크리스트

### 계정·계약·앱 레코드

- [ ] 서비스 운영 법인의 Apple Developer 조직 계정, D-U-N-S, 조직 도메인 이메일과 계약 권한자 확인
- [ ] 최종 Team ID, Bundle ID, App ID, Associated Domains와 AASA 일치
- [ ] App Store Connect 앱 이름, SKU, 기본 언어, 버전, 저작권의 법인 승인
- [ ] 대한민국 배포에 필요한 조직 정보 입력
- [ ] EU 배포 시 Digital Services Act trader 상태와 공개 연락 정보 법무 확인
- [ ] 중국 본토는 종교 정보 서비스에 필요한 허가·위임서·사업자·ICP 자료를 법무가 확인하기 전 판매 지역에서 제외
- [ ] 공개 또는 Unlisted 배포 방식 최종 승인; Unlisted 신청 절차와 링크 유출 대응 문서화
- [ ] 주·보조 카테고리와 무료 가격 확인
- [ ] Pricing and Availability에서 iPhone 앱의 Apple silicon Mac 제공을 해제. 1.0은 Mac 실행·키보드·창 크기·Keychain을 검증하지 않음
- [ ] Pricing and Availability에서 Apple Vision Pro 제공을 해제. 1.0은 visionOS 호환 실행과 입력 방식을 검증하지 않음
- [ ] Content Rights에서 UGC와 조직 자료를 다룬다는 사실을 반영하고, 이용약관상 게시 권한·신고·삭제 절차 법무 확인

### 빌드·개인정보·수출 규정

- [ ] signed Archive의 Bundle ID, 버전, build, 최소 iOS 16.0, iPhone 전용 `TARGETED_DEVICE_FAMILY = 1`과 portrait-only 방향 확인
- [ ] Archive Privacy Report와 [App Privacy 선언 초안](ios-app-store-1.0.md#app-privacy-선언-초안) 일치
- [ ] 회계장부의 `Other Financial Info`를 `Linked to User: Yes`, `App Functionality`, `Tracking: No`로 공개
- [ ] actor 연결 감사 로그의 `Other Usage Data`와 이메일 문의의 `Customer Support`를 각각 `Linked to User: Yes`, `App Functionality`, `Tracking: No`로 공개
- [ ] Vercel·Supabase 요청 로그의 `Coarse Location`과 `Other Diagnostic Data`를 `Linked to User: Yes`, `App Functionality`, `Tracking: No`로 공개
- [ ] 기존 미디어가 iOS에서 열람되므로 `Photos or Videos`를 `Linked to User: Yes`, `App Functionality`, `Tracking: No`로 공개
- [ ] 공급자별 실제 보존기간, Log Drain 사용 여부와 운영자 접근 범위를 확인해 개인정보처리방침의 수탁자·보존 설명과 일치
- [ ] Tracking `No`, IDFA 미사용, 광고·외부 분석·외부 crash SDK 없음 확인
- [ ] `ITSAppUsesNonExemptEncryption=NO`와 실제 구현이 운영체제 표준 TLS/Keychain만 사용한다는 근거 확인
- [ ] APNs capability, push entitlement, 푸시 SDK와 알림 권한 요청이 없음
- [ ] Camera, Photo Library, Microphone 사용 설명 문자열과 접근 코드가 없음
- [ ] 공식 iOS 클라이언트에 파일 선택 UI가 없고 번들 내 업로드 호출이 차단되는지 시험. 이는 클라이언트 동작이며 서버가 iOS 플랫폼을 증명하는 권한 경계라고 기록하지 않음
- [ ] 계정 삭제 worker, 5분 scheduler, 14일 유예·취소·최종 Auth/Storage 삭제의 staging 근거 확보

### 메타데이터·이미지

- [ ] 한국어 이름·부제·홍보 문구·설명·키워드 길이 재검사
- [ ] 영문 현지화를 사용할 경우 브랜드 승인과 “현재 UI는 한국어” 문구 유지
- [ ] Privacy Policy URL, Community Guidelines와 Account Deletion URL이 비로그인 상태에서 HTTP 200으로 열림
- [ ] 공개 Support URL 배포 후 비로그인 HTTP 200, 운영 문의 링크와 필요한 연락 정보 표시 확인
- [ ] iPhone 6.9형 스크린샷을 합성 데이터로 캡처하고 iOS 1.0에 iPad 스크린샷을 올리지 않음
- [ ] 각 이미지의 픽셀 규격·방향·알파 채널·개인정보 노출 확인
- [ ] 공식 iOS 클라이언트가 제공하지 않는 업로드 UI, APNs, 라이브 또는 영어 UI를 이미지·설명에서 암시하지 않음. 기존 미디어 열람은 숨기지 않음
- [ ] 앱 아이콘 1024 × 1024, RGB, 알파 없음과 Archive 포함 여부 확인

### 연령등급·안전

- [ ] UGC, Social Media, Messaging and Chat을 모두 사실대로 `Yes`
- [ ] 자유 웹 접근·광고·도박·구매 기능을 실제 동작과 대조
- [ ] 글로벌 `16+` 상향 지정과 대한민국 지역 표시 캡처
- [ ] 서버 텍스트 필터, 게시글·댓글·메시지 신고, 사용자 차단과 운영큐 실제 시험
- [ ] 기존 사진·영상의 열람, 신고, 차단 반영, 운영자 숨김·삭제와 이의제기 흐름 실제 시험
- [ ] 운영 담당자, 지원 이메일, 신고 처리 SLA와 이의제기 절차 근무표 확인

### 심사 계정·Review Notes

- [ ] 일반 회원 심사 계정은 합성 데이터, 이메일 확인·필수 동의·가입 승인 완료, 자동 만료 없음
- [ ] `<TODO_REVIEW_DELETION_EMAIL>` 전용 합성 계정을 제공하고 기본 심사 계정에서 삭제를 실행하지 말라는 안내 확인
- [ ] 회원 승인용 사역자, 현재 연도 서기·회계 직책 임원, 현재 연도 명시적 담임목사 심사 계정을 각각 제공
- [ ] 추가 계정이 MFA를 요구하면 우회하지 않고 App Store Connect에 재현 가능한 시험 방법 제공
- [ ] 모든 계정이 심사 및 이의제기 기간 내 잠기거나 만료되지 않도록 모니터링
- [ ] 심사 연락 담당자가 한국 업무시간 외 Apple 문의에도 응답할 수 있는 대체 연락망 준비
- [ ] Notes의 경로를 TestFlight 최종 빌드에서 한 단계씩 재현
- [ ] 서버 점검·마이그레이션·심사 계정 데이터 초기화를 심사 기간에 예약하지 않음
- [ ] APNs·공식 iOS 클라이언트 미디어 업로드 UI·광고·IAP·구독·라이브가 없다는 안내와 기존 미디어 열람 안내가 실제 바이너리와 일치

## Apple 공식 참고자료

- [App 정보 필드](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [버전 정보와 문자 제한](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [스크린샷 업로드](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)
- [스크린샷 규격](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [카테고리 선택](https://developer.apple.com/app-store/categories/)
- [연령등급 설정](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- [연령등급 문항과 지역별 값](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)
- [App Privacy 세부 지침](https://developer.apple.com/app-store/app-privacy-details/)
- [계정 삭제 제공 지침](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [Apple Developer 조직 등록 요건](https://developer.apple.com/help/account/membership/program-enrollment/)
- [Unlisted App Distribution](https://developer.apple.com/support/unlisted-app-distribution)
