-- Jaegun community: core data model
-- All user identities are anchored to Supabase Auth. No people are seeded.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.organization_status as enum (
  'seeded_unclaimed',
  'active',
  'suspended',
  'archived'
);

create type public.app_role as enum (
  'member',
  'minister',
  'executive'
);

create type public.membership_status as enum (
  'active',
  'suspended',
  'revoked'
);

create type public.application_status as enum (
  'pending',
  'approved',
  'rejected',
  'withdrawn'
);

create type public.review_decision as enum (
  'approve',
  'reject'
);

create type public.post_status as enum (
  'draft',
  'published',
  'hidden',
  'deleted'
);

create type public.comment_status as enum (
  'active',
  'hidden',
  'deleted'
);

create type public.media_kind as enum (
  'image',
  'video'
);

create type public.message_kind as enum (
  'text',
  'image',
  'video'
);

create type public.notification_kind as enum (
  'application_submitted',
  'application_approved',
  'application_rejected',
  'application_withdrawn',
  'membership_changed',
  'new_message',
  'post_comment',
  'admin_action'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  bio text check (bio is null or char_length(bio) <= 500),
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deactivated_at timestamptz
);

comment on table public.profiles is
  'Private application profile. Visibility is limited to the user, legitimate approvers, same-organization active members, and platform admins.';

create table public.platform_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.profiles(id) on delete set null,
  note text check (note is null or char_length(note) <= 500)
);

comment on table public.platform_admins is
  'Highest-trust operators. Bootstrap the first row only from the SQL editor/service role; never from a client.';

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  source_name text not null,
  display_name text not null,
  presbytery text not null,
  status public.organization_status not null default 'seeded_unclaimed',
  description text check (description is null or char_length(description) <= 5000),
  location_text text check (location_text is null or char_length(location_text) <= 500),
  contact_phone text check (contact_phone is null or char_length(contact_phone) <= 40),
  website_url text check (website_url is null or char_length(website_url) <= 500),
  worship_schedule jsonb not null default '[]'::jsonb,
  hero_path text,
  seed_source text,
  seed_metadata jsonb not null default '{}'::jsonb,
  seeded_at timestamptz,
  claimed_at timestamptz,
  claimed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_seed_state_check check (
    (status <> 'seeded_unclaimed')
    or (claimed_at is null and claimed_by is null)
  )
);

create index organizations_presbytery_display_idx
  on public.organizations (presbytery, display_name);
create index organizations_status_idx
  on public.organizations (status);

create table public.membership_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  requested_role public.app_role not null,
  status public.application_status not null default 'pending',
  applicant_note text check (applicant_note is null or char_length(applicant_note) <= 2000),
  evidence_path text,
  review_reason text check (review_reason is null or char_length(review_reason) <= 2000),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint membership_applications_review_state_check check (
    (status = 'pending' and reviewed_at is null and reviewed_by is null)
    or (status = 'withdrawn' and reviewed_at is not null)
    or (status in ('approved', 'rejected') and reviewed_at is not null)
  ),
  constraint membership_applications_rejection_reason_check check (
    status <> 'rejected' or nullif(btrim(review_reason), '') is not null
  )
);

create unique index membership_applications_one_pending_per_user_idx
  on public.membership_applications (user_id)
  where status = 'pending';
create index membership_applications_review_queue_idx
  on public.membership_applications (organization_id, requested_role, created_at)
  where status = 'pending';
create index membership_applications_user_history_idx
  on public.membership_applications (user_id, created_at desc);

create table public.organization_memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  role public.app_role not null,
  status public.membership_status not null default 'active',
  approved_from_application_id uuid references public.membership_applications(id) on delete set null,
  approved_by uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  ended_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint organization_memberships_end_state_check check (
    (status = 'active' and ended_at is null)
    or (status <> 'active' and ended_at is not null)
  )
);

create unique index organization_memberships_one_active_per_user_idx
  on public.organization_memberships (user_id)
  where status = 'active';
create index organization_memberships_org_active_role_idx
  on public.organization_memberships (organization_id, role, user_id)
  where status = 'active';
create index organization_memberships_user_history_idx
  on public.organization_memberships (user_id, joined_at desc);

create table public.boards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  slug text not null check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text not null check (char_length(name) between 1 and 80),
  description text check (description is null or char_length(description) <= 500),
  sort_order integer not null default 0,
  is_global boolean not null default false,
  is_read_only boolean not null default false,
  staff_only_posting boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint boards_scope_check check (
    (is_global and organization_id is null)
    or (not is_global and organization_id is not null)
  )
);

create unique index boards_org_slug_unique_idx
  on public.boards (organization_id, slug)
  where organization_id is not null;
create unique index boards_global_slug_unique_idx
  on public.boards (slug)
  where is_global;
create index boards_org_sort_idx
  on public.boards (organization_id, sort_order, name);

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  board_id uuid not null references public.boards(id) on delete restrict,
  author_id uuid references public.profiles(id) on delete set null,
  author_label text,
  title text not null check (char_length(title) between 1 and 200),
  body text not null check (char_length(body) between 1 and 50000),
  status public.post_status not null default 'published',
  is_system boolean not null default false,
  is_pinned boolean not null default false,
  allow_comments boolean not null default true,
  published_at timestamptz,
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint posts_author_check check (
    (is_system and author_id is null and nullif(btrim(author_label), '') is not null)
    or not is_system
  ),
  constraint posts_scope_check check (
    (is_system and organization_id is null)
    or (not is_system and organization_id is not null)
  ),
  constraint posts_publish_state_check check (
    (status = 'published' and published_at is not null and deleted_at is null)
    or (status in ('draft', 'hidden') and deleted_at is null)
    or (status = 'deleted' and deleted_at is not null)
  )
);

create index posts_org_board_feed_idx
  on public.posts (organization_id, board_id, is_pinned desc, published_at desc)
  where status = 'published';
create index posts_global_feed_idx
  on public.posts (is_pinned desc, published_at desc)
  where organization_id is null and status = 'published';
create index posts_author_idx
  on public.posts (author_id, created_at desc)
  where author_id is not null;

create table public.post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  uploader_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null unique,
  kind public.media_kind not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size > 0),
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  duration_seconds numeric(10, 3) check (duration_seconds is null or duration_seconds >= 0),
  alt_text text check (alt_text is null or char_length(alt_text) <= 1000),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint post_media_kind_metadata_check check (
    (kind = 'image' and duration_seconds is null)
    or kind = 'video'
  ),
  constraint post_media_size_check check (
    (kind = 'image' and byte_size <= 15728640)
    or (kind = 'video' and byte_size <= 524288000)
  )
);

create index post_media_post_sort_idx
  on public.post_media (post_id, sort_order, created_at);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null,
  parent_id uuid references public.comments(id) on delete set null,
  body text not null check (char_length(body) between 1 and 5000),
  status public.comment_status not null default 'active',
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint comments_delete_state_check check (
    (status = 'deleted' and deleted_at is not null)
    or (status <> 'deleted' and deleted_at is null)
  )
);

create index comments_post_thread_idx
  on public.comments (post_id, parent_id, created_at)
  where status <> 'deleted';
create index comments_author_idx
  on public.comments (author_id, created_at desc)
  where author_id is not null;

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  participant_low uuid not null references public.profiles(id) on delete cascade,
  participant_high uuid not null references public.profiles(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz,
  constraint conversations_two_distinct_users_check check (participant_low <> participant_high),
  constraint conversations_canonical_order_check check (participant_low::text < participant_high::text),
  constraint conversations_creator_participant_check check (
    created_by = participant_low or created_by = participant_high
  ),
  unique (organization_id, participant_low, participant_high)
);

create index conversations_low_inbox_idx
  on public.conversations (participant_low, last_message_at desc nulls last);
create index conversations_high_inbox_idx
  on public.conversations (participant_high, last_message_at desc nulls last);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid references public.profiles(id) on delete set null,
  kind public.message_kind not null default 'text',
  body text check (body is null or char_length(body) <= 10000),
  media_path text,
  media_metadata jsonb not null default '{}'::jsonb,
  client_nonce uuid not null default gen_random_uuid(),
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  constraint messages_content_check check (
    (deleted_at is not null)
    or (kind = 'text' and nullif(btrim(body), '') is not null and media_path is null)
    or (kind in ('image', 'video') and media_path is not null)
  ),
  unique (conversation_id, sender_id, client_nonce)
);

create index messages_conversation_timeline_idx
  on public.messages (conversation_id, created_at desc);
create index messages_sender_idx
  on public.messages (sender_id, created_at desc)
  where sender_id is not null;

create table public.conversation_reads (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_message_id uuid references public.messages(id) on delete set null,
  last_read_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index conversation_reads_user_unread_idx
  on public.conversation_reads (user_id, last_read_at desc);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind public.notification_kind not null,
  title text not null check (char_length(title) between 1 and 200),
  body text not null check (char_length(body) between 1 and 2000),
  entity_type text check (entity_type is null or char_length(entity_type) <= 80),
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_user_inbox_idx
  on public.notifications (user_id, read_at nulls first, created_at desc);
create index notifications_unread_idx
  on public.notifications (user_id, created_at desc)
  where read_at is null;

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null check (char_length(action) between 1 and 120),
  entity_type text not null check (char_length(entity_type) between 1 and 80),
  entity_id uuid,
  organization_id uuid references public.organizations(id) on delete set null,
  target_user_id uuid references public.profiles(id) on delete set null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_logs_org_time_idx
  on public.audit_logs (organization_id, created_at desc);
create index audit_logs_actor_time_idx
  on public.audit_logs (actor_id, created_at desc);
create index audit_logs_target_time_idx
  on public.audit_logs (target_user_id, created_at desc);

-- Common timestamp trigger. It is not client-callable.
create or replace function private.set_updated_at()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public, anon, authenticated;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

create trigger organizations_set_updated_at
before update on public.organizations
for each row execute function private.set_updated_at();

create trigger membership_applications_set_updated_at
before update on public.membership_applications
for each row execute function private.set_updated_at();

create trigger organization_memberships_set_updated_at
before update on public.organization_memberships
for each row execute function private.set_updated_at();

create trigger boards_set_updated_at
before update on public.boards
for each row execute function private.set_updated_at();

create trigger posts_set_updated_at
before update on public.posts
for each row execute function private.set_updated_at();

create trigger comments_set_updated_at
before update on public.comments
for each row execute function private.set_updated_at();

create trigger conversations_set_updated_at
before update on public.conversations
for each row execute function private.set_updated_at();

-- Auth signup -> application profile. Names come only from the real user's auth metadata.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_name text;
begin
  v_name := nullif(pg_catalog.btrim(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    split_part(coalesce(new.email, ''), '@', 1)
  )), '');

  insert into public.profiles (id, display_name)
  values (new.id, left(coalesce(v_name, '사용자'), 80))
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Backfill only real Auth users that existed before this migration.
insert into public.profiles (id, display_name)
select
  u.id,
  left(coalesce(
    nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
    nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
    '사용자'
  ), 80)
from auth.users as u
on conflict (id) do nothing;
