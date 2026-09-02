# iOS App Store 1.0 출시 게이트

기준일: 2026-09-02
대상: `apps/web`의 번들 웹 자산을 포함한 Capacitor iOS 앱

이 문서는 코드가 빌드된다는 사실과 App Store 출시 가능 상태를 구분한다. 아래 `BLOCK` 항목에 하나라도 근거가 없으면 TestFlight 내부 테스트까지만 허용하고 App Review 제출은 중단한다.

## 현재 출시 판정

| 게이트 | 상태 | 완료 근거 또는 남은 작업 |
| --- | --- | --- |
| Xcode 26 / iOS 26 SDK | 무서명 검증 완료 | Xcode 26.6·iOS 26.5 SDK의 Release 기기용 무서명 빌드와 번들 메타데이터 검증 통과. Store validation과 조직 서명 Archive는 별도 BLOCK |
| 법인 Apple Developer 조직 계정 | BLOCK | 종교 소속이라는 민감정보를 필수 처리하므로 서비스 제공 법인 명의 계정, D-U-N-S, 조직 도메인 이메일 확인 필요 |
| 최종 App ID·Team ID·서명 | BLOCK | 로컬 Bundle ID는 임시값. Apple 계정에서 최종 ID를 확인한 뒤 AASA와 함께 고정 |
| Keychain·PKCE·Universal Link | 코드 검증 완료 / 기기 BLOCK | Keychain `ThisDeviceOnly`, PKCE, 변조·중복·강제종료 복구 회귀 통과. 최종 Team ID의 AASA와 실제 설치·재설치 시험 필요 |
| 계정 삭제 실제 처리 | BLOCK | 워커·전용 secret·기본 비활성 GitHub fallback과 Supabase Cron/last-success·백로그 감시 계약 구현. read-only due/stale 점검 후 worker enable, 018 운영 반영, Vault credential 원자적 회전, provider-required cutover, 15분 heartbeat·알림 수신, staging hard-delete 증거 필요 |
| UGC 안전 운영 | BLOCK | 기존 사진·영상을 포함한 게시글·채팅 신고·차단·운영큐와 서버 쓰기 경계 텍스트 필터(016·017) 운영 반영 및 테스트 완료. 실제 미디어 신고 처리 인력/SLA 증거 필요 |
| 사진·영상 안전 | 공식 iOS 클라이언트 업로드 미제공 / 운영 BLOCK | 번들 iOS 앱의 업로드 UI와 프로그램 호출만 차단한다. 서버는 요청 플랫폼을 신뢰성 있게 증명할 수 없으므로 백엔드 권한 경계가 아니다. 웹/API 미디어 정책은 유지되고 기존 미디어는 iOS에서 열람되며, dormant scanner/transcoder를 대신할 신고·삭제 운영 증거가 필요하다. |
| APNs 푸시 | 보류 | 현 국외이전 동의에 Apple/APNs가 없어 iOS 1.0에서 SDK·entitlement·권한 요청 제외 |
| Privacy Manifest·App Privacy | 무서명 번들 검증 완료 / 제출 BLOCK | Release 앱 번들에 사진·영상을 포함한 12개 데이터 유형과 UserDefaults 사유 포함 확인. signed Archive report·공급자 보존 설정·App Store Connect 입력 대조 필요 |
| 심사용 계정·합성 데이터 | BLOCK | 승인 대기 없이 핵심 기능을 확인할 일반 회원 계정과 역할별 테스트 계정 필요 |
| 기기 지원 범위 | iOS 1.0 iPhone 세로 전용 고정 | 검증되지 않은 iPad·가로 회전 네이티브 UI를 1.0 범위에서 제외. Xcode Debug·Release 모두 `TARGETED_DEVICE_FAMILY = 1`, `Info.plist`는 portrait-only이며 동기화 후 preflight가 회귀를 차단 |
| 실제 기기·TestFlight | BLOCK | 지원 대상 iPhone에서 설치·복구·오프라인·키보드·미디어·탈퇴 시험 필요 |
| 익명 교회 디렉터리 RLS | 로컬 수정·검증 완료 / 운영 반영 대기 | `security_invoker` 뷰, 5개 공개 열 권한, 공개 상태 RLS와 7개 전용 pgTAP 추가. 019 마이그레이션 운영 반영 후 Advisor 재확인 필요 |

## 고정할 출시 구성

- 앱 이름: `재건 공동체`
- 로컬 자산 번들: `apps/web/dist`; `server.url` 또는 원격 코드 로딩 금지
- 지원 기기: iOS 1.0은 iPhone 세로 전용. iPad 네이티브 지원과 가로 회전은 별도 반응형·접근성·키보드·실기기 QA 후 후속 버전에서 검토
- 최소 지원 버전: iOS 16.0. 핵심 생성 흐름에서 사용하는 Web Crypto `crypto.randomUUID()`가 모든 지원 WebKit에 존재하도록 iOS 15.x는 1.0 대상에서 제외하며, iOS 16 실제 기기 시험 후 제출한다.
- v1 권한: 알림·사진 전체 접근·카메라·마이크·위치·연락처·광고 ID를 요청하지 않음
- 인증: 이메일/비밀번호 + PKCE, refresh token과 PKCE verifier는 Keychain `ThisDeviceOnly`
- 외부 링크: 운영 도메인의 법적 문서만 `SFSafariViewController`로 열고 나머지 메인 프레임 이동은 차단
- 네트워크/내비게이션: `server.allowNavigation`은 빈 배열, Cordova 접근 origin은 운영 Supabase HTTPS origin 하나만 허용하며 `native:sync:ios` 뒤 검증 스크립트로 고정
- 분석/광고/외부 crash SDK: v1에 추가하지 않음
- 배포 후보: 공개 검색보다 `Unlisted App`을 우선 검토. 링크 보유자도 설치할 수 있으므로 서버 승인은 계속 필수

## App Privacy 선언 초안

아래는 현재 서비스 동작 기준이며 Archive와 운영 로그·보존 정책이 다르면 실제 동작에 맞춰 수정한다. 실제로 수집하는 항목은 Tracking `No`, 목적 `App Functionality`, 계정과 연결됨 `Yes`로 입력한다. 조건이 붙은 항목은 해당 기능을 실제로 켠 버전부터 추가한다.

- Name
- Email Address
- Sensitive Info — 교회·노회·직분을 통해 드러나는 종교 소속
- User ID
- Emails or Text Messages — 1:1 채팅
- Other User Content — 게시글, 댓글, 소개, 신고, 회의록 등
- Other Usage Data — iOS 1.0에서 수집함. 승인·거버넌스·회의록·회계·신고·동의·보안 작업의 actor 연결 감사 로그. `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`
- Customer Support — iOS 1.0에서 사용자가 공개 지원 경로로 이메일 문의를 선택하면 문의 내용과 발신 이메일을 처리·보유함. `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`
- Other Financial Info — iOS 1.0에서 수집함. 권한 있는 임원이 입력하는 회계장부의 수입·지출 구분, 금액, 분류와 메모가 작성자 계정에 연결됨. `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`
- Coarse Location — iOS 1.0에서 수집함. Vercel과 Supabase가 서비스 제공·보안을 위해 요청 IP에서 국가·도시 수준 정보를 처리할 수 있음. 보수적으로 `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`
- Other Diagnostic Data — iOS 1.0에서 수집함. Vercel·Supabase가 서버 가용성·보안·오류 대응을 위해 요청 경로·시각, 사용자 에이전트, 응답 상태와 네트워크 메타데이터를 로그로 처리함. 보수적으로 `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`
- Photos or Videos — 서비스에 저장된 기존 사진·영상이 업로더·조직과 연결되고 승인된 사용자가 iOS 앱에서 열람함. iOS 공식 클라이언트가 새 업로드 UI를 제공하지 않더라도 `Linked to User: Yes`, `Purpose: App Functionality`, `Tracking: No`
- Device ID — 설치 UUID 또는 APNs 토큰을 실제 수집하는 버전부터

외부 분석 SDK가 없다는 이유만으로 사용·진단 데이터가 없다고 답하지 않는다. Apple은 IP 주소를 저장할 때 실제 사용에 따라 위치·식별자·진단 유형을 공개하라고 안내하며, Supabase API 로그에는 IP·국가·사용자 에이전트 등이 포함되고 Vercel은 IP에서 도시·국가 수준 위치를 처리한다고 밝힌다. 따라서 1.0은 위 `Coarse Location`과 `Other Diagnostic Data`를 보수적으로 공개한다. iOS 업로드 제한은 공식 클라이언트 동작일 뿐 서버가 증명하는 플랫폼 권한 경계가 아니며, 웹/API를 통해 저장된 사진·영상의 iOS 열람도 App Privacy와 UGC 안전 범위에서 제외하지 않는다. 제출 전 실제 요금제별 보존기간, Log Drain 사용 여부와 운영자 접근 범위를 대시보드에서 확인해 개인정보처리방침의 수탁자·보존 설명과 맞춘다. 안정적인 설치 식별자나 APNs 토큰을 수집하지 않으므로 `Device ID`는 선택하지 않는다. Product Interaction, Crash Data와 Performance Data는 별도 재고 조사에서 실제 수집 근거가 확인될 때만 선택한다.

## App Review Notes 초안

```text
재건 공동체는 승인된 교회 구성원만 사용하는 비공개 공동체 서비스입니다.
로그인은 교회 명단, 1:1 채팅, 회의록과 회계 자료를 보호하기 위해 필수입니다.

일반 회원 심사 계정
- 이메일: <REVIEW_MEMBER_EMAIL>
- 비밀번호: <REVIEW_MEMBER_PASSWORD>
- 교회: <SYNTHETIC_REVIEW_CHURCH>

주요 확인 경로
- 게시판 신고: 게시물 상세 > 신고
- 사용자 차단: 상대방 프로필/대화 > 차단
- 차단 사용자 관리: 내 정보 > 차단한 사용자
- 계정 삭제: 내 정보 > 보안 및 개인정보 > 계정 삭제
- 개인정보처리방침: 로그인 화면 및 내 정보 > 개인정보

심사 계정은 합성 데이터만 포함하고 만료되지 않으며 가입 승인과 이메일 확인이 완료되어 있습니다.
관리자 기능 확인이 필요한 경우 Review Notes에 별도 기간 제한 계정을 제공합니다. MFA는 우회하지 않습니다.
```

실제 비밀번호는 Git, 문서, 이슈, Review Notes 템플릿에 커밋하지 않고 App Store Connect의 보안 필드에만 입력한다.

## 제출 전 실제 기기 시험

- 최초 설치, 앱 삭제 후 재설치, 로그아웃, 계정 전환에서 이전 Keychain 세션이 복원되지 않음
- 이메일 확인·비밀번호 복구 Universal Link의 정상, 만료, 변조, 중복 클릭, 다른 기기 클릭
- 앱 백그라운드 전환 시 채팅·명단·회계 화면이 앱 전환기 스냅샷에 노출되지 않음
- 오프라인, 느린 네트워크, 토큰 만료, Wi-Fi/셀룰러 전환 후 안전한 재시도
- 모든 로그인·가입·MFA·채팅 폼에서 키보드와 하단 내비게이션이 겹치지 않음
- VoiceOver, Dynamic Type, 키보드 탐색, 색상 대비와 44px 터치 영역
- 계정 삭제 요청·취소·유예 만료·Storage/Auth 삭제 완료와 재로그인 차단
- 신고→숨김→제재→통지→이의제기 전 과정과 운영 SLA
- 공식 iOS 클라이언트에 파일 선택기가 없고 번들 내 업로드 호출이 차단되지만, 기존 사진·영상의 열람·신고·차단·운영자 삭제가 정상 동작함. 서버가 iOS 요청 자체를 식별한다고 가정하지 않음

## Apple 공식 기준

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [계정 삭제 제공 지침](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [App Privacy 세부 지침](https://developer.apple.com/app-store/app-privacy-details/)
- [Privacy Manifest](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [현재 App Store 제출 SDK 기준](https://developer.apple.com/app-store/submitting/)
- [Apple Developer 조직 등록 요건](https://developer.apple.com/help/account/membership/program-enrollment/)
- [Unlisted App Distribution](https://developer.apple.com/support/unlisted-app-distribution)
- [Supabase API 로그 수집 필드](https://supabase.com/docs/guides/monitoring-and-debugging/logs)
- [Vercel 요청 로그 필드](https://vercel.com/docs/logs/runtime)
- [Vercel 개인정보 고지](https://vercel.com/legal/privacy-policy)
