# iOS·Android 보안 출시 체크리스트

이 문서는 WebView 래핑 여부와 관계없이 스토어 제출 전 모두 증거가 있어야 하는 항목이다. 기준은 OWASP MASVS의 저장·인증·네트워크·플랫폼·코드·복원력·개인정보 영역을 따른다.

## 인증과 세션

- [ ] OAuth/이메일 링크/비밀번호 재설정은 PKCE를 사용한다.
- [ ] refresh token은 iOS Keychain 또는 Android Keystore로 보호된 저장소에만 저장하며 WebView `localStorage`에 두지 않는다.
- [ ] 로그아웃·계정 전환·탈퇴 시 token, 민감 캐시, 초안, signed URL을 제거한다.
- [ ] Universal Links와 Android App Links의 소유권 파일을 배포하고 callback scheme·host·path를 allowlist로 검증한다.
- [ ] 플랫폼 관리자, 회장, 목사, 위임 관리자는 AAL2/MFA를 필수화한다.
- [ ] 임원 변경·위임·명단 내보내기·계정 삭제·회계 변경은 최근 재인증을 요구한다.
- [ ] 활성 세션·기기 확인, 개별 폐기, 전체 로그아웃과 권한 변경 알림을 제공한다.

## 플랫폼·네트워크

- [ ] iOS ATS 예외 없이 HTTPS만 허용한다.
- [ ] Android `usesCleartextTraffic=false`이며 release WebView debugging을 끈다.
- [ ] WebView는 Jaegun 및 승인된 인증 host만 열고 외부 링크는 시스템 브라우저로 보낸다.
- [ ] 파일 URL·임의 JavaScript bridge·혼합 콘텐츠 접근을 차단한다.
- [ ] 서버 인증서를 정상 검증하고 자체 인증서 우회 코드를 넣지 않는다.
- [ ] 난독화는 인증·RLS를 대신하지 않으며 모든 권한을 서버에서 재검증한다.

## 권한과 기기 데이터

- [ ] 전체 사진첩 권한 대신 iOS Photos Picker/Android Photo Picker를 사용한다.
- [ ] 카메라·마이크·알림은 기능 사용 시점에 목적을 설명하고 요청한다.
- [ ] 위치·연락처·광고 ID는 현재 기능에 필요 없으므로 요청하지 않는다.
- [ ] 민감 캐시·로그·DB를 OS 백업에서 제외하고 화면 캡처 제한이 필요한 관리자 화면을 별도 검토한다.
- [ ] 로그와 crash report에 JWT, reset code, 채팅·기도 내용, push token, signed URL을 기록하지 않는다.

## 개인정보와 스토어 선언

- [ ] 앱에서 개인정보처리방침, 이용약관, 커뮤니티 운영정책, 지원 연락처를 열 수 있다.
- [ ] 교회 소속의 목적·보유기간·처리 위치·철회 방법을 별도 버전 동의로 기록한다.
- [ ] 명단은 이름·직분·교회를 기본 최소값으로 하고 사진·전화·이메일은 항목별 공개 동의를 받는다.
- [ ] 앱 내 계정 삭제와 Google용 외부 삭제 URL이 있으며 Storage까지 삭제/익명화된다.
- [ ] Apple Privacy Nutrition Label, Privacy Manifest, Google Data Safety가 실제 SDK·로그·보존 동작과 일치한다.
- [ ] 청소년 허용 범위, 보호자 정책, 성인과의 메시지·미디어 안전장치와 아동 안전 연락체계를 확정한다.

## 공급망과 출시 빌드

- [ ] 잠금 파일 기반 재현 빌드, high/critical dependency audit, 비밀 스캔, SBOM을 보관한다.
- [ ] iOS 배포 인증서·Android signing key는 CI secret store/HSM에 있고 최소권한으로 접근한다.
- [ ] release 빌드에 dev server, test account, 상세 오류, source map 공개, 임의 endpoint 변경 기능이 없다.
- [ ] root/jailbreak 탐지는 보조 신호로만 쓰며 접근성이나 정상 기기를 무조건 차단하지 않는다.
- [ ] 설치·업그레이드·다운그레이드·오프라인·토큰 만료·앱 복귀·딥링크 변조를 실제 기기에서 시험한다.

체크 표시에는 PR, 스토어 설정 화면, 자동화 테스트 또는 실제 기기 시험 기록 링크를 붙인다. 근거 없는 체크는 완료로 보지 않는다.
