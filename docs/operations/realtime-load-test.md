# Realtime 600 연결 부하 시험

목표는 300명의 동시 사용자에서 다중 기기·탭과 재접속 여유를 포함해 600개의 Realtime 연결이 안정적으로 구독되는지 확인하는 것이다. 이 시험은 메시지 전체 부하나 데이터베이스 쓰기 처리량을 대신하지 않는다.

## 안전장치

- URL, anon key, 환경 이름을 모두 명시해야 실행된다.
- `local`은 loopback URL만 허용한다.
- 저장소에 등록된 운영 Supabase와 `production` 환경은 기본 거부한다.
- 운영 시험은 변경 승인과 비용 확인 후 `REALTIME_LOAD_ALLOW_PRODUCTION=YES_I_ACCEPT_TRAFFIC_AND_COST`를 명시해야 한다.
- service-role key나 사용자 세션을 사용하지 않는다.
- 기본 상한은 1,500연결, 기본 시험은 600연결·초당 25연결 ramp-up·60초 유지다.

staging 실행 예:

```bash
REALTIME_LOAD_URL=https://staging-project.supabase.co \
REALTIME_LOAD_ANON_KEY=<staging-anon-key> \
REALTIME_LOAD_ENV=staging \
npm run test:realtime-load
```

주요 조정값:

| 변수 | 기본값 | 의미 |
| --- | ---: | --- |
| `REALTIME_LOAD_CONNECTIONS` | 600 | 총 연결 수 |
| `REALTIME_LOAD_RAMP_PER_SECOND` | 25 | 초당 신규 연결 수 |
| `REALTIME_LOAD_HOLD_SECONDS` | 60 | 연결 유지 시간 |
| `REALTIME_LOAD_CONNECT_TIMEOUT_SECONDS` | 30 | 개별 구독 제한 시간 |
| `REALTIME_LOAD_MAX_FAILURE_PERCENT` | 1 | 허용 실패율 |

## 합격 기준

- 구독 성공률 99% 이상
- 연결 p95가 5초 이하이고 시간 경과에 따라 악화되지 않음
- Supabase quota 초과, CPU·메모리 포화, DB 연결 고갈, 5xx·WebSocket 오류 급증 없음
- 시험 종료 후 모든 연결이 정리되고 사용량이 기준선으로 복귀

그 다음 별도 시나리오로 600연결 중 30% 동시 재접속, 공지 한 건 fan-out, 채팅 송수신, 토큰 만료·네트워크 전환을 시험한다. 개인 채팅 내용이나 실제 회원 계정을 staging 부하 시험에 사용하지 않는다. 결과에는 프로젝트, 플랜·quota, git SHA, 시간, 지역, ramp, p50/p95/p99, 실패 사유와 관측성 그래프를 첨부한다.
