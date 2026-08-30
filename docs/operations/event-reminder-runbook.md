# 일정 알림 scheduler 운영 런북

## 배포와 비밀값

일정 알림은 클라이언트 기기 시각이나 로컬 알람을 권한 기준으로 사용하지 않는다. `dispatch-event-reminders`가 service-role 전용 `service_dispatch_due_event_reminders` RPC를 호출하고, 데이터베이스의 `statement_timestamp()`를 기준으로 참석 `yes` 또는 `maybe`인 사용자에게만 인앱 알림을 만든다. 취소된 일정·발생 건, 탈퇴·비활성·범위 접근을 잃은 회원, 대기·불참 RSVP, 일정 알림을 끈 사용자는 제외한다.

1. 32-256자의 무작위 URL-safe 값으로 `EVENT_REMINDER_SCHEDULER_SECRET`를 만든다. push worker secret, service-role key, JWT secret과 재사용하지 않는다.
2. Supabase Edge secrets에 `EVENT_REMINDER_SCHEDULER_SECRET`를 저장한다. service-role key는 Edge 런타임 제공값만 사용하고 Vercel 또는 `VITE_*` 환경변수에 넣지 않는다.
3. 마이그레이션 `202608270012_events_calendar.sql`을 적용한 뒤 `dispatch-event-reminders`를 배포한다. `supabase/config.toml`의 이 함수만 `verify_jwt = false`이며 함수 내부 bearer secret 검증을 제거하면 안 된다.
4. staging에서 아래 호출을 실행해 HTTP 200과 개인 식별자가 없는 집계 응답만 오는지 확인한다.

```bash
curl --fail-with-body --request POST \
  --header "Authorization: Bearer $EVENT_REMINDER_SCHEDULER_SECRET" \
  --header "Content-Type: application/json" \
  --data '{"limit":100}' \
  "https://<project-ref>.supabase.co/functions/v1/dispatch-event-reminders"
```

## 매분 scheduler

Supabase Dashboard의 Cron에서 Edge Function 호출 작업을 `* * * * *`로 만든다. 요청은 위 URL에 POST하고 본문은 `{ "limit": 100 }`, Authorization은 Vault/secret store에서 주입한 전용 bearer 값으로 설정한다. secret을 cron SQL 본문, 작업명, 로그 또는 저장소에 평문으로 넣지 않는다. 실행 제한시간은 다음 분 실행과 겹치지 않게 30초 이하로 둔다. 데이터베이스 advisory lock과 occurrence/user/offset unique key가 겹친 실행과 재시도를 멱등 처리한다.

대기량이 한 번에 100건을 넘을 수 있으면 응답의 `hasMore`를 지표로 수집한다. 상시 `hasMore=true`, 실행 실패 2회, 또는 예정 시각 대비 인앱 알림 p95 지연 5분 초과를 경보한다. 한 scheduler 호출에서 비밀값·사용자 ID·event/occurrence ID·제목·장소·설명을 로그로 수집하지 않는다.

## 정확성 확인

- 시작 60분 전 일정에 `yes`, `maybe`, `no`, `waitlist` RSVP를 각각 만들고 앞의 두 사용자만 한 번씩 받는지 확인한다.
- 같은 호출을 반복해 `dispatched=0`이며 중복 인앱 알림과 push outbox가 없는지 확인한다.
- 일정 또는 occurrence를 취소한 뒤에는 알림이 생성되지 않는지 확인한다.
- `events_enabled=false`인 사용자는 인앱 일정 알림과 push outbox 모두 생성되지 않는지 확인한다.
- DB와 테스트 기기의 시간을 다르게 설정해도 DB 시각만 사용되는지 확인한다. RPC와 Edge body에는 현재 시각 인수가 없다.
- 반복 일정은 각각의 occurrence UUID와 offset마다 정확히 한 번 생성되는지 확인한다.

## 장애와 복구

Scheduler 장애 중에도 임의 `now` 값을 넘겨 과거를 재생하지 않는다. 복구 후 동일 함수를 호출하면 시작 전인 overdue reminder는 멱등하게 보충하고, 이미 시작한 일정은 건너뛴다. 단, offset 0은 매분 실행 오차를 위해 시작 후 5분까지만 허용한다. 알림 설정이나 RSVP를 바꿔 억제된 항목은 delivery ledger에 기록하지 않으므로, 다시 활성화했을 때 아직 시작 전이고 해당 offset이 이미 지났다면 다음 실행에서 받을 수 있다.

인앱 알림 생성 뒤 push 전송은 기존 `private.push_outbox`와 `deliver-push`가 담당한다. `event_occurrence` entity type은 `events_enabled` 범주와 generic `community_notice` push로 매핑되어야 한다. 마이그레이션 012는 011 뒤에서 이 매핑을 보존하므로 011을 직접 수정하지 않는다.
