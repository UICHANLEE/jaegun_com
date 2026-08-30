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
