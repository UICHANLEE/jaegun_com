# 계정 삭제 운영 런북

## 처리 순서

1. 사용자가 재인증과 `계정 삭제` 확인 문구를 통과하면 14일 유예 요청이 생성된다. 유예 중에는 사용자가 취소할 수 있다.
2. `process-account-deletions`가 만기 요청을 claim하면 DB가 즉시 프로필을 비활성화하고 멤버십·임원직·위임을 철회한다. 기존 JWT가 남아 있어도 제품 권한은 다시 획득하지 못한다.
3. DB가 스냅샷한 `avatars`, `community-media`, `community-media-quarantine`의 exact path만 삭제하고 항목별 결과를 기록한다. 현재 조직 대표 이미지로 연결된 파일은 조직 소유로 전환하고 보존한다.
4. 모든 Storage 항목이 `deleted` 또는 `not_found`인 경우에만 게시물·댓글·메시지·프로필 개인정보를 비식별화한다.
5. 별도 identity lease에서 `auth.admin.deleteUser(userId, false)`를 실행한 다음 `getUserById`로 부재를 확인하고 요청을 완료한다.

## Scheduler와 secret

- Supabase Edge secret에 서로 다른 `ACCOUNT_DELETION_WORKER_SECRET`와 service-role key를 저장한다. scheduler secret은 URL-safe 무작위 32자 이상으로 생성하고 브라우저·클라이언트·Vercel 공개 환경 변수에 넣지 않는다.
- 운영 주 scheduler는 Supabase Cron이다. `pg_cron`이 5분마다 `pg_net`으로 `POST /functions/v1/process-account-deletions`, `Content-Type: application/json`, body `{ "limit": 5 }`를 호출한다. 장기 bearer는 queue에 넣지 않는다. Vault secret으로 timestamp·무작위 nonce·고정 process contract를 HMAC-SHA256 서명하고 세 `X-Jaegun-Scheduler-*` header에 넣는다. 서명은 3분만 유효하며 Edge 검증 뒤 DB unique nonce claim으로 재사용을 차단한다. 호출 응답은 식별자가 없는 집계값만 90일 보존한다.
- GitHub Actions는 장기 bearer를 GitHub secret에서 직접 주입해 같은 process endpoint를 호출하는 독립 fallback이자 watchdog이다. 이 bearer는 `pg_net` queue에 들어가지 않는다. Supabase Cron이 설치된 뒤에는 `{ "operation": "status" }` 응답의 마지막 성공 시각과 백로그 기준까지 검사하며, 비정상이면 workflow를 실패시켜 Actions 알림을 발생시킨다.
- Gateway JWT 검사는 끄되 handler의 전용 secret 검사를 우회하지 않는다. `Origin`이 있는 요청은 항상 거부된다.
- scheduler timeout은 Edge 실행 제한보다 짧게 설정하고, 동일 요청을 즉시 반복 호출하지 않는다. processing/identity lease는 각각 10분이다.

### 첫 활성화 전 read-only 점검

GitHub workflow는 첫 push만으로 예약 실행되지 않는다. Repository variable `ACCOUNT_DELETION_WORKER_ENABLED`가 정확히 `true`일 때만 `schedule` event가 worker를 호출한다. `workflow_dispatch`는 이 변수와 관계없이 실행할 수 있지만, 아래 점검을 마친 뒤 확인 입력에 정확히 `PROCESS_DUE_ACCOUNT_DELETIONS`를 적어야 job이 시작된다.

SQL editor에서 식별자를 조회하지 않는 다음 aggregate만 확인한다. 이 쿼리는 상태를 바꾸지 않는다.

```sql
select
  count(*) filter (
    where request.status = 'requested'
      and request.scheduled_for <= pg_catalog.clock_timestamp()
  ) as due_requests,
  count(*) filter (
    where request.status = 'requested'
      and request.scheduled_for <= pg_catalog.clock_timestamp() - interval '15 minutes'
  ) as overdue_requests,
  count(*) filter (
    where request.status = 'processing'
      and coalesce(request.processing_claimed_at, request.processing_started_at)
        <= pg_catalog.clock_timestamp() - interval '30 minutes'
  ) as stale_processing,
  count(*) filter (
    where request.status = 'awaiting_identity_deletion'
      and coalesce(request.identity_claimed_at, request.processing_started_at)
        <= pg_catalog.clock_timestamp() - interval '30 minutes'
  ) as stale_identity_deletion,
  count(*) filter (where request.status = 'failed') as failed_requests
from public.account_deletion_requests as request;

select
  count(*) filter (where item.status = 'dead') as dead_cleanup_items,
  count(*) filter (
    where item.status = 'failed' and item.attempt_count >= 3
  ) as retrying_cleanup_items
from private.account_deletion_cleanup_items as item;
```

due/stale/failed/dead 건수를 운영 요청 기록과 대조하고, staging hard-delete·복원 훈련, Edge 배포, 세 secret 일치, 당직 연락망을 확인한 뒤에만 `ACCOUNT_DELETION_WORKER_ENABLED=true`를 설정한다. 다른 값이나 변수 부재는 예약 job을 skip한다. 설정 후 첫 예약 실행과 별개로 확인 입력 `PROCESS_DUE_ACCOUNT_DELETIONS`를 사용해 한 번 수동 실행하고 200 응답을 확인한다.

### Supabase Cron 명시적 설치

Migration `202608310018_account_deletion_scheduler_observability.sql`은 테이블·RPC·설치 함수만 만든다. 로컬 reset이나 Preview가 운영 함수를 호출하지 않도록 migration 적용만으로 cron job을 만들지 않는다. Hosted Supabase의 `net` 객체는 `supabase_admin` 소유이므로 app migration이 ACL 회수를 완료했다고 주장하지 않는다. 대신 queue에는 3분짜리 HMAC·nonce만 남기고 장기 bearer나 service-role key를 절대 넣지 않는다.

1. migration과 새 Edge Function을 먼저 반영한다. 위 점검을 통과해 `ACCOUNT_DELETION_WORKER_ENABLED=true`인 경우에만 GitHub 5분 fallback이 실행된다.
2. 비밀관리 도구에서 새 credential을 만들고 Supabase Edge secret과 GitHub Actions secret `ACCOUNT_DELETION_WORKER_SECRET`를 같은 값으로 원자적으로 회전한다. 기존 두 secret은 읽어낼 수 없으므로 Vault 추가를 빌미로 로그·shell history·SQL 파일에 값을 복사하지 않는다.
3. Supabase Dashboard의 Vault UI에서 같은 값을 이름 `account_deletion_worker_secret`로 하나만 저장한다. SQL editor 본문이나 migration에 평문을 쓰지 않는다.
4. SQL editor에서 `select private.install_account_deletion_scheduler();`를 한 번 실행한다. 이 명시적 단계만 `jaegun-account-deletion-worker`(5분)와 `jaegun-account-deletion-reconciler`(1분)를 설치한다.
5. `ACCOUNT_DELETION_PROVIDER_REQUIRED`는 아직 설정하지 않은 채 16분 이상 기다리고 GitHub workflow를 수동 실행한다. provider configured, 최근 15분 이내 성공, 지연·실패 백로그 0을 확인한다. `cron.job_run_details`, sanitized dispatch table, Edge logs를 함께 대조하되 원문 header나 응답을 복사하지 않는다.
6. 위 확인이 모두 통과한 뒤 Repository variable `ACCOUNT_DELETION_PROVIDER_REQUIRED=true`를 설정하고 workflow를 다시 수동 실행한다. 이후 status endpoint 장애, 잘못된 health contract, `providerConfigured=false`는 warning이 아니라 workflow 실패가 된다. 변수 설정 전에는 하위 호환 전환을 위해 이 세 상태를 warning으로만 처리한다.
7. 저장소의 Actions 실패 알림을 실제 당직 이메일 또는 업무 채널로 전달되도록 켠다. staging 또는 별도 알림 시험 workflow로 수신까지 검증한다. 알림 수신 시험이 없으면 자동 경보가 운영된다고 판정하지 않는다.

`ACCOUNT_DELETION_WORKER_ENABLED=true` 이후에는 공급자 cron 설치 전에도 GitHub fallback이 삭제를 수행한다. 다만 provider `lastSuccessAt`, `ACCOUNT_DELETION_PROVIDER_REQUIRED=true`, 독립 경보 수신 시험이 없으면 App Store 출시 게이트는 계속 `BLOCK`이다.

Sanitized dispatch 결과는 90일 보존한다. `cron.job_run_details`는 설치 시 기록한 정확한 두 job ID에 대해서만 30일 지난 완료 행을 reconciler가 정리한다. 이름이 같은 다른 사용자·DB job의 이력은 건드리지 않는다. 두 job을 unschedule하면 config의 정확한 ID는 감사 근거로 남지만 reconciler도 멈추므로 오래된 run detail은 자동 정리되지 않는다. 중지 직전에 reconciler를 실행하고, 장기 중지 뒤 필요하면 SQL editor에서 `select private.reconcile_account_deletion_worker_dispatches();`를 명시적으로 실행해 같은 ID의 보존기간 초과 이력만 정리한다. job 이름만으로 orphan 이력을 일괄 삭제하지 않는다.

## 경보 기준

- `account_deletion_requests.status = 'failed'`인 미해결 incident가 1건 이상
- `deletion_worker_lease_exhausted`, `identity_deletion_lease_exhausted`, `storage_cleanup_retry_exhausted`, `invalid_storage_cleanup_contract`
- 만기 후 30분 넘게 `processing` 또는 `awaiting_identity_deletion`인 요청
- cleanup item의 `dead` 상태 또는 3회 이상 반복 실패
- Edge Function 5xx, scheduler 누락, Storage/Auth Admin API 429 증가
- provider `lastSuccessAt`이 15분 이상 오래됐거나 GitHub watchdog workflow 실패

대시보드와 알림에는 요청 수·상태·오류 코드만 노출한다. 이메일, 사용자 UUID, subject fingerprint, object path, Authorization, service-role key, Auth/Storage 원문 오류를 로그에 남기지 않는다.

`failedRequests`와 `deadCleanupItems`는 의도적으로 latched된 미해결 incident 수다. 한 번 발생하면 알림을 읽었다는 이유나 다음 worker 성공으로 자동 감소하지 않으며 health는 계속 실패한다. 알림 채널에서 확인 표시를 하더라도 원인 조사와 별도 검토를 거친 감사 가능한 복구 절차·migration으로 실제 상태를 해소하기 전에는 정상으로 판정하지 않는다. queue row 삭제나 위험한 자동 clear는 금지한다.

## 장애와 멱등 복구

- Storage 삭제 후 DB 기록 전 중단되면 lease 만료 뒤 같은 exact path를 다시 삭제한다. 이미 없는 객체는 성공적인 `not_found`로 기록한다.
- Auth 삭제 응답을 잃어도 `auth.users` 삭제가 profile FK를 null로 만든다. 다음 identity claim의 `user_id = null`은 삭제 완료의 DB 증거이므로 Admin API를 다시 호출하지 않고 완료한다.
- Auth 조회가 timeout/5xx인 경우 부재로 간주하지 않는다. lease 만료 후 재시도한다.
- `failed` 요청은 자동으로 원본 권한이나 데이터를 복구하지 않는다. 원인을 수정한 뒤 감사 가능한 별도 운영 절차/마이그레이션으로만 재개한다.
- DB row를 지우거나 임의 경로를 Storage에서 수동 일괄 삭제해 queue를 우회하지 않는다.

## 출시 전 복구 훈련

Staging에서 다음을 분기마다 검증한다: 유예 취소, Storage 404/403/429/timeout, 함수 중간 종료, 중복 scheduler 호출, Auth 삭제 성공 응답 유실, Auth 조회 실패, 보존 조직 대표 이미지, 상대방 채팅 보존, 8회 lease 소진. 처리 전·후 백업 복원 훈련과 pgTAP 회귀 테스트도 함께 수행한다.
