# APNs·FCM 푸시 알림 운영 런북

## 원칙

인앱 알림 DB가 원본이고 APNs/FCM은 재시도 가능한 배송 채널이다. 잠금화면 payload에는 채팅·기도제목·상담·회원 승인 사유를 넣지 않는다. 기본 문구는 `새 메시지가 있습니다`처럼 일반화하고 불투명 notification ID만 전달한다. 앱은 인증과 권한 확인 후 서버에서 본문을 읽는다.

## 등록과 발송

1. 알림 기능을 사용하려는 순간 OS 권한을 요청한다.
2. 설치별 무작위 ID, 사용자, 플랫폼, token, 앱 버전, 마지막 사용, 비활성 시각을 서버에 등록한다.
3. 사용자는 자기 설치 token만 등록·폐기할 수 있고 발송 서버만 전체 token을 읽는다.
4. APNs 키·FCM 서버 자격증명은 서버 secret store에만 두고 클라이언트·Vite 환경에 넣지 않는다.
5. outbox에 멱등 event ID를 기록하고 worker가 범주 설정·대화 음소거·조용한 시간·차단 관계를 서버에서 확인한다.
6. 제공자 응답을 저장하되 payload 본문과 token 원문은 로그에서 마스킹한다.

구현 경로는 다음과 같다.

- 앱 → `register-push-device`: 사용자 JWT를 다시 검증하고 token을 AES-256-GCM으로 암호화한 뒤 서비스 전용 RPC로 저장한다.
- 인앱 알림 trigger → private outbox: 잠금화면에는 정해진 일반 문구와 UUID·허용된 딥링크만 적재한다.
- scheduler → `deliver-push`: 전용 `PUSH_WORKER_SECRET`로 호출하고 per-device job을 lease로 claim해 APNs/FCM에 전송한다.
- 제공자 결과 → `service_complete_push_delivery`: 성공, 재시도, 영구 무효 token을 구분한다.

필수 Edge secret은 `PUSH_TOKEN_ENCRYPTION_KEYS`, `PUSH_TOKEN_ENCRYPTION_KEY_VERSION`, `PUSH_WORKER_SECRET`과 APNs/FCM 공급자 자격증명이다. 암호화 키는 JSON key ring으로 두어 이전 버전을 읽을 수 있게 한 상태에서 새 버전으로 회전한다. 이 값들은 Vercel이나 `VITE_*` 환경변수에 두지 않는다. `deliver-push`만 외부 scheduler 인증을 위해 gateway JWT 검증을 끄며, 함수 내부 secret 검증은 유지한다. `register-push-device`는 기본 user-JWT gateway 검증과 함수 내부 `auth.getUser()`를 모두 통과해야 한다.

## 재시도와 token 수명

- 일시 오류·429·5xx는 지수 backoff와 jitter, 제공자의 `Retry-After`로 재시도한다.
- 영구 무효 token은 즉시 비활성화한다. 30일 미사용은 확인 대상으로, 90일 미사용은 삭제 대상으로 검토한다.
- 최대 재시도 후 DLQ로 이동하고 승인·보안 알림 실패는 인앱 배너/이메일 대체 경로를 사용한다.
- 동일 event ID·설치 ID 조합은 한 번만 보낸다.
- 계정 전환·로그아웃·탈퇴 시 해당 설치와 이전 사용자의 연결을 끊는다.

## 사용자 제어

공지, 댓글, 채팅, 승인, 일정, 관리 보안 알림을 분리한다. 대화별 음소거와 한국시간 기준 조용한 시간을 제공한다. 비밀번호·MFA·권한·새 기기 로그인처럼 보안에 필요한 알림은 사용자가 마케팅 설정으로 끌 수 없게 하되 본문은 최소화한다.

## 장애 대응과 지표

모니터링 지표는 outbox backlog, 발송 성공률, p95 지연, provider 오류 코드, 재시도, DLQ, invalid-token 비율, 범주별 opt-out이다. 15분 이상 backlog 증가 또는 보안 알림 성공률 99% 미만이면 당직자에게 경보한다.

장애 시 중복 발송을 막기 위해 worker를 멱등하게 정지하고, 제공자 상태·자격증명 만료·quota·최근 배포를 확인한다. 복구 후 오래된 일반 알림은 폐기하고 승인·보안 알림만 우선 재처리한다. 테스트 알림은 운영 전체 대상에게 보내지 않고 전용 교회·기기 allowlist를 사용한다.
