-- Opt-in revision-safe API; existing web save_event signature remains compatible.
create table private.event_create_receipts (
  event_id uuid primary key references public.events(id) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  created_at timestamptz not null default pg_catalog.clock_timestamp()
);
create index event_create_receipts_actor_retention_idx on private.event_create_receipts(actor_id, created_at, event_id);
create index event_create_receipts_retention_idx on private.event_create_receipts(created_at, event_id);
alter table private.event_create_receipts enable row level security;
revoke all on private.event_create_receipts from public, anon, authenticated;
comment on table private.event_create_receipts is
  'Private exact create-request receipts; replay window 90 days. Bounded actor cleanup plus internal janitor; scheduling the janitor is an explicit deployment step. Missing receipts never permit overwriting an existing event.';

-- Dormant bounded janitor: this migration does not silently activate a cron job.
create function private.prune_event_create_receipts(p_limit integer default 1000)
returns integer language plpgsql security invoker set search_path = pg_catalog
as $$
declare v_count integer;
begin
  if p_limit is null or p_limit < 1 or p_limit > 10000 then
    raise exception 'invalid_receipt_prune_limit' using errcode = '22023';
  end if;
  with expired as (
    select event_id from private.event_create_receipts
    where created_at < pg_catalog.statement_timestamp() - interval '90 days'
    order by created_at, event_id for update skip locked limit p_limit
  )
  delete from private.event_create_receipts as receipt using expired
  where receipt.event_id = expired.event_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function private.prune_event_create_receipts(integer) from public, anon, authenticated;

create function public.save_event_checked(
  p_id uuid, p_create boolean, p_scope_id uuid, p_title text,
  p_description text, p_location_text text, p_starts_at timestamptz,
  p_ends_at timestamptz, p_capacity integer, p_recurrence_frequency text,
  p_recurrence_interval integer, p_recurrence_weekdays smallint[],
  p_recurrence_month_day integer, p_recurrence_until timestamptz,
  p_recurrence_count integer, p_reminder_offsets_minutes integer[],
  p_host_name text, p_expected_revision integer
)
returns uuid
language plpgsql security definer set search_path = pg_catalog
as $$
declare
  v_actor uuid;
  v_event public.events%rowtype;
  v_receipt private.event_create_receipts%rowtype;
  v_payload jsonb;
  v_result uuid;
begin
  v_actor := private.require_current_consent_actor();
  -- Check the authorized requested scope before any target existence lookup.
  if p_id is null or p_scope_id is null or p_create is null
    or not private.can_manage_events(p_scope_id, v_actor) then
    raise exception 'event_save_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  perform private.require_aal2('event_save');
  if (p_create and p_expected_revision is not null)
    or (not p_create and (p_expected_revision is null or p_expected_revision < 1)) then
    raise exception 'event_expected_revision_required' using errcode = '22023';
  end if;
  -- Same lock family as save_event, including when the event does not yet exist.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('event:' || p_id::text, 0));
  select * into v_event from public.events where id = p_id for update;
  if found and v_event.scope_id is distinct from p_scope_id then
    raise exception 'event_save_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  if not p_create then
    if v_event.id is null then
      raise exception 'event_save_not_found_or_forbidden' using errcode = 'P0002';
    end if;
    if v_event.revision <> p_expected_revision then
      raise exception 'event_revision_conflict' using errcode = '40001';
    end if;
  else
    v_payload := pg_catalog.jsonb_build_object(
      'id', p_id, 'scope', p_scope_id, 'title', p_title, 'description', p_description,
      'location', p_location_text, 'start', p_starts_at, 'end', p_ends_at,
      'capacity', p_capacity, 'frequency', p_recurrence_frequency,
      'interval', p_recurrence_interval, 'weekdays', p_recurrence_weekdays,
      'month_day', p_recurrence_month_day, 'until', p_recurrence_until,
      'count', p_recurrence_count, 'reminders', p_reminder_offsets_minutes,
      'host', p_host_name
    );
    if v_event.id is not null then
      select * into v_receipt from private.event_create_receipts where event_id = p_id;
      if v_receipt.actor_id is distinct from v_actor
        or v_receipt.request_payload is distinct from v_payload
        or v_receipt.created_at < pg_catalog.statement_timestamp() - interval '90 days' then
        raise exception 'event_create_operation_conflict' using errcode = '40001';
      end if;
      -- Retry acknowledges original success; never rewrites subsequent edits/cancellation.
      return p_id;
    end if;
  end if;
  v_result := public.save_event(p_id, p_create, p_scope_id, p_title,
    p_description, p_location_text, p_starts_at, p_ends_at, p_capacity,
    p_recurrence_frequency, p_recurrence_interval, p_recurrence_weekdays,
    p_recurrence_month_day, p_recurrence_until, p_recurrence_count,
    p_reminder_offsets_minutes, p_host_name);
  if p_create then
    insert into private.event_create_receipts(event_id, actor_id, request_payload)
    values(v_result, v_actor, v_payload);
  end if;
  -- No worker/cron activation: bounded cleanup only after a successful actor call.
  delete from private.event_create_receipts as receipt where receipt.event_id in (
    select expired.event_id from private.event_create_receipts as expired
    where expired.actor_id = v_actor and expired.created_at < pg_catalog.statement_timestamp() - interval '90 days'
    order by expired.created_at, expired.event_id limit 100
  );
  return v_result;
end;
$$;
revoke all on function public.save_event_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer) from public, anon, authenticated;
grant execute on function public.save_event_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer) to authenticated;
comment on function public.save_event_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer) is
  'Exact-scope consent/proof-bound event mutation with row-locked expected revision and actor/payload-bound create idempotency. Existing audited save_event performs all final validation.';
