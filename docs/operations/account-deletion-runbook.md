# 계정 삭제 운영 런북

## 처리 순서

1. 사용자가 재인증과 `계정 삭제` 확인 문구를 통과하면 14일 유예 요청이 생성된다. 유예 중에는 사용자가 취소할 수 있다.
2. `process-account-deletions`가 만기 요청을 claim하면 DB가 즉시 프로필을 비활성화하고 멤버십·임원직·위임을 철회한다. 기존 JWT가 남아 있어도 제품 권한은 다시 획득하지 못한다.
3. DB가 스냅샷한 `avatars`, `community-media`, `community-media-quarantine`의 exact path만 삭제하고 항목별 결과를 기록한다. 현재 조직 대표 이미지로 연결된 파일은 조직 소유로 전환하고 보존한다.
4. 모든 Storage 항목이 `deleted` 또는 `not_found`인 경우에만 게시물·댓글·메시지·프로필 개인정보를 비식별화한다.
5. 별도 identity lease에서 `auth.admin.deleteUser(userId, false)`를 실행한 다음 `getUserById`로 부재를 확인하고 요청을 완료한다.

## Scheduler와 secret

- Supabase Edge secret에 서로 다른 `ACCOUNT_DELETION_WORKER_SECRET`와 service-role key를 저장한다. scheduler secret은 URL-safe 무작위 32자 이상으로 생성하고 브라우저·클라이언트·Vercel 공개 환경 변수에 넣지 않는다.
- 5분마다 `POST /functions/v1/process-account-deletions`, `Authorization: Bearer <secret>`, `Content-Type: application/json`, body `{ "limit": 5 }`로 호출한다.
- Gateway JWT 검사는 끄되 handler의 전용 secret 검사를 우회하지 않는다. `Origin`이 있는 요청은 항상 거부된다.
- scheduler timeout은 Edge 실행 제한보다 짧게 설정하고, 동일 요청을 즉시 반복 호출하지 않는다. processing/identity lease는 각각 10분이다.

## 경보 기준

- `account_deletion_requests.status = 'failed'` 신규 발생
- `deletion_worker_lease_exhausted`, `identity_deletion_lease_exhausted`, `storage_cleanup_retry_exhausted`, `invalid_storage_cleanup_contract`
- 만기 후 30분 넘게 `processing` 또는 `awaiting_identity_deletion`인 요청
- cleanup item의 `dead` 상태 또는 3회 이상 반복 실패
- Edge Function 5xx, scheduler 누락, Storage/Auth Admin API 429 증가

대시보드와 알림에는 요청 수·상태·오류 코드만 노출한다. 이메일, 사용자 UUID, subject fingerprint, object path, Authorization, service-role key, Auth/Storage 원문 오류를 로그에 남기지 않는다.

## 장애와 멱등 복구

- Storage 삭제 후 DB 기록 전 중단되면 lease 만료 뒤 같은 exact path를 다시 삭제한다. 이미 없는 객체는 성공적인 `not_found`로 기록한다.
- Auth 삭제 응답을 잃어도 `auth.users` 삭제가 profile FK를 null로 만든다. 다음 identity claim의 `user_id = null`은 삭제 완료의 DB 증거이므로 Admin API를 다시 호출하지 않고 완료한다.
- Auth 조회가 timeout/5xx인 경우 부재로 간주하지 않는다. lease 만료 후 재시도한다.
- `failed` 요청은 자동으로 원본 권한이나 데이터를 복구하지 않는다. 원인을 수정한 뒤 감사 가능한 별도 운영 절차/마이그레이션으로만 재개한다.
- DB row를 지우거나 임의 경로를 Storage에서 수동 일괄 삭제해 queue를 우회하지 않는다.

## 출시 전 복구 훈련

Staging에서 다음을 분기마다 검증한다: 유예 취소, Storage 404/403/429/timeout, 함수 중간 종료, 중복 scheduler 호출, Auth 삭제 성공 응답 유실, Auth 조회 실패, 보존 조직 대표 이미지, 상대방 채팅 보존, 8회 lease 소진. 처리 전·후 백업 복원 훈련과 pgTAP 회귀 테스트도 함께 수행한다.
