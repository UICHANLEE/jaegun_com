# 재건 공동체 Supabase 백엔드

이 디렉터리는 실제 Auth 사용자만 사용하는 운영 스키마입니다. `seed.sql`은 엑셀에서 추출한 정확히 36개 교회, 각 교회의 빈 기본 게시판, 전 교회 공통 운영 안내 3건만 생성합니다. 사람·가짜 회원·교회별 가짜 글은 만들지 않습니다.

## 적용

Supabase CLI로 프로젝트를 연결한 뒤 마이그레이션과 seed를 적용합니다.

```bash
npx supabase login
npx supabase link --project-ref <project-ref>
npx supabase db push
npx supabase db seed
```

로컬 전체 재구성은 `npx supabase start && npx supabase db reset`입니다. 원격 운영 DB에서 `db reset`은 사용하지 않습니다.

프런트엔드 런타임에는 다음 두 값만 둡니다.

```dotenv
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<publishable-anon-key>
```

CLI/CI에는 필요에 따라 `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, `SUPABASE_DB_PASSWORD`를 비밀값으로 설정합니다. `SUPABASE_SERVICE_ROLE_KEY`는 서버 전용이며 `VITE_` 변수나 브라우저 번들에 절대 넣지 않습니다.

Auth에서 이메일 또는 휴대폰 로그인을 활성화하고 Vercel 운영 URL을 Redirect URL에 추가합니다. Storage의 `avatars`와 `community-media`는 마이그레이션이 비공개 버킷으로 생성합니다.

`messages`, `notifications`, 승인 큐, 회원 상태, 게시물·댓글, 대화 읽음 상태와 임원 직책·회의록·회계장부는 `supabase_realtime` publication에 멱등 등록됩니다. 클라이언트 Realtime 구독에도 각 사용자의 RLS가 그대로 적용됩니다.

## 최초 최고 관리자 등록

먼저 본인이 앱 또는 Auth Dashboard에서 실제 계정을 만든 뒤, SQL Editor에서 해당 Auth UUID로 아래 트랜잭션을 한 번 실행합니다. 임의 UUID나 seed 사용자를 만들지 마세요.

```sql
begin;

insert into public.profiles (id, display_name)
select id, '이재건'
from auth.users
where id = '<본인의-auth-user-uuid>'::uuid
on conflict (id) do update set display_name = excluded.display_name;

insert into public.platform_admins (user_id, note)
values ('<본인의-auth-user-uuid>'::uuid, '최초 최고 관리자')
on conflict (user_id) do nothing;

insert into public.audit_logs (
  actor_id, action, entity_type, target_user_id, details
)
values (
  '<본인의-auth-user-uuid>'::uuid,
  'platform_admin.bootstrapped',
  'platform_admin',
  '<본인의-auth-user-uuid>'::uuid,
  '{"source":"manual_sql_editor"}'::jsonb
);

commit;
```

사역자·임원의 승인 및 상태 변경은 최고 관리자만 할 수 있습니다. 일반 회원의 승인 및 상태 변경은 해당 교회의 **활성 사역자 또는 임원만** 할 수 있습니다. 최고 관리자도 그 교회의 사역자/임원 자격이 없다면 일반 회원을 대신 승인할 수 없습니다. 모든 변경은 자기 자신, 다른 교회, 동급 권한 처리를 거부하며 `audit_logs`에 남습니다.

최고 관리자는 별도의 교회 회원권이 없어도 로그인 후 사역자·임원 승인 화면에 접근할 수 있습니다. 게시글 작성과 1:1 채팅은 일반 사용자와 동일하게 승인된 교회 회원권이 있을 때만 활성화됩니다.

## 클라이언트 데이터 계약

주요 테이블과 컬럼은 다음과 같습니다.

- `organizations`: `id`, `slug`, `source_name`, `display_name`, `presbytery`, `status`, `description`, `location_text`, `contact_phone`, `website_url`, `worship_schedule`, `hero_path`, `claimed_at`, `claimed_by`, timestamps
- `profiles`: `id`, `display_name`, `bio`, `avatar_path`, `deactivated_at`, timestamps
- `organization_memberships`: `id`, `user_id`, `organization_id`, `role`, `church_title_code`, `status`, `approved_from_application_id`, `approved_by`, `joined_at`, `ended_at`, `updated_at`
- `membership_applications`: `id`, `user_id`, `organization_id`, `requested_role`, `requested_church_title_code`, `requested_executive_office_codes`, `requested_service_year`, `status`, `applicant_note`, `evidence_path`, `review_reason`, `reviewed_by`, `reviewed_at`, timestamps
- `executive_office_assignments`: `id`, `membership_id`, `service_year`, `office_code`, `assigned_from_application_id`, `assigned_by`, `created_at`, `ended_at`
- `meeting_minutes`: `id`, `organization_id`, `meeting_year`, `meeting_date`, `title`, `body`, `status`, `author_id`, `author_name`, timestamps
- `ledger_entries`: `id`, `organization_id`, `fiscal_year`, `entry_date`, `entry_type`, `category`, `description`, `amount`, `memo`, `author_id`, `author_name`, timestamps
- `boards`: `id`, `organization_id`, `slug`, `name`, `description`, `sort_order`, `is_global`, `is_read_only`, `staff_only_posting`, timestamps
- `posts`: `id`, `organization_id`, `board_id`, `author_id`, `author_label`, `title`, `body`, `status`, `is_system`, `is_pinned`, `allow_comments`, `published_at`, `edited_at`, `deleted_at`, timestamps
- `post_media`: `id`, `post_id`, `uploader_id`, `storage_path`, `kind`, `mime_type`, `byte_size`, `width`, `height`, `duration_seconds`, `alt_text`, `sort_order`, `created_at`
- `comments`: `id`, `post_id`, `author_id`, `parent_id`, `body`, `status`, `edited_at`, `deleted_at`, timestamps
- `conversations`: `id`, `organization_id`, `participant_low`, `participant_high`, `created_by`, `last_message_at`, timestamps
- `messages`: `id`, `conversation_id`, `sender_id`, `kind`, `body`, `media_path`, `media_metadata`, `client_nonce`, `edited_at`, `deleted_at`, `created_at`
- `conversation_reads`: `conversation_id`, `user_id`, `last_read_message_id`, `last_read_at`
- `notifications`: `id`, `user_id`, `kind`, `title`, `body`, `entity_type`, `entity_id`, `metadata`, `read_at`, `created_at`
- `audit_logs`: `id`, `actor_id`, `action`, `entity_type`, `entity_id`, `organization_id`, `target_user_id`, `details`, `created_at`

쓰기 흐름에서 사용하는 RPC 시그니처입니다. 파라미터 이름을 그대로 보내면 됩니다.

```text
get_my_context() -> jsonb
get_service_year() -> smallint
get_service_clock() -> jsonb
submit_membership_application(p_organization_id uuid, p_requested_role app_role, p_applicant_note text = null, p_requested_church_title_code text = null, p_requested_executive_office_codes text[] = {}, p_requested_service_year integer = null) -> uuid
set_membership_application_evidence(p_application_id uuid, p_evidence_path text) -> void
withdraw_membership_application(p_application_id uuid) -> void
review_membership_application(p_application_id uuid, p_decision review_decision, p_reason text = null) -> jsonb
set_membership_status(p_membership_id uuid, p_status membership_status, p_reason text) -> void
update_organization_profile(p_organization_id uuid, p_patch jsonb) -> jsonb
get_or_create_conversation(p_other_user_id uuid) -> uuid
get_conversation_summaries() -> table(id uuid, organization_id uuid, participants jsonb, last_message jsonb, unread_count bigint)
send_message(p_conversation_id uuid, p_kind message_kind, p_body text = null, p_media_path text = null, p_media_metadata jsonb = {}, p_client_nonce uuid = generated) -> uuid
mark_conversation_read(p_conversation_id uuid, p_message_id uuid = null) -> void
mark_notifications_read(p_notification_ids uuid[] = null) -> integer
save_meeting_minute(p_id uuid, p_organization_id uuid, p_meeting_year integer, p_meeting_date date, p_title text, p_body text, p_status text) -> uuid
delete_meeting_minute(p_id uuid) -> void
save_ledger_entry(p_id uuid, p_organization_id uuid, p_fiscal_year integer, p_entry_date date, p_entry_type text, p_category text, p_description text, p_amount numeric, p_memo text) -> uuid
delete_ledger_entry(p_id uuid) -> void
set_executive_offices(p_membership_id uuid, p_service_year integer, p_office_codes text[]) -> jsonb
```

게시물·댓글은 RLS를 거쳐 테이블에 직접 `insert/update`하고, 채팅·승인·회원 상태·조직 수정·알림 읽음은 반드시 RPC를 사용합니다. 승인 대기 목록은 `membership_applications`를 `profiles(id=user_id)` 및 `organizations(id=organization_id)`와 조인합니다. 게시물 목록은 `posts`를 `boards`와 `post_media`에 조인합니다. 채팅 목록은 `get_conversation_summaries()`를 호출해 대화별 참가자 배열, 마지막 메시지 객체(`id`, `sender_id`, `kind`, `body`, `created_at`), `conversation_reads.last_read_at` 이후 상대방이 보낸 메시지의 `unread_count`만 받습니다. 목록 화면에서 `messages` 전체를 먼저 읽지 마세요. RLS가 승인 전·타 교회 데이터를 자동으로 숨깁니다.

임원 직책은 회원 역할과 분리된 연도별 메타데이터입니다. `executive_office_assignments`를 클라이언트에서 직접 수정하지 말고 최고 관리자의 승인 흐름 또는 최고 관리자 전용 `set_executive_offices` RPC로 배정합니다. 같은 교회의 활성 임원만 회의록과 회계장부를 열람할 수 있습니다. 회의록 쓰기는 회장·부회장·총무·서기, 회계장부 쓰기는 회장·회계에게만 허용되며 과거 연도는 보존 기록으로 읽기 전용입니다. 서비스 연도는 데이터베이스가 `Asia/Seoul` 기준으로 계산하고, 로그인한 클라이언트는 `get_service_year()`로 동일한 값을 받아 사용합니다. 플랫폼 최고 관리자도 해당 교회의 활성 임원 자격 없이는 운영 기록에 접근할 수 없고, 사역자와 일반 회원 역시 접근할 수 없습니다.

## 미디어 경로

원본 파일명 대신 UUID 파일명을 사용하고 업로드 후 DB 경로만 저장합니다.

```text
avatars/<user-id>/<file-id>.<ext>
community-media/<organization-id>/organization/<file-id>.<ext>
community-media/<organization-id>/applications/<application-id>/<file-id>.<ext>
community-media/<organization-id>/posts/<post-id>/<file-id>.<ext>
community-media/<organization-id>/messages/<conversation-id>/<file-id>.<ext>
```

아바타는 이미지 5MiB, 게시물 이미지는 15MiB, 공동체 영상은 500MiB까지 허용됩니다. 비공개 객체는 `createSignedUrl`로 짧은 만료 시간을 지정해 표시하고 공개 URL을 저장하지 않습니다.
