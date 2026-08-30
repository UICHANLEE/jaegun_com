-- Release safety, privacy, moderation, account deletion, push, and media-upload foundations.
--
-- This migration deliberately keeps all client authority behind auth.uid(), RLS,
-- or narrowly granted RPCs. Operations that require the service role or an Edge
-- Function are named service_* and are never granted to browser roles.

-- Account removal must not erase a surviving participant's conversation. The
-- former CASCADE foreign keys made deleting either profile delete the whole
-- conversation and every message. Participant UUIDs are immutable historical
-- identifiers without a profile FK; after Auth erasure the UI resolves a missing
-- profile as "탈퇴한 회원" while the surviving participant keeps access/history.
alter table public.conversations
  drop constraint if exists conversations_participant_low_fkey,
  drop constraint if exists conversations_participant_high_fkey,
  drop constraint if exists conversations_created_by_fkey,
  drop constraint if exists conversations_two_distinct_users_check,
  drop constraint if exists conversations_canonical_order_check,
  drop constraint if exists conversations_creator_participant_check;

alter table public.conversations
  add constraint conversations_two_distinct_users_check check (participant_low <> participant_high),
  add constraint conversations_canonical_order_check check (participant_low::text < participant_high::text),
  add constraint conversations_creator_participant_check check (
    created_by = participant_low or created_by = participant_high
  );

create table public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_user_id uuid not null references public.profiles(id) on delete cascade,
  reason text check (reason is null or char_length(reason) <= 500),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (blocker_id, blocked_user_id),
  constraint user_blocks_distinct_users_check check (blocker_id <> blocked_user_id)
);

create index user_blocks_blocked_lookup_idx
  on public.user_blocks (blocked_user_id, blocker_id);

comment on table public.user_blocks is
  'A user-controlled safety boundary. Either direction blocks new conversations and messages.';

-- A fixed-window primitive is intentionally private. Product RPCs and write
-- triggers consume named buckets; clients can never choose their own limits.
create table private.rate_limit_counters (
  actor_id uuid not null,
  action_key text not null check (char_length(action_key) between 1 and 80),
  window_started_at timestamptz not null,
  event_count integer not null check (event_count >= 0),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_id, action_key)
);

revoke all on table private.rate_limit_counters from public, anon, authenticated;

create table public.consent_documents (
  document_key text not null check (
    document_key in ('privacy_policy', 'community_guidelines')
  ),
  version text not null check (char_length(version) between 1 and 40),
  locale text not null default 'ko-KR' check (char_length(locale) between 2 and 20),
  title text not null check (char_length(title) between 1 and 120),
  document_url text not null check (char_length(document_url) between 1 and 500),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  required boolean not null default true,
  published_at timestamptz not null,
  effective_at timestamptz not null,
  retired_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (document_key, version),
  constraint consent_documents_lifecycle_check check (
    retired_at is null or retired_at >= effective_at
  )
);

create unique index consent_documents_one_active_version_idx
  on public.consent_documents (document_key, locale)
  where retired_at is null;

insert into public.consent_documents (
  document_key,
  version,
  title,
  document_url,
  content_sha256,
  required,
  published_at,
  effective_at
)
values
  (
    'privacy_policy',
    '2026-08-27',
    '개인정보 처리방침',
    '/legal/privacy/2026-08-27',
    '2eeac1f3dbaa45d8b2742aa9239aedf2507d67c02b397a6ac362ef20d9a2f829',
    true,
    '2026-08-27 00:00:00+09'::timestamptz,
    '2026-08-27 00:00:00+09'::timestamptz
  ),
  (
    'community_guidelines',
    '2026-08-27',
    '공동체 이용규칙',
    '/legal/community/2026-08-27',
    'c587eae93255d82391ddd287a1737679f9a2823e598dd091fa4cb819eed3c59f',
    true,
    '2026-08-27 00:00:00+09'::timestamptz,
    '2026-08-27 00:00:00+09'::timestamptz
  )
on conflict (document_key, version) do nothing;

comment on column public.consent_documents.content_sha256 is
  'SHA-256 of the canonical UTF-8 JSON emitted by apps/web/src/data/legalDocuments.ts for this exact version.';

create table public.user_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  document_key text not null,
  document_version text not null,
  accepted boolean not null,
  recorded_at timestamptz not null default pg_catalog.clock_timestamp(),
  withdrawn_at timestamptz,
  source text not null default 'app' check (
    source in ('app', 'web', 'signup_metadata', 'admin_migration')
  ),
  foreign key (document_key, document_version)
    references public.consent_documents(document_key, version) on delete restrict,
  constraint user_consents_withdrawal_check check (
    (accepted and withdrawn_at is null)
    or (not accepted and withdrawn_at is not null)
  )
);

create unique index user_consents_current_event_idx
  on public.user_consents (user_id, document_key, document_version, recorded_at);
create index user_consents_user_timeline_idx
  on public.user_consents (user_id, recorded_at desc);

comment on table public.user_consents is
  'Append-only evidence of the exact policy/community-rule version accepted or withdrawn by auth.uid().';

create table public.privacy_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  directory_visibility text not null default 'private' check (
    directory_visibility in ('private', 'name_only', 'church_profile')
  ),
  avatar_visible boolean not null default false,
  church_title_visible boolean not null default true,
  email_visible boolean not null default false,
  bio_visible boolean not null default false,
  analytics_opt_in boolean not null default false,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp()
);

create table public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  push_enabled boolean not null default true,
  messages_enabled boolean not null default true,
  posts_enabled boolean not null default true,
  comments_enabled boolean not null default true,
  approvals_enabled boolean not null default true,
  governance_enabled boolean not null default true,
  events_enabled boolean not null default true,
  community_enabled boolean not null default true,
  quiet_hours_start time,
  quiet_hours_end time,
  timezone text not null default 'Asia/Seoul' check (char_length(timezone) between 1 and 80),
  lock_screen_preview text not null default 'generic' check (
    lock_screen_preview in ('generic', 'hidden')
  ),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint notification_preferences_quiet_hours_check check (
    (quiet_hours_start is null and quiet_hours_end is null)
    or (quiet_hours_start is not null and quiet_hours_end is not null)
  )
);

create table public.conversation_preferences (
  user_id uuid not null references public.profiles(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  notifications_enabled boolean not null default true,
  muted_until timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (user_id, conversation_id)
);

create table public.push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  installation_id uuid not null,
  platform text not null check (platform in ('ios', 'android', 'web')),
  token_fingerprint text not null check (token_fingerprint ~ '^[0-9a-f]{64}$'),
  app_version text check (app_version is null or char_length(app_version) <= 40),
  last_seen_at timestamptz not null default pg_catalog.clock_timestamp(),
  disabled_at timestamptz,
  disabled_reason text check (disabled_reason is null or char_length(disabled_reason) <= 120),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (user_id, installation_id),
  constraint push_devices_installation_unique unique (installation_id),
  constraint push_devices_token_fingerprint_unique unique (token_fingerprint)
);

comment on table public.push_devices is
  'Self-visible device metadata only. Provider tokens are encrypted into private.push_device_secrets by an Edge Function.';

create table private.push_device_secrets (
  device_id uuid primary key references public.push_devices(id) on delete cascade,
  token_ciphertext text not null,
  encryption_key_version smallint not null check (encryption_key_version > 0),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  rotated_at timestamptz
);

create table private.push_outbox (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  event_code text not null check (
    event_code in (
      'new_message',
      'post_comment',
      'application_update',
      'community_notice',
      'security_notice'
    )
  ),
  entity_type text not null check (char_length(entity_type) between 1 and 80),
  entity_id uuid,
  title text not null check (
    title in ('새 메시지가 있습니다', '새 알림이 있습니다', '보안 알림이 있습니다')
  ),
  body text not null default '앱에서 내용을 확인해 주세요.' check (
    body = '앱에서 내용을 확인해 주세요.'
  ),
  is_silent boolean not null default false,
  collapse_key text check (collapse_key is null or char_length(collapse_key) <= 160),
  idempotency_key text not null unique check (char_length(idempotency_key) between 1 and 200),
  status text not null default 'pending' check (
    status in ('pending', 'processing', 'delivered', 'failed', 'dead')
  ),
  next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
  claimed_at timestamptz,
  delivered_at timestamptz,
  attempts integer not null default 0 check (attempts >= 0),
  last_error_code text check (last_error_code is null or char_length(last_error_code) <= 120),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint push_outbox_generic_payload_check check (
    entity_type !~* '(body|content|message_text|prayer)'
  )
);

create index push_outbox_claim_idx
  on private.push_outbox (next_attempt_at, created_at)
  where status in ('pending', 'failed');

comment on table private.push_outbox is
  'Generic push queue: title/body are constrained boilerplate and entity IDs are opaque. No chat/prayer content is stored.';

create table private.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references private.push_outbox(id) on delete cascade,
  device_id uuid not null references public.push_devices(id) on delete cascade,
  status text not null default 'pending' check (
    status in ('pending', 'processing', 'delivered', 'failed', 'dead')
  ),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
  claimed_at timestamptz,
  delivered_at timestamptz,
  last_error_code text check (last_error_code is null or char_length(last_error_code) <= 120),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (job_id, device_id)
);

create index push_deliveries_claim_idx
  on private.push_deliveries (next_attempt_at, created_at)
  where status in ('pending', 'failed');

revoke all on table private.push_device_secrets from public, anon, authenticated;
revoke all on table private.push_outbox from public, anon, authenticated;
revoke all on table private.push_deliveries from public, anon, authenticated;

create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  subject_fingerprint text not null check (subject_fingerprint ~ '^[0-9a-f]{64}$'),
  status text not null default 'requested' check (
    status in (
      'requested',
      'cancelled',
      'processing',
      'awaiting_identity_deletion',
      'completed',
      'failed'
    )
  ),
  reason text check (reason is null or char_length(reason) <= 1000),
  requested_at timestamptz not null default pg_catalog.clock_timestamp(),
  scheduled_for timestamptz not null,
  cancelled_at timestamptz,
  processing_started_at timestamptz,
  processing_claimed_at timestamptz,
  processing_attempts integer not null default 0 check (processing_attempts >= 0),
  identity_claimed_at timestamptz,
  identity_attempts integer not null default 0 check (identity_attempts >= 0),
  completed_at timestamptz,
  failure_code text check (failure_code is null or char_length(failure_code) <= 120),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint account_deletion_schedule_check check (scheduled_for >= requested_at),
  constraint account_deletion_state_check check (
    (status = 'requested' and cancelled_at is null and completed_at is null)
    or (status = 'cancelled' and cancelled_at is not null and completed_at is null)
    or (status in ('processing', 'awaiting_identity_deletion') and processing_started_at is not null and completed_at is null)
    or (status = 'completed' and completed_at is not null)
    or (status = 'failed' and failure_code is not null)
  )
);

create unique index account_deletion_one_active_request_idx
  on public.account_deletion_requests (user_id)
  where user_id is not null
    and status in ('requested', 'processing', 'awaiting_identity_deletion');
create index account_deletion_due_idx
  on public.account_deletion_requests (scheduled_for)
  where status = 'requested';
create index account_deletion_processing_lease_idx
  on public.account_deletion_requests (processing_claimed_at)
  where status = 'processing';
create index account_deletion_identity_lease_idx
  on public.account_deletion_requests (identity_claimed_at)
  where status = 'awaiting_identity_deletion';

create table private.account_deletion_cleanup_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.account_deletion_requests(id) on delete cascade,
  bucket_id text not null check (char_length(bucket_id) between 1 and 100),
  storage_path text not null check (char_length(storage_path) between 1 and 1000),
  status text not null default 'pending' check (
    status in ('pending', 'deleted', 'not_found', 'failed', 'dead')
  ),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  last_error_code text check (last_error_code is null or char_length(last_error_code) <= 120),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint account_cleanup_item_path_unique
    unique (request_id, bucket_id, storage_path)
);

comment on table private.account_deletion_cleanup_items is
  'Edge Function work queue. Storage bytes must be removed before Auth Admin deletes the identity.';

revoke all on table private.account_deletion_cleanup_items from public, anon, authenticated;

-- Media is uploaded into a non-readable quarantine bucket. A service-side scanner
-- validates magic bytes, decodes dimensions/duration, strips metadata/transcodes,
-- copies the safe derivative to approved_path, then records its decision.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'community-media-quarantine',
  'community-media-quarantine',
  false,
  524288000,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/avif',
    'image/heic',
    'image/heif',
    'video/mp4',
    'video/quicktime',
    'video/webm'
  ]::text[]
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table public.media_upload_intents (
  id uuid primary key default gen_random_uuid(),
  uploader_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid references public.organizations(id) on delete cascade,
  purpose text not null check (
    purpose in ('post', 'message', 'organization_hero', 'application_evidence', 'avatar')
  ),
  target_id uuid not null,
  kind public.media_kind not null,
  expected_mime_type text not null check (char_length(expected_mime_type) between 3 and 120),
  expected_byte_size bigint not null check (expected_byte_size > 0),
  quarantine_path text not null unique,
  approved_bucket_id text not null default 'community-media' check (
    approved_bucket_id in ('community-media', 'avatars')
  ),
  approved_path text not null unique,
  status text not null default 'quarantine' check (
    status in ('quarantine', 'scanning', 'approved', 'attached', 'rejected', 'expired')
  ),
  rejection_code text check (rejection_code is null or char_length(rejection_code) <= 120),
  approved_mime_type text check (
    approved_mime_type is null or char_length(approved_mime_type) between 3 and 120
  ),
  approved_byte_size bigint check (approved_byte_size is null or approved_byte_size > 0),
  approved_width integer check (approved_width is null or approved_width > 0),
  approved_height integer check (approved_height is null or approved_height > 0),
  approved_duration_seconds numeric(10, 3) check (
    approved_duration_seconds is null or approved_duration_seconds >= 0
  ),
  scan_attempts integer not null default 0 check (scan_attempts >= 0),
  scan_next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
  scan_claimed_at timestamptz,
  scan_lease_token uuid,
  expires_at timestamptz not null,
  approved_at timestamptz,
  attached_at timestamptz,
  attached_entity_id uuid,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint media_upload_intents_expiry_check check (expires_at > created_at),
  constraint media_upload_intents_scope_check check (
    (purpose = 'avatar' and organization_id is null and approved_bucket_id = 'avatars' and target_id = uploader_id)
    or (purpose <> 'avatar' and organization_id is not null and approved_bucket_id = 'community-media')
  ),
  constraint media_upload_intents_kind_size_check check (
    (kind = 'image'::public.media_kind and expected_byte_size <= 15728640)
    or (kind = 'video'::public.media_kind and expected_byte_size <= 524288000)
  ),
  constraint media_upload_intents_scan_lease_check check (
    status <> 'scanning'
    or (scan_claimed_at is not null and scan_lease_token is not null)
  ),
  constraint media_upload_intents_state_check check (
    (status in ('quarantine', 'scanning') and approved_at is null and attached_at is null)
    or (
      status = 'approved'
      and approved_at is not null
      and attached_at is null
      and approved_mime_type is not null
      and approved_byte_size is not null
    )
    or (
      status = 'attached'
      and approved_at is not null
      and attached_at is not null
      and attached_entity_id is not null
      and approved_mime_type is not null
      and approved_byte_size is not null
    )
    or (status in ('rejected', 'expired') and attached_at is null)
  )
);

create index media_upload_intents_user_quota_idx
  on public.media_upload_intents (uploader_id, created_at desc, status);
create index media_upload_intents_org_quota_idx
  on public.media_upload_intents (organization_id, status);
create index media_upload_intents_expiry_idx
  on public.media_upload_intents (expires_at)
  where status in ('quarantine', 'scanning');
create index media_upload_intents_scan_claim_idx
  on public.media_upload_intents (scan_next_attempt_at, created_at, id)
  where status = 'quarantine';
create index media_upload_intents_scan_lease_idx
  on public.media_upload_intents (scan_claimed_at)
  where status = 'scanning';

create table public.media_scan_records (
  id uuid primary key default gen_random_uuid(),
  intent_id uuid not null references public.media_upload_intents(id) on delete cascade,
  scanner_version text not null check (char_length(scanner_version) between 1 and 80),
  decision text not null check (decision in ('approved', 'rejected')),
  observed_mime_type text not null check (char_length(observed_mime_type) between 3 and 120),
  observed_byte_size bigint not null check (observed_byte_size > 0),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  duration_seconds numeric(10, 3) check (duration_seconds is null or duration_seconds >= 0),
  codec text check (codec is null or char_length(codec) <= 80),
  metadata_stripped boolean not null default false,
  malware_scan_clean boolean not null,
  rejection_code text check (rejection_code is null or char_length(rejection_code) <= 120),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint media_scan_records_decision_state_check check (
    (decision = 'approved' and malware_scan_clean and rejection_code is null)
    or (decision = 'rejected' and rejection_code is not null)
  )
);

comment on table public.media_scan_records is
  'Append-only scanner evidence. Only service_record_media_scan may write it.';

-- Approved bucket writes are service-only, so abandoned/expired objects must
-- also be removed by a service worker instead of a browser Storage DELETE.
create table private.media_cleanup_items (
  id uuid primary key default gen_random_uuid(),
  intent_id uuid references public.media_upload_intents(id) on delete set null,
  uploader_id uuid not null,
  bucket_id text not null check (
    bucket_id in ('community-media-quarantine', 'community-media', 'avatars')
  ),
  storage_path text not null check (char_length(storage_path) between 1 and 1000),
  reason text not null check (
    reason in ('user_abandoned', 'intent_expired', 'scan_rejected')
  ),
  status text not null default 'pending' check (
    status in ('pending', 'processing', 'deleted', 'not_found', 'failed', 'dead')
  ),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
  claimed_at timestamptz,
  completed_at timestamptz,
  last_error_code text check (last_error_code is null or char_length(last_error_code) <= 120),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (bucket_id, storage_path)
);

create index media_cleanup_items_claim_idx
  on private.media_cleanup_items (next_attempt_at, created_at)
  where status in ('pending', 'failed');
create index media_cleanup_items_lease_idx
  on private.media_cleanup_items (claimed_at)
  where status = 'processing';

revoke all on table private.media_cleanup_items from public, anon, authenticated;

comment on table private.media_cleanup_items is
  'Service-only Storage cleanup queue for abandoned, expired, or rejected upload intents.';

create table public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete set null,
  target_type text not null check (target_type in ('post', 'comment', 'message', 'profile')),
  target_id uuid not null,
  reported_user_id uuid references public.profiles(id) on delete set null,
  reason_code text not null check (
    reason_code in (
      'harassment',
      'spam',
      'hate',
      'sexual_content',
      'violence',
      'privacy',
      'impersonation',
      'self_harm',
      'other'
    )
  ),
  details text check (details is null or char_length(details) <= 2000),
  evidence_snapshot jsonb not null,
  status text not null default 'open' check (
    status in ('open', 'reviewing', 'resolved', 'dismissed', 'escalated')
  ),
  assigned_to uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  resolved_at timestamptz,
  resolution_code text check (resolution_code is null or char_length(resolution_code) <= 80),
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 2000),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint content_reports_resolution_check check (
    (status in ('open', 'reviewing') and resolved_at is null)
    or (status in ('resolved', 'dismissed', 'escalated') and resolved_at is not null)
  )
);

create index content_reports_moderation_queue_idx
  on public.content_reports (organization_id, status, created_at);
create index content_reports_reporter_idx
  on public.content_reports (reporter_id, created_at desc);
create unique index content_reports_one_active_target_idx
  on public.content_reports (reporter_id, target_type, target_id)
  where reporter_id is not null
    and status in ('open', 'reviewing', 'escalated');

create table public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.content_reports(id) on delete restrict,
  actor_id uuid references public.profiles(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete set null,
  target_type text not null check (target_type in ('post', 'comment', 'message', 'profile')),
  target_id uuid not null,
  target_user_id uuid references public.profiles(id) on delete set null,
  action_code text not null check (
    action_code in (
      'no_action',
      'warning_recorded',
      'content_hidden',
      'member_suspended',
      'escalated_to_platform'
    )
  ),
  note text not null check (char_length(note) between 1 and 2000),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp()
);

create index moderation_actions_report_timeline_idx
  on public.moderation_actions (report_id, created_at);
create index moderation_actions_org_timeline_idx
  on public.moderation_actions (organization_id, created_at desc);

comment on table public.content_reports is
  'Server-snapshotted UGC/user reports. Reporters see their own cases; moderators see only their exact church scope.';
comment on table public.moderation_actions is
  'Immutable moderation decision ledger. Every mutation is also written to public.audit_logs.';

-- Timestamp triggers reuse the existing non-client-callable helper.
create trigger privacy_preferences_set_updated_at
before update on public.privacy_preferences
for each row execute function private.set_updated_at();

create trigger notification_preferences_set_updated_at
before update on public.notification_preferences
for each row execute function private.set_updated_at();

create trigger conversation_preferences_set_updated_at
before update on public.conversation_preferences
for each row execute function private.set_updated_at();

create trigger push_devices_set_updated_at
before update on public.push_devices
for each row execute function private.set_updated_at();

create trigger account_deletion_requests_set_updated_at
before update on public.account_deletion_requests
for each row execute function private.set_updated_at();

create trigger media_upload_intents_set_updated_at
before update on public.media_upload_intents
for each row execute function private.set_updated_at();

create trigger content_reports_set_updated_at
before update on public.content_reports
for each row execute function private.set_updated_at();

create or replace function private.require_aal2(p_operation text)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_claims_text text := pg_catalog.current_setting('request.jwt.claims', true);
  v_claims jsonb;
  v_role_setting text := pg_catalog.current_setting('role', true);
begin
  -- Browser/PostgREST roles fail closed without the signed JWT envelope. Direct
  -- owner migrations have role=none. The named pgTAP setting is available only
  -- to trusted SQL and preserves the pre-existing governance regression suite.
  if v_claims_text is null or v_claims_text = '' then
    if v_role_setting in ('authenticated', 'anon', 'service_role') then
      if session_user in ('postgres', 'supabase_admin')
        and pg_catalog.current_setting('test.governance_service_year', true) is not null then
        return;
      end if;
      raise exception 'signed_authentication_context_required:%', p_operation
        using errcode = '42501';
    end if;
    if session_user not in ('postgres', 'supabase_admin') then
      raise exception 'signed_authentication_context_required:%', p_operation
        using errcode = '42501';
    end if;
    return;
  end if;

  begin
    v_claims := v_claims_text::jsonb;
  exception
    when invalid_text_representation then
      raise exception 'invalid_authentication_context' using errcode = '42501';
  end;

  if coalesce(v_claims ->> 'role', '') = 'service_role' then
    return;
  end if;
  if coalesce(v_claims ->> 'aal', '') <> 'aal2' then
    raise exception 'aal2_required:%', p_operation using errcode = '42501';
  end if;
end;
$$;

create or replace function private.users_are_blocked(
  p_left_user_id uuid,
  p_right_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_left_user_id is not null
    and p_right_user_id is not null
    and exists (
      select 1
      from public.user_blocks as block
      where (block.blocker_id = p_left_user_id and block.blocked_user_id = p_right_user_id)
         or (block.blocker_id = p_right_user_id and block.blocked_user_id = p_left_user_id)
    );
$$;

create or replace function private.require_service_role(p_operation text)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service_role_required:%', p_operation using errcode = '42501';
  end if;
end;
$$;

create or replace function private.user_has_blocked(
  p_actor_id uuid,
  p_target_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and p_target_user_id is not null
    and exists (
      select 1
      from public.user_blocks as block
      where block.blocker_id = p_actor_id
        and block.blocked_user_id = p_target_user_id
    );
$$;

create or replace function private.can_moderate_organization(
  p_organization_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and (
      private.is_platform_admin(p_actor_id)
      or (
        p_organization_id is not null
        and exists (
          select 1
          from public.organization_memberships as membership
          join public.organizations as organization
            on organization.id = membership.organization_id
          join public.profiles as profile
            on profile.id = membership.user_id
          where membership.organization_id = p_organization_id
            and membership.user_id = p_actor_id
            and membership.status = 'active'::public.membership_status
            and membership.role in (
              'minister'::public.app_role,
              'executive'::public.app_role
            )
            and organization.status = 'active'::public.organization_status
            and profile.deactivated_at is null
        )
      )
    );
$$;

create or replace function private.consume_rate_limit(
  p_actor_id uuid,
  p_action_key text,
  p_max_events integer,
  p_window_seconds integer,
  p_cost integer default 1
)
returns void
language plpgsql
volatile
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_counter private.rate_limit_counters%rowtype;
  v_retry_after integer;
begin
  if p_actor_id is null
    or nullif(pg_catalog.btrim(p_action_key), '') is null
    or p_max_events < 1
    or p_window_seconds < 1
    or p_cost < 1 then
    raise exception 'invalid_rate_limit_configuration' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_actor_id::text || ':' || p_action_key, 0)
  );

  select * into v_counter
  from private.rate_limit_counters
  where actor_id = p_actor_id
    and action_key = p_action_key
  for update;

  if not found
    or v_counter.window_started_at + pg_catalog.make_interval(secs => p_window_seconds) <= v_now then
    insert into private.rate_limit_counters (
      actor_id,
      action_key,
      window_started_at,
      event_count,
      updated_at
    )
    values (p_actor_id, p_action_key, v_now, p_cost, v_now)
    on conflict (actor_id, action_key)
    do update set
      window_started_at = excluded.window_started_at,
      event_count = excluded.event_count,
      updated_at = excluded.updated_at;
    return;
  end if;

  if v_counter.event_count + p_cost > p_max_events then
    v_retry_after := greatest(
      1,
      pg_catalog.ceil(
        extract(epoch from (
          v_counter.window_started_at
          + pg_catalog.make_interval(secs => p_window_seconds)
          - v_now
        ))
      )::integer
    );
    raise exception 'rate_limit_exceeded:%', p_action_key
      using errcode = 'P0001', detail = 'retry_after_seconds=' || v_retry_after::text;
  end if;

  update private.rate_limit_counters
  set event_count = event_count + p_cost,
      updated_at = v_now
  where actor_id = p_actor_id
    and action_key = p_action_key;
end;
$$;

create or replace function private.can_write_quarantine_media(
  p_name text,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and private.try_uuid(pg_catalog.split_part(p_name, '/', 1)) = p_actor_id
    and exists (
      select 1
      from public.media_upload_intents as intent
      where intent.id = private.try_uuid(pg_catalog.split_part(p_name, '/', 2))
        and intent.uploader_id = p_actor_id
        and intent.quarantine_path = p_name
        -- Once a worker claims an intent, the browser can no longer mutate or
        -- delete the bytes being inspected (TOCTOU boundary).
        and intent.status = 'quarantine'
        and intent.expires_at > pg_catalog.clock_timestamp()
    );
$$;

create or replace function private.claim_approved_media(
  p_purpose text,
  p_target_id uuid,
  p_storage_path text,
  p_uploader_id uuid,
  p_attached_entity_id uuid
)
returns public.media_upload_intents
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_intent public.media_upload_intents%rowtype;
begin
  select * into v_intent
  from public.media_upload_intents as intent
  where intent.approved_path = p_storage_path
  for update;

  if not found
    or v_intent.uploader_id is distinct from p_uploader_id
    or v_intent.purpose is distinct from p_purpose
    or v_intent.target_id is distinct from p_target_id
    or v_intent.status <> 'approved' then
    raise exception 'approved_media_required' using errcode = '42501';
  end if;

  update public.media_upload_intents
  set status = 'attached',
      attached_at = pg_catalog.clock_timestamp(),
      attached_entity_id = p_attached_entity_id
  where id = v_intent.id
  returning * into v_intent;

  return v_intent;
end;
$$;

-- Signup metadata is only evidence when both explicit booleans are true and the
-- submitted versions exactly match the currently published rows. Client-supplied
-- timestamps are deliberately ignored in favor of the database clock.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_name text;
  v_privacy_version text := new.raw_user_meta_data ->> 'accepted_privacy_version';
  v_community_version text := new.raw_user_meta_data ->> 'accepted_community_version';
begin
  v_name := nullif(pg_catalog.btrim(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    pg_catalog.split_part(coalesce(new.email, ''), '@', 1)
  )), '');

  insert into public.profiles (id, display_name)
  values (new.id, pg_catalog.left(coalesce(v_name, '사용자'), 80))
  on conflict (id) do nothing;

  if coalesce(pg_catalog.lower(new.raw_user_meta_data ->> 'accepted_privacy'), 'false') = 'true'
    and exists (
      select 1
      from public.consent_documents as document
      where document.document_key = 'privacy_policy'
        and document.version = v_privacy_version
        and document.retired_at is null
        and document.effective_at <= pg_catalog.clock_timestamp()
    ) then
    insert into public.user_consents (
      user_id, document_key, document_version, accepted, source
    )
    values (new.id, 'privacy_policy', v_privacy_version, true, 'signup_metadata');
  end if;

  if coalesce(pg_catalog.lower(new.raw_user_meta_data ->> 'accepted_community'), 'false') = 'true'
    and exists (
      select 1
      from public.consent_documents as document
      where document.document_key = 'community_guidelines'
        and document.version = v_community_version
        and document.retired_at is null
        and document.effective_at <= pg_catalog.clock_timestamp()
    ) then
    insert into public.user_consents (
      user_id, document_key, document_version, accepted, source
    )
    values (new.id, 'community_guidelines', v_community_version, true, 'signup_metadata');
  end if;

  return new;
end;
$$;

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

create or replace function private.enforce_high_risk_aal2()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is not null then
    perform private.require_aal2(tg_table_name || '.' || lower(tg_op));
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger governance_offices_require_aal2
before insert or update or delete on public.governance_office_assignments
for each row execute function private.enforce_high_risk_aal2();

create trigger governance_delegations_require_aal2
before insert or update or delete on public.governance_authority_delegations
for each row execute function private.enforce_high_risk_aal2();

create or replace function private.enforce_leadership_review_aal2()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is not null
    and old.status = 'pending'::public.application_status
    and new.status in ('approved'::public.application_status, 'rejected'::public.application_status)
    and new.requested_role in ('minister'::public.app_role, 'executive'::public.app_role) then
    perform private.require_aal2('leadership_membership_review');
  end if;
  return new;
end;
$$;

create trigger membership_leadership_review_require_aal2
before update of status on public.membership_applications
for each row execute function private.enforce_leadership_review_aal2();

-- RLS and table privileges ---------------------------------------------------
alter table public.user_blocks enable row level security;
alter table public.consent_documents enable row level security;
alter table public.user_consents enable row level security;
alter table public.privacy_preferences enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.conversation_preferences enable row level security;
alter table public.push_devices enable row level security;
alter table public.account_deletion_requests enable row level security;
alter table public.media_upload_intents enable row level security;
alter table public.media_scan_records enable row level security;
alter table public.content_reports enable row level security;
alter table public.moderation_actions enable row level security;

create policy user_blocks_select_self
on public.user_blocks for select to authenticated
using (blocker_id = auth.uid());

create policy user_blocks_insert_self
on public.user_blocks for insert to authenticated
with check (blocker_id = auth.uid());

create policy user_blocks_delete_self
on public.user_blocks for delete to authenticated
using (blocker_id = auth.uid());

create policy consent_documents_select_published
on public.consent_documents for select to anon, authenticated
using (
  published_at <= pg_catalog.clock_timestamp()
  and effective_at <= pg_catalog.clock_timestamp()
);

create policy user_consents_select_self
on public.user_consents for select to authenticated
using (user_id = auth.uid());

create policy privacy_preferences_select_self
on public.privacy_preferences for select to authenticated
using (user_id = auth.uid());

create policy notification_preferences_select_self
on public.notification_preferences for select to authenticated
using (user_id = auth.uid());

create policy conversation_preferences_select_self
on public.conversation_preferences for select to authenticated
using (
  user_id = auth.uid()
  and private.can_access_conversation(conversation_id, auth.uid())
);

create policy push_devices_select_self
on public.push_devices for select to authenticated
using (user_id = auth.uid());

create policy account_deletion_requests_select_self
on public.account_deletion_requests for select to authenticated
using (user_id = auth.uid());

create policy media_upload_intents_select_self
on public.media_upload_intents for select to authenticated
using (uploader_id = auth.uid());

create policy media_scan_records_select_owner
on public.media_scan_records for select to authenticated
using (
  exists (
    select 1
    from public.media_upload_intents as intent
    where intent.id = media_scan_records.intent_id
      and intent.uploader_id = auth.uid()
  )
);

create policy content_reports_select_authorized
on public.content_reports for select to authenticated
using (
  reporter_id = auth.uid()
  or private.can_moderate_organization(organization_id, auth.uid())
);

create policy moderation_actions_select_authorized
on public.moderation_actions for select to authenticated
using (
  private.can_moderate_organization(organization_id, auth.uid())
  or exists (
    select 1
    from public.content_reports as report
    where report.id = moderation_actions.report_id
      and report.reporter_id = auth.uid()
  )
);

-- One-way block visibility: the blocker no longer receives ordinary content,
-- profile suggestions, or notifications from the blocked user. The blocked
-- person's view is unchanged; exact-scope moderators/platform admins retain
-- evidence access.
drop policy if exists profiles_select_authorized on public.profiles;
create policy profiles_select_authorized
on public.profiles for select to authenticated
using (
  private.can_view_profile(id, auth.uid())
  and (
    id = auth.uid()
    or not private.user_has_blocked(auth.uid(), id)
    or private.is_platform_admin(auth.uid())
    or exists (
      select 1
      from public.organization_memberships as target_membership
      where target_membership.user_id = profiles.id
        and private.can_moderate_organization(target_membership.organization_id, auth.uid())
    )
  )
);

drop policy if exists posts_select_authorized on public.posts;
create policy posts_select_authorized
on public.posts for select to authenticated
using (
  auth.uid() is not null
  and (
    (
      status = 'published'::public.post_status
      and (organization_id is null or private.is_active_member(organization_id, auth.uid()))
    )
    or (
      organization_id is not null
      and (author_id = auth.uid() or private.can_manage_members(organization_id, auth.uid()))
    )
    or private.is_platform_admin(auth.uid())
  )
  and (
    author_id is null
    or author_id = auth.uid()
    or not private.user_has_blocked(auth.uid(), author_id)
    or private.can_moderate_organization(organization_id, auth.uid())
  )
);

drop policy if exists comments_select_authorized on public.comments;
create policy comments_select_authorized
on public.comments for select to authenticated
using (
  private.can_read_post(post_id, auth.uid())
  and (
    status = 'active'::public.comment_status
    or author_id = auth.uid()
    or private.can_manage_post(post_id, auth.uid())
  )
  and (
    author_id is null
    or author_id = auth.uid()
    or not private.user_has_blocked(auth.uid(), author_id)
    or private.can_manage_post(post_id, auth.uid())
  )
);

revoke all on table public.user_blocks from public, anon, authenticated;
revoke all on table public.consent_documents from public, anon, authenticated;
revoke all on table public.user_consents from public, anon, authenticated;
revoke all on table public.privacy_preferences from public, anon, authenticated;
revoke all on table public.notification_preferences from public, anon, authenticated;
revoke all on table public.conversation_preferences from public, anon, authenticated;
revoke all on table public.push_devices from public, anon, authenticated;
revoke all on table public.account_deletion_requests from public, anon, authenticated;
revoke all on table public.media_upload_intents from public, anon, authenticated;
revoke all on table public.media_scan_records from public, anon, authenticated;
revoke all on table public.content_reports from public, anon, authenticated;
revoke all on table public.moderation_actions from public, anon, authenticated;

grant select on table public.user_blocks to authenticated;
grant select on table public.consent_documents to anon, authenticated;
grant select on table public.user_consents to authenticated;
grant select on table public.privacy_preferences to authenticated;
grant select on table public.notification_preferences to authenticated;
grant select on table public.conversation_preferences to authenticated;
grant select on table public.push_devices to authenticated;
grant select on table public.account_deletion_requests to authenticated;
grant select on table public.media_upload_intents to authenticated;
grant select on table public.media_scan_records to authenticated;
grant select on table public.content_reports to authenticated;
grant select on table public.moderation_actions to authenticated;

-- Anonymous organization discovery is column-minimized through the RPC below.
-- Signed-in users retain the existing full church-profile read contract.
drop policy if exists organizations_select_directory on public.organizations;
create policy organizations_select_directory_authenticated
on public.organizations for select to authenticated
using (
  status in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  )
);
revoke select on table public.organizations from anon;

drop policy if exists jaegun_quarantine_media_insert on storage.objects;
create policy jaegun_quarantine_media_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'community-media-quarantine'
  and private.can_write_quarantine_media(name, auth.uid())
  and private.community_object_size_allowed(metadata)
);

drop policy if exists jaegun_quarantine_media_update on storage.objects;
create policy jaegun_quarantine_media_update
on storage.objects for update to authenticated
using (
  bucket_id = 'community-media-quarantine'
  and owner_id = auth.uid()::text
  and private.can_write_quarantine_media(name, auth.uid())
)
with check (
  bucket_id = 'community-media-quarantine'
  and owner_id = auth.uid()::text
  and private.can_write_quarantine_media(name, auth.uid())
  and private.community_object_size_allowed(metadata)
);

drop policy if exists jaegun_quarantine_media_delete on storage.objects;
create policy jaegun_quarantine_media_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'community-media-quarantine'
  and owner_id = auth.uid()::text
  and private.can_write_quarantine_media(name, auth.uid())
);

-- There is intentionally no authenticated SELECT policy on the quarantine
-- bucket. Scanner/copy workers use service_role; approved derivatives live in
-- the existing private community-media bucket.

-- Clients cannot write/delete approved bytes. All post/message/evidence/hero/
-- avatar objects enter quarantine and only the scanner worker copies a safe
-- derivative into these buckets. This also prevents orphan-storage abuse.
drop policy if exists jaegun_community_media_insert on storage.objects;
drop policy if exists jaegun_community_media_update on storage.objects;
drop policy if exists jaegun_community_media_delete on storage.objects;
drop policy if exists jaegun_avatars_insert on storage.objects;
drop policy if exists jaegun_avatars_update on storage.objects;
drop policy if exists jaegun_avatars_delete on storage.objects;

create or replace function private.enforce_conversation_block_boundary()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.participant_low is not null
    and new.participant_high is not null
    and private.users_are_blocked(new.participant_low, new.participant_high) then
    raise exception 'user_block_boundary' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger conversations_enforce_block_boundary
before insert or update of participant_low, participant_high on public.conversations
for each row execute function private.enforce_conversation_block_boundary();

create or replace function private.enforce_message_block_boundary()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_conversation public.conversations%rowtype;
begin
  if new.sender_id is null then
    return new;
  end if;

  select * into v_conversation
  from public.conversations
  where id = new.conversation_id;

  if not found
    or new.sender_id not in (v_conversation.participant_low, v_conversation.participant_high) then
    raise exception 'message_sender_not_conversation_participant' using errcode = '42501';
  end if;
  if private.users_are_blocked(
    v_conversation.participant_low,
    v_conversation.participant_high
  ) then
    raise exception 'user_block_boundary' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger messages_enforce_block_boundary
before insert on public.messages
for each row execute function private.enforce_message_block_boundary();

create or replace function private.enforce_content_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if tg_table_name = 'posts' and new.author_id = auth.uid() then
    perform private.consume_rate_limit(auth.uid(), 'posts', 20, 300, 1);
  elsif tg_table_name = 'comments' and new.author_id = auth.uid() then
    perform private.consume_rate_limit(auth.uid(), 'comments', 30, 60, 1);
  end if;
  return new;
end;
$$;

create trigger posts_enforce_rate_limit
before insert on public.posts
for each row execute function private.enforce_content_rate_limit();

create trigger comments_enforce_rate_limit
before insert on public.comments
for each row execute function private.enforce_content_rate_limit();

create or replace function private.enforce_approved_post_media()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_intent public.media_upload_intents%rowtype;
begin
  if tg_op = 'UPDATE' and new.storage_path is not distinct from old.storage_path then
    return new;
  end if;

  v_intent := private.claim_approved_media(
    'post',
    new.post_id,
    new.storage_path,
    new.uploader_id,
    new.post_id
  );
  if v_intent.kind is distinct from new.kind
    or v_intent.approved_mime_type is distinct from new.mime_type
    or v_intent.approved_byte_size is distinct from new.byte_size then
    raise exception 'post_media_metadata_mismatch' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger post_media_require_approved_upload
before insert or update of storage_path on public.post_media
for each row execute function private.enforce_approved_post_media();

create or replace function private.enforce_approved_profile_avatar()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.avatar_path is not distinct from old.avatar_path or new.avatar_path is null then
    return new;
  end if;
  if auth.uid() is null or auth.uid() <> new.id then
    raise exception 'approved_avatar_update_required' using errcode = '42501';
  end if;
  perform private.claim_approved_media('avatar', new.id, new.avatar_path, auth.uid(), new.id);
  return new;
end;
$$;

create trigger profiles_require_approved_avatar
before update of avatar_path on public.profiles
for each row execute function private.enforce_approved_profile_avatar();

create or replace function private.enforce_approved_organization_hero()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.hero_path is not distinct from old.hero_path or new.hero_path is null then
    return new;
  end if;
  if auth.uid() is null or not private.can_manage_members(new.id, auth.uid()) then
    raise exception 'approved_organization_hero_required' using errcode = '42501';
  end if;
  perform private.claim_approved_media(
    'organization_hero', new.id, new.hero_path, auth.uid(), new.id
  );
  return new;
end;
$$;

create trigger organizations_require_approved_hero
before update of hero_path on public.organizations
for each row execute function private.enforce_approved_organization_hero();

create or replace function private.enforce_approved_application_evidence()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.evidence_path is not distinct from old.evidence_path or new.evidence_path is null then
    return new;
  end if;
  if auth.uid() is null or auth.uid() <> new.user_id
    or new.status <> 'pending'::public.application_status then
    raise exception 'approved_application_evidence_required' using errcode = '42501';
  end if;
  perform private.claim_approved_media(
    'application_evidence', new.id, new.evidence_path, auth.uid(), new.id
  );
  return new;
end;
$$;

create trigger membership_applications_require_approved_evidence
before update of evidence_path on public.membership_applications
for each row execute function private.enforce_approved_application_evidence();

-- User-facing safety/privacy RPCs -------------------------------------------
create or replace view public.public_organization_directory
with (security_barrier = true)
as
select
  organization.id,
  organization.slug,
  organization.display_name,
  organization.presbytery,
  organization.status
from public.organizations as organization
where organization.status in (
  'seeded_unclaimed'::public.organization_status,
  'active'::public.organization_status
);

revoke all on table public.public_organization_directory from public, anon, authenticated;
grant select on table public.public_organization_directory to anon, authenticated;

comment on view public.public_organization_directory is
  'Anonymous-safe signup directory exposing only id, slug, display_name, presbytery, and status.';

create or replace function public.list_public_organization_directory(
  p_presbytery text default null
)
returns table (
  id uuid,
  slug text,
  display_name text,
  presbytery text,
  status public.organization_status
)
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select
    organization.id,
    organization.slug,
    organization.display_name,
    organization.presbytery,
    organization.status
  from public.organizations as organization
  where organization.status in (
      'seeded_unclaimed'::public.organization_status,
      'active'::public.organization_status
    )
    and (
      nullif(pg_catalog.btrim(p_presbytery), '') is null
      or organization.presbytery = pg_catalog.btrim(p_presbytery)
    )
  order by organization.presbytery, organization.display_name, organization.id;
$$;

comment on function public.list_public_organization_directory(text) is
  'Authenticated filtered directory. Anonymous signup reads public.public_organization_directory, which exposes the same five safe fields.';

create or replace function public.block_user(
  p_user_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_created_at timestamptz;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_user_id is null or p_user_id = v_actor_id then
    raise exception 'invalid_block_target' using errcode = '23514';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'block_target_not_found' using errcode = 'P0002';
  end if;
  if p_reason is not null and char_length(p_reason) > 500 then
    raise exception 'block_reason_too_long' using errcode = '22001';
  end if;

  insert into public.user_blocks (blocker_id, blocked_user_id, reason)
  values (v_actor_id, p_user_id, nullif(pg_catalog.btrim(p_reason), ''))
  on conflict (blocker_id, blocked_user_id)
  do update set reason = coalesce(excluded.reason, public.user_blocks.reason)
  returning created_at into v_created_at;

  perform private.write_audit(
    v_actor_id,
    'safety.user_blocked',
    'profile',
    p_user_id,
    null,
    p_user_id,
    '{}'::jsonb
  );

  return pg_catalog.jsonb_build_object(
    'blocked_user_id', p_user_id,
    'created_at', v_created_at
  );
end;
$$;

create or replace function public.unblock_user(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_deleted boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  delete from public.user_blocks
  where blocker_id = v_actor_id
    and blocked_user_id = p_user_id;
  v_deleted := found;

  if v_deleted then
    perform private.write_audit(
      v_actor_id,
      'safety.user_unblocked',
      'profile',
      p_user_id,
      null,
      p_user_id,
      '{}'::jsonb
    );
  end if;
  return v_deleted;
end;
$$;

create or replace function public.upsert_my_privacy_preferences(
  p_directory_visibility text,
  p_analytics_opt_in boolean,
  p_push_enabled boolean,
  p_privacy_document_version text,
  p_community_document_version text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_privacy public.privacy_preferences%rowtype;
  v_notifications public.notification_preferences%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_directory_visibility not in ('private', 'name_only', 'church_profile') then
    raise exception 'invalid_directory_visibility' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.consent_documents as document
    where document.document_key = 'privacy_policy'
      and document.version = p_privacy_document_version
      and document.retired_at is null
      and document.effective_at <= pg_catalog.clock_timestamp()
  ) then
    raise exception 'current_privacy_consent_required' using errcode = '23514';
  end if;
  if not exists (
    select 1
    from public.consent_documents as document
    where document.document_key = 'community_guidelines'
      and document.version = p_community_document_version
      and document.retired_at is null
      and document.effective_at <= pg_catalog.clock_timestamp()
  ) then
    raise exception 'current_community_consent_required' using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.user_consents as consent
    where consent.user_id = v_actor_id
      and consent.document_key = 'privacy_policy'
      and consent.document_version = p_privacy_document_version
      and consent.accepted
  ) then
    insert into public.user_consents (
      user_id, document_key, document_version, accepted, source
    )
    values (
      v_actor_id, 'privacy_policy', p_privacy_document_version, true, 'app'
    );
  end if;

  if not exists (
    select 1
    from public.user_consents as consent
    where consent.user_id = v_actor_id
      and consent.document_key = 'community_guidelines'
      and consent.document_version = p_community_document_version
      and consent.accepted
  ) then
    insert into public.user_consents (
      user_id, document_key, document_version, accepted, source
    )
    values (
      v_actor_id, 'community_guidelines', p_community_document_version, true, 'app'
    );
  end if;

  insert into public.privacy_preferences (
    user_id, directory_visibility, analytics_opt_in
  )
  values (v_actor_id, p_directory_visibility, coalesce(p_analytics_opt_in, false))
  on conflict (user_id)
  do update set
    directory_visibility = excluded.directory_visibility,
    analytics_opt_in = excluded.analytics_opt_in
  returning * into v_privacy;

  insert into public.notification_preferences (user_id, push_enabled)
  values (v_actor_id, coalesce(p_push_enabled, false))
  on conflict (user_id)
  do update set push_enabled = excluded.push_enabled
  returning * into v_notifications;

  perform private.write_audit(
    v_actor_id,
    'privacy.preferences_updated',
    'profile',
    v_actor_id,
    null,
    v_actor_id,
    pg_catalog.jsonb_build_object(
      'directory_visibility', p_directory_visibility,
      'analytics_opt_in', coalesce(p_analytics_opt_in, false),
      'push_enabled', coalesce(p_push_enabled, false),
      'privacy_version', p_privacy_document_version,
      'community_version', p_community_document_version
    )
  );

  return pg_catalog.jsonb_build_object(
    'privacy_preferences', pg_catalog.to_jsonb(v_privacy),
    'notification_preferences', pg_catalog.to_jsonb(v_notifications),
    'consent_gate_open', true
  );
end;
$$;

create or replace function public.upsert_conversation_preference(
  p_conversation_id uuid,
  p_notifications_enabled boolean default true,
  p_muted_until timestamptz default null,
  p_archived boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_result public.conversation_preferences%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.can_access_conversation(p_conversation_id, v_actor_id) then
    raise exception 'conversation_access_denied' using errcode = '42501';
  end if;
  if p_muted_until is not null
    and p_muted_until > pg_catalog.clock_timestamp() + interval '1 year' then
    raise exception 'mute_period_too_long' using errcode = '23514';
  end if;

  insert into public.conversation_preferences (
    user_id,
    conversation_id,
    notifications_enabled,
    muted_until,
    archived_at
  )
  values (
    v_actor_id,
    p_conversation_id,
    coalesce(p_notifications_enabled, true),
    p_muted_until,
    case when coalesce(p_archived, false) then pg_catalog.clock_timestamp() else null end
  )
  on conflict (user_id, conversation_id)
  do update set
    notifications_enabled = excluded.notifications_enabled,
    muted_until = excluded.muted_until,
    archived_at = excluded.archived_at
  returning * into v_result;

  return pg_catalog.to_jsonb(v_result);
end;
$$;

create or replace function public.remove_my_push_device(p_device_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  delete from public.push_devices
  where id = p_device_id
    and user_id = v_actor_id;
  return found;
end;
$$;

create or replace function public.remove_my_push_device_by_installation(
  p_installation_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_installation_id is null then
    raise exception 'installation_id_required' using errcode = '22023';
  end if;

  -- Invoke this while the old Auth session is still present during logout or
  -- account switching. The user ID predicate prevents detaching another
  -- account even if its installation UUID is guessed.
  delete from public.push_devices as device
  where device.installation_id = p_installation_id
    and device.user_id = v_actor_id;
  return found;
end;
$$;

create or replace function public.get_my_safety_privacy_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_documents jsonb;
  v_consents jsonb;
  v_privacy jsonb;
  v_notifications jsonb;
  v_deletion jsonb;
  v_blocks jsonb;
  v_devices jsonb;
  v_muted_conversations jsonb;
  v_gate_open boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select coalesce(
    pg_catalog.jsonb_object_agg(
      document.document_key,
      pg_catalog.jsonb_build_object(
        'version', document.version,
        'title', document.title,
        'url', document.document_url,
        'effective_at', document.effective_at,
        'required', document.required
      )
    ),
    '{}'::jsonb
  ) into v_documents
  from public.consent_documents as document
  where document.retired_at is null
    and document.effective_at <= pg_catalog.clock_timestamp();

  select pg_catalog.jsonb_build_object(
    'sensitive_affiliation', pg_catalog.jsonb_build_object(
      'version', privacy_document.version,
      'accepted_at', (
        select max(consent.recorded_at)
        from public.user_consents as consent
        where consent.user_id = v_actor_id
          and consent.document_key = 'privacy_policy'
          and consent.document_version = privacy_document.version
          and consent.accepted
      )
    ),
    'community_policy', pg_catalog.jsonb_build_object(
      'version', community_document.version,
      'accepted_at', (
        select max(consent.recorded_at)
        from public.user_consents as consent
        where consent.user_id = v_actor_id
          and consent.document_key = 'community_guidelines'
          and consent.document_version = community_document.version
          and consent.accepted
      )
    )
  ) into v_consents
  from public.consent_documents as privacy_document
  cross join public.consent_documents as community_document
  where privacy_document.document_key = 'privacy_policy'
    and privacy_document.retired_at is null
    and community_document.document_key = 'community_guidelines'
    and community_document.retired_at is null;

  select pg_catalog.to_jsonb(preference) into v_privacy
  from public.privacy_preferences as preference
  where preference.user_id = v_actor_id;

  select pg_catalog.to_jsonb(preference) into v_notifications
  from public.notification_preferences as preference
  where preference.user_id = v_actor_id;

  select pg_catalog.to_jsonb(request) into v_deletion
  from public.account_deletion_requests as request
  where request.user_id = v_actor_id
  order by request.requested_at desc
  limit 1;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'user_id', block.blocked_user_id,
        'display_name', profile.display_name,
        'avatar_url', null,
        'blocked_at', block.created_at
      ) order by block.created_at desc
    ),
    '[]'::jsonb
  ) into v_blocks
  from public.user_blocks as block
  left join public.profiles as profile on profile.id = block.blocked_user_id
  where block.blocker_id = v_actor_id;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', device.id,
        'installation_id', device.installation_id,
        'platform', device.platform,
        'app_version', device.app_version,
        'last_seen_at', device.last_seen_at,
        'disabled_at', device.disabled_at
      ) order by device.last_seen_at desc
    ),
    '[]'::jsonb
  ) into v_devices
  from public.push_devices as device
  where device.user_id = v_actor_id;

  select coalesce(pg_catalog.jsonb_agg(preference.conversation_id), '[]'::jsonb)
  into v_muted_conversations
  from public.conversation_preferences as preference
  where preference.user_id = v_actor_id
    and (
      not preference.notifications_enabled
      or preference.muted_until > pg_catalog.clock_timestamp()
    );

  select count(*) = 2 into v_gate_open
  from public.consent_documents as document
  where document.retired_at is null
    and document.required
    and document.document_key in ('privacy_policy', 'community_guidelines')
    and exists (
      select 1
      from public.user_consents as consent
      where consent.user_id = v_actor_id
        and consent.document_key = document.document_key
        and consent.document_version = document.version
        and consent.accepted
    );

  return pg_catalog.jsonb_build_object(
    'current_documents', v_documents,
    'consents', v_consents,
    'consent_gate_open', v_gate_open,
    'directory_visibility', pg_catalog.jsonb_build_object(
      'avatar', coalesce((v_privacy ->> 'avatar_visible')::boolean, false),
      'church_title', coalesce((v_privacy ->> 'church_title_visible')::boolean, true),
      'email', coalesce((v_privacy ->> 'email_visible')::boolean, false),
      'bio', coalesce((v_privacy ->> 'bio_visible')::boolean, false)
    ),
    'notifications', pg_catalog.jsonb_build_object(
      'push_enabled', coalesce((v_notifications ->> 'push_enabled')::boolean, true),
      'categories', pg_catalog.jsonb_build_object(
        'approvals', coalesce((v_notifications ->> 'approvals_enabled')::boolean, true),
        'posts', coalesce((v_notifications ->> 'posts_enabled')::boolean, true),
        'comments', coalesce((v_notifications ->> 'comments_enabled')::boolean, true),
        'chats', coalesce((v_notifications ->> 'messages_enabled')::boolean, true),
        'governance', coalesce((v_notifications ->> 'governance_enabled')::boolean, true),
        'events', coalesce((v_notifications ->> 'events_enabled')::boolean, true)
      ),
      'quiet_hours_enabled', (v_notifications ->> 'quiet_hours_start') is not null,
      'quiet_hours_start', coalesce(pg_catalog.left(v_notifications ->> 'quiet_hours_start', 5), '21:00'),
      'quiet_hours_end', coalesce(pg_catalog.left(v_notifications ->> 'quiet_hours_end', 5), '08:00'),
      'time_zone', coalesce(v_notifications ->> 'timezone', 'Asia/Seoul'),
      'lock_screen_preview', coalesce(v_notifications ->> 'lock_screen_preview', 'generic')
    ),
    'blocked_profiles', v_blocks,
    'muted_conversation_ids', v_muted_conversations,
    'account_deletion', case
      when v_deletion ->> 'status' in ('requested', 'processing', 'awaiting_identity_deletion') then
        pg_catalog.jsonb_build_object(
          'status', 'pending',
          'requested_at', v_deletion -> 'requested_at',
          'scheduled_for', v_deletion -> 'scheduled_for'
        )
      else pg_catalog.jsonb_build_object(
        'status', 'none',
        'requested_at', null,
        'scheduled_for', null
      )
    end,
    'privacy_preferences', coalesce(v_privacy, pg_catalog.jsonb_build_object(
      'user_id', v_actor_id,
      'directory_visibility', 'private',
      'analytics_opt_in', false
    )),
    'notification_preferences', coalesce(v_notifications, pg_catalog.jsonb_build_object(
      'user_id', v_actor_id,
      'push_enabled', true,
      'messages_enabled', true,
      'comments_enabled', true,
      'approvals_enabled', true,
      'community_enabled', true,
      'timezone', 'Asia/Seoul'
    )),
    'deletion_request', v_deletion,
    'blocked_users', v_blocks,
    'push_devices', v_devices
  );
end;
$$;

create or replace function public.list_my_security_activity(
  p_limit integer default 50
)
returns table (
  id uuid,
  action text,
  action_label text,
  occurred_at timestamptz,
  device_label text,
  ip_hint text
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_activity_limit' using errcode = '22023';
  end if;

  return query
  select
    audit.id,
    audit.action,
    case
      when audit.action = 'safety.user_blocked' then '사용자를 차단했습니다.'
      when audit.action = 'safety.user_unblocked' then '사용자 차단을 해제했습니다.'
      when audit.action = 'privacy.preferences_updated' then '개인정보 설정을 변경했습니다.'
      when audit.action = 'account.deletion_requested' then '계정 삭제를 요청했습니다.'
      when audit.action = 'account.deletion_cancelled' then '계정 삭제 요청을 취소했습니다.'
      when audit.action like 'moderation.%' then '콘텐츠 안전 조치가 기록되었습니다.'
      else '계정 또는 권한 변경이 기록되었습니다.'
    end,
    audit.created_at,
    null::text,
    null::text
  from public.audit_logs as audit
  where (audit.actor_id = v_actor_id or audit.target_user_id = v_actor_id)
  order by audit.created_at desc, audit.id desc
  limit p_limit;
end;
$$;

-- Account deletion: AAL2 request -> 14-day grace -> service claim/cleanup ->
-- anonymize -> Auth Admin deleteUser -> service completion. Auth deletion is
-- deliberately outside SQL so sessions and provider identities are revoked by
-- the supported Admin API.
create or replace function public.request_account_deletion(
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_request public.account_deletion_requests%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  perform private.require_aal2('account_deletion_request');
  if p_reason is not null and char_length(p_reason) > 1000 then
    raise exception 'deletion_reason_too_long' using errcode = '22001';
  end if;

  select * into v_request
  from public.account_deletion_requests as request
  where request.user_id = v_actor_id
    and request.status in ('requested', 'processing', 'awaiting_identity_deletion')
  for update;

  if found then
    return pg_catalog.to_jsonb(v_request);
  end if;

  insert into public.account_deletion_requests (
    user_id,
    subject_fingerprint,
    status,
    reason,
    requested_at,
    scheduled_for
  )
  values (
    v_actor_id,
    pg_catalog.encode(extensions.digest(v_actor_id::text, 'sha256'), 'hex'),
    'requested',
    nullif(pg_catalog.btrim(p_reason), ''),
    v_now,
    v_now + interval '14 days'
  )
  returning * into v_request;

  perform private.write_audit(
    v_actor_id,
    'account.deletion_requested',
    'account_deletion_request',
    v_request.id,
    null,
    v_actor_id,
    pg_catalog.jsonb_build_object('scheduled_for', v_request.scheduled_for)
  );

  return pg_catalog.to_jsonb(v_request);
end;
$$;

create or replace function public.request_account_deletion_verified(
  p_user_id uuid,
  p_reason text,
  p_confirmation_text text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_request public.account_deletion_requests%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  perform private.require_service_role('request_account_deletion_verified');
  if p_user_id is null or p_confirmation_text <> '계정 삭제' then
    raise exception 'verified_deletion_request_invalid' using errcode = '23514';
  end if;
  if p_reason is not null and char_length(p_reason) > 1000 then
    raise exception 'deletion_reason_too_long' using errcode = '22001';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = p_user_id and deactivated_at is null
  ) then
    raise exception 'verified_deletion_user_not_active' using errcode = 'P0002';
  end if;

  select * into v_request
  from public.account_deletion_requests as request
  where request.user_id = p_user_id
    and request.status in ('requested', 'processing', 'awaiting_identity_deletion')
  for update;
  if found then
    return pg_catalog.to_jsonb(v_request);
  end if;

  insert into public.account_deletion_requests (
    user_id,
    subject_fingerprint,
    status,
    reason,
    requested_at,
    scheduled_for
  )
  values (
    p_user_id,
    pg_catalog.encode(extensions.digest(p_user_id::text, 'sha256'), 'hex'),
    'requested',
    nullif(pg_catalog.btrim(p_reason), ''),
    v_now,
    v_now + interval '14 days'
  )
  returning * into v_request;

  perform private.write_audit(
    null,
    'account.deletion_requested_verified',
    'account_deletion_request',
    v_request.id,
    null,
    p_user_id,
    pg_catalog.jsonb_build_object(
      'verified_by', 'edge_gotrue_reauthentication',
      'scheduled_for', v_request.scheduled_for
    )
  );

  return pg_catalog.to_jsonb(v_request);
end;
$$;

create or replace function public.cancel_account_deletion()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_request public.account_deletion_requests%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_request
  from public.account_deletion_requests as request
  where request.user_id = v_actor_id
    and request.status = 'requested'
  order by request.requested_at desc
  limit 1
  for update;

  if not found then
    raise exception 'cancellable_deletion_request_not_found' using errcode = 'P0002';
  end if;

  update public.account_deletion_requests
  set status = 'cancelled',
      cancelled_at = pg_catalog.clock_timestamp()
  where id = v_request.id
  returning * into v_request;

  perform private.write_audit(
    v_actor_id,
    'account.deletion_cancelled',
    'account_deletion_request',
    v_request.id,
    null,
    v_actor_id,
    '{}'::jsonb
  );

  return pg_catalog.to_jsonb(v_request);
end;
$$;

create or replace function public.service_claim_due_account_deletions(
  p_limit integer default 10
)
returns table (
  request_id uuid,
  user_id uuid,
  subject_fingerprint text,
  cleanup_items jsonb
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_request public.account_deletion_requests%rowtype;
  v_cleanup jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_preserved_object_count integer := 0;
begin
  perform private.require_service_role('claim_due_account_deletions');
  if p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_deletion_claim_limit' using errcode = '22023';
  end if;

  update public.account_deletion_requests as deletion_request
  set status = 'failed',
      failure_code = 'deletion_worker_lease_exhausted',
      updated_at = v_now
  where deletion_request.status = 'processing'
    and (
      deletion_request.processing_claimed_at is null
      or deletion_request.processing_claimed_at <= v_now - interval '10 minutes'
    )
    and deletion_request.processing_attempts >= 8;

  for v_request in
    select request.*
    from public.account_deletion_requests as request
    where (
        (
          request.status = 'requested'
          and request.scheduled_for <= v_now
        )
        or (
          request.status = 'processing'
          and (
            request.processing_claimed_at is null
            or request.processing_claimed_at <= v_now - interval '10 minutes'
          )
          and request.processing_attempts < 8
        )
      )
      and request.user_id is not null
    order by request.scheduled_for, request.id
    for update skip locked
    limit p_limit
  loop
    -- Snapshot every known user-owned Storage path before any profile/Auth row
    -- can disappear. The queue is idempotent for retries.
    insert into private.account_deletion_cleanup_items (
      request_id, bucket_id, storage_path
    )
    select v_request.id, 'avatars', profile.avatar_path
    from public.profiles as profile
    where profile.id = v_request.user_id
      and profile.avatar_path is not null
    on conflict on constraint account_cleanup_item_path_unique do nothing;

    insert into private.account_deletion_cleanup_items (
      request_id, bucket_id, storage_path
    )
    select v_request.id, 'community-media', media.storage_path
    from public.post_media as media
    where media.uploader_id = v_request.user_id
    on conflict on constraint account_cleanup_item_path_unique do nothing;

    insert into private.account_deletion_cleanup_items (
      request_id, bucket_id, storage_path
    )
    select v_request.id, 'community-media', message.media_path
    from public.messages as message
    where message.sender_id = v_request.user_id
      and message.media_path is not null
    on conflict on constraint account_cleanup_item_path_unique do nothing;

    insert into private.account_deletion_cleanup_items (
      request_id, bucket_id, storage_path
    )
    select v_request.id, 'community-media', application.evidence_path
    from public.membership_applications as application
    where application.user_id = v_request.user_id
      and application.evidence_path is not null
    on conflict on constraint account_cleanup_item_path_unique do nothing;

    insert into private.account_deletion_cleanup_items (
      request_id, bucket_id, storage_path
    )
    select v_request.id, 'community-media-quarantine', intent.quarantine_path
    from public.media_upload_intents as intent
    where intent.uploader_id = v_request.user_id
    on conflict on constraint account_cleanup_item_path_unique do nothing;

    insert into private.account_deletion_cleanup_items (
      request_id, bucket_id, storage_path
    )
    select v_request.id, intent.approved_bucket_id, intent.approved_path
    from public.media_upload_intents as intent
    where intent.uploader_id = v_request.user_id
      and intent.status in ('approved', 'attached')
      and not (
        intent.purpose = 'organization_hero'
        and intent.status = 'attached'
      )
    on conflict on constraint account_cleanup_item_path_unique do nothing;

    -- An attached organization hero is now organization-owned content, not a
    -- personal upload to erase. Supabase Auth refuses to delete a user who is
    -- still recorded as a Storage object owner, so transfer only the exact
    -- currently attached hero object while retaining its bytes and DB link.
    update storage.objects as object
    set owner = null,
        owner_id = null,
        updated_at = v_now
    from public.media_upload_intents as intent
    join public.organizations as organization
      on organization.id = intent.target_id
     and organization.hero_path = intent.approved_path
    where intent.uploader_id = v_request.user_id
      and intent.purpose = 'organization_hero'
      and intent.status = 'attached'
      and object.bucket_id = intent.approved_bucket_id
      and object.name = intent.approved_path
      and (
        object.owner_id = v_request.user_id::text
        or object.owner = v_request.user_id
      );
    get diagnostics v_preserved_object_count = row_count;
    if v_preserved_object_count > 0 then
      perform private.write_audit(
        null,
        'account.storage_ownership_transferred',
        'account_deletion_request',
        v_request.id,
        null,
        v_request.user_id,
        pg_catalog.jsonb_build_object(
          'preserved_organization_hero_count', v_preserved_object_count
        )
      );
    end if;

    update public.account_deletion_requests as deletion_request
    set status = 'processing',
        processing_started_at = coalesce(deletion_request.processing_started_at, v_now),
        processing_claimed_at = v_now,
        processing_attempts = deletion_request.processing_attempts + 1,
        failure_code = null
    where deletion_request.id = v_request.id;

    -- Freeze product authority immediately. GoTrue does not expose a safe
    -- user-id-only global sign-out call, so the worker must not mutate
    -- auth.sessions/refresh_tokens directly. Existing tokens remain unable to
    -- exercise product authority after profile and membership deactivation;
    -- Auth Admin identity deletion invalidates them at the final step.
    update public.organization_memberships as membership
    set status = 'revoked'::public.membership_status,
        ended_at = coalesce(membership.ended_at, v_now),
        updated_at = v_now
    where membership.user_id = v_request.user_id
      and membership.status = 'active'::public.membership_status;

    update public.membership_applications as application
    set status = 'withdrawn'::public.application_status,
        reviewed_at = coalesce(application.reviewed_at, v_now),
        review_reason = coalesce(application.review_reason, '계정 삭제 처리')
    where application.user_id = v_request.user_id
      and application.status = 'pending'::public.application_status;

    update public.governance_office_assignments as assignment
    set ended_at = coalesce(assignment.ended_at, v_now)
    where assignment.user_id = v_request.user_id
      and assignment.ended_at is null;

    update public.governance_authority_delegations as delegation
    set revoked_at = coalesce(delegation.revoked_at, v_now),
        revoked_by = coalesce(delegation.revoked_by, v_request.user_id),
        revocation_reason = coalesce(delegation.revocation_reason, '계정 삭제 처리')
    where (
        delegation.grantor_user_id = v_request.user_id
        or delegation.delegate_user_id = v_request.user_id
      )
      and delegation.revoked_at is null;

    update public.profiles as profile
    set deactivated_at = coalesce(profile.deactivated_at, v_now)
    where profile.id = v_request.user_id;

    delete from public.push_devices
    where public.push_devices.user_id = v_request.user_id;

    select coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', item.id,
          'bucket_id', item.bucket_id,
          'storage_path', item.storage_path,
          'status', item.status
        ) order by item.created_at, item.id
      ),
      '[]'::jsonb
    ) into v_cleanup
    from private.account_deletion_cleanup_items as item
    where item.request_id = v_request.id;

    request_id := v_request.id;
    user_id := v_request.user_id;
    subject_fingerprint := v_request.subject_fingerprint;
    cleanup_items := v_cleanup;
    return next;
  end loop;
end;
$$;

create or replace function public.service_mark_account_cleanup_item(
  p_item_id uuid,
  p_status text,
  p_error_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_item private.account_deletion_cleanup_items%rowtype;
begin
  perform private.require_service_role('mark_account_cleanup_item');
  if p_status not in ('deleted', 'not_found', 'failed') then
    raise exception 'invalid_cleanup_status' using errcode = '22023';
  end if;
  if p_status = 'failed' and nullif(pg_catalog.btrim(p_error_code), '') is null then
    raise exception 'cleanup_error_code_required' using errcode = '23514';
  end if;

  select item.* into v_item
  from private.account_deletion_cleanup_items as item
  join public.account_deletion_requests as deletion_request
    on deletion_request.id = item.request_id
  where item.id = p_item_id
    and deletion_request.status = 'processing'
  for update of item;
  if not found then
    raise exception 'cleanup_item_not_in_processing_request' using errcode = '55000';
  end if;
  if p_status = 'failed' and v_item.attempt_count >= 8 then
    raise exception 'cleanup_retry_limit_exceeded' using errcode = '54000';
  end if;

  update private.account_deletion_cleanup_items as item
  set status = case
        when p_status = 'failed' and item.attempt_count + 1 >= 8 then 'dead'
        else p_status
      end,
      attempt_count = item.attempt_count + 1,
      last_error_code = case
        when p_status = 'failed' then pg_catalog.left(pg_catalog.btrim(p_error_code), 120)
        else null
      end,
      updated_at = pg_catalog.clock_timestamp()
  where item.id = p_item_id
  returning * into v_item;
  return pg_catalog.to_jsonb(v_item);
end;
$$;

create or replace function public.service_finalize_account_anonymization(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_request public.account_deletion_requests%rowtype;
begin
  perform private.require_service_role('finalize_account_anonymization');
  select * into v_request
  from public.account_deletion_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'deletion_request_not_found' using errcode = 'P0002';
  end if;
  if v_request.status <> 'processing' or v_request.user_id is null then
    raise exception 'deletion_request_not_anonymizable' using errcode = '55000';
  end if;
  if exists (
    select 1
    from private.account_deletion_cleanup_items as item
    where item.request_id = p_request_id
      and item.status not in ('deleted', 'not_found')
  ) then
    raise exception 'storage_cleanup_incomplete' using errcode = '55000';
  end if;

  update public.profiles
  set display_name = '탈퇴한 회원',
      bio = null,
      avatar_path = null,
      deactivated_at = coalesce(deactivated_at, pg_catalog.clock_timestamp())
  where id = v_request.user_id;

  update public.membership_applications
  set applicant_note = null,
      evidence_path = null
  where user_id = v_request.user_id;

  delete from public.post_media
  where uploader_id = v_request.user_id;

  update public.messages
  set body = null,
      media_path = null,
      media_metadata = '{}'::jsonb,
      deleted_at = coalesce(deleted_at, pg_catalog.clock_timestamp())
  where sender_id = v_request.user_id;

  update public.comments
  set body = '삭제된 댓글입니다.',
      status = 'deleted'::public.comment_status,
      deleted_at = coalesce(deleted_at, pg_catalog.clock_timestamp())
  where author_id = v_request.user_id;

  update public.posts
  set title = '삭제된 게시글',
      body = '작성자가 계정을 삭제하여 게시글이 삭제되었습니다.',
      status = 'deleted'::public.post_status,
      deleted_at = coalesce(deleted_at, pg_catalog.clock_timestamp())
  where author_id = v_request.user_id
    and not is_system;

  update public.meeting_minutes
  set author_name = '탈퇴한 회원'
  where author_id = v_request.user_id;

  update public.ledger_entries
  set author_name = '탈퇴한 회원'
  where author_id = v_request.user_id;

  delete from public.notifications where user_id = v_request.user_id;
  delete from public.notification_preferences where user_id = v_request.user_id;
  delete from public.privacy_preferences where user_id = v_request.user_id;
  delete from public.conversation_preferences where user_id = v_request.user_id;

  update public.account_deletion_requests
  set status = 'awaiting_identity_deletion'
  where id = p_request_id
  returning * into v_request;

  perform private.write_audit(
    null,
    'account.anonymization_ready',
    'account_deletion_request',
    p_request_id,
    null,
    v_request.user_id,
    '{}'::jsonb
  );

  -- The caller now invokes supabase.auth.admin.deleteUser(user_id). Conversation
  -- participant UUIDs have no FK, so that operation cannot erase counterpart data.
  return pg_catalog.jsonb_build_object(
    'request_id', p_request_id,
    'user_id', v_request.user_id,
    'status', v_request.status,
    'next_operation', 'auth.admin.deleteUser'
  );
end;
$$;

create or replace function public.service_claim_pending_identity_deletions(
  p_limit integer default 25
)
returns table (
  request_id uuid,
  user_id uuid,
  subject_fingerprint text,
  identity_attempts integer
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  perform private.require_service_role('claim_pending_identity_deletions');
  if p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_identity_deletion_claim_limit' using errcode = '22023';
  end if;

  update public.account_deletion_requests as deletion_request
  set status = 'failed',
      failure_code = 'identity_deletion_lease_exhausted',
      updated_at = v_now
  where deletion_request.status = 'awaiting_identity_deletion'
    and deletion_request.user_id is not null
    and (
      deletion_request.identity_claimed_at is null
      or deletion_request.identity_claimed_at <= v_now - interval '10 minutes'
    )
    and deletion_request.identity_attempts >= 8;

  return query
  with candidates as (
    select request.id
    from public.account_deletion_requests as request
    where request.status = 'awaiting_identity_deletion'
      and (
        request.identity_claimed_at is null
        or request.identity_claimed_at <= v_now - interval '10 minutes'
      )
      and (request.user_id is null or request.identity_attempts < 8)
    order by request.updated_at, request.id
    for update skip locked
    limit p_limit
  )
  update public.account_deletion_requests as request
  set identity_claimed_at = v_now,
      identity_attempts = request.identity_attempts + 1,
      updated_at = v_now
  from candidates
  where request.id = candidates.id
  returning
    request.id,
    request.user_id,
    request.subject_fingerprint,
    request.identity_attempts;
end;
$$;

create or replace function public.service_complete_account_deletion(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_request public.account_deletion_requests%rowtype;
begin
  perform private.require_service_role('complete_account_deletion');
  select * into v_request
  from public.account_deletion_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'deletion_request_not_found' using errcode = 'P0002';
  end if;
  if v_request.status <> 'awaiting_identity_deletion'
    or v_request.user_id is not null then
    raise exception 'auth_identity_deletion_not_confirmed' using errcode = '55000';
  end if;

  update public.account_deletion_requests
  set status = 'completed',
      completed_at = pg_catalog.clock_timestamp()
  where id = p_request_id
  returning * into v_request;

  return pg_catalog.to_jsonb(v_request);
end;
$$;

create or replace function public.service_fail_account_deletion(
  p_request_id uuid,
  p_failure_code text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_service_role('fail_account_deletion');
  if nullif(pg_catalog.btrim(p_failure_code), '') is null then
    raise exception 'failure_code_required' using errcode = '23514';
  end if;
  update public.account_deletion_requests
  set status = 'failed',
      failure_code = pg_catalog.left(pg_catalog.btrim(p_failure_code), 120)
  where id = p_request_id
    and status in ('processing', 'awaiting_identity_deletion');
  if not found then
    raise exception 'deletion_request_not_fail_markable' using errcode = '55000';
  end if;
end;
$$;

-- UGC reporting and scoped moderation --------------------------------------
create or replace function public.create_content_report(
  p_target_type text,
  p_target_id uuid,
  p_reason_code text,
  p_details text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_organization_id uuid;
  v_reported_user_id uuid;
  v_snapshot jsonb;
  v_report_id uuid;
  v_existing_reason text;
  v_conversation public.conversations%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_target_type not in ('post', 'comment', 'message', 'profile')
    or p_target_id is null then
    raise exception 'invalid_report_target' using errcode = '22023';
  end if;
  if p_reason_code not in (
    'harassment', 'spam', 'hate', 'sexual_content', 'violence',
    'privacy', 'impersonation', 'self_harm', 'other'
  ) then
    raise exception 'invalid_report_reason' using errcode = '22023';
  end if;
  if p_details is not null and char_length(p_details) > 2000 then
    raise exception 'report_details_too_long' using errcode = '22001';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'report:' || v_actor_id::text || ':' || p_target_type || ':' || p_target_id::text,
      0
    )
  );
  select report.id, report.reason_code
  into v_report_id, v_existing_reason
  from public.content_reports as report
  where report.reporter_id = v_actor_id
    and report.target_type = p_target_type
    and report.target_id = p_target_id
    and report.status in ('open', 'reviewing', 'escalated')
  order by report.created_at desc
  limit 1;

  if v_report_id is not null then
    if v_existing_reason = p_reason_code then
      return v_report_id;
    end if;
    raise exception 'active_report_already_exists' using errcode = '23505';
  end if;

  perform private.consume_rate_limit(v_actor_id, 'reports', 5, 3600, 1);

  case p_target_type
    when 'post' then
      select
        post.organization_id,
        post.author_id,
        pg_catalog.jsonb_build_object(
          'target_type', 'post',
          'id', post.id,
          'title', post.title,
          'body_excerpt', pg_catalog.left(post.body, 2000),
          'status', post.status,
          'created_at', post.created_at
        )
      into v_organization_id, v_reported_user_id, v_snapshot
      from public.posts as post
      where post.id = p_target_id
        and private.can_read_post(post.id, v_actor_id);

    when 'comment' then
      select
        post.organization_id,
        comment.author_id,
        pg_catalog.jsonb_build_object(
          'target_type', 'comment',
          'id', comment.id,
          'post_id', comment.post_id,
          'body_excerpt', pg_catalog.left(comment.body, 2000),
          'status', comment.status,
          'created_at', comment.created_at
        )
      into v_organization_id, v_reported_user_id, v_snapshot
      from public.comments as comment
      join public.posts as post on post.id = comment.post_id
      where comment.id = p_target_id
        and private.can_read_post(post.id, v_actor_id);

    when 'message' then
      select conversation.* into v_conversation
      from public.messages as message
      join public.conversations as conversation on conversation.id = message.conversation_id
      where message.id = p_target_id
        and private.can_access_conversation(conversation.id, v_actor_id);

      if not found then
        raise exception 'report_target_not_accessible' using errcode = '42501';
      end if;

      select
        v_conversation.organization_id,
        message.sender_id,
        pg_catalog.jsonb_build_object(
          'target_type', 'message',
          'id', message.id,
          'conversation_id', message.conversation_id,
          'sender_id', message.sender_id,
          'kind', message.kind,
          'body_excerpt', pg_catalog.left(coalesce(message.body, ''), 2000),
          'has_media', message.media_path is not null,
          'created_at', message.created_at
        )
      into v_organization_id, v_reported_user_id, v_snapshot
      from public.messages as message
      where message.id = p_target_id;

      if v_reported_user_id is null or v_reported_user_id = v_actor_id then
        raise exception 'cannot_report_own_or_anonymized_message' using errcode = '23514';
      end if;

    when 'profile' then
      if p_target_id = v_actor_id then
        raise exception 'cannot_report_self' using errcode = '23514';
      end if;

      select
        actor_membership.organization_id,
        profile.id,
        pg_catalog.jsonb_build_object(
          'target_type', 'profile',
          'id', profile.id,
          'display_name', profile.display_name,
          'bio_excerpt', pg_catalog.left(coalesce(profile.bio, ''), 1000),
          'captured_at', pg_catalog.clock_timestamp()
        )
      into v_organization_id, v_reported_user_id, v_snapshot
      from public.organization_memberships as actor_membership
      join public.organization_memberships as target_membership
        on target_membership.organization_id = actor_membership.organization_id
       and target_membership.status = 'active'::public.membership_status
      join public.profiles as profile on profile.id = target_membership.user_id
      where actor_membership.user_id = v_actor_id
        and actor_membership.status = 'active'::public.membership_status
        and target_membership.user_id = p_target_id;
  end case;

  if v_snapshot is null then
    raise exception 'report_target_not_accessible' using errcode = '42501';
  end if;
  if v_reported_user_id = v_actor_id then
    raise exception 'cannot_report_own_content' using errcode = '23514';
  end if;

  insert into public.content_reports (
    reporter_id,
    organization_id,
    target_type,
    target_id,
    reported_user_id,
    reason_code,
    details,
    evidence_snapshot
  )
  values (
    v_actor_id,
    v_organization_id,
    p_target_type,
    p_target_id,
    v_reported_user_id,
    p_reason_code,
    nullif(pg_catalog.btrim(p_details), ''),
    v_snapshot
  )
  returning id into v_report_id;

  perform private.write_audit(
    v_actor_id,
    'moderation.report_created',
    'content_report',
    v_report_id,
    v_organization_id,
    v_reported_user_id,
    pg_catalog.jsonb_build_object(
      'target_type', p_target_type,
      'target_id', p_target_id,
      'reason_code', p_reason_code
    )
  );

  return v_report_id;
end;
$$;

create or replace function public.list_moderation_reports(
  p_status text default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  organization_name text,
  target_type text,
  target_id uuid,
  reported_user_id uuid,
  target_author_name text,
  reporter_display_name text,
  reason_code text,
  details text,
  evidence_summary text,
  status text,
  created_at timestamptz,
  resolved_at timestamptz,
  resolution_reason text
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_report_limit' using errcode = '22023';
  end if;
  if p_status is not null
    and p_status not in ('open', 'reviewing', 'resolved', 'dismissed', 'escalated') then
    raise exception 'invalid_report_status' using errcode = '22023';
  end if;

  return query
  select
    report.id,
    report.organization_id,
    organization.display_name,
    report.target_type,
    report.target_id,
    report.reported_user_id,
    target_profile.display_name,
    reporter_profile.display_name,
    report.reason_code,
    report.details,
    case report.target_type
      when 'post' then coalesce(report.evidence_snapshot ->> 'title', '게시글')
        || ' · ' || pg_catalog.left(coalesce(report.evidence_snapshot ->> 'body_excerpt', ''), 240)
      when 'comment' then pg_catalog.left(coalesce(report.evidence_snapshot ->> 'body_excerpt', '댓글'), 280)
      when 'message' then pg_catalog.left(coalesce(report.evidence_snapshot ->> 'body_excerpt', '메시지 또는 미디어'), 280)
      else coalesce(report.evidence_snapshot ->> 'display_name', '사용자 프로필')
    end,
    report.status,
    report.created_at,
    report.resolved_at,
    report.resolution_note
  from public.content_reports as report
  left join public.organizations as organization on organization.id = report.organization_id
  left join public.profiles as target_profile on target_profile.id = report.reported_user_id
  left join public.profiles as reporter_profile on reporter_profile.id = report.reporter_id
  where private.can_moderate_organization(report.organization_id, v_actor_id)
    and (p_status is null or report.status = p_status)
  order by
    case report.status when 'open' then 0 when 'reviewing' then 1 when 'escalated' then 2 else 3 end,
    report.created_at,
    report.id
  limit p_limit;
end;
$$;

create or replace function private.enforce_moderation_action_aal2()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is not null
    and new.action_code in ('warning_recorded', 'content_hidden', 'member_suspended') then
    perform private.require_aal2('moderation_sanction');
  end if;
  return new;
end;
$$;

create trigger moderation_actions_require_aal2
before insert on public.moderation_actions
for each row execute function private.enforce_moderation_action_aal2();

create or replace function public.resolve_content_report(
  p_report_id uuid,
  p_action text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_report public.content_reports%rowtype;
  v_membership_id uuid;
  v_new_status text;
  v_action_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_action not in (
    'no_action', 'warning_recorded', 'content_hidden',
    'member_suspended', 'escalated_to_platform'
  ) then
    raise exception 'invalid_moderation_action' using errcode = '22023';
  end if;
  if nullif(pg_catalog.btrim(p_reason), '') is null then
    raise exception 'moderation_reason_required' using errcode = '23514';
  end if;
  if char_length(p_reason) > 2000 then
    raise exception 'moderation_reason_too_long' using errcode = '22001';
  end if;

  select * into v_report
  from public.content_reports
  where id = p_report_id
  for update;

  if not found then
    raise exception 'content_report_not_found' using errcode = 'P0002';
  end if;
  if not private.can_moderate_organization(v_report.organization_id, v_actor_id) then
    raise exception 'moderation_scope_forbidden' using errcode = '42501';
  end if;
  if v_report.status in ('resolved', 'dismissed') then
    raise exception 'content_report_already_resolved' using errcode = '55000';
  end if;

  if p_action in ('warning_recorded', 'content_hidden', 'member_suspended') then
    perform private.require_aal2('moderation_sanction');
  end if;

  case p_action
    when 'content_hidden' then
      if v_report.target_type = 'post' then
        update public.posts
        set status = 'hidden'::public.post_status
        where id = v_report.target_id
          and organization_id is not distinct from v_report.organization_id;
      elsif v_report.target_type = 'comment' then
        update public.comments as comment
        set status = 'hidden'::public.comment_status
        from public.posts as post
        where comment.id = v_report.target_id
          and post.id = comment.post_id
          and post.organization_id is not distinct from v_report.organization_id;
      else
        raise exception 'target_cannot_be_hidden_by_moderator' using errcode = '42501';
      end if;
      if not found then
        raise exception 'moderation_target_not_found_in_scope' using errcode = 'P0002';
      end if;
      v_new_status := 'resolved';

    when 'member_suspended' then
      select membership.id into v_membership_id
      from public.organization_memberships as membership
      where membership.user_id = v_report.reported_user_id
        and membership.organization_id = v_report.organization_id
        and membership.status = 'active'::public.membership_status;
      if v_membership_id is null then
        raise exception 'active_reported_membership_not_found' using errcode = 'P0002';
      end if;
      perform public.set_membership_status(
        v_membership_id,
        'suspended'::public.membership_status,
        pg_catalog.btrim(p_reason)
      );
      v_new_status := 'resolved';

    when 'escalated_to_platform' then
      v_new_status := 'escalated';

    when 'no_action' then
      v_new_status := 'dismissed';

    else
      v_new_status := 'resolved';
  end case;

  insert into public.moderation_actions (
    report_id,
    actor_id,
    organization_id,
    target_type,
    target_id,
    target_user_id,
    action_code,
    note
  )
  values (
    v_report.id,
    v_actor_id,
    v_report.organization_id,
    v_report.target_type,
    v_report.target_id,
    v_report.reported_user_id,
    p_action,
    pg_catalog.btrim(p_reason)
  )
  returning id into v_action_id;

  update public.content_reports
  set status = v_new_status,
      assigned_to = v_actor_id,
      reviewed_at = pg_catalog.clock_timestamp(),
      resolved_at = pg_catalog.clock_timestamp(),
      resolution_code = p_action,
      resolution_note = pg_catalog.btrim(p_reason)
  where id = p_report_id;

  perform private.write_audit(
    v_actor_id,
    'moderation.report_resolved',
    'content_report',
    p_report_id,
    v_report.organization_id,
    v_report.reported_user_id,
    pg_catalog.jsonb_build_object(
      'action_id', v_action_id,
      'action', p_action,
      'target_type', v_report.target_type,
      'target_id', v_report.target_id
    )
  );

  return pg_catalog.jsonb_build_object(
    'report_id', p_report_id,
    'action_id', v_action_id,
    'status', v_new_status,
    'action', p_action
  );
end;
$$;

-- Quarantined media upload contracts ---------------------------------------
create or replace function public.create_media_upload_intent(
  p_purpose text,
  p_target_id uuid,
  p_kind public.media_kind,
  p_expected_mime_type text,
  p_expected_byte_size bigint
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_organization_id uuid;
  v_intent_id uuid := gen_random_uuid();
  v_quarantine_extension text;
  v_approved_extension text;
  v_quarantine_path text;
  v_approved_path text;
  v_approved_bucket_id text := 'community-media';
  v_daily_bytes bigint;
  v_retained_user_bytes bigint;
  v_retained_org_bytes bigint;
  v_intent public.media_upload_intents%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_target_id is null or p_purpose not in (
    'post', 'message', 'organization_hero', 'application_evidence', 'avatar'
  ) then
    raise exception 'invalid_media_upload_target' using errcode = '22023';
  end if;
  if p_expected_mime_type not in (
    'image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/heic', 'image/heif',
    'video/mp4', 'video/quicktime', 'video/webm'
  ) then
    raise exception 'unsupported_media_mime_type' using errcode = '22023';
  end if;
  if (p_kind = 'image'::public.media_kind and p_expected_mime_type not like 'image/%')
    or (p_kind = 'video'::public.media_kind and p_expected_mime_type not like 'video/%') then
    raise exception 'media_kind_mime_mismatch' using errcode = '23514';
  end if;
  if p_expected_byte_size is null or p_expected_byte_size <= 0
    or (p_kind = 'image'::public.media_kind and p_expected_byte_size > 15728640)
    or (p_kind = 'video'::public.media_kind and p_expected_byte_size > 524288000)
    or (p_purpose = 'avatar' and p_expected_byte_size > 5242880) then
    raise exception 'media_size_out_of_range' using errcode = '22023';
  end if;

  case p_purpose
    when 'post' then
      select post.organization_id into v_organization_id
      from public.posts as post
      where post.id = p_target_id
        and post.author_id = v_actor_id
        and post.status = 'draft'::public.post_status
        and private.can_manage_post(post.id, v_actor_id);
    when 'message' then
      select conversation.organization_id into v_organization_id
      from public.conversations as conversation
      where conversation.id = p_target_id
        and private.can_access_conversation(conversation.id, v_actor_id);
    when 'organization_hero' then
      select organization.id into v_organization_id
      from public.organizations as organization
      where organization.id = p_target_id
        and p_kind = 'image'::public.media_kind
        and private.can_manage_members(organization.id, v_actor_id);
    when 'application_evidence' then
      select application.organization_id into v_organization_id
      from public.membership_applications as application
      where application.id = p_target_id
        and application.user_id = v_actor_id
        and application.status = 'pending'::public.application_status
        and p_kind = 'image'::public.media_kind;
    when 'avatar' then
      if p_target_id = v_actor_id and p_kind = 'image'::public.media_kind then
        v_approved_bucket_id := 'avatars';
      end if;
  end case;

  if (p_purpose = 'avatar' and v_approved_bucket_id <> 'avatars')
    or (p_purpose <> 'avatar' and v_organization_id is null) then
    raise exception 'media_upload_target_forbidden' using errcode = '42501';
  end if;

  perform private.consume_rate_limit(v_actor_id, 'uploads', 12, 600, 1);
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('media-quota:' || v_actor_id::text, 0)
  );

  select coalesce(sum(intent.expected_byte_size), 0)::bigint into v_daily_bytes
  from public.media_upload_intents as intent
  where intent.uploader_id = v_actor_id
    and intent.created_at >= pg_catalog.clock_timestamp() - interval '24 hours'
    and intent.status not in ('rejected', 'expired');

  select coalesce(sum(coalesce(intent.approved_byte_size, intent.expected_byte_size)), 0)::bigint
  into v_retained_user_bytes
  from public.media_upload_intents as intent
  where intent.uploader_id = v_actor_id
    and intent.status in ('quarantine', 'scanning', 'approved', 'attached');

  if v_organization_id is not null then
    select coalesce(sum(coalesce(intent.approved_byte_size, intent.expected_byte_size)), 0)::bigint
    into v_retained_org_bytes
    from public.media_upload_intents as intent
    where intent.organization_id = v_organization_id
      and intent.status in ('quarantine', 'scanning', 'approved', 'attached');
  else
    v_retained_org_bytes := 0;
  end if;

  if v_daily_bytes + p_expected_byte_size > 1073741824 then
    raise exception 'daily_media_quota_exceeded' using errcode = '54000';
  end if;
  if v_retained_user_bytes + p_expected_byte_size > 5368709120 then
    raise exception 'user_media_quota_exceeded' using errcode = '54000';
  end if;
  if v_organization_id is not null
    and v_retained_org_bytes + p_expected_byte_size > 107374182400 then
    raise exception 'organization_media_quota_exceeded' using errcode = '54000';
  end if;

  v_quarantine_extension := case p_expected_mime_type
    when 'image/jpeg' then 'jpg'
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'image/avif' then 'avif'
    when 'image/heic' then 'heic'
    when 'image/heif' then 'heif'
    when 'video/mp4' then 'mp4'
    when 'video/quicktime' then 'mov'
    else 'webm'
  end;
  -- HEIC/HEIF and QuickTime are quarantine inputs only. The scanner writes a
  -- portable sanitized derivative whose suffix agrees with the approved MIME.
  v_approved_extension := case p_expected_mime_type
    when 'image/heic' then 'jpg'
    when 'image/heif' then 'jpg'
    when 'video/quicktime' then 'mp4'
    else v_quarantine_extension
  end;

  v_quarantine_path := v_actor_id::text || '/' || v_intent_id::text || '/upload.' || v_quarantine_extension;
  v_approved_path := case p_purpose
    when 'post' then v_organization_id::text || '/posts/' || p_target_id::text || '/' || v_intent_id::text || '.' || v_approved_extension
    when 'message' then v_organization_id::text || '/messages/' || p_target_id::text || '/' || v_intent_id::text || '.' || v_approved_extension
    when 'organization_hero' then v_organization_id::text || '/organization/' || v_intent_id::text || '.' || v_approved_extension
    when 'application_evidence' then v_organization_id::text || '/applications/' || p_target_id::text || '/' || v_intent_id::text || '.' || v_approved_extension
    else v_actor_id::text || '/' || v_intent_id::text || '.' || v_approved_extension
  end;

  insert into public.media_upload_intents (
    id,
    uploader_id,
    organization_id,
    purpose,
    target_id,
    kind,
    expected_mime_type,
    expected_byte_size,
    quarantine_path,
    approved_bucket_id,
    approved_path,
    expires_at
  )
  values (
    v_intent_id,
    v_actor_id,
    v_organization_id,
    p_purpose,
    p_target_id,
    p_kind,
    p_expected_mime_type,
    p_expected_byte_size,
    v_quarantine_path,
    v_approved_bucket_id,
    v_approved_path,
    pg_catalog.clock_timestamp() + interval '1 hour'
  )
  returning * into v_intent;

  return pg_catalog.jsonb_build_object(
    'id', v_intent.id,
    'bucket_id', 'community-media-quarantine',
    'quarantine_path', v_intent.quarantine_path,
    'approved_path', v_intent.approved_path,
    'approved_bucket_id', v_intent.approved_bucket_id,
    'expires_at', v_intent.expires_at,
    'expected_mime_type', v_intent.expected_mime_type,
    'expected_byte_size', v_intent.expected_byte_size,
    'status', v_intent.status
  );
end;
$$;

create or replace function public.abandon_media_upload_intents(
  p_approved_paths text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_requested_count integer;
  v_matched_count integer := 0;
  v_intent public.media_upload_intents%rowtype;
  v_abandoned_ids jsonb := '[]'::jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select count(distinct path)::integer into v_requested_count
  from pg_catalog.unnest(coalesce(p_approved_paths, array[]::text[])) as requested(path)
  where nullif(pg_catalog.btrim(path), '') is not null;

  if v_requested_count < 1 or v_requested_count > 20 then
    raise exception 'invalid_media_abandon_batch' using errcode = '22023';
  end if;

  perform private.consume_rate_limit(v_actor_id, 'media_abandon', 30, 600, 1);

  for v_intent in
    select intent.*
    from public.media_upload_intents as intent
    where intent.uploader_id = v_actor_id
      and intent.approved_path = any(p_approved_paths)
      and intent.attached_at is null
      and intent.status in ('quarantine', 'scanning', 'approved', 'rejected', 'expired')
    order by intent.id
    for update
  loop
    v_matched_count := v_matched_count + 1;
    if v_intent.status in ('quarantine', 'scanning', 'approved') then
      update public.media_upload_intents
      set status = 'expired',
          rejection_code = 'abandoned_by_user',
          updated_at = pg_catalog.clock_timestamp()
      where id = v_intent.id;
    end if;

    insert into private.media_cleanup_items (
      intent_id, uploader_id, bucket_id, storage_path, reason
    )
    values
      (
        v_intent.id,
        v_actor_id,
        'community-media-quarantine',
        v_intent.quarantine_path,
        case when v_intent.status = 'rejected' then 'scan_rejected' else 'user_abandoned' end
      ),
      (
        v_intent.id,
        v_actor_id,
        v_intent.approved_bucket_id,
        v_intent.approved_path,
        case when v_intent.status = 'rejected' then 'scan_rejected' else 'user_abandoned' end
      )
    on conflict (bucket_id, storage_path) do nothing;

    v_abandoned_ids := v_abandoned_ids || pg_catalog.jsonb_build_array(v_intent.id);
  end loop;

  if v_matched_count <> v_requested_count then
    raise exception 'media_intent_abandon_forbidden' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'abandoned_count', v_matched_count,
    'intent_ids', v_abandoned_ids,
    'cleanup_queued', true
  );
end;
$$;

create or replace function public.prepare_post_media_cleanup(
  p_post_id uuid,
  p_expected_author_id uuid,
  p_storage_paths text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_post public.posts%rowtype;
  v_requested text[];
  v_referenced text[];
  v_removable text[];
  v_protected text[];
  v_prefix text;
  v_path text;
  v_intent public.media_upload_intents%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_author_id is null or v_actor_id <> p_expected_author_id then
    raise exception 'post_author_session_changed' using errcode = '42501';
  end if;
  if p_post_id is null or p_storage_paths is null
    or pg_catalog.cardinality(p_storage_paths) > 100 then
    raise exception 'invalid_post_cleanup_request' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('post:' || p_post_id::text, 0)
  );
  select * into v_post
  from public.posts
  where id = p_post_id
  for update;
  if not found then
    return pg_catalog.jsonb_build_object(
      'status', 'not_found',
      'removable_paths', '[]'::jsonb,
      'protected_paths', '[]'::jsonb,
      'cleanup_queued', false
    );
  end if;
  if v_post.is_system or v_post.author_id is distinct from p_expected_author_id then
    raise exception 'post_cleanup_forbidden' using errcode = '42501';
  end if;

  v_prefix := v_post.organization_id::text || '/posts/' || p_post_id::text || '/';
  select coalesce(pg_catalog.array_agg(paths.path order by paths.path), '{}'::text[])
  into v_requested
  from (
    select distinct pg_catalog.btrim(path) as path
    from pg_catalog.unnest(p_storage_paths) as supplied(path)
    where nullif(pg_catalog.btrim(path), '') is not null
  ) as paths;
  if exists (
    select 1
    from pg_catalog.unnest(v_requested) as requested(path)
    where pg_catalog.strpos(requested.path, v_prefix) <> 1
  ) then
    raise exception 'post_cleanup_path_mismatch' using errcode = '22023';
  end if;

  select coalesce(pg_catalog.array_agg(media.storage_path order by media.storage_path), '{}'::text[])
  into v_referenced
  from public.post_media as media
  where media.post_id = p_post_id
    and media.storage_path = any(v_requested);

  if v_post.status = 'draft'::public.post_status then
    delete from public.post_media
    where post_id = p_post_id
      and storage_path = any(v_requested);
    v_removable := v_requested;
    v_protected := '{}'::text[];
  elsif v_post.status = 'published'::public.post_status then
    select coalesce(pg_catalog.array_agg(requested.path order by requested.path), '{}'::text[])
    into v_removable
    from pg_catalog.unnest(v_requested) as requested(path)
    where not (requested.path = any(v_referenced));
    v_protected := v_referenced;
  else
    v_removable := '{}'::text[];
    v_protected := v_requested;
  end if;

  foreach v_path in array v_removable
  loop
    select * into v_intent
    from public.media_upload_intents as intent
    where intent.uploader_id = v_actor_id
      and intent.purpose = 'post'
      and intent.target_id = p_post_id
      and intent.approved_path = v_path
      and intent.status in (
        'quarantine', 'scanning', 'approved', 'attached', 'rejected', 'expired'
      )
    for update;

    if found then
      if v_intent.status not in ('rejected', 'expired') then
        update public.media_upload_intents
        set status = 'expired',
            rejection_code = 'post_cleanup',
            attached_at = null,
            attached_entity_id = null,
            updated_at = pg_catalog.clock_timestamp()
        where id = v_intent.id;
      end if;

      insert into private.media_cleanup_items (
        intent_id, uploader_id, bucket_id, storage_path, reason
      )
      values
        (
          v_intent.id,
          v_actor_id,
          'community-media-quarantine',
          v_intent.quarantine_path,
          case when v_intent.status = 'rejected' then 'scan_rejected' else 'user_abandoned' end
        ),
        (
          v_intent.id,
          v_actor_id,
          v_intent.approved_bucket_id,
          v_intent.approved_path,
          case when v_intent.status = 'rejected' then 'scan_rejected' else 'user_abandoned' end
        )
      on conflict (bucket_id, storage_path) do nothing;
    else
      -- Rollout compatibility for draft objects created before upload intents:
      -- exact owned-post prefix validation plus absence from post_media makes
      -- this legacy approved path safe for the service worker to delete.
      insert into private.media_cleanup_items (
        intent_id, uploader_id, bucket_id, storage_path, reason
      )
      values (null, v_actor_id, 'community-media', v_path, 'user_abandoned')
      on conflict (bucket_id, storage_path) do nothing;
    end if;
  end loop;

  return pg_catalog.jsonb_build_object(
    'status', v_post.status,
    'removable_paths', pg_catalog.to_jsonb(v_removable),
    'protected_paths', pg_catalog.to_jsonb(v_protected),
    'cleanup_queued', pg_catalog.cardinality(v_removable) > 0
  );
end;
$$;

create or replace function public.service_claim_media_scan_intents(
  p_limit integer default 25
)
returns table (
  intent_id uuid,
  lease_token uuid,
  uploader_id uuid,
  organization_id uuid,
  purpose text,
  target_id uuid,
  kind public.media_kind,
  quarantine_bucket_id text,
  quarantine_path text,
  approved_bucket_id text,
  approved_path text,
  expected_mime_type text,
  expected_byte_size bigint,
  expires_at timestamptz,
  scan_attempts integer
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  perform private.require_service_role('claim_media_scan_intents');
  if p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_media_scan_claim_limit' using errcode = '22023';
  end if;

  -- A scanner invocation may disappear after claiming work. Re-open an
  -- expired ten-minute lease, but stop retrying an intent after five claims.
  -- The per-claim UUID fences a late/stale worker from recording a decision.
  update public.media_upload_intents as intent
  set status = case when intent.scan_attempts >= 5 then 'rejected' else 'quarantine' end,
      rejection_code = case
        when intent.scan_attempts >= 5 then 'scan_lease_exhausted'
        else null
      end,
      scan_next_attempt_at = v_now,
      scan_claimed_at = null,
      scan_lease_token = null,
      updated_at = v_now
  where intent.status = 'scanning'
    and intent.scan_claimed_at <= v_now - interval '10 minutes';

  update public.media_upload_intents as intent
  set status = 'expired',
      rejection_code = coalesce(intent.rejection_code, 'intent_expired'),
      scan_claimed_at = null,
      scan_lease_token = null,
      updated_at = v_now
  where intent.status = 'quarantine'
    and intent.expires_at <= v_now;

  return query
  with candidates as (
    select candidate.id
    from public.media_upload_intents as candidate
    where candidate.status = 'quarantine'
      and candidate.expires_at > v_now
      and candidate.scan_next_attempt_at <= v_now
      and exists (
        select 1
        from storage.objects as object
        where object.bucket_id = 'community-media-quarantine'
          and object.name = candidate.quarantine_path
          and object.owner_id = candidate.uploader_id::text
      )
    order by candidate.scan_next_attempt_at, candidate.created_at, candidate.id
    for update skip locked
    limit p_limit
  )
  update public.media_upload_intents as intent
  set status = 'scanning',
      scan_attempts = intent.scan_attempts + 1,
      scan_claimed_at = v_now,
      scan_lease_token = gen_random_uuid(),
      updated_at = v_now
  from candidates
  where intent.id = candidates.id
  returning
    intent.id,
    intent.scan_lease_token,
    intent.uploader_id,
    intent.organization_id,
    intent.purpose,
    intent.target_id,
    intent.kind,
    'community-media-quarantine'::text,
    intent.quarantine_path,
    intent.approved_bucket_id,
    intent.approved_path,
    intent.expected_mime_type,
    intent.expected_byte_size,
    intent.expires_at,
    intent.scan_attempts;
end;
$$;

create or replace function public.service_claim_media_cleanup_items(
  p_limit integer default 50
)
returns table (
  item_id uuid,
  intent_id uuid,
  bucket_id text,
  storage_path text,
  reason text,
  attempts integer
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_service_role('claim_media_cleanup_items');
  if p_limit < 1 or p_limit > 500 then
    raise exception 'invalid_media_cleanup_claim_limit' using errcode = '22023';
  end if;

  -- Storage deletion is idempotent. Reclaim work after a ten-minute worker
  -- lease and let the normal attempt ceiling move repeatedly failing paths to
  -- the dead-letter state.
  update private.media_cleanup_items as item
  set status = case when item.attempts >= 8 then 'dead' else 'failed' end,
      next_attempt_at = pg_catalog.clock_timestamp(),
      claimed_at = null,
      last_error_code = 'worker_lease_expired',
      updated_at = pg_catalog.clock_timestamp()
  where item.status = 'processing'
    and item.claimed_at <= pg_catalog.clock_timestamp() - interval '10 minutes';

  update public.media_upload_intents as intent
  set status = 'expired',
      rejection_code = coalesce(intent.rejection_code, 'intent_expired'),
      updated_at = pg_catalog.clock_timestamp()
  where intent.attached_at is null
    and intent.expires_at <= pg_catalog.clock_timestamp()
    and intent.status in ('quarantine', 'scanning', 'approved');

  insert into private.media_cleanup_items (
    intent_id, uploader_id, bucket_id, storage_path, reason
  )
  select
    intent.id,
    intent.uploader_id,
    'community-media-quarantine',
    intent.quarantine_path,
    case when intent.status = 'rejected' then 'scan_rejected' else 'intent_expired' end
  from public.media_upload_intents as intent
  where intent.status in ('expired', 'rejected')
    and intent.attached_at is null
  on conflict on constraint media_cleanup_items_bucket_id_storage_path_key do nothing;

  insert into private.media_cleanup_items (
    intent_id, uploader_id, bucket_id, storage_path, reason
  )
  select
    intent.id,
    intent.uploader_id,
    intent.approved_bucket_id,
    intent.approved_path,
    case when intent.status = 'rejected' then 'scan_rejected' else 'intent_expired' end
  from public.media_upload_intents as intent
  where intent.status in ('expired', 'rejected')
    and intent.attached_at is null
  on conflict on constraint media_cleanup_items_bucket_id_storage_path_key do nothing;

  return query
  with candidates as (
    select item.id
    from private.media_cleanup_items as item
    where item.status in ('pending', 'failed')
      and item.next_attempt_at <= pg_catalog.clock_timestamp()
    order by item.next_attempt_at, item.created_at, item.id
    for update skip locked
    limit p_limit
  )
  update private.media_cleanup_items as item
  set status = 'processing',
      attempts = item.attempts + 1,
      claimed_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.clock_timestamp()
  from candidates
  where item.id = candidates.id
  returning
    item.id,
    item.intent_id,
    item.bucket_id,
    item.storage_path,
    item.reason,
    item.attempts;
end;
$$;

create or replace function public.service_complete_media_cleanup_item(
  p_item_id uuid,
  p_status text,
  p_error_code text default null,
  p_retry_after_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_item private.media_cleanup_items%rowtype;
begin
  perform private.require_service_role('complete_media_cleanup_item');
  if p_status not in ('deleted', 'not_found', 'failed') then
    raise exception 'invalid_media_cleanup_status' using errcode = '22023';
  end if;
  if p_status = 'failed' and nullif(pg_catalog.btrim(p_error_code), '') is null then
    raise exception 'media_cleanup_error_code_required' using errcode = '23514';
  end if;
  if p_retry_after_seconds < 1 or p_retry_after_seconds > 86400 then
    raise exception 'invalid_media_cleanup_retry_delay' using errcode = '22023';
  end if;

  update private.media_cleanup_items
  set status = case
        when p_status = 'failed' and attempts >= 8 then 'dead'
        else p_status
      end,
      completed_at = case when p_status in ('deleted', 'not_found') then pg_catalog.clock_timestamp() else null end,
      next_attempt_at = case
        when p_status = 'failed' then pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => p_retry_after_seconds)
        else next_attempt_at
      end,
      last_error_code = case
        when p_status = 'failed' then pg_catalog.left(pg_catalog.btrim(p_error_code), 120)
        else null
      end,
      updated_at = pg_catalog.clock_timestamp()
  where id = p_item_id
    and status = 'processing'
  returning * into v_item;

  if not found then
    raise exception 'media_cleanup_item_not_processing' using errcode = '55000';
  end if;
  return pg_catalog.to_jsonb(v_item);
end;
$$;

create or replace function public.service_record_media_scan(
  p_intent_id uuid,
  p_lease_token uuid,
  p_scanner_version text,
  p_decision text,
  p_observed_mime_type text,
  p_observed_byte_size bigint,
  p_sha256 text,
  p_malware_scan_clean boolean,
  p_metadata_stripped boolean,
  p_width integer default null,
  p_height integer default null,
  p_duration_seconds numeric default null,
  p_codec text default null,
  p_rejection_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_intent public.media_upload_intents%rowtype;
  v_record public.media_scan_records%rowtype;
  v_approved boolean;
  v_expected_approved_mime text;
  v_normalized_codec text;
begin
  perform private.require_service_role('record_media_scan');
  select * into v_intent
  from public.media_upload_intents as intent
  where intent.id = p_intent_id
  for update;

  if not found then
    raise exception 'media_upload_intent_not_found' using errcode = 'P0002';
  end if;
  if v_intent.status <> 'scanning'
    or p_lease_token is null
    or v_intent.scan_lease_token is distinct from p_lease_token
    or v_intent.expires_at <= pg_catalog.clock_timestamp() then
    raise exception 'media_scan_lease_invalid' using errcode = '55000';
  end if;
  if nullif(pg_catalog.btrim(p_scanner_version), '') is null
    or pg_catalog.btrim(p_scanner_version) !~ '^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,79}$'
    or p_decision is null
    or p_decision not in ('approved', 'rejected')
    or nullif(pg_catalog.btrim(p_observed_mime_type), '') is null
    or pg_catalog.char_length(pg_catalog.btrim(p_observed_mime_type)) > 120
    or p_observed_byte_size is null
    or p_observed_byte_size <= 0
    or p_sha256 is null
    or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_media_scan_result' using errcode = '22023';
  end if;

  v_expected_approved_mime := case v_intent.expected_mime_type
    when 'image/heic' then 'image/jpeg'
    when 'image/heif' then 'image/jpeg'
    when 'video/quicktime' then 'video/mp4'
    else v_intent.expected_mime_type
  end;
  v_normalized_codec := pg_catalog.lower(pg_catalog.btrim(coalesce(p_codec, '')));

  v_approved := p_decision = 'approved'
    and coalesce(p_malware_scan_clean, false)
    and coalesce(p_metadata_stripped, false)
    and p_observed_mime_type = v_expected_approved_mime
    and p_observed_byte_size <= v_intent.expected_byte_size
    and (v_intent.purpose <> 'avatar' or p_observed_byte_size <= 5242880)
    and (
      (v_intent.kind = 'image'::public.media_kind
        and p_observed_mime_type in (
          'image/jpeg', 'image/png', 'image/webp', 'image/avif'
        )
        and p_observed_byte_size <= 15728640
        and p_width is not null
        and p_height is not null
        and p_width between 1 and 12000
        and p_height between 1 and 12000
        and p_width::bigint * p_height::bigint <= 50000000
        and p_duration_seconds is null
        and nullif(v_normalized_codec, '') is null)
      or
      (v_intent.kind = 'video'::public.media_kind
        and p_observed_mime_type in ('video/mp4', 'video/webm')
        and p_observed_byte_size <= 524288000
        and p_duration_seconds is not null
        and p_duration_seconds > 0
        and p_duration_seconds <= 7200
        and p_width is not null
        and p_height is not null
        and p_width between 1 and 4096
        and p_height between 1 and 4096
        and p_width::bigint * p_height::bigint <= 8847360
        and (
          (p_observed_mime_type = 'video/mp4'
            and v_normalized_codec in ('h264', 'avc', 'avc1', 'av1', 'av01'))
          or
          (p_observed_mime_type = 'video/webm'
            and v_normalized_codec in ('vp8', 'vp9', 'av1', 'av01'))
        ))
    );

  if p_decision = 'approved' and not v_approved then
    raise exception 'unsafe_media_cannot_be_approved' using errcode = '23514';
  end if;
  if not v_approved and nullif(pg_catalog.btrim(p_rejection_code), '') is null then
    raise exception 'media_rejection_code_required' using errcode = '23514';
  end if;

  insert into public.media_scan_records (
    intent_id,
    scanner_version,
    decision,
    observed_mime_type,
    observed_byte_size,
    sha256,
    width,
    height,
    duration_seconds,
    codec,
    metadata_stripped,
    malware_scan_clean,
    rejection_code
  )
  values (
    p_intent_id,
    pg_catalog.btrim(p_scanner_version),
    case when v_approved then 'approved' else 'rejected' end,
    p_observed_mime_type,
    p_observed_byte_size,
    p_sha256,
    p_width,
    p_height,
    p_duration_seconds,
    nullif(v_normalized_codec, ''),
    coalesce(p_metadata_stripped, false),
    coalesce(p_malware_scan_clean, false),
    case when v_approved then null else pg_catalog.left(pg_catalog.btrim(p_rejection_code), 120) end
  )
  returning * into v_record;

  -- For approved decisions, the Edge worker must finish copying/re-encoding the
  -- derivative into approved_path before calling this RPC.
  update public.media_upload_intents
  set status = case when v_approved then 'approved' else 'rejected' end,
      rejection_code = case when v_approved then null else v_record.rejection_code end,
      approved_mime_type = case when v_approved then p_observed_mime_type else null end,
      approved_byte_size = case when v_approved then p_observed_byte_size else null end,
      approved_width = case when v_approved then p_width else null end,
      approved_height = case when v_approved then p_height else null end,
      approved_duration_seconds = case when v_approved then p_duration_seconds else null end,
      approved_at = case when v_approved then pg_catalog.clock_timestamp() else null end,
      scan_claimed_at = null,
      scan_lease_token = null
  where id = p_intent_id
  returning * into v_intent;

  return pg_catalog.jsonb_build_object(
    'intent_id', v_intent.id,
    'scan_record_id', v_record.id,
    'status', v_intent.status,
    'approved_path', case when v_approved then v_intent.approved_path else null end,
    'rejection_code', v_intent.rejection_code
  );
end;
$$;

-- Block-aware conversations and approved-media messaging -------------------
create or replace function public.get_or_create_conversation(p_other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_membership public.organization_memberships%rowtype;
  v_low uuid;
  v_high uuid;
  v_conversation_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_other_user_id is null or p_other_user_id = v_actor_id then
    raise exception 'conversation_requires_another_user' using errcode = '23514';
  end if;
  if private.users_are_blocked(v_actor_id, p_other_user_id) then
    raise exception 'user_block_boundary' using errcode = '42501';
  end if;

  select * into v_actor_membership
  from public.organization_memberships
  where user_id = v_actor_id
    and status = 'active'::public.membership_status;

  if not found then
    raise exception 'active_membership_required' using errcode = '42501';
  end if;
  if not private.is_active_member(v_actor_membership.organization_id, p_other_user_id) then
    raise exception 'other_user_must_be_active_in_same_organization' using errcode = '42501';
  end if;

  if v_actor_id::text < p_other_user_id::text then
    v_low := v_actor_id;
    v_high := p_other_user_id;
  else
    v_low := p_other_user_id;
    v_high := v_actor_id;
  end if;

  insert into public.conversations (
    organization_id,
    participant_low,
    participant_high,
    created_by
  )
  values (
    v_actor_membership.organization_id,
    v_low,
    v_high,
    v_actor_id
  )
  on conflict (organization_id, participant_low, participant_high)
  do update set updated_at = excluded.updated_at
  returning id into v_conversation_id;

  insert into public.conversation_reads (conversation_id, user_id)
  values
    (v_conversation_id, v_low),
    (v_conversation_id, v_high)
  on conflict (conversation_id, user_id) do nothing;

  return v_conversation_id;
end;
$$;

create or replace function public.send_message(
  p_conversation_id uuid,
  p_kind public.message_kind,
  p_body text default null,
  p_media_path text default null,
  p_media_metadata jsonb default '{}'::jsonb,
  p_client_nonce uuid default gen_random_uuid()
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_conversation public.conversations%rowtype;
  v_recipient_id uuid;
  v_message_id uuid := gen_random_uuid();
  v_sender_name text;
  v_existing_message_id uuid;
  v_intent public.media_upload_intents%rowtype;
  v_media_metadata jsonb := '{}'::jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_client_nonce is null then
    raise exception 'client_nonce_required' using errcode = '23502';
  end if;

  select * into v_conversation
  from public.conversations
  where id = p_conversation_id
  for update;

  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if not private.can_access_conversation(p_conversation_id, v_actor_id) then
    raise exception 'conversation_access_denied' using errcode = '42501';
  end if;

  v_recipient_id := case
    when v_conversation.participant_low = v_actor_id then v_conversation.participant_high
    else v_conversation.participant_low
  end;
  if not exists (select 1 from public.profiles where id = v_recipient_id) then
    raise exception 'conversation_recipient_unavailable' using errcode = '41000';
  end if;
  if private.users_are_blocked(v_actor_id, v_recipient_id) then
    raise exception 'user_block_boundary' using errcode = '42501';
  end if;

  -- Idempotent retries return the original row without charging another rate
  -- limit or trying to claim an already attached media intent.
  select message.id into v_existing_message_id
  from public.messages as message
  where message.conversation_id = p_conversation_id
    and message.sender_id = v_actor_id
    and message.client_nonce = p_client_nonce;
  if v_existing_message_id is not null then
    return v_existing_message_id;
  end if;

  perform private.consume_rate_limit(v_actor_id, 'messages', 60, 60, 1);

  if p_kind = 'text'::public.message_kind then
    if nullif(pg_catalog.btrim(p_body), '') is null or p_media_path is not null then
      raise exception 'invalid_text_message' using errcode = '23514';
    end if;
    if char_length(p_body) > 10000 then
      raise exception 'message_body_too_long' using errcode = '22001';
    end if;
  else
    if p_media_path is null
      or not private.message_media_path_matches(p_conversation_id, p_media_path) then
      raise exception 'invalid_message_media_path' using errcode = '23514';
    end if;

    v_intent := private.claim_approved_media(
      'message',
      p_conversation_id,
      p_media_path,
      v_actor_id,
      v_message_id
    );
    if (p_kind = 'image'::public.message_kind and v_intent.kind <> 'image'::public.media_kind)
      or (p_kind = 'video'::public.message_kind and v_intent.kind <> 'video'::public.media_kind) then
      raise exception 'message_media_kind_mismatch' using errcode = '23514';
    end if;

    v_media_metadata := pg_catalog.jsonb_build_object(
      'mime_type', v_intent.approved_mime_type,
      'byte_size', v_intent.approved_byte_size,
      'width', v_intent.approved_width,
      'height', v_intent.approved_height,
      'duration_seconds', v_intent.approved_duration_seconds,
      'scan_approved', true,
      'upload_intent_id', v_intent.id
    );
  end if;

  insert into public.messages (
    id,
    conversation_id,
    sender_id,
    kind,
    body,
    media_path,
    media_metadata,
    client_nonce,
    created_at
  )
  values (
    v_message_id,
    p_conversation_id,
    v_actor_id,
    p_kind,
    nullif(pg_catalog.btrim(p_body), ''),
    p_media_path,
    v_media_metadata,
    p_client_nonce,
    v_now
  );

  update public.conversations
  set last_message_at = v_now
  where id = p_conversation_id;

  insert into public.conversation_reads (
    conversation_id,
    user_id,
    last_read_message_id,
    last_read_at
  )
  values (p_conversation_id, v_actor_id, v_message_id, v_now)
  on conflict (conversation_id, user_id)
  do update set
    last_read_message_id = excluded.last_read_message_id,
    last_read_at = excluded.last_read_at;

  select profile.display_name into v_sender_name
  from public.profiles as profile
  where profile.id = v_actor_id;

  insert into public.notifications (
    user_id, kind, title, body, entity_type, entity_id, metadata
  )
  values (
    v_recipient_id,
    'new_message'::public.notification_kind,
    coalesce(v_sender_name, '회원') || '님의 새 메시지',
    '새 메시지가 도착했습니다.',
    'conversation',
    p_conversation_id,
    pg_catalog.jsonb_build_object('message_id', v_message_id)
  );

  return v_message_id;
end;
$$;

-- Explicitly replace the legacy 008 batch entry point. Each validated item is
-- delegated to the current block-aware/rate-limited/approved-media send_message
-- implementation, so the batch remains atomic and cannot preserve forged
-- client media metadata.
create or replace function public.send_message_batch(
  p_conversation_id uuid,
  p_expected_sender_id uuid,
  p_messages jsonb
)
returns uuid[]
language plpgsql
security invoker
set search_path = pg_catalog
as $$
declare
  v_item jsonb;
  v_kind public.message_kind;
  v_kind_text text;
  v_nonce uuid;
  v_seen_nonces uuid[] := '{}'::uuid[];
  v_message_ids uuid[] := '{}'::uuid[];
  v_message_id uuid;
  v_item_count integer;
  v_key_count integer;
  v_text_count integer := 0;
  v_media_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_sender_id is null or auth.uid() <> p_expected_sender_id then
    raise exception 'message_sender_session_changed' using errcode = '42501';
  end if;
  if pg_catalog.jsonb_typeof(p_messages) is distinct from 'array' then
    raise exception 'invalid_message_batch_array' using errcode = '22023';
  end if;

  v_item_count := pg_catalog.jsonb_array_length(p_messages);
  if v_item_count < 1 or v_item_count > 4 then
    raise exception 'message_batch_size_out_of_range' using errcode = '22023';
  end if;

  for v_item in
    select batch.item
    from pg_catalog.jsonb_array_elements(p_messages)
      with ordinality as batch(item, position)
    order by batch.position
  loop
    if pg_catalog.jsonb_typeof(v_item) is distinct from 'object' then
      raise exception 'invalid_message_batch_item' using errcode = '22023';
    end if;
    select pg_catalog.count(*) into v_key_count
    from pg_catalog.jsonb_object_keys(v_item);
    if v_key_count <> 5
      or not (
        v_item ?& array[
          'kind', 'body', 'media_path', 'media_metadata', 'client_nonce'
        ]::text[]
      ) then
      raise exception 'invalid_message_batch_keys' using errcode = '22023';
    end if;

    if pg_catalog.jsonb_typeof(v_item -> 'kind') is distinct from 'string' then
      raise exception 'invalid_message_batch_kind' using errcode = '22023';
    end if;
    v_kind_text := v_item ->> 'kind';
    if v_kind_text not in ('text', 'image', 'video') then
      raise exception 'invalid_message_batch_kind' using errcode = '22023';
    end if;
    if pg_catalog.jsonb_typeof(v_item -> 'body') not in ('string', 'null') then
      raise exception 'invalid_message_batch_body' using errcode = '22023';
    end if;
    if pg_catalog.jsonb_typeof(v_item -> 'media_path') not in ('string', 'null') then
      raise exception 'invalid_message_batch_media_path' using errcode = '22023';
    end if;
    if pg_catalog.jsonb_typeof(v_item -> 'media_metadata') is distinct from 'object' then
      raise exception 'invalid_message_batch_media_metadata' using errcode = '22023';
    end if;
    if pg_catalog.jsonb_typeof(v_item -> 'client_nonce') is distinct from 'string' then
      raise exception 'invalid_message_batch_client_nonce' using errcode = '22023';
    end if;

    begin
      v_nonce := (v_item ->> 'client_nonce')::uuid;
    exception
      when invalid_text_representation then
        raise exception 'invalid_message_batch_client_nonce' using errcode = '22023';
    end;
    if v_nonce = any(v_seen_nonces) then
      raise exception 'duplicate_message_batch_client_nonce' using errcode = '23505';
    end if;
    v_seen_nonces := pg_catalog.array_append(v_seen_nonces, v_nonce);

    if v_kind_text = 'text' then
      v_text_count := v_text_count + 1;
    else
      v_media_count := v_media_count + 1;
    end if;
  end loop;

  if v_text_count > 1 then
    raise exception 'message_batch_text_limit_exceeded' using errcode = '22023';
  end if;
  if v_media_count > 3 then
    raise exception 'message_batch_media_limit_exceeded' using errcode = '22023';
  end if;

  for v_item in
    select batch.item
    from pg_catalog.jsonb_array_elements(p_messages)
      with ordinality as batch(item, position)
    order by batch.position
  loop
    v_kind := (v_item ->> 'kind')::public.message_kind;
    v_nonce := (v_item ->> 'client_nonce')::uuid;
    v_message_id := public.send_message(
      p_conversation_id,
      v_kind,
      v_item ->> 'body',
      v_item ->> 'media_path',
      v_item -> 'media_metadata',
      v_nonce
    );
    v_message_ids := pg_catalog.array_append(v_message_ids, v_message_id);
  end loop;
  return v_message_ids;
end;
$$;

comment on function public.send_message_batch(uuid, uuid, jsonb) is
  'Atomic 1-4 item composer batch; every item uses current block, rate, approved-media, nonce, and generic-notification enforcement.';

create or replace function public.get_conversation_summaries()
returns table (
  id uuid,
  organization_id uuid,
  participants jsonb,
  last_message jsonb,
  unread_count bigint
)
language sql
stable
security definer
set search_path = pg_catalog
as $$
  with actor as (
    select auth.uid() as user_id
  ),
  accessible_conversations as (
    select conversation.*
    from public.conversations as conversation
    cross join actor
    where actor.user_id is not null
      and actor.user_id in (conversation.participant_low, conversation.participant_high)
      and private.is_active_member(conversation.organization_id, actor.user_id)
  )
  select
    conversation.id,
    conversation.organization_id,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', conversation.participant_low,
        'display_name', coalesce(low_profile.display_name, '탈퇴한 회원'),
        'avatar_path', low_profile.avatar_path,
        'is_deleted', low_profile.id is null
      ),
      pg_catalog.jsonb_build_object(
        'id', conversation.participant_high,
        'display_name', coalesce(high_profile.display_name, '탈퇴한 회원'),
        'avatar_path', high_profile.avatar_path,
        'is_deleted', high_profile.id is null
      )
    ),
    case
      when latest.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', latest.id,
        'sender_id', latest.sender_id,
        'kind', latest.kind,
        'body', latest.body,
        'created_at', latest.created_at
      )
    end,
    coalesce(unread.unread_count, 0)::bigint
  from accessible_conversations as conversation
  cross join actor
  left join public.profiles as low_profile on low_profile.id = conversation.participant_low
  left join public.profiles as high_profile on high_profile.id = conversation.participant_high
  left join public.conversation_reads as reads
    on reads.conversation_id = conversation.id
   and reads.user_id = actor.user_id
  left join lateral (
    select message.id, message.sender_id, message.kind, message.body, message.created_at
    from public.messages as message
    where message.conversation_id = conversation.id
      and message.deleted_at is null
    order by message.created_at desc, message.id desc
    limit 1
  ) as latest on true
  left join lateral (
    select count(*)::bigint as unread_count
    from public.messages as unread_message
    where unread_message.conversation_id = conversation.id
      and unread_message.deleted_at is null
      and unread_message.sender_id is distinct from actor.user_id
      and unread_message.created_at > coalesce(reads.last_read_at, '-infinity'::timestamptz)
  ) as unread on true
  order by coalesce(latest.created_at, conversation.created_at) desc, conversation.id;
$$;

-- Generic push pipeline -----------------------------------------------------
create or replace function private.suppress_blocked_user_notification()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_source_user_id uuid;
begin
  if new.kind = 'new_message'::public.notification_kind then
    select message.sender_id into v_source_user_id
    from public.messages as message
    where message.id = private.try_uuid(new.metadata ->> 'message_id');
  elsif new.kind = 'post_comment'::public.notification_kind then
    select comment.author_id into v_source_user_id
    from public.comments as comment
    where comment.id = private.try_uuid(new.metadata ->> 'comment_id');
  end if;

  if private.user_has_blocked(new.user_id, v_source_user_id) then
    return null;
  end if;
  return new;
end;
$$;

create trigger notifications_suppress_blocked_source
before insert on public.notifications
for each row execute function private.suppress_blocked_user_notification();

create or replace function private.next_push_attempt_at(
  p_user_id uuid,
  p_now timestamptz default pg_catalog.clock_timestamp()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_preference public.notification_preferences%rowtype;
  v_local_now timestamp;
  v_local_target timestamp;
  v_local_time time;
begin
  select * into v_preference
  from public.notification_preferences
  where user_id = p_user_id;

  if not found
    or v_preference.quiet_hours_start is null
    or v_preference.quiet_hours_end is null
    or v_preference.quiet_hours_start = v_preference.quiet_hours_end then
    return p_now;
  end if;

  v_local_now := p_now at time zone v_preference.timezone;
  v_local_time := v_local_now::time;

  if v_preference.quiet_hours_start < v_preference.quiet_hours_end then
    if v_local_time >= v_preference.quiet_hours_start
      and v_local_time < v_preference.quiet_hours_end then
      v_local_target := v_local_now::date + v_preference.quiet_hours_end;
    else
      return p_now;
    end if;
  else
    if v_local_time >= v_preference.quiet_hours_start then
      v_local_target := (v_local_now::date + 1) + v_preference.quiet_hours_end;
    elsif v_local_time < v_preference.quiet_hours_end then
      v_local_target := v_local_now::date + v_preference.quiet_hours_end;
    else
      return p_now;
    end if;
  end if;

  return v_local_target at time zone v_preference.timezone;
end;
$$;

create or replace function private.enqueue_generic_push_notification()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_preferences public.notification_preferences%rowtype;
  v_allowed boolean := true;
  v_has_preferences boolean := false;
  v_event_code text;
  v_title text;
begin
  select * into v_preferences
  from public.notification_preferences
  where user_id = new.user_id;
  v_has_preferences := found;

  if v_has_preferences and not v_preferences.push_enabled then
    return new;
  end if;

  if new.entity_type in ('event', 'event_occurrence') then
    v_allowed := not v_has_preferences or v_preferences.events_enabled;
    v_event_code := 'community_notice';
    v_title := '새 알림이 있습니다';
  else
  case new.kind
    when 'new_message'::public.notification_kind then
      v_allowed := not v_has_preferences or v_preferences.messages_enabled;
      v_event_code := 'new_message';
      v_title := '새 메시지가 있습니다';
      if exists (
        select 1
        from public.conversation_preferences as preference
        where preference.user_id = new.user_id
          and preference.conversation_id = new.entity_id
          and (
            not preference.notifications_enabled
            or preference.muted_until > pg_catalog.clock_timestamp()
          )
      ) then
        v_allowed := false;
      end if;
    when 'post_comment'::public.notification_kind then
      v_allowed := not v_has_preferences or v_preferences.comments_enabled;
      v_event_code := 'post_comment';
      v_title := '새 알림이 있습니다';
    when 'application_submitted'::public.notification_kind,
         'application_approved'::public.notification_kind,
         'application_rejected'::public.notification_kind,
         'application_withdrawn'::public.notification_kind,
         'membership_changed'::public.notification_kind then
      v_allowed := not v_has_preferences or v_preferences.approvals_enabled;
      v_event_code := 'application_update';
      v_title := '새 알림이 있습니다';
    when 'admin_action'::public.notification_kind then
      v_event_code := 'security_notice';
      v_title := '보안 알림이 있습니다';
    else
      v_allowed := not v_has_preferences or v_preferences.community_enabled;
      v_event_code := 'community_notice';
      v_title := '새 알림이 있습니다';
  end case;
  end if;

  if not v_allowed then
    return new;
  end if;

  insert into private.push_outbox (
    user_id,
    event_code,
    entity_type,
    entity_id,
    title,
    body,
    collapse_key,
    idempotency_key,
    is_silent,
    next_attempt_at
  )
  values (
    new.user_id,
    v_event_code,
    coalesce(new.entity_type, 'notification'),
    new.entity_id,
    v_title,
    '앱에서 내용을 확인해 주세요.',
    case when new.entity_id is null then null else coalesce(new.entity_type, 'notification') || ':' || new.entity_id::text end,
    'notification:' || new.id::text,
    v_has_preferences and v_preferences.lock_screen_preview = 'hidden',
    private.next_push_attempt_at(new.user_id, pg_catalog.clock_timestamp())
  )
  on conflict (idempotency_key) do nothing;

  return new;
end;
$$;

create trigger notifications_enqueue_generic_push
after insert on public.notifications
for each row execute function private.enqueue_generic_push_notification();

create or replace function public.service_register_push_device(
  p_user_id uuid,
  p_installation_id uuid,
  p_platform text,
  p_token_ciphertext text,
  p_token_fingerprint text,
  p_encryption_key_version integer,
  p_app_version text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_device_id uuid;
  v_active_device_count integer;
  v_first_lock_key text;
  v_second_lock_key text;
begin
  perform private.require_service_role('register_push_device');
  if p_user_id is null
    or p_installation_id is null
    or p_platform is null
    or p_platform not in ('ios', 'android', 'web')
    or nullif(p_token_ciphertext, '') is null
    or p_token_fingerprint is null
    or p_token_fingerprint !~ '^[0-9a-f]{64}$'
    or p_encryption_key_version is null
    or p_encryption_key_version < 1 then
    raise exception 'invalid_push_device_registration' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = p_user_id and deactivated_at is null
  ) then
    raise exception 'push_device_user_not_active' using errcode = 'P0002';
  end if;

  perform private.consume_rate_limit(p_user_id, 'push_registration', 20, 600, 1);
  v_first_lock_key := least(p_installation_id::text, p_token_fingerprint);
  v_second_lock_key := greatest(p_installation_id::text, p_token_fingerprint);
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('push-registration:' || v_first_lock_key, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('push-registration:' || v_second_lock_key, 0)
  );

  -- A physical installation/provider token belongs to exactly one signed-in
  -- account. Removing an older binding also cascades its pending deliveries,
  -- so an old account cannot notify a device after logout/account switching.
  delete from public.push_devices as device
  where (
      device.installation_id = p_installation_id
      or device.token_fingerprint = p_token_fingerprint
    )
    and not (
      device.user_id = p_user_id
      and device.installation_id = p_installation_id
    );

  select count(*)::integer into v_active_device_count
  from public.push_devices as device
  where device.user_id = p_user_id
    and device.disabled_at is null
    and device.installation_id <> p_installation_id;
  if v_active_device_count >= 10 then
    raise exception 'active_push_device_limit_exceeded' using errcode = '54000';
  end if;

  insert into public.push_devices (
    user_id,
    installation_id,
    platform,
    token_fingerprint,
    app_version,
    last_seen_at,
    disabled_at,
    disabled_reason
  )
  values (
    p_user_id,
    p_installation_id,
    p_platform,
    p_token_fingerprint,
    nullif(pg_catalog.btrim(p_app_version), ''),
    pg_catalog.clock_timestamp(),
    null,
    null
  )
  on conflict (user_id, installation_id)
  do update set
    platform = excluded.platform,
    token_fingerprint = excluded.token_fingerprint,
    app_version = excluded.app_version,
    last_seen_at = excluded.last_seen_at,
    disabled_at = null,
    disabled_reason = null
  returning id into v_device_id;

  insert into private.push_device_secrets (
    device_id,
    token_ciphertext,
    encryption_key_version
  )
  values (
    v_device_id,
    p_token_ciphertext,
    p_encryption_key_version::smallint
  )
  on conflict (device_id)
  do update set
    token_ciphertext = excluded.token_ciphertext,
    encryption_key_version = excluded.encryption_key_version,
    rotated_at = pg_catalog.clock_timestamp();

  return v_device_id;
end;
$$;

create or replace function public.touch_my_push_device(
  p_device_id uuid,
  p_app_version text default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  update public.push_devices
  set last_seen_at = pg_catalog.clock_timestamp(),
      app_version = coalesce(nullif(pg_catalog.btrim(p_app_version), ''), app_version)
  where id = p_device_id
    and user_id = v_actor_id
    and disabled_at is null;
  return found;
end;
$$;

create or replace function public.service_claim_push_jobs(
  p_limit integer default 50
)
returns table (
  delivery_id uuid,
  job_id uuid,
  device_id uuid,
  platform text,
  token_ciphertext text,
  encryption_key_version smallint,
  event_code text,
  entity_type text,
  entity_id uuid,
  title text,
  body text,
  is_silent boolean,
  collapse_key text,
  delivery_attempts integer
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_service_role('claim_push_jobs');
  if p_limit < 1 or p_limit > 500 then
    raise exception 'invalid_push_claim_limit' using errcode = '22023';
  end if;

  -- Edge invocations can time out after claiming. A bounded ten-minute lease
  -- makes the same per-device delivery retryable without duplicating already
  -- delivered sibling devices.
  update private.push_deliveries as delivery
  set status = case when delivery.attempts >= 8 then 'dead' else 'failed' end,
      claimed_at = null,
      next_attempt_at = pg_catalog.clock_timestamp(),
      last_error_code = 'delivery_lease_expired',
      updated_at = pg_catalog.clock_timestamp()
  where delivery.status = 'processing'
    and delivery.claimed_at < pg_catalog.clock_timestamp() - interval '10 minutes';

  update private.push_outbox as job
  set status = case
        when exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status in ('pending', 'failed')
        ) then 'failed'
        when exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status = 'processing'
        ) then 'processing'
        when exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status = 'delivered'
        ) then 'delivered'
        else 'dead'
      end,
      claimed_at = case
        when exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status = 'processing'
        ) then job.claimed_at
        else null
      end,
      last_error_code = case
        when exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.last_error_code = 'delivery_lease_expired'
        ) then 'delivery_lease_expired'
        else job.last_error_code
      end,
      updated_at = pg_catalog.clock_timestamp()
  where job.status = 'processing'
    and job.claimed_at < pg_catalog.clock_timestamp() - interval '10 minutes';

  insert into private.push_deliveries (job_id, device_id, next_attempt_at)
  select job.id, device.id, job.next_attempt_at
  from private.push_outbox as job
  join public.push_devices as device
    on device.user_id = job.user_id
   and device.disabled_at is null
  join private.push_device_secrets as secret on secret.device_id = device.id
  where job.status in ('pending', 'failed', 'processing')
    and job.next_attempt_at <= pg_catalog.clock_timestamp()
  on conflict on constraint push_deliveries_job_id_device_id_key do nothing;

  update private.push_outbox as job
  set status = 'dead',
      last_error_code = 'no_active_device',
      updated_at = pg_catalog.clock_timestamp()
  where job.status in ('pending', 'failed')
    and job.next_attempt_at <= pg_catalog.clock_timestamp()
    and not exists (
      select 1
      from private.push_deliveries as delivery
      where delivery.job_id = job.id
    );

  return query
  with candidates as (
    select delivery.id
    from private.push_deliveries as delivery
    join private.push_outbox as job on job.id = delivery.job_id
    where delivery.status in ('pending', 'failed')
      and delivery.next_attempt_at <= pg_catalog.clock_timestamp()
      and job.status in ('pending', 'failed', 'processing')
    order by delivery.next_attempt_at, delivery.created_at, delivery.id
    for update of delivery skip locked
    limit p_limit
  ), claimed as (
    update private.push_deliveries as delivery
    set status = 'processing',
        claimed_at = pg_catalog.clock_timestamp(),
        attempts = delivery.attempts + 1,
        updated_at = pg_catalog.clock_timestamp()
    from candidates
    where delivery.id = candidates.id
    returning delivery.*
  ), parent_updates as (
    update private.push_outbox as job
    set status = 'processing',
        claimed_at = coalesce(job.claimed_at, pg_catalog.clock_timestamp()),
        updated_at = pg_catalog.clock_timestamp()
    where job.id in (select distinct claimed.job_id from claimed)
    returning job.*
  )
  select
    claimed.id,
    job.id,
    device.id,
    device.platform,
    secret.token_ciphertext,
    secret.encryption_key_version,
    job.event_code,
    job.entity_type,
    job.entity_id,
    job.title,
    job.body,
    job.is_silent,
    job.collapse_key,
    claimed.attempts
  from claimed
  join parent_updates as job on job.id = claimed.job_id
  join public.push_devices as device on device.id = claimed.device_id
  join private.push_device_secrets as secret on secret.device_id = device.id
  order by claimed.created_at, claimed.id;
end;
$$;

create or replace function public.service_complete_push_delivery(
  p_delivery_id uuid,
  p_success boolean,
  p_invalid_token boolean default false,
  p_error_code text default null,
  p_retry_after_seconds integer default 60
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_service_role('complete_push_delivery');
  if not coalesce(p_success, false)
    and nullif(pg_catalog.btrim(p_error_code), '') is null then
    raise exception 'push_error_code_required' using errcode = '23514';
  end if;
  if p_retry_after_seconds < 1 or p_retry_after_seconds > 86400 then
    raise exception 'invalid_push_retry_delay' using errcode = '22023';
  end if;

  update private.push_deliveries
  set status = case
        when p_success then 'delivered'
        when coalesce(p_invalid_token, false) then 'dead'
        when attempts >= 8 then 'dead'
        else 'failed'
      end,
      delivered_at = case when p_success then pg_catalog.clock_timestamp() else null end,
      next_attempt_at = case
        when p_success then next_attempt_at
        else pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => p_retry_after_seconds)
      end,
      last_error_code = case
        when p_success then null
        else pg_catalog.left(pg_catalog.btrim(p_error_code), 120)
      end,
      updated_at = pg_catalog.clock_timestamp()
  where id = p_delivery_id
    and status = 'processing';
  if not found then
    raise exception 'push_delivery_not_processing' using errcode = '55000';
  end if;

  if coalesce(p_invalid_token, false) then
    update public.push_devices as device
    set disabled_at = pg_catalog.clock_timestamp(),
        disabled_reason = 'provider_token_invalid'
    from private.push_deliveries as delivery
    where delivery.id = p_delivery_id
      and device.id = delivery.device_id;
  end if;

  update private.push_outbox as job
  set status = case
        when not exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status not in ('delivered', 'dead')
        ) and exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status = 'delivered'
        ) then 'delivered'
        when not exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status not in ('delivered', 'dead')
        ) then 'dead'
        when exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status = 'processing'
        ) then 'processing'
        else 'failed'
      end,
      delivered_at = case
        when not exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status not in ('delivered', 'dead')
        ) and exists (
          select 1 from private.push_deliveries as delivery
          where delivery.job_id = job.id
            and delivery.status = 'delivered'
        ) then pg_catalog.clock_timestamp()
        else null
      end,
      next_attempt_at = coalesce((
        select min(delivery.next_attempt_at)
        from private.push_deliveries as delivery
        where delivery.job_id = job.id
          and delivery.status in ('pending', 'failed')
      ), job.next_attempt_at),
      last_error_code = case when p_success then null else pg_catalog.left(pg_catalog.btrim(p_error_code), 120) end,
      updated_at = pg_catalog.clock_timestamp()
  where job.id = (
    select delivery.job_id
    from private.push_deliveries as delivery
    where delivery.id = p_delivery_id
  );
end;
$$;

-- Stable frontend naming contracts. The older upsert_* names remain as
-- implementation helpers but are not granted to clients below.
create or replace function public.save_my_privacy_preferences(
  p_sensitive_affiliation_consent_version text,
  p_community_policy_version text,
  p_avatar_visible boolean,
  p_church_title_visible boolean,
  p_email_visible boolean,
  p_bio_visible boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_push_enabled boolean;
  v_analytics_opt_in boolean;
  v_directory_visibility text;
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select preference.push_enabled into v_push_enabled
  from public.notification_preferences as preference
  where preference.user_id = v_actor_id;

  select preference.analytics_opt_in into v_analytics_opt_in
  from public.privacy_preferences as preference
  where preference.user_id = v_actor_id;

  v_directory_visibility := case
    when coalesce(p_avatar_visible, false)
      or coalesce(p_email_visible, false)
      or coalesce(p_bio_visible, false) then 'church_profile'
    when coalesce(p_church_title_visible, false) then 'name_only'
    else 'private'
  end;

  v_result := public.upsert_my_privacy_preferences(
    v_directory_visibility,
    coalesce(v_analytics_opt_in, false),
    coalesce(v_push_enabled, true),
    p_sensitive_affiliation_consent_version,
    p_community_policy_version
  );

  update public.privacy_preferences
  set avatar_visible = coalesce(p_avatar_visible, false),
      church_title_visible = coalesce(p_church_title_visible, false),
      email_visible = coalesce(p_email_visible, false),
      bio_visible = coalesce(p_bio_visible, false)
  where user_id = v_actor_id;

  return v_result || pg_catalog.jsonb_build_object(
    'directory_visibility', pg_catalog.jsonb_build_object(
      'avatar', coalesce(p_avatar_visible, false),
      'church_title', coalesce(p_church_title_visible, false),
      'email', coalesce(p_email_visible, false),
      'bio', coalesce(p_bio_visible, false)
    )
  );
end;
$$;

create or replace function public.save_my_notification_preferences(
  p_push_enabled boolean,
  p_approvals boolean,
  p_posts boolean,
  p_comments boolean,
  p_chats boolean,
  p_governance boolean,
  p_events boolean,
  p_quiet_hours_enabled boolean,
  p_quiet_hours_start text,
  p_quiet_hours_end text,
  p_time_zone text,
  p_lock_screen_preview text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_result public.notification_preferences%rowtype;
  v_quiet_start time;
  v_quiet_end time;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if coalesce(p_quiet_hours_enabled, false) then
    if coalesce(p_quiet_hours_start, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or coalesce(p_quiet_hours_end, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'invalid_quiet_hours' using errcode = '23514';
    end if;
    v_quiet_start := p_quiet_hours_start::time;
    v_quiet_end := p_quiet_hours_end::time;
  end if;
  if not exists (
    select 1 from pg_catalog.pg_timezone_names
    where name = p_time_zone
  ) then
    raise exception 'invalid_notification_timezone' using errcode = '22023';
  end if;
  if p_lock_screen_preview not in ('generic', 'hidden') then
    raise exception 'invalid_lock_screen_preview' using errcode = '22023';
  end if;

  insert into public.notification_preferences (
    user_id,
    push_enabled,
    messages_enabled,
    posts_enabled,
    comments_enabled,
    approvals_enabled,
    governance_enabled,
    events_enabled,
    community_enabled,
    quiet_hours_start,
    quiet_hours_end,
    timezone,
    lock_screen_preview
  )
  values (
    v_actor_id,
    coalesce(p_push_enabled, false),
    coalesce(p_chats, false),
    coalesce(p_posts, false),
    coalesce(p_comments, false),
    coalesce(p_approvals, false),
    coalesce(p_governance, false),
    coalesce(p_events, false),
    coalesce(p_posts, false) or coalesce(p_governance, false) or coalesce(p_events, false),
    v_quiet_start,
    v_quiet_end,
    p_time_zone,
    p_lock_screen_preview
  )
  on conflict (user_id)
  do update set
    push_enabled = excluded.push_enabled,
    messages_enabled = excluded.messages_enabled,
    posts_enabled = excluded.posts_enabled,
    comments_enabled = excluded.comments_enabled,
    approvals_enabled = excluded.approvals_enabled,
    governance_enabled = excluded.governance_enabled,
    events_enabled = excluded.events_enabled,
    community_enabled = excluded.community_enabled,
    quiet_hours_start = excluded.quiet_hours_start,
    quiet_hours_end = excluded.quiet_hours_end,
    timezone = excluded.timezone,
    lock_screen_preview = excluded.lock_screen_preview
  returning * into v_result;

  perform private.write_audit(
    v_actor_id,
    'privacy.notification_preferences_updated',
    'profile',
    v_actor_id,
    null,
    v_actor_id,
    pg_catalog.jsonb_build_object(
      'push_enabled', v_result.push_enabled,
      'approvals', v_result.approvals_enabled,
      'posts', v_result.posts_enabled,
      'comments_enabled', v_result.comments_enabled,
      'chats', v_result.messages_enabled,
      'governance', v_result.governance_enabled,
      'events', v_result.events_enabled,
      'quiet_hours_enabled', v_result.quiet_hours_start is not null,
      'timezone', v_result.timezone
    )
  );

  return pg_catalog.to_jsonb(v_result);
end;
$$;

create or replace function public.set_conversation_muted(
  p_conversation_id uuid,
  p_muted boolean
)
returns jsonb
language sql
security definer
set search_path = pg_catalog
as $$
  select public.upsert_conversation_preference(
    p_conversation_id,
    not coalesce(p_muted, false),
    null,
    false
  );
$$;

create or replace function public.request_account_deletion(
  p_confirmation_text text,
  p_reason text,
  p_reauth_nonce text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if p_confirmation_text <> '계정 삭제' then
    raise exception 'account_deletion_confirmation_mismatch' using errcode = '23514';
  end if;
  -- p_reauth_nonce is transport compatibility only and is intentionally not
  -- trusted. The called function verifies the PostgREST JWT is AAL2 at the DB
  -- boundary; Edge should still consume a server-issued one-time proof when used.
  if p_reauth_nonce is not null then
    null;
  end if;
  return public.request_account_deletion(p_reason);
end;
$$;

-- Function exposure and future-object hardening -----------------------------
revoke all on function private.require_aal2(text) from public, anon, authenticated;
revoke all on function private.require_service_role(text) from public, anon, authenticated;
revoke all on function private.users_are_blocked(uuid, uuid) from public, anon, authenticated;
revoke all on function private.user_has_blocked(uuid, uuid) from public, anon, authenticated;
revoke all on function private.can_moderate_organization(uuid, uuid) from public, anon, authenticated;
revoke all on function private.consume_rate_limit(uuid, text, integer, integer, integer) from public, anon, authenticated;
revoke all on function private.can_write_quarantine_media(text, uuid) from public, anon, authenticated;
revoke all on function private.claim_approved_media(text, uuid, text, uuid, uuid) from public, anon, authenticated;
revoke all on function private.enforce_high_risk_aal2() from public, anon, authenticated;
revoke all on function private.enforce_leadership_review_aal2() from public, anon, authenticated;
revoke all on function private.enforce_conversation_block_boundary() from public, anon, authenticated;
revoke all on function private.enforce_message_block_boundary() from public, anon, authenticated;
revoke all on function private.enforce_content_rate_limit() from public, anon, authenticated;
revoke all on function private.enforce_approved_post_media() from public, anon, authenticated;
revoke all on function private.enforce_approved_profile_avatar() from public, anon, authenticated;
revoke all on function private.enforce_approved_organization_hero() from public, anon, authenticated;
revoke all on function private.enforce_approved_application_evidence() from public, anon, authenticated;
revoke all on function private.enforce_moderation_action_aal2() from public, anon, authenticated;
revoke all on function private.suppress_blocked_user_notification() from public, anon, authenticated;
revoke all on function private.next_push_attempt_at(uuid, timestamptz) from public, anon, authenticated;
revoke all on function private.enqueue_generic_push_notification() from public, anon, authenticated;

grant execute on function private.can_moderate_organization(uuid, uuid) to authenticated;
grant execute on function private.can_write_quarantine_media(text, uuid) to authenticated;
grant execute on function private.user_has_blocked(uuid, uuid) to authenticated;

revoke all on function public.list_public_organization_directory(text) from public, anon, authenticated;
revoke all on function public.block_user(uuid, text) from public, anon, authenticated;
revoke all on function public.unblock_user(uuid) from public, anon, authenticated;
revoke all on function public.upsert_my_privacy_preferences(text, boolean, boolean, text, text) from public, anon, authenticated;
revoke all on function public.save_my_privacy_preferences(text, text, boolean, boolean, boolean, boolean) from public, anon, authenticated;
revoke all on function public.save_my_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, text, text, text, text) from public, anon, authenticated;
revoke all on function public.upsert_conversation_preference(uuid, boolean, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.set_conversation_muted(uuid, boolean) from public, anon, authenticated;
revoke all on function public.remove_my_push_device(uuid) from public, anon, authenticated;
revoke all on function public.remove_my_push_device_by_installation(uuid) from public, anon, authenticated;
revoke all on function public.touch_my_push_device(uuid, text) from public, anon, authenticated;
revoke all on function public.get_my_safety_privacy_state() from public, anon, authenticated;
revoke all on function public.list_my_security_activity(integer) from public, anon, authenticated;
revoke all on function public.request_account_deletion(text) from public, anon, authenticated;
revoke all on function public.request_account_deletion(text, text, text) from public, anon, authenticated;
revoke all on function public.request_account_deletion_verified(uuid, text, text) from public, anon, authenticated;
revoke all on function public.cancel_account_deletion() from public, anon, authenticated;
revoke all on function public.create_content_report(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.list_moderation_reports(text, integer) from public, anon, authenticated;
revoke all on function public.resolve_content_report(uuid, text, text) from public, anon, authenticated;
revoke all on function public.create_media_upload_intent(text, uuid, public.media_kind, text, bigint) from public, anon, authenticated;
revoke all on function public.abandon_media_upload_intents(text[]) from public, anon, authenticated;
revoke all on function public.prepare_post_media_cleanup(uuid, uuid, text[]) from public, anon, authenticated;
revoke all on function public.get_or_create_conversation(uuid) from public, anon, authenticated;
revoke all on function public.send_message(uuid, public.message_kind, text, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.send_message_batch(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.get_conversation_summaries() from public, anon, authenticated;

revoke all on function public.service_claim_due_account_deletions(integer) from public, anon, authenticated;
revoke all on function public.service_mark_account_cleanup_item(uuid, text, text) from public, anon, authenticated;
revoke all on function public.service_finalize_account_anonymization(uuid) from public, anon, authenticated;
revoke all on function public.service_claim_pending_identity_deletions(integer) from public, anon, authenticated;
revoke all on function public.service_complete_account_deletion(uuid) from public, anon, authenticated;
revoke all on function public.service_fail_account_deletion(uuid, text) from public, anon, authenticated;
revoke all on function public.service_claim_media_scan_intents(integer) from public, anon, authenticated;
revoke all on function public.service_record_media_scan(uuid, uuid, text, text, text, bigint, text, boolean, boolean, integer, integer, numeric, text, text) from public, anon, authenticated;
revoke all on function public.service_claim_media_cleanup_items(integer) from public, anon, authenticated;
revoke all on function public.service_complete_media_cleanup_item(uuid, text, text, integer) from public, anon, authenticated;
revoke all on function public.service_register_push_device(uuid, uuid, text, text, text, integer, text) from public, anon, authenticated;
revoke all on function public.service_claim_push_jobs(integer) from public, anon, authenticated;
revoke all on function public.service_complete_push_delivery(uuid, boolean, boolean, text, integer) from public, anon, authenticated;

grant execute on function public.list_public_organization_directory(text) to authenticated;
grant execute on function public.block_user(uuid, text) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
grant execute on function public.save_my_privacy_preferences(text, text, boolean, boolean, boolean, boolean) to authenticated;
grant execute on function public.save_my_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, text, text, text, text) to authenticated;
grant execute on function public.set_conversation_muted(uuid, boolean) to authenticated;
grant execute on function public.remove_my_push_device(uuid) to authenticated;
grant execute on function public.remove_my_push_device_by_installation(uuid) to authenticated;
grant execute on function public.touch_my_push_device(uuid, text) to authenticated;
grant execute on function public.get_my_safety_privacy_state() to authenticated;
grant execute on function public.list_my_security_activity(integer) to authenticated;
grant execute on function public.request_account_deletion(text, text, text) to authenticated;
grant execute on function public.cancel_account_deletion() to authenticated;
grant execute on function public.create_content_report(text, uuid, text, text) to authenticated;
grant execute on function public.list_moderation_reports(text, integer) to authenticated;
grant execute on function public.resolve_content_report(uuid, text, text) to authenticated;
grant execute on function public.create_media_upload_intent(text, uuid, public.media_kind, text, bigint) to authenticated;
grant execute on function public.abandon_media_upload_intents(text[]) to authenticated;
grant execute on function public.prepare_post_media_cleanup(uuid, uuid, text[]) to authenticated;
grant execute on function public.get_or_create_conversation(uuid) to authenticated;
grant execute on function public.send_message(uuid, public.message_kind, text, text, jsonb, uuid) to authenticated;
grant execute on function public.send_message_batch(uuid, uuid, jsonb) to authenticated;
grant execute on function public.get_conversation_summaries() to authenticated;

grant execute on function public.service_claim_due_account_deletions(integer) to service_role;
grant execute on function public.request_account_deletion_verified(uuid, text, text) to service_role;
grant execute on function public.service_mark_account_cleanup_item(uuid, text, text) to service_role;
grant execute on function public.service_finalize_account_anonymization(uuid) to service_role;
grant execute on function public.service_claim_pending_identity_deletions(integer) to service_role;
grant execute on function public.service_complete_account_deletion(uuid) to service_role;
grant execute on function public.service_fail_account_deletion(uuid, text) to service_role;
grant execute on function public.service_claim_media_scan_intents(integer) to service_role;
grant execute on function public.service_record_media_scan(uuid, uuid, text, text, text, bigint, text, boolean, boolean, integer, integer, numeric, text, text) to service_role;
grant execute on function public.service_claim_media_cleanup_items(integer) to service_role;
grant execute on function public.service_complete_media_cleanup_item(uuid, text, text, integer) to service_role;
grant execute on function public.service_register_push_device(uuid, uuid, text, text, text, integer, text) to service_role;
grant execute on function public.service_claim_push_jobs(integer) to service_role;
grant execute on function public.service_complete_push_delivery(uuid, boolean, boolean, text, integer) to service_role;

-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default. Future
-- migrations must opt clients in explicitly, and new tables/sequences start
-- closed to browser roles.
alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private
  revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public
  revoke all on tables from public, anon, authenticated;
alter default privileges in schema private
  revoke all on tables from public, anon, authenticated;
alter default privileges in schema public
  revoke all on sequences from public, anon, authenticated;
alter default privileges in schema private
  revoke all on sequences from public, anon, authenticated;

comment on function public.save_my_privacy_preferences(text, text, boolean, boolean, boolean, boolean) is
  'Records exact current required consent versions and saves directory/analytics preferences for auth.uid().';
comment on function public.save_my_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, text, text, text, text) is
  'Saves self-only notification categories and quiet hours; push payload content remains generic regardless of preference.';
comment on function public.set_conversation_muted(uuid, boolean) is
  'Sets or clears a self-only conversation mute after participant authorization.';
comment on function public.request_account_deletion(text, text, text) is
  'AAL2-protected deletion request with explicit Korean confirmation and a 14-day cancellation grace period.';
comment on function public.request_account_deletion_verified(uuid, text, text) is
  'Service-role-only deletion request for an Edge Function that has independently reauthenticated the exact GoTrue user.';
comment on function public.service_claim_due_account_deletions(integer) is
  'Edge-only claim that freezes authority and snapshots every known Storage path before Auth identity deletion.';
comment on function public.service_finalize_account_anonymization(uuid) is
  'Edge-only finalizer after Storage cleanup; returns the Auth user ID for Admin API deletion without cascading conversations.';
comment on function public.service_claim_pending_identity_deletions(integer) is
  'Service-only recoverable Auth deletion claim; a null user_id means identity deletion succeeded and completion should be recorded.';
comment on function public.create_content_report(text, uuid, text, text) is
  'Creates a rate-limited report with a server-derived immutable evidence snapshot.';
comment on function public.list_moderation_reports(text, integer) is
  'Lists reports only for platform admins or active minister/executive moderators in the exact reported church.';
comment on function public.resolve_content_report(uuid, text, text) is
  'Resolves one exact-scope report; sanctions require AAL2 and reuse bounded membership authorization.';
comment on function public.service_claim_media_scan_intents(integer) is
  'Service-only atomic quarantine claim with a ten-minute lease, bounded retries, and a fencing token.';
comment on function public.service_record_media_scan(uuid, uuid, text, text, text, bigint, text, boolean, boolean, integer, integer, numeric, text, text) is
  'Edge-only fenced scanner decision. Approved bytes must be sanitized/re-encoded and copied to approved_path before completion.';
comment on function public.abandon_media_upload_intents(text[]) is
  'Marks auth.uid-owned unattached upload intents expired and queues quarantine plus approved paths for service cleanup.';
comment on function public.prepare_post_media_cleanup(uuid, uuid, text[]) is
  'Detaches owned draft media atomically and queues both quarantine and approved objects; published referenced paths remain protected.';
comment on function public.service_claim_media_cleanup_items(integer) is
  'Service-only worker claim that also discovers expired/rejected unattached upload intents.';
comment on function public.service_complete_media_cleanup_item(uuid, text, text, integer) is
  'Service-only idempotent outcome recorder for one claimed Storage cleanup item.';
comment on function public.service_register_push_device(uuid, uuid, text, text, text, integer, text) is
  'Edge-only encrypted push registration; an installation/token is rebound atomically to one user and active devices are capped at ten.';
comment on function public.remove_my_push_device_by_installation(uuid) is
  'Self-only logout/account-switch detach by installation UUID; invoke before clearing the Auth session.';
