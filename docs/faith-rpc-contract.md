# 성경 통독·개인 QT RPC

현재 필수 동의와 정확한 교회의 활성 회원권을 모두 서버에서 확인한다. 플랫폼 관리자도 회원권 없이 통과하지 않는다. 개인 기록은 계정 귀속이며 교회를 옮겨도 다른 교회에 노출되지 않는다. `private` 테이블은 RLS 활성화 및 클라이언트 직접 권한 제거, 공개 RPC만 사용한다. 계정 삭제 시 FK cascade로 삭제된다.

기존 필수 5종 동의를 변경하지 않는다. 별도 선택 문서 `faith_private_records` 버전 `2026-10-14`, SHA-256 `4572f759bdcf51050b55f208af2513c63761db5127bc7c754175b4c8a31b8aa4`의 명시적 동의가 개인 기록의 추가 서버 접근 조건이다. 동의 상태 확인은 기록을 생성하지 않으며, Google 인증·회원 승인으로 대신하지 않는다.

- `get_faith_consent_status(p_organization_id uuid)` → `{accepted,document:{document_key,version,content_sha256,title,url}}`. 현재 필수 동의 및 활성 교회 회원만 본인 상태 확인.
- `accept_faith_consent(p_organization_id uuid,p_version text,p_content_sha256 text)` → 위 상태. 정확한 문서만 허용하고 동일 동의 재시도는 최초 시각을 보존한다.
- `withdraw_faith_consent(p_organization_id uuid,p_confirm_delete boolean)` → `{accepted:false,deleted:true}`. 살아 있는 본인 Auth 세션과 명시적 삭제 확인 필수. 조직 인수는 권한에 사용하지 않으며 필수 동의 갱신 전·교회 탈퇴 후에도 자기 기록 철회 가능. 모든 연도의 개인 진도·QT·요청 해시를 제거하고 기능 접근을 중단한다. 기존 게시판 사본은 별도 삭제한다.

- `get_faith_snapshot(p_organization_id uuid)` → JSON `{server_today,service_year,completed_chapters:int[],completed_count,total_chapters:1189,streak_days,last_read_date,latest_private_qt:[{id,reference,body,created_at}]}`. 날짜는 Seoul 서버 날짜이며 최신 QT 최대 25개.
- `set_my_reading_chapter(p_organization_id uuid,p_service_year int,p_chapter_id int,p_completed bool)` → 위 snapshot. 현재 서버 연도만, 개신교 66권 순서의 장 번호 1–1189. 명시한 상태 저장, 중복 완료는 날짜를 갱신하지 않는다. 완료 취소는 해당 기록을 제거하므로 그날 마지막 장을 취소하면 연속 일수에서도 제외된다. 오늘 또는 어제부터 이어지는 실제 완료 날짜만 연속 일수로 계산하며 연도 경계를 넘기지 않는다. 클라이언트 날짜/사용자 ID 입력 없음.
- `create_my_qt(p_organization_id uuid,p_client_request_id uuid,p_reference text,p_body text)` → UUID. 본문 1–500자, 구절 표기 1–80자, 양끝 공백 제거. plain text로 렌더링하며 HTML 실행 금지. 계정과 요청 UUID의 동일 payload 재시도는 같은 UUID 반환, 변경 payload는 거부. 삭제 후 같은 UUID 재전송도 복구하지 않는다; 새 QT에는 새 요청 UUID 필요. 서버 서울 날짜 기준 신규 작성은 하루 20개, 보관 중인 QT는 계정당 1,000개까지이며 초과 시 거부하고 자동 삭제하지 않는다. 삭제해도 당일 작성 횟수는 복구되지 않는다. 계정 단위 트랜잭션 잠금으로 동시 요청이 제한을 우회하지 못하며 기존 동일 요청 재확인은 한도를 소모하지 않는다.
- `list_my_qt(p_organization_id uuid,p_limit int=25,p_offset int=0)` → JSON array, 오직 자신의 기록. limit 1–100, offset 0–10000.
- `delete_my_qt(p_organization_id uuid,p_qt_id uuid)` → changed boolean. 다른 사용자의 UUID와 없는 UUID 모두 false로 반환하여 존재 여부를 공개하지 않는다.

중복 처리용 영수증에는 canonical JSON의 SHA-256 해시, 요청/기록 UUID, 작성 시각만 저장한다. 본문이나 구절 원문은 저장하지 않는다. QT 삭제 후에도 중복 생성 방지를 위해 해시 영수증은 계정 삭제까지 보존하며 계정 삭제 시 자동 제거한다. 본문은 실제 개인 QT 작성 호출에서만 저장하고 숨은 자동 기록을 만들지 않는다.

QT 원본은 **비공개로 저장**한다. 웹에서는 본인이 명시적으로 확인한 경우에만 기존 신고·차단·삭제가 적용되는 교회 게시판으로 사본을 공유한다. SwiftUI 게시판 공유와 독립 아멘 반응은 미지원이다. 별도의 신고 불가능한 공개 피드는 만들지 않는다. 교회/노회별 순위는 명시적 참여 동의 및 최소 집계 인원 정책 전까지 보류한다. 성경 본문을 복제하지 않고 사실적인 책/장 목록만 클라이언트에서 제공한다.

법적 안내는 웹 `/legal/faith/2026-10-14`와 동일 바이트의 native `FaithConsent.md`로 제공한다. 두 클라이언트 모두 SHA-256와 서버 manifest를 검증하고 읽기 동작·선택 체크·명시적 저장 이전에 기능을 활성화하지 않는다. 가입·기존 5종 문서와 이력은 보존한다. 로컬 pgTAP 60건은 트랜잭션 후 롤백하여 검증한다.
