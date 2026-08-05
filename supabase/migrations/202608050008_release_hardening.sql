-- Release hardening for user-authored posts.
-- Non-system authors must never control the trusted author label or publication
-- timestamp, and only active church managers or platform administrators may
-- change pin state. Draft deletion is limited to the active author so failed
-- media uploads can compensate without exposing general post deletion.

update public.posts
set author_label = null
where not is_system
  and author_label is not null;

alter table public.posts
  drop constraint if exists posts_non_system_author_label_check;

alter table public.posts
  add constraint posts_non_system_author_label_check check (
    is_system or author_label is null
  );

create or replace function private.validate_post_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_pin_changed boolean := tg_op = 'INSERT'
    or old.is_pinned is distinct from new.is_pinned;
begin
  if new.is_system then
    return new;
  end if;

  if new.author_label is not null then
    raise exception 'non_system_author_label_forbidden' using errcode = '42501';
  end if;

  -- User-authored posts receive a server timestamp on first publication. Clients
  -- cannot predate/future-date a draft, move a published post in the feed, or bump
  -- it by toggling status and supplying another timestamp.
  if tg_op = 'INSERT' then
    new.published_at := case
      when new.status = 'published'::public.post_status then pg_catalog.now()
      else null
    end;
  elsif old.published_at is null
    and new.status = 'published'::public.post_status then
    new.published_at := pg_catalog.now();
  else
    new.published_at := old.published_at;
  end if;

  if v_pin_changed
    and new.is_pinned
    and not (
      private.is_platform_admin(v_actor_id)
      or private.can_manage_members(new.organization_id, v_actor_id)
    ) then
    raise exception 'post_pin_requires_manager' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE'
    and old.is_pinned
    and not new.is_pinned
    and not (
      private.is_platform_admin(v_actor_id)
      or private.can_manage_members(new.organization_id, v_actor_id)
    ) then
    raise exception 'post_unpin_requires_manager' using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists posts_validate_privileged_fields on public.posts;
create trigger posts_validate_privileged_fields
before insert or update of author_label, is_pinned, published_at, status on public.posts
for each row execute function private.validate_post_privileged_fields();

revoke all on function private.validate_post_privileged_fields() from public;
revoke all on function private.validate_post_privileged_fields() from anon;
revoke all on function private.validate_post_privileged_fields() from authenticated;

drop policy if exists posts_delete_own_draft on public.posts;
create policy posts_delete_own_draft
on public.posts for delete to authenticated
using (
  auth.uid() is not null
  and status = 'draft'::public.post_status
  and author_id = auth.uid()
  and organization_id is not null
  and private.is_active_member(organization_id, auth.uid())
  and private.can_manage_post(id, auth.uid())
);

grant delete on table public.posts to authenticated;

-- A composer can send one optional text item and up to three uploaded media items
-- as one atomic operation. Each individual write still flows through send_message,
-- which remains the authority for conversation access, content, and media paths.
drop function if exists public.send_message_batch(uuid, jsonb);
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

  -- Validate the complete envelope before invoking the first mutating RPC. This is
  -- not the atomicity boundary (the function call already is one transaction), but
  -- it keeps malformed payloads from doing avoidable work.
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
          'kind',
          'body',
          'media_path',
          'media_metadata',
          'client_nonce'
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
  'Atomically sends 1-4 validated composer items for the explicitly bound authenticated sender; one text and up to three media items.';

revoke all on function public.send_message_batch(uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.send_message_batch(uuid, uuid, jsonb)
  to authenticated;

-- A singleton browser client can swap sessions while an HTTP request is in
-- flight. Reconciliation must therefore bind the database actor explicitly;
-- an RLS-empty response under the next account is not proof that the previous
-- account's transaction did not commit.
drop function if exists public.reconcile_message_batch(uuid, uuid, uuid[]);
create or replace function public.reconcile_message_batch(
  p_conversation_id uuid,
  p_expected_sender_id uuid,
  p_client_nonces uuid[]
)
returns table(client_nonce uuid)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_sender_id is null or auth.uid() <> p_expected_sender_id then
    raise exception 'message_sender_session_changed' using errcode = '42501';
  end if;
  if p_conversation_id is null
    or p_client_nonces is null
    or pg_catalog.cardinality(p_client_nonces) < 1
    or pg_catalog.cardinality(p_client_nonces) > 4
    or pg_catalog.array_position(p_client_nonces, null) is not null then
    raise exception 'invalid_message_reconciliation_request' using errcode = '22023';
  end if;

  return query
  select m.client_nonce
  from public.messages as m
  where m.conversation_id = p_conversation_id
    and m.sender_id = p_expected_sender_id
    and m.client_nonce = any(p_client_nonces)
  order by m.created_at, m.id;
end;
$$;

create or replace function public.reconcile_post_operation(
  p_post_id uuid,
  p_expected_author_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_author_id is null or auth.uid() <> p_expected_author_id then
    raise exception 'post_author_session_changed' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'status', p.status,
    'published_at', p.published_at,
    'created_at', p.created_at
  )
  into v_result
  from public.posts as p
  where p.id = p_post_id
    and p.author_id = p_expected_author_id
    and not p.is_system;

  return v_result;
end;
$$;

create or replace function public.publish_owned_post(
  p_post_id uuid,
  p_expected_author_id uuid,
  p_expected_media_paths text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_post public.posts%rowtype;
  v_actual_media_paths text[];
  v_expected_media_paths text[];
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_author_id is null or auth.uid() <> p_expected_author_id then
    raise exception 'post_author_session_changed' using errcode = '42501';
  end if;
  if p_post_id is null or p_expected_media_paths is null then
    raise exception 'invalid_post_publish_request' using errcode = '22023';
  end if;
  if pg_catalog.cardinality(p_expected_media_paths) > 6 then
    raise exception 'post_media_limit_exceeded' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('post:' || p_post_id::text, 0)
  );
  select * into v_post
  from public.posts
  where id = p_post_id
  for update;
  if not found then
    raise exception 'post_not_found' using errcode = 'P0002';
  end if;
  if v_post.is_system
    or v_post.author_id is distinct from p_expected_author_id
    or not private.is_active_member(v_post.organization_id, p_expected_author_id) then
    raise exception 'post_publish_forbidden' using errcode = '42501';
  end if;
  if v_post.status not in ('draft'::public.post_status, 'published'::public.post_status) then
    raise exception 'post_not_publishable' using errcode = '55000';
  end if;

  select coalesce(pg_catalog.array_agg(paths.path order by paths.path), '{}'::text[])
  into v_expected_media_paths
  from (
    select distinct path
    from pg_catalog.unnest(p_expected_media_paths) as supplied(path)
    where nullif(pg_catalog.btrim(path), '') is not null
  ) as paths;
  select coalesce(pg_catalog.array_agg(pm.storage_path order by pm.storage_path), '{}'::text[])
  into v_actual_media_paths
  from public.post_media as pm
  where pm.post_id = p_post_id;
  if pg_catalog.cardinality(v_actual_media_paths) > 6 then
    raise exception 'post_media_limit_exceeded' using errcode = '22023';
  end if;
  if v_actual_media_paths is distinct from v_expected_media_paths then
    raise exception 'post_media_set_mismatch' using errcode = '55000';
  end if;

  if v_post.status = 'draft'::public.post_status then
    update public.posts
    set status = 'published'::public.post_status
    where id = p_post_id
    returning * into v_post;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', v_post.status,
    'published_at', v_post.published_at,
    'created_at', v_post.created_at
  );
end;
$$;

comment on function public.reconcile_message_batch(uuid, uuid, uuid[]) is
  'Returns only the expected sender nonces, even after membership suspension, and rejects browser account switches.';
comment on function public.reconcile_post_operation(uuid, uuid) is
  'Returns an owned post operation status and rejects browser account switches.';
comment on function public.publish_owned_post(uuid, uuid, text[]) is
  'Idempotently publishes an owned draft only for the explicitly bound authenticated author and exact media set.';

revoke all on function public.reconcile_message_batch(uuid, uuid, uuid[])
  from public, anon, authenticated;
revoke all on function public.reconcile_post_operation(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.publish_owned_post(uuid, uuid, text[])
  from public, anon, authenticated;
grant execute on function public.reconcile_message_batch(uuid, uuid, uuid[])
  to authenticated;
grant execute on function public.reconcile_post_operation(uuid, uuid)
  to authenticated;
grant execute on function public.publish_owned_post(uuid, uuid, text[])
  to authenticated;

-- Path authorization answers whether an actor may write within an application
-- entity. Storage object mutation additionally requires byte ownership so another
-- conversation participant or church manager cannot replace/delete the uploader's
-- object merely by learning its name.
drop policy if exists jaegun_community_media_update on storage.objects;
create policy jaegun_community_media_update
on storage.objects for update to authenticated
using (
  bucket_id = 'community-media'
  and owner_id = auth.uid()::text
  and private.can_write_community_media(name, auth.uid())
)
with check (
  bucket_id = 'community-media'
  and owner_id = auth.uid()::text
  and private.can_write_community_media(name, auth.uid())
  and private.community_object_size_allowed(metadata)
);

drop policy if exists jaegun_community_media_delete on storage.objects;
create policy jaegun_community_media_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'community-media'
  and owner_id = auth.uid()::text
  and private.can_write_community_media(name, auth.uid())
);

-- Physical deletion remains the public executive-record behavior, but a durable
-- private tombstone prevents a lost-response create retry from resurrecting the
-- same client-generated UUID after another authorized executive deletes it.
create table if not exists private.executive_operation_tombstones (
  entity_type text not null check (
    entity_type in ('meeting_minute', 'ledger_entry')
  ),
  entity_id uuid not null,
  organization_id uuid not null,
  deleted_by uuid not null,
  deleted_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (entity_type, entity_id)
);

comment on table private.executive_operation_tombstones is
  'Durable deleted client UUIDs for executive records; prevents create-retry resurrection without exposing deleted content.';

revoke all on table private.executive_operation_tombstones
  from public, anon, authenticated;

-- New executive-operation records use a client-generated UUID. Replaying the
-- same save after a lost HTTP response therefore updates/no-ops that row instead
-- of inserting a second minute or (more critically) a duplicate ledger entry.
-- The advisory lock also serializes the same UUID across tabs or overlapping
-- retries before the first transaction has completed.
drop function if exists public.save_meeting_minute(uuid, uuid, integer, date, text, text, text);
create or replace function public.save_meeting_minute(
  p_id uuid,
  p_create boolean,
  p_organization_id uuid,
  p_meeting_year integer,
  p_meeting_date date,
  p_title text,
  p_body text,
  p_status text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_id uuid;
  v_existing public.meeting_minutes%rowtype;
  v_author_name text;
  v_title text := nullif(pg_catalog.btrim(p_title), '');
  v_body text := nullif(pg_catalog.btrim(p_body), '');
  v_action text;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_create is null or p_id is null then
    raise exception 'meeting_minute_operation_id_required' using errcode = '22023';
  end if;
  if not private.can_manage_meeting_minutes(p_organization_id, v_actor_id) then
    raise exception 'meeting_minute_write_forbidden' using errcode = '42501';
  end if;
  if p_meeting_year not between 2000 and 2100
    or p_meeting_date is null
    or extract(year from p_meeting_date)::integer <> p_meeting_year then
    raise exception 'invalid_meeting_year_or_date' using errcode = '23514';
  end if;
  if p_meeting_year <> private.current_service_year() then
    raise exception 'historical_meeting_minutes_are_read_only' using errcode = '42501';
  end if;
  if v_title is null or char_length(v_title) > 200 then
    raise exception 'invalid_meeting_title' using errcode = '23514';
  end if;
  if v_body is null or char_length(v_body) > 50000 then
    raise exception 'invalid_meeting_body' using errcode = '23514';
  end if;
  if p_status not in ('draft', 'published') then
    raise exception 'invalid_meeting_status' using errcode = '23514';
  end if;

  select display_name into v_author_name
  from public.profiles
  where id = v_actor_id;
  if v_author_name is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  v_id := coalesce(p_id, pg_catalog.gen_random_uuid());
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('meeting_minute:' || v_id::text, 0)
  );
  if exists (
    select 1
    from private.executive_operation_tombstones as tombstone
    where tombstone.entity_type = 'meeting_minute'
      and tombstone.entity_id = v_id
  ) then
    raise exception 'meeting_minute_operation_deleted' using errcode = '55000';
  end if;
  select * into v_existing
  from public.meeting_minutes
  where id = v_id
  for update;

  if found then
    if v_existing.organization_id <> p_organization_id then
      raise exception 'meeting_minute_organization_mismatch' using errcode = '42501';
    end if;
    if v_existing.meeting_year <> private.current_service_year() then
      raise exception 'historical_meeting_minutes_are_read_only' using errcode = '42501';
    end if;
    if p_create and v_existing.author_id is distinct from v_actor_id then
      raise exception 'meeting_minute_operation_id_conflict' using errcode = '42501';
    end if;
    if v_existing.meeting_year = p_meeting_year
      and v_existing.meeting_date = p_meeting_date
      and v_existing.title = v_title
      and v_existing.body = v_body
      and v_existing.status = p_status
      and v_existing.author_id = v_actor_id then
      return v_id;
    end if;

    update public.meeting_minutes
    set
      meeting_year = p_meeting_year,
      meeting_date = p_meeting_date,
      title = v_title,
      body = v_body,
      status = p_status,
      author_id = v_actor_id,
      author_name = v_author_name
    where id = v_id;
    v_action := 'meeting_minute.updated';
  else
    if not p_create then
      raise exception 'meeting_minute_not_found' using errcode = 'P0002';
    end if;
    insert into public.meeting_minutes (
      id, organization_id, meeting_year, meeting_date, title, body, status,
      author_id, author_name
    )
    values (
      v_id, p_organization_id, p_meeting_year, p_meeting_date, v_title,
      v_body, p_status, v_actor_id, v_author_name
    );
    v_action := 'meeting_minute.created';
  end if;

  perform private.write_audit(
    v_actor_id,
    v_action,
    'meeting_minute',
    v_id,
    p_organization_id,
    null,
    pg_catalog.jsonb_build_object(
      'meeting_year', p_meeting_year,
      'status', p_status
    )
  );
  return v_id;
end;
$$;

drop function if exists public.save_ledger_entry(uuid, uuid, integer, date, text, text, text, numeric, text);
create or replace function public.save_ledger_entry(
  p_id uuid,
  p_create boolean,
  p_organization_id uuid,
  p_fiscal_year integer,
  p_entry_date date,
  p_entry_type text,
  p_category text,
  p_description text,
  p_amount numeric,
  p_memo text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_id uuid;
  v_existing public.ledger_entries%rowtype;
  v_author_name text;
  v_category text := nullif(pg_catalog.btrim(p_category), '');
  v_description text := nullif(pg_catalog.btrim(p_description), '');
  v_memo text := nullif(pg_catalog.btrim(p_memo), '');
  v_action text;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_create is null or p_id is null then
    raise exception 'ledger_operation_id_required' using errcode = '22023';
  end if;
  if not private.can_manage_ledger(p_organization_id, v_actor_id) then
    raise exception 'ledger_write_forbidden' using errcode = '42501';
  end if;
  if p_fiscal_year not between 2000 and 2100
    or p_entry_date is null
    or extract(year from p_entry_date)::integer <> p_fiscal_year then
    raise exception 'invalid_fiscal_year_or_date' using errcode = '23514';
  end if;
  if p_fiscal_year <> private.current_service_year() then
    raise exception 'historical_ledger_entries_are_read_only' using errcode = '42501';
  end if;
  if p_entry_type not in ('income', 'expense') then
    raise exception 'invalid_ledger_entry_type' using errcode = '23514';
  end if;
  if v_category is null or char_length(v_category) > 80 then
    raise exception 'invalid_ledger_category' using errcode = '23514';
  end if;
  if v_description is null or char_length(v_description) > 500 then
    raise exception 'invalid_ledger_description' using errcode = '23514';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 9999999999999.99 then
    raise exception 'invalid_ledger_amount' using errcode = '23514';
  end if;
  if v_memo is not null and char_length(v_memo) > 2000 then
    raise exception 'ledger_memo_too_long' using errcode = '22001';
  end if;

  select display_name into v_author_name
  from public.profiles
  where id = v_actor_id;
  if v_author_name is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  v_id := coalesce(p_id, pg_catalog.gen_random_uuid());
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('ledger_entry:' || v_id::text, 0)
  );
  if exists (
    select 1
    from private.executive_operation_tombstones as tombstone
    where tombstone.entity_type = 'ledger_entry'
      and tombstone.entity_id = v_id
  ) then
    raise exception 'ledger_operation_deleted' using errcode = '55000';
  end if;
  select * into v_existing
  from public.ledger_entries
  where id = v_id
  for update;

  if found then
    if v_existing.organization_id <> p_organization_id then
      raise exception 'ledger_entry_organization_mismatch' using errcode = '42501';
    end if;
    if v_existing.fiscal_year <> private.current_service_year() then
      raise exception 'historical_ledger_entries_are_read_only' using errcode = '42501';
    end if;
    if p_create and v_existing.author_id is distinct from v_actor_id then
      raise exception 'ledger_operation_id_conflict' using errcode = '42501';
    end if;
    if v_existing.fiscal_year = p_fiscal_year
      and v_existing.entry_date = p_entry_date
      and v_existing.entry_type = p_entry_type
      and v_existing.category = v_category
      and v_existing.description = v_description
      and v_existing.amount = p_amount
      and v_existing.memo is not distinct from v_memo
      and v_existing.author_id = v_actor_id then
      return v_id;
    end if;

    update public.ledger_entries
    set
      fiscal_year = p_fiscal_year,
      entry_date = p_entry_date,
      entry_type = p_entry_type,
      category = v_category,
      description = v_description,
      amount = p_amount,
      memo = v_memo,
      author_id = v_actor_id,
      author_name = v_author_name
    where id = v_id;
    v_action := 'ledger_entry.updated';
  else
    if not p_create then
      raise exception 'ledger_entry_not_found' using errcode = 'P0002';
    end if;
    insert into public.ledger_entries (
      id, organization_id, fiscal_year, entry_date, entry_type, category,
      description, amount, memo, author_id, author_name
    )
    values (
      v_id, p_organization_id, p_fiscal_year, p_entry_date, p_entry_type,
      v_category, v_description, p_amount, v_memo, v_actor_id, v_author_name
    );
    v_action := 'ledger_entry.created';
  end if;

  perform private.write_audit(
    v_actor_id,
    v_action,
    'ledger_entry',
    v_id,
    p_organization_id,
    null,
    pg_catalog.jsonb_build_object(
      'fiscal_year', p_fiscal_year,
      'entry_type', p_entry_type,
      'amount', p_amount
    )
  );
  return v_id;
end;
$$;

comment on function public.save_meeting_minute(uuid, boolean, uuid, integer, date, text, text, text) is
  'Creates or updates a current-year meeting minute; client UUID retries are idempotent.';
comment on function public.save_ledger_entry(uuid, boolean, uuid, integer, date, text, text, text, numeric, text) is
  'Creates or updates a current-year ledger entry; client UUID retries are idempotent.';

revoke all on function public.save_meeting_minute(uuid, boolean, uuid, integer, date, text, text, text)
  from public, anon, authenticated;
revoke all on function public.save_ledger_entry(uuid, boolean, uuid, integer, date, text, text, text, numeric, text)
  from public, anon, authenticated;
grant execute on function public.save_meeting_minute(uuid, boolean, uuid, integer, date, text, text, text)
  to authenticated;
grant execute on function public.save_ledger_entry(uuid, boolean, uuid, integer, date, text, text, text, numeric, text)
  to authenticated;

create or replace function public.delete_meeting_minute(p_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_existing public.meeting_minutes%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('meeting_minute:' || p_id::text, 0)
  );
  select * into v_existing
  from public.meeting_minutes
  where id = p_id
  for update;
  if not found then
    raise exception 'meeting_minute_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_meeting_minutes(v_existing.organization_id, v_actor_id) then
    raise exception 'meeting_minute_delete_forbidden' using errcode = '42501';
  end if;
  if v_existing.meeting_year <> private.current_service_year() then
    raise exception 'historical_meeting_minutes_are_read_only' using errcode = '42501';
  end if;

  insert into private.executive_operation_tombstones (
    entity_type,
    entity_id,
    organization_id,
    deleted_by
  )
  values (
    'meeting_minute',
    p_id,
    v_existing.organization_id,
    v_actor_id
  )
  on conflict (entity_type, entity_id) do nothing;

  delete from public.meeting_minutes where id = p_id;
  perform private.write_audit(
    v_actor_id,
    'meeting_minute.deleted',
    'meeting_minute',
    p_id,
    v_existing.organization_id,
    null,
    pg_catalog.jsonb_build_object('meeting_year', v_existing.meeting_year)
  );
end;
$$;

create or replace function public.delete_ledger_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_existing public.ledger_entries%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('ledger_entry:' || p_id::text, 0)
  );
  select * into v_existing
  from public.ledger_entries
  where id = p_id
  for update;
  if not found then
    raise exception 'ledger_entry_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_ledger(v_existing.organization_id, v_actor_id) then
    raise exception 'ledger_delete_forbidden' using errcode = '42501';
  end if;
  if v_existing.fiscal_year <> private.current_service_year() then
    raise exception 'historical_ledger_entries_are_read_only' using errcode = '42501';
  end if;

  insert into private.executive_operation_tombstones (
    entity_type,
    entity_id,
    organization_id,
    deleted_by
  )
  values (
    'ledger_entry',
    p_id,
    v_existing.organization_id,
    v_actor_id
  )
  on conflict (entity_type, entity_id) do nothing;

  delete from public.ledger_entries where id = p_id;
  perform private.write_audit(
    v_actor_id,
    'ledger_entry.deleted',
    'ledger_entry',
    p_id,
    v_existing.organization_id,
    null,
    pg_catalog.jsonb_build_object(
      'fiscal_year', v_existing.fiscal_year,
      'entry_type', v_existing.entry_type,
      'amount', v_existing.amount
    )
  );
end;
$$;

comment on function public.delete_meeting_minute(uuid) is
  'Deletes a current-year meeting minute and atomically records its UUID tombstone.';
comment on function public.delete_ledger_entry(uuid) is
  'Deletes a current-year ledger entry and atomically records its UUID tombstone.';

revoke all on function public.delete_meeting_minute(uuid)
  from public, anon, authenticated;
revoke all on function public.delete_ledger_entry(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_meeting_minute(uuid)
  to authenticated;
grant execute on function public.delete_ledger_entry(uuid)
  to authenticated;

-- Post composer operations are bound to the user who created the client UUID.
-- Existing drafts are updated with the newest form values before a retry; a
-- manager who happens to sign in on the same browser cannot mutate or publish
-- another author's in-flight draft.
create or replace function public.save_owned_post_draft(
  p_post_id uuid,
  p_expected_author_id uuid,
  p_organization_id uuid,
  p_board_id uuid,
  p_title text,
  p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_post public.posts%rowtype;
  v_media_paths text[];
  v_scope_recreated boolean := false;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_author_id is null or auth.uid() <> p_expected_author_id then
    raise exception 'post_author_session_changed' using errcode = '42501';
  end if;
  if p_post_id is null or p_organization_id is null or p_board_id is null then
    raise exception 'invalid_post_draft_request' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('post:' || p_post_id::text, 0)
  );
  select * into v_post
  from public.posts
  where id = p_post_id
  for update;

  if found then
    if v_post.is_system
      or v_post.author_id is distinct from p_expected_author_id
      or v_post.organization_id is distinct from p_organization_id then
      raise exception 'post_draft_owner_mismatch' using errcode = '42501';
    end if;
    select coalesce(pg_catalog.array_agg(pm.storage_path order by pm.storage_path), '{}'::text[])
    into v_media_paths
    from public.post_media as pm
    where pm.post_id = p_post_id;
    if v_post.status = 'draft'::public.post_status then
      if not private.can_create_post(p_organization_id, p_board_id, p_expected_author_id) then
        raise exception 'post_draft_write_forbidden' using errcode = '42501';
      end if;
      if v_post.board_id is distinct from p_board_id then
        -- board_id is intentionally immutable on an existing row. Recreate only
        -- this author's still-private draft under the same client UUID so the
        -- canonical scope trigger validates the new board normally.
        delete from public.posts where id = p_post_id;
        insert into public.posts (
          id,
          organization_id,
          board_id,
          author_id,
          title,
          body,
          status,
          is_system
        )
        values (
          p_post_id,
          p_organization_id,
          p_board_id,
          p_expected_author_id,
          p_title,
          p_body,
          'draft'::public.post_status,
          false
        )
        returning * into v_post;
        v_scope_recreated := true;
      else
        update public.posts
        set title = p_title,
            body = p_body
        where id = p_post_id
        returning * into v_post;
      end if;
    elsif v_post.status <> 'published'::public.post_status then
      raise exception 'post_draft_not_writable' using errcode = '55000';
    end if;
  else
    v_media_paths := '{}'::text[];
    if not private.can_create_post(p_organization_id, p_board_id, p_expected_author_id) then
      raise exception 'post_draft_write_forbidden' using errcode = '42501';
    end if;
    insert into public.posts (
      id,
      organization_id,
      board_id,
      author_id,
      title,
      body,
      status,
      is_system
    )
    values (
      p_post_id,
      p_organization_id,
      p_board_id,
      p_expected_author_id,
      p_title,
      p_body,
      'draft'::public.post_status,
      false
    )
    returning * into v_post;
  end if;

  return pg_catalog.jsonb_build_object(
    'id', v_post.id,
    'status', v_post.status,
    'organization_id', v_post.organization_id,
    'board_id', v_post.board_id,
    'title', v_post.title,
    'body', v_post.body,
    'created_at', v_post.created_at,
    'published_at', v_post.published_at,
    'scope_recreated', v_scope_recreated,
    'media_paths', pg_catalog.to_jsonb(v_media_paths)
  );
end;
$$;

-- Atomically classify queued paths while holding the post row lock. Draft media
-- references are detached before Storage deletion; published references remain
-- protected and can never be mistaken for abandoned upload bytes.
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
  v_post public.posts%rowtype;
  v_requested text[];
  v_referenced text[];
  v_removable text[];
  v_protected text[];
  v_prefix text;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_expected_author_id is null or auth.uid() <> p_expected_author_id then
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
      'protected_paths', '[]'::jsonb
    );
  end if;
  if v_post.is_system or v_post.author_id is distinct from p_expected_author_id then
    raise exception 'post_cleanup_forbidden' using errcode = '42501';
  end if;

  v_prefix := v_post.organization_id::text || '/posts/' || p_post_id::text || '/';
  select coalesce(pg_catalog.array_agg(paths.path order by paths.path), '{}'::text[])
  into v_requested
  from (
    select distinct path
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

  select coalesce(pg_catalog.array_agg(pm.storage_path order by pm.storage_path), '{}'::text[])
  into v_referenced
  from public.post_media as pm
  where pm.post_id = p_post_id
    and pm.storage_path = any(v_requested);

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

  return pg_catalog.jsonb_build_object(
    'status', v_post.status,
    'removable_paths', pg_catalog.to_jsonb(v_removable),
    'protected_paths', pg_catalog.to_jsonb(v_protected)
  );
end;
$$;

comment on function public.save_owned_post_draft(uuid, uuid, uuid, uuid, text, text) is
  'Creates or refreshes one client-ID post draft for its explicitly bound authenticated author.';
comment on function public.prepare_post_media_cleanup(uuid, uuid, text[]) is
  'Classifies queued post media atomically; detaches only media belonging to an owned draft.';

revoke all on function public.save_owned_post_draft(uuid, uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.prepare_post_media_cleanup(uuid, uuid, text[])
  from public, anon, authenticated;
grant execute on function public.save_owned_post_draft(uuid, uuid, uuid, uuid, text, text)
  to authenticated;
grant execute on function public.prepare_post_media_cleanup(uuid, uuid, text[])
  to authenticated;
