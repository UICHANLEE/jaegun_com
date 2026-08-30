# 미디어 격리·검사·정리 운영 런북

## 공개 전 필수 흐름

1. 클라이언트가 목적·대상·예상 MIME·크기로 upload intent를 만든다.
2. 원본은 읽기 정책이 없는 `community-media-quarantine`에만 업로드한다.
3. 외부 검사 서비스가 service claim lease를 획득하고 원본을 magic-byte 판별, 완전 디코딩, 악성코드 검사한다.
4. 이미지는 재인코딩해 EXIF·프로필·부가 청크를 제거하고 픽셀 상한을 확인한다. 영상은 허용 코덱/길이/해상도로 트랜스코딩하고 썸네일을 생성한다.
5. 정제된 파생 파일을 DB가 지정한 approved bucket/path에 먼저 쓴 다음 `service_record_media_scan`에 해시·실제 MIME·바이트·치수/길이·도구 버전을 기록한다.
6. 승인 상태가 된 intent만 게시글/채팅 RPC가 한 번 claim해 연결한다. 격리 원본은 어떤 클라이언트에도 서명 URL을 발급하지 않는다.
7. 만료·반려·사용자 포기 파일은 `cleanup-media`가 private queue에서 exact path를 claim해 제거한다.

Edge Function 자체를 악성코드 검사기나 영상 트랜스코더로 간주하지 않는다. 실제 출시에는 격리 파일을 처리할 샌드박스 서비스(ClamAV 또는 상용 malware scanning, 이미지 decoder/re-encoder, ffmpeg 계열 isolated worker)가 필요하다. 서비스가 없거나 응답이 불완전하면 intent는 승인하지 않고 만료시킨다.

## Secret과 scheduler

- 외부 검사 자격증명, `MEDIA_CLEANUP_WORKER_SECRET`, service role은 Supabase Edge secret에만 둔다.
- `cleanup-media`는 browser origin을 거부하고 scheduler bearer secret을 상수시간 비교한 뒤 최대 100개만 claim한다.
- worker는 bucket/path/token/Authorization을 로그에 남기지 않는다.
- lease timeout보다 짧은 주기로 실행하고 `processing`이 lease를 초과하면 DB claim RPC가 재처리한다.
- 8회 실패, dead-letter 증가, 격리 대기 10분 초과, 스토리지 quota 80%를 경보한다.

## 장애·복구

- scanner 장애 중에는 업로드 UI에 “검사 지연”을 표시하고 기존 승인 미디어는 계속 제공한다. 미검사 파일을 임시 승인하지 않는다.
- approved copy 후 DB 기록 전 장애는 동일 intent/hash로 멱등 재개하고, orphan derivative는 정리 queue가 제거한다.
- 삭제 worker 장애는 데이터 노출보다 비용/보존 위험이므로 즉시 우회 삭제하지 말고 queue와 exact path를 보존한 채 복구한다.
- 분기별로 악성 샘플(EICAR는 격리 환경에서만), 이미지 폭탄, 잘못된 MIME, 손상 영상, 중복 callback, scanner timeout, cleanup 재시도를 staging에서 검증한다.
