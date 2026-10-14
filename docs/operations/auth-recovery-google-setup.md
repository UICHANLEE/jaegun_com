# 이메일 복구·Google 인증 운영 연결

2026-10-14 점검에서 운영 Auth 공개 설정은 이메일 활성, Google 비활성이었다. 최근 Auth 서버 기록에 복구 메일 요청의 `429 / over_email_send_rate_limit`가 있었다. 사용자가 대시보드에 로그인한 후 확인한 운영 설정에서는 custom SMTP가 꺼져 있었고, Google Client ID와 Secret도 비어 있었다. 메일 실제 수신은 아직 확인되지 않았다. 설정 전체를 가져오는 작업은 비밀 값이 함께 조회될 수 있어 자동 승인 검토에서 차단됐으며, 이후 대시보드의 해당 설정만 확인했다. 이 문서는 비밀 값을 저장하지 않는다.

## 앱 수정

- 이메일 로그인·회원가입과 `/forgot-password`, `/reset-password` 화면을 복원했다.
- 복구 링크의 PKCE 교환은 경로·용도·세션 사용자를 확인한 후 수행한다. 이메일 인증번호는 `verifyOtp(type: recovery)`로 검증하며, 다른 브라우저에서도 입력할 수 있다.
- 복구 중에는 공동체 데이터 조회를 차단한다. 일반 로그인 세션만으로 비밀번호를 변경할 수 없다. 변경 후 인증 세션을 종료한다.
- 메일 요청 실패를 숨기지 않고 재요청 대기·중복 요청 방지를 제공한다.
- Google 인증은 서버 설정에서 실제 활성 상태가 확인돼야 버튼을 활성화한다. 5개 필수 동의와 만 14세 이상 확인, 계정별 OAuth 요청 식별자, 기존 계정 연결 검사를 유지한다.
- 브라우저 콜백은 인증을 시작한 동일한 주소로 돌아온다. 네이티브 앱은 고정된 운영 콜백을 사용한다. 회원의 교회·역할은 인증 후 별도 온보딩과 승인을 거친다.

## 운영 설정에서 완료할 항목

1. Supabase 프로젝트 `supabase-violet-park`의 Auth 이메일 설정에서 운영 SMTP 발송 서비스를 확인하고 연결한다. 공유 프로젝트의 다른 서비스 발송량도 포함해 발송 한도를 점검한다. 보호용 제한을 해제하는 방식으로 우회하지 않는다.
2. 비밀번호 복구 메일 템플릿에 `supabase/templates/recovery.html`의 `{{ .Token }}` 인증번호와 `{{ .ConfirmationURL }}` 링크를 반영한다. 저장소에 템플릿을 추가한 것만으로 운영 이메일이 변경되지는 않는다.
3. 사용자가 Google 설정을 완료했다고 알린 후 공개 Auth 설정을 다시 조회해 HTTP 200, `external.google: true`, 이메일 활성, 신규 가입 허용을 확인했다. 로컬 앱에서도 Google 버튼 활성화를 확인했다. 실제 계정 인증 완료와 네이티브 앱 복귀 검증은 아직 남았다. Google Client Secret은 브라우저 번들·Git·채팅에 넣지 않는다.
4. Supabase Auth URL 설정에 `supabase/config.toml`의 정확한 콜백 주소를 대조한다. 운영 Google 반환 주소 `https://jaegun-com.vercel.app/auth/callback/social?social_intent=*`는 대시보드에서 추가하고 성공 알림과 목록을 확인했다. 이메일 signup/recovery의 `sb_flow_id` 반환 주소는 이미 등록돼 있었다. host/path의 와일드카드는 사용하지 않는다. 로컬 개발 주소는 아직 운영 목록에 등록하지 않았다.
5. 운영 메일 수신→인증번호 또는 동일 브라우저 링크→사용자 직접 비밀번호 설정→새 비밀번호 로그인, 그리고 Google 신규 가입·기존 계정 연결·취소를 실제 계정으로 확인한다. 가입 후 아직 승인되지 않은 계정은 보호된 공동체 데이터를 읽을 수 없어야 한다.

현재 코드에는 다른 작업에서 준비된 법적 동의 버전 변경도 있다. 기존 동의 이력을 지우거나 전체 DB를 초기화하지 않는다. 운영 동의 문서 변경은 배포된 클라이언트와 실제 서버 계약을 대조한 뒤 별도로 적용한다.

## 현재 범위

### 관리자 인증 앱 강제 등록 제거

2026-10-14 사용자가 인증 앱 강제 등록 대신 민감한 관리 작업의 Google 재인증을 승인했다. 자동 승인 검토에서 전체 호출 범위를 명시하라는 이유로 최초 운영 적용이 차단됐고, 임원 임명·위임, 사역자/임원 승인, 부서 임원 설정, 모임 관리, 신고 제재, 계정 삭제를 명시해 사용자의 추가 승인을 받은 후 `20261014045531_management_google_reauthentication`를 적용했다.

- 관리자 홈과 읽기 전용 화면의 신규 TOTP 등록 강제를 제거했다. 이미 등록한 MFA 기기는 삭제하지 않으며 기존 로그인 확인과 복구/해제를 유지한다.
- 서버는 서명된 JWT의 OAuth AMR, 해당 사용자의 실제 Google identity, 현재 Auth session, Auth-owned AMR 시각을 대조해 최대 5분의 인증만 인정한다. 토큰 갱신·기기 시계·editable user metadata는 인증 시간을 연장하지 않는다. 다른 OAuth provider가 함께 연결돼 provider를 특정할 수 없는 경우 실패 처리한다. 기존 유효 AAL2 세션은 호환 경로로 인정한다.
- 기존 역할·조직 범위·동의·감사 검사와 민감한 작업의 서버 검사는 유지한다. UI의 재인증 반환 경로는 관리·보안·계정 내부 경로만 허용하며 재인증 후 쓰기 작업을 자동 재실행하지 않는다.
- 운영 DB 회귀 테스트는 새 인증, 만료·미래 시각·다른 계정·잘못된 세션·AMR 누락·토큰 갱신·메타데이터 위조·동의 미완료를 검사했다. 테스트 트랜잭션은 롤백됐고 합성 계정 잔여 수 0을 확인했다.
- 최종 전체 웹 테스트 47개 파일·385개 통과. 운영 빌드·타입 검사·런타임 무결성·정적 보안 검사 통과. 같은 화면의 인증 상태 재확인 중 입력을 보존하고, 만료 시 편집기를 숨김/inert 처리한다. 외부 Google 이동·페이지 새로고침을 넘는 초안 보존은 보장하지 않는다. 실제 사용자 Google 재인증 복귀와 새 프런트엔드의 운영 배포는 아직 미확인이다.
- 사용자 승인으로 `http://127.0.0.1:5176/auth/callback/social?social_intent=*`만 운영 반환 목록에 임시 추가했다. 실제 계정 검증이 아직 끝나지 않아 유지 중이며, 검증 종료 후 이 주소만 제거한다.
- DB advisory에는 새 상태 RPC의 authenticated SECURITY DEFINER 안내와 공유 프로젝트의 기존 경고가 있다. 이 RPC는 actor의 현재 동의를 검증하고 최소 인증 상태만 반환하며, anon·private 함수 직접 실행 권한은 없다. [함수 권한 점검 안내](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)

검증: 웹 45개 파일·366개 테스트 통과, TypeScript와 운영 빌드 통과, Edge Function 보안 36개·법적 문서 해시 12개·비밀 정보 검사 통과, 기존 모바일 런타임 보호 파일 28개 통과. 실제 브라우저에서 이메일 로그인→비밀번호 복구 경로를 확인했다. 자동 테스트의 OTP·비밀번호 변경은 모의 인증 응답이며 운영 계정의 비밀번호를 변경하지 않았다.

코드·자동 테스트와 로컬 화면 검증, 운영 Google 제공자 활성화를 확인했다. SMTP/템플릿 저장, 실제 복구 메일 수신과 Google 인증 완료, 이번 수정의 Git push·운영 배포는 완료로 표시하지 않는다.

공식 참고: [Google OAuth 설정](https://supabase.com/docs/guides/auth/social-login/auth-google), [운영 SMTP](https://supabase.com/docs/guides/auth/auth-smtp), [복구 메일 템플릿](https://supabase.com/docs/guides/auth/auth-email-templates), [PKCE](https://supabase.com/docs/guides/auth/sessions/pkce-flow).
