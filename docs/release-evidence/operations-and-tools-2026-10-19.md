# 관제·감사·이의신청 / 성경 도구 전환

확인일: 2026-10-19 (Asia/Seoul). 프로젝트: `opwzujhfsxqaivtbjewg`.

## 이번 범위

- 웹·순수 SwiftUI AI 화면을 성경 도구 랜딩으로 교체. 성경 지도 보기 / 본문에 나온 이름 분석은 **링크 연결 예정**이며 동작을 가장하는 링크나 생성 버튼이 없다.
- 회의록 AI 초안 및 성경 본문에서 AI 질문 준비 진입 제거. 도구 랜딩은 개인정보·본문·프롬프트를 전송하지 않는다. 과거 AI 구현 파일은 보존하되 현재 화면에서 호출하지 않으며 AI DB/Edge/provider는 활성화하지 않았다.
- 관리자 현황, 신고된 증거 조사, 감사 검색·최소화 내보내기·체크섬 검증, 본인 신고 조회와 이의신청 경로 연결.
- AI 사용량 / 미배포 공급자 조회를 관제에서 제거. 현재 DB 크기는 실제 값만 표시하며 500MB 무료 플랜이라고 가정하지 않는다.
- 관리자와 동의·실제 살아 있는 Auth 세션을 서버에서 확인. 사건 조사·조치는 기존 최근 Google 본인확인 경계를 유지한다.
- 신고된 증거만 사유와 함께 감사 기록을 남기고 열람한다. 모든 DM·삭제된 메시지·비공개 신앙 기록을 몰래 조회하는 기능은 만들지 않았다.
- 개인 테이블 3개의 RLS 및 클라이언트 직접 접근 차단, 이의신청 길이·속도 제한과 중복 pending 제약, 만료 세션 차단 추가.
- 다른 사건 조회 실패 시 이전 증거에 남은 조치 버튼이 다른 사건을 가리키는 문제 수정. 웹 중복 요청 잠금, 계정/동의 변경 시 결과 폐기, 내보내기 계정 전환 보호 추가.
- 웹 본인 신고 화면 로딩·빈 상태·실패·재시도, 잘못된 이의신청 URL, 중복 제출 상태를 구분한다.

## 운영 DB 반영

아래 두 마이그레이션만 원자적 트랜잭션으로 적용하고 이력을 기록했다. AI·화상회의·라이브의 다른 pending 마이그레이션을 일괄 적용하지 않았다.

- `20261015090000_operations_console`
- `20261015110000_audit_provenance`

접속 출처의 검증용 gateway는 활성 키가 0개다. 검증되지 않은 IP를 사실처럼 표시하지 않고 unavailable로 응답한다. 실제 IP 수집 gateway를 배포·활성화하지 않았다. 기존 감사 데이터에는 가짜 접속 출처를 채우지 않는다.

실제 회원의 승인·권한·동의·제재를 테스트 목적으로 변경하지 않았다. 합성 테스트는 모두 롤백했다. 배포 직후 운영 appeals / holds / exports는 각각 0개였다.

## 검증 근거

| 검사 | 결과 |
| --- | --- |
| 운영 DB 적용 전 합성 pgTAP | 67개 통과, 전부 롤백 |
| 운영 DB 적용 후 동일 pgTAP | 67개 통과, 전부 롤백 |
| 기존 회계·장부·영수증 pgTAP 회귀 | 68개 통과, 전부 롤백 |
| 최종 전체 웹 테스트 | 65 파일 / 499개 통과 |
| 웹 TypeScript 검사 | 통과 |
| 웹 production build / 데모 노출 차단 검사 | 통과 |
| 테마 명암·웹/네이티브 토큰 | 5개 통과 |
| 보호된 레거시 런타임 | 28개 파일 무결성 통과 |
| SwiftUI generic iOS Simulator Debug build | 통과. 기존 Pods 타깃·deprecated 경고는 남음 |
| 브라우저 실화면 | 격리 로컬 데모에서 도구 랜딩·미연결 상태와 여백 확인 |

pgTAP은 finish() 실패를 SQL 예외로 바꾸는 strict gate를 사용한다. CLI 종료 코드만으로 성공을 주장하지 않았다. 원본 테스트는 `supabase/tests/operations_console.test.sql`, 웹 테스트는 `apps/web/src/test/operations-console.test.tsx`에 있다.

## 미완료 / 제한

- 이번 턴에서는 운영 웹을 Vercel로 재배포하거나 iPhone에 새 앱을 설치하지 않았다. 로컬 웹·SwiftUI 소스 변경과 운영 DB 적용을 구분해야 한다.
- 실제 iPhone 관리자 로그인·Google 재인증 복귀·신고 심사·내보내기 사용은 아직 실기기에서 검증하지 않았다. Debug 컴파일 성공은 App Store 출시 승인 근거가 아니다.
- 이의신청 인용은 재검토 결정 기록이다. 기존 이용 정지·콘텐츠 숨김을 자동으로 되돌리지 않는다. 역할·개인정보·다른 제재를 자동 복구하는 우회 기능은 추가하지 않았다.
- 감사 파일 검증은 무결성 확인이며 전체 DB 복원이나 로그 삭제 승인이 아니다.
- 최신 native literal RPC 목록 92개 중 88개가 존재한다. 별도 기능인 `church_live_command`, `church_live_snapshot`, `meeting_command`, `meeting_snapshot` 4개는 누락되어 **전체 native 출시 gate는 차단 상태**다. 관련 snapshot은 `operations-native-rpcs-2026-10-19.json`이며 15분 이후 재사용할 수 없다.
- Supabase 보안 advisor는 기존 SECURITY DEFINER RPC 경고와 유출 비밀번호 보호 비활성 경고 등을 반환했다. 전체 시스템을 무결하다고 판정하지 않았다. RPC-only 테이블의 RLS/no-policy 항목은 직접 접근 차단 의도와 구분해야 한다. 다른 앱의 기존 함수·Auth 설정은 이번 범위에서 임의 변경하지 않았다.

관련 보안 지침: [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [Security definer 점검](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable), [유출 비밀번호 보호](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
