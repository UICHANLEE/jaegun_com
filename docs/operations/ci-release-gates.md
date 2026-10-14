# CI와 릴리스 게이트

`Web quality` 워크플로는 PR과 `main` 변경에 다음 네 가지 독립 게이트를 적용한다.

| 게이트 | 실패 조건 | 비고 |
| --- | --- | --- |
| 정적 보안 | 비밀값 패턴, 위험한 SQL DDL, RLS 누락, 고정되지 않은 `SECURITY DEFINER search_path`, `PUBLIC`/`anon` 함수 실행 권한 | `npm run test:security-static`으로 로컬 재현 |
| 공급망 | 루트 또는 `apps/web` 잠금 파일에 high/critical 취약점 | `npm run audit:dependencies`로 로컬 재현. 예외는 만료일·담당자·완화책이 있는 승인 기록 없이는 허용하지 않는다. |
| 웹 품질 | 타입 검사, Vitest, 프로덕션 빌드 실패 | `apps/web`의 잠금 파일을 사용한다. |
| 데이터베이스 | 로컬 Supabase 기동, 전체 마이그레이션·seed 재적용, pgTAP 실패 | 원격 프로젝트나 운영 비밀값을 사용하지 않는다. |

## pgTAP 실행 환경

데이터베이스 게이트는 단순 PostgreSQL 서비스가 아니라 Auth·Storage 스키마와 Supabase 역할을 포함한 격리된 로컬 Supabase가 필요하다. GitHub 호스팅 Ubuntu runner의 Docker를 사용하며 `supabase@2.115.0`으로 고정한다. CI에 `SUPABASE_ACCESS_TOKEN`, DB 비밀번호 또는 service-role key를 등록하지 않는다.

로컬 재현:

```bash
npx --yes supabase@2.115.0 start
npx --yes supabase@2.115.0 db reset --local
npx --yes supabase@2.115.0 test db --local
npx --yes supabase@2.115.0 stop --no-backup
```

Docker가 최소 4 CPU, 8GB 메모리와 충분한 디스크를 사용할 수 있게 한다. 이미지 다운로드나 Docker 장애는 테스트 실패와 구분해 재실행할 수 있지만, SQL·pgTAP 실패를 재시도로 무시하면 안 된다.

## 병합·배포 원칙

1. `main` 직접 푸시는 금지하고 PR을 사용한다.
2. 네 게이트를 모두 필수 상태 검사로 지정하고 force-push를 막는다.
3. Preview는 운영 DB가 아닌 별도 staging Supabase의 공개 URL과 anon key만 사용한다.
4. 스키마 변경은 staging에 적용하고 pgTAP·권한 공격 테스트를 통과한 뒤 검증된 Preview artifact를 Production으로 승격한다.
5. Vercel 정적 빌드 환경에는 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`만 둔다. service-role, JWT secret, DB URL·비밀번호는 제거한다.
6. 배포 후 1시간 오류 로그, 로그인·가입·게시·채팅·승인 smoke test와 관측성 경보를 확인한다.

보안 스캐너의 `secret-scan: allow` 및 `migration-lint: allow-destructive` 표식은 거짓 양성 억제가 아니라 검토 기록이다. PR 설명에 대상, 이유, 복구 방법과 승인자를 남겨야 한다.

## 2026-10-13 UI 릴리스 의존성 보안 업데이트

배포 전 공급망 게이트에서 발견된 취약점에 대응하여 Capacitor core/CLI/iOS를 `8.5.3`, Vitest를 `4.1.11`로 고정하고 `source-map-js`·`brace-expansion`·`undici`의 잠금 파일을 호환 수정 버전으로 갱신했습니다. 루트와 웹의 `npm audit`는 각각 취약점 0건이며, 웹 289개 테스트와 iOS 시뮬레이터 빌드를 통과했습니다. 운영 DB 마이그레이션과 인증 정책은 변경하지 않습니다.

## 2026-10-14 모임 관리 릴리스

별도 원격 staging 프로젝트가 없는 상태에서 사용자가 **격리된 로컬 검증 후 운영 반영**을 명시적으로 선택했습니다. 검증은 별도의 Supabase 프로젝트 ID와 포트를 사용하며 원래 로컬 DB와 운영 DB를 초기화하지 않습니다. 운영 DB는 RAFT와 공유되므로 새 작업 공간에서 실제 원격 이력을 내려받고, 추가 대상이 `20261014000100_event_logistics.sql` 한 개이며 seed·roles·Vault 변경이 없음을 dry-run으로 확인했습니다. 원격 전용 이력을 지우거나 가짜 이력으로 맞추지 않습니다.

Vercel은 `--prod --skip-domain`으로 운영 환경의 산출물을 먼저 빌드하고, DB 권한/회귀 검증 및 승인된 마이그레이션 적용 후 `promote`로 도메인을 전환합니다. `.vercelignore`는 네이티브 빌드·iOS 프로젝트·node_modules·검증 이미지·환경 파일을 웹 소스 업로드에서 제외합니다. 운영 계정·시험 참석자·시험 모임은 생성하지 않습니다.

릴리스 완료 기록:

- 웹 43개 파일·295개 테스트, DB 14개 파일·850개 pgTAP 테스트를 통과했습니다. 정적 보안·동의 문서 해시·마이그레이션 린트·Edge 테스트·보호 런타임 검사도 통과했고 루트/웹 공급망 취약점은 각각 0건입니다.
- 운영에 적용한 `20261014000100_event_logistics.sql`의 SHA-256은 `c05e2909d8608b39a4fa6ae09add6508a68c40069371bf9eaddee72fedf5a4bd`입니다. 적용 후 dry-run은 `upToDate: true`, 추가 migration·seed·roles 없음으로 확인했습니다.
- Vercel `dpl_FKAa9cgWXZgXG86HbYoTrvR1VJrP`가 Production / Ready이며 [운영 서비스](https://jaegun-com.vercel.app)로 승격했습니다. 모임 관리 자산의 HTTP 200 응답과 새 화면 코드 전달도 확인했습니다.
- 운영 로그인/가입 화면에서 5개 필수 동의·14세 이상 확인·노회 우선 교회 선택, 390px 가로 넘침 없음, 실시간 라이트/다크 전환, 콘솔 오류 없음, 보호 경로의 로그인 이동을 확인했습니다. 공개 API 키로 호출한 비로그인 명단 조회/배정 저장은 각각 HTTP 401 / SQLSTATE `42501`로 거부됐습니다. CSP `frame-ancestors 'none'`, HSTS, `nosniff` 헤더도 확인했습니다.
- 실제 로그인 이후 개최자 등록·수정 보존, 참석 명단·조/차량 배정·운전자 좌석·초과 인원·재접속·동시 저장·일반 회원 차단은 격리된 실제 Supabase Auth/TOTP·DB에서 검증했습니다. 운영 계정 로그인 이후 흐름과 1시간 관측은 이번 확인 범위에 포함하지 않습니다.
- 임원 회의록/회계 폼은 최초 마운트가 아닌 실제 서버 서비스 연도 변경 때만 초기화하도록 수정했습니다. 신규 폼이 초기 로딩 효과로 닫히는 경쟁 조건을 제거했으며 기존 미저장 이동 방지 회귀 테스트를 통과했습니다.
- 최신 웹 산출물을 iOS 번들에도 동기화하고 네이티브 릴리스 설정/데모 데이터 미포함 검사를 통과했습니다. App Store 배포는 하지 않았으며 기존 iOS 보안 초기화 차단을 우회하지 않았습니다.
- 검증 후 자체 임시 웹 서버와 격리 Supabase를 종료했습니다. 기존 사용자 로컬 서버·DB는 유지했습니다.
