# 운영 서버·데이터베이스 연결 점검 — 2026-10-11

## 완료 범위

- [x] 로컬 앱 `http://127.0.0.1:5176`의 데모용 빈 환경 변수 실행을 종료하고 실제 Supabase 연결로 재시작했다.
- [x] 기존 프로젝트 `supabase-violet-park` (`opwzujhfsxqaivtbjewg`, `us-east-1`, ACTIVE_HEALTHY)를 사용했다. 새 프로젝트를 생성하거나 DB를 초기화하지 않았다.
- [x] 공개 URL/anon 키만 Git에서 제외되는 `apps/web/.env.development.local`에 설정했다. 배포용 파일의 프로젝트 및 공개 키 유형을 검증했다. 단위 테스트 환경은 분리했다.
- [x] 누락된 채널 마이그레이션 3개를 운영 DB에 원래 버전으로 적용했다.
- [x] 적용 후 재검사에서 추가 적용 대상 0개(`upToDate: true`)를 확인했다.
- [ ] 실제 사용자 로그인 후 채널 읽기·쓰기·업로드·두 브라우저 Realtime 종단 검증은 미완료다.
- [ ] 이번 연결 작업에서 Git push, Vercel 재배포, 앱스토어 제출은 수행하지 않았다.

## 적용 이력

| 버전 | 변경 | SHA-256 |
| --- | --- | --- |
| `20260909135418` | 채널 이모지·멘션·전달·사진/영상 첨부 | `86e00183a2efe21d07ed586f0e40a8fcece7c146e13d5c4ece1db90b37ff43dd` |
| `20260913022919` | 비공개 Realtime 변경 이벤트·스레드·알림 설정 | `bde699edd092d91556f9284f04684b394574a609cb113624eaded23c9c490011` |
| `20261011043227` | 메시지 가시성·스레드 읽음·재시도 무결성 | `ced683fd24bf41820974a87eedd2504c6dbd97e142682e840e214bfb3c7be590` |

운영 프로젝트는 다른 서비스와 공유된다. `20261006153528`, `20261006155409`는 RAFT 이력이므로 재건 저장소에 없는 것이 정상이다. 루트에서의 일반 `db push --dry-run`은 이 원격 전용 이력 때문에 중단됐다. **`migration repair --status reverted`를 사용하지 않았고, 가짜 이력 파일도 만들지 않았다.**

새 임시 작업 공간을 기존 프로젝트에 연결하고, 공식 `migration fetch --linked`로 실제 운영 이력 22개를 내려받았다. 여기에 검토한 재건 마이그레이션 3개만 추가하고 원본과 해시 일치를 확인했다. `db push --linked --include-all --skip-vault --dry-run`의 대상이 위 3개뿐임을 확인한 후 동일 옵션으로 실제 적용했다. seed·roles·Vault 변경은 없었다. 다음 배포도 새 작업 공간에서 현재 공유 이력을 다시 받아 대조해야 하며, 이 보고서의 임시 작업 공간을 영구 배포 기준으로 사용하면 안 된다.

## 실제 운영 확인

- 교회 36개, 노회 5개: 공개 가입 디렉터리 REST **200**.
- 현재 필수 동의 문서 5개: REST **200**. 브라우저 가입 화면에서도 노회 선택 및 필수 동의 문서 5개를 확인했다. 가입이나 동의 제출은 하지 않았다.
- Auth `/settings`: **200**, 이메일 인증 수단 활성, 가입 활성. 로그인 성공 자체의 증거는 아니다.
- 적용 전후 조직 36개·채널 1개·채널 메시지 0개로 동일했다. 운영 테스트 메시지나 회원을 생성하지 않았다.
- `channel_rich_command`와 `channel_thread_snapshot` RPC 존재, `channel_change_events`가 `supabase_realtime` 발행 대상이며 이벤트 트리거 7개가 설치됨을 확인했다.
- 로그인하지 않은 공개 키의 채널 snapshot/thread/rich RPC 호출과 메시지·첨부·이벤트 테이블 조회 총 6개는 모두 **401 / 42501**로 차단됐다.
- authenticated 역할에도 원본 `channel_messages`, 비공개 `channel_thread_reads` SELECT 권한이 없고, 이전 `channel_rich_command_before_visibility_integrity` 실행 권한이 없음을 확인했다.
- Storage 조회 정책이 새 `private.can_read_community_media(name, auth.uid())`를 사용함을 확인했다.

## 회귀 검증

- `supabase test db --local`: **13 파일 / 766 테스트 통과**. 운영 DB에는 시험 데이터를 넣지 않았다.
- 웹 단위 테스트: **41 파일 / 275 테스트 통과**.
- TypeScript 검사 통과.
- 마이그레이션 정적 검사: 23개 통과.
- 기존 모바일 런타임 무결성: 보호 파일 28개 통과.

## 로그인 미완료 원인

실제 Auth `/token` 요청에서 **400 / `invalid_credentials`**를 확인했다. 요청이 서버에 도달했고 DB 또는 네트워크 연결 실패가 아니라 자격 증명이 거절됐다. 공개 점검 자료에는 계정 식별자, 계정별 상태, 상세 요청 시각, 비밀번호·해시·토큰을 기록하지 않는다. 비밀번호 변경이나 계정 재생성으로 인증을 우회하지 않았다. 이후 사용자가 승인한 재설정 메일 요청은 서비스 화면에서 접수됐으며, 실제 수신·비밀번호 변경·로그인 완료는 사용자가 직접 확인할 단계다.

## 남아 있는 보안 점검

운영 보안 경고가 0개인 것은 아니다. 적용 전후 WARN 항목은 동일하다.

- [익명 호출 가능 SECURITY DEFINER 경고](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable) 1개: 다른 서비스의 `capture_cashlog_signup_consents`. 이번 범위에서 변경하지 않았다.
- [인증 사용자 호출 가능 SECURITY DEFINER 경고](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable) 71개: 기존 RPC별 의도된 호출 권한과 내부 검사에 대한 별도 리뷰 대상이다. 경고만 보고 일괄 권한을 삭제하지 않았다.
- [유출 비밀번호 차단 미활성](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection): 기존 경고 유지. 요금제·운영 정책 확인 후 설정할 항목이다.
- RLS 활성/정책 없음 INFO는 11개에서 17개로 증가했다. 신규 6개는 직접 읽기 권한을 제거하고 검증된 RPC에서만 접근하도록 의도한 내부 테이블이다. 공개 SELECT 정책을 추가해 경고를 숨기지 않았다.

이는 서버·DB 연결 확인이지 전체 서비스 출시 승인 또는 로그인·메일·파일 업로드 종단 검증 완료 보고가 아니다.
