-- First-class scoped events and calendar occurrences.
--
-- Events are deliberately separate from posts. Read access follows active
-- membership in a scope, while write authority is exact-scope only: platform
-- administrators, the current annual president/pastor, or a bounded
-- manage_events delegation. A church minister/executive role by itself is not
-- event write authority.

create or replace function private.governance_capabilities_are_valid(p_capabilities text[])
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select p_capabilities is not null
    and pg_catalog.cardinality(p_capabilities) between 1 and 3
    and pg_catalog.array_position(p_capabilities, null) is null
    and not exists (
      select 1
      from pg_catalog.unnest(p_capabilities) as capability(code)
      where capability.code not in ('manage_officers', 'view_roster', 'manage_events')
    )
    and pg_catalog.cardinality(p_capabilities) = (
      select pg_catalog.count(distinct capability.code)
      from pg_catalog.unnest(p_capabilities) as capability(code)
    );
$$;

create or replace function private.has_active_governance_delegation(
  p_scope_id uuid,
  p_user_id uuid,
  p_capability text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_capability in ('manage_officers', 'view_roster', 'manage_events')
    and private.is_user_active_in_governance_scope(p_scope_id, p_user_id)
    and exists (
      select 1
      from public.governance_authority_delegations as delegation
      where delegation.scope_id = p_scope_id
        and delegation.delegate_user_id = p_user_id
        and delegation.revoked_at is null
        and delegation.starts_at <= pg_catalog.statement_timestamp()
        and delegation.expires_at > pg_catalog.statement_timestamp()
        and p_capability = any(delegation.capabilities)
        and private.has_native_governance_authority(
          p_scope_id,
          delegation.grantor_user_id
        )
    );
$$;

revoke all on function private.governance_capabilities_are_valid(text[])
  from public, anon, authenticated;
revoke all on function private.has_active_governance_delegation(uuid, uuid, text)
  from public, anon, authenticated;

create table public.events (
  id uuid primary key,
  scope_id uuid not null references public.governance_scopes(id) on delete restrict,
  title text not null check (char_length(title) between 1 and 200),
  description text check (description is null or char_length(description) <= 10000),
  location_text text check (location_text is null or char_length(location_text) <= 500),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  capacity integer check (capacity is null or capacity between 1 and 100000),
  timezone text not null default 'Asia/Seoul' check (timezone = 'Asia/Seoul'),
  recurrence_frequency text not null default 'none' check (
    recurrence_frequency in ('none', 'daily', 'weekly', 'monthly')
  ),
  recurrence_interval smallint not null default 1 check (recurrence_interval between 1 and 30),
  recurrence_weekdays smallint[] not null default '{}'::smallint[],
  recurrence_month_day smallint check (recurrence_month_day between 1 and 31),
  recurrence_until timestamptz,
  recurrence_count smallint check (recurrence_count between 2 and 366),
  reminder_offsets_minutes integer[] not null default array[1440, 60]::integer[],
  status text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
  cancellation_reason text check (
    cancellation_reason is null or char_length(cancellation_reason) between 2 and 500
  ),
  cancelled_at timestamptz,
  revision integer not null default 1 check (revision > 0),
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint events_duration_check check (
    ends_at > starts_at and ends_at <= starts_at + interval '7 days'
  ),
  constraint events_cancellation_state_check check (
    (status = 'scheduled' and cancellation_reason is null and cancelled_at is null)
    or (status = 'cancelled' and cancellation_reason is not null and cancelled_at is not null)
  ),
  constraint events_recurrence_shape_check check (
    (
      recurrence_frequency = 'none'
      and recurrence_interval = 1
      and pg_catalog.cardinality(recurrence_weekdays) = 0
      and recurrence_month_day is null
      and recurrence_until is null
      and recurrence_count is null
    )
    or (
      recurrence_frequency = 'daily'
      and recurrence_interval between 1 and 30
      and pg_catalog.cardinality(recurrence_weekdays) = 0
      and recurrence_month_day is null
      and ((recurrence_until is null) <> (recurrence_count is null))
    )
    or (
      recurrence_frequency = 'weekly'
      and recurrence_interval between 1 and 4
      and pg_catalog.cardinality(recurrence_weekdays) between 1 and 7
      and recurrence_month_day is null
      and ((recurrence_until is null) <> (recurrence_count is null))
    )
    or (
      recurrence_frequency = 'monthly'
      and recurrence_interval between 1 and 12
      and pg_catalog.cardinality(recurrence_weekdays) = 0
      and recurrence_month_day is not null
      and ((recurrence_until is null) <> (recurrence_count is null))
    )
  ),
  constraint events_recurrence_until_check check (
    recurrence_until is null
    or (
      recurrence_until > starts_at
      and recurrence_until <= starts_at + interval '2 years'
    )
  )
);

comment on table public.events is
  'First-class event definitions at one exact governance scope; never represented as posts.';
comment on column public.events.reminder_offsets_minutes is
  'Server-authoritative reminder offsets. Delivery workers consume these values; clients never schedule authoritative reminders.';

create index events_scope_start_idx
  on public.events (scope_id, starts_at, id)
  where status = 'scheduled';
create index events_updated_idx on public.events (updated_at desc);

create table public.event_occurrences (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  occurrence_index integer not null check (occurrence_index >= 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint event_occurrences_duration_check check (
    ends_at > starts_at and ends_at <= starts_at + interval '7 days'
  ),
  unique (event_id, occurrence_index),
  unique (event_id, starts_at)
);

create index event_occurrences_upcoming_idx
  on public.event_occurrences (starts_at, event_id)
  where status = 'scheduled';

create table public.event_rsvps (
  occurrence_id uuid not null references public.event_occurrences(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  response text not null check (response in ('yes', 'no', 'maybe', 'waitlist')),
  responded_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (occurrence_id, user_id)
);

create index event_rsvps_waitlist_idx
  on public.event_rsvps (occurrence_id, responded_at, user_id)
  where response = 'waitlist';
create index event_rsvps_reminder_candidates_idx
  on public.event_rsvps (occurrence_id, user_id)
  where response in ('yes', 'maybe');

create table public.event_revisions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  revision integer not null check (revision > 0),
  action text not null check (action in ('created', 'updated', 'cancelled')),
  snapshot jsonb not null,
  changed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (event_id, revision)
);

comment on table public.event_revisions is
  'Append-only event definition and cancellation history for exact-scope managers.';

create table private.event_rsvp_operations (
  actor_id uuid not null,
  operation_id uuid not null,
  occurrence_id uuid not null,
  requested_response text not null,
  result jsonb not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_id, operation_id)
);

create table private.event_mutation_operations (
  actor_id uuid not null,
  operation_id uuid not null,
  action text not null check (action in ('cancel')),
  event_id uuid not null,
  request_fingerprint text not null,
  result jsonb not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_id, operation_id)
);

create table private.event_reminder_deliveries (
  id uuid primary key default gen_random_uuid(),
  occurrence_id uuid not null references public.event_occurrences(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reminder_offset_minutes integer not null check (
    reminder_offset_minutes between 0 and 40320
  ),
  scheduled_for timestamptz not null,
  occurrence_starts_at timestamptz not null,
  event_revision integer not null check (event_revision > 0),
  notification_id uuid unique references public.notifications(id) on delete set null,
  dispatched_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (occurrence_id, user_id, reminder_offset_minutes),
  constraint event_reminder_delivery_schedule_check check (
    scheduled_for = occurrence_starts_at
      - pg_catalog.make_interval(mins => reminder_offset_minutes)
  )
);

comment on table private.event_reminder_deliveries is
  'Idempotency ledger for server-clock event reminders. Each RSVP user receives an occurrence/offset reminder at most once.';

revoke all on table private.event_rsvp_operations from public, anon, authenticated;
revoke all on table private.event_mutation_operations from public, anon, authenticated;
revoke all on table private.event_reminder_deliveries from public, anon, authenticated;

create or replace function private.event_smallint_array_is_unique_and_bounded(
  p_values smallint[],
  p_min smallint,
  p_max smallint,
  p_max_items integer
)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select p_values is not null
    and pg_catalog.cardinality(p_values) <= p_max_items
    and pg_catalog.array_position(p_values, null) is null
    and not exists (
      select 1 from pg_catalog.unnest(p_values) as value(item)
      where value.item < p_min or value.item > p_max
    )
    and pg_catalog.cardinality(p_values) = (
      select pg_catalog.count(distinct value.item)
      from pg_catalog.unnest(p_values) as value(item)
    );
$$;

create or replace function private.event_integer_array_is_unique_and_bounded(
  p_values integer[],
  p_min integer,
  p_max integer,
  p_max_items integer
)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select p_values is not null
    and pg_catalog.cardinality(p_values) <= p_max_items
    and pg_catalog.array_position(p_values, null) is null
    and not exists (
      select 1 from pg_catalog.unnest(p_values) as value(item)
      where value.item < p_min or value.item > p_max
    )
    and pg_catalog.cardinality(p_values) = (
      select pg_catalog.count(distinct value.item)
      from pg_catalog.unnest(p_values) as value(item)
    );
$$;

alter table public.events
  add constraint events_recurrence_weekdays_values_check check (
    private.event_smallint_array_is_unique_and_bounded(
      recurrence_weekdays,
      1::smallint,
      7::smallint,
      7
    )
  ),
  add constraint events_reminder_offsets_values_check check (
    private.event_integer_array_is_unique_and_bounded(
      reminder_offsets_minutes,
      0,
      40320,
      5
    )
  );

revoke all on function private.event_smallint_array_is_unique_and_bounded(smallint[], smallint, smallint, integer)
  from public, anon, authenticated;
revoke all on function private.event_integer_array_is_unique_and_bounded(integer[], integer, integer, integer)
  from public, anon, authenticated;

create or replace function private.can_read_event_scope(p_scope_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.governance_scopes as scope
      where scope.id = p_scope_id
        and scope.is_active
        and (
          scope.scope_type <> 'church'::public.governance_scope_type
          or exists (
            select 1
            from public.organizations as organization
            where organization.id = scope.organization_id
              and organization.status = 'active'::public.organization_status
          )
        )
        and (
          private.is_platform_admin(p_actor_id)
          or private.is_user_active_in_governance_scope(p_scope_id, p_actor_id)
        )
    );
$$;

create or replace function private.can_manage_events(p_scope_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_native_governance_authority(p_scope_id, p_actor_id)
    or private.has_active_governance_delegation(
      p_scope_id,
      p_actor_id,
      'manage_events'
    );
$$;

revoke all on function private.can_read_event_scope(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_manage_events(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.validate_event_definition()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_scope public.governance_scopes%rowtype;
  v_seoul_start timestamp without time zone;
begin
  select * into v_scope
  from public.governance_scopes as scope
  where scope.id = new.scope_id
    and scope.is_active;

  if not found then
    raise exception 'active_event_scope_required' using errcode = '23514';
  end if;
  if v_scope.scope_type = 'church'::public.governance_scope_type
    and not exists (
      select 1
      from public.organizations as organization
      where organization.id = v_scope.organization_id
        and organization.status = 'active'::public.organization_status
    ) then
    raise exception 'active_event_church_required' using errcode = '23514';
  end if;

  if new.starts_at < pg_catalog.statement_timestamp() - interval '1 day'
    or new.starts_at > pg_catalog.statement_timestamp() + interval '3 years' then
    raise exception 'event_start_outside_allowed_window' using errcode = '23514';
  end if;

  v_seoul_start := pg_catalog.timezone('Asia/Seoul', new.starts_at);
  if new.recurrence_frequency = 'weekly'
    and not (
      extract(isodow from v_seoul_start)::smallint = any(new.recurrence_weekdays)
    ) then
    raise exception 'weekly_recurrence_must_include_start_weekday' using errcode = '23514';
  end if;
  if new.recurrence_frequency = 'monthly'
    and new.recurrence_month_day <> extract(day from v_seoul_start)::smallint then
    raise exception 'monthly_recurrence_day_must_match_start' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    if old.scope_id is distinct from new.scope_id
      or old.created_by is distinct from new.created_by
      or old.created_at is distinct from new.created_at then
      raise exception 'event_scope_and_creator_are_immutable' using errcode = '42501';
    end if;
    if old.status = 'cancelled' and row(new.*) is distinct from row(old.*) then
      raise exception 'cancelled_event_is_immutable' using errcode = '42501';
    end if;
    if exists (
      select 1
      from public.event_occurrences as occurrence
      join public.event_rsvps as rsvp on rsvp.occurrence_id = occurrence.id
      where occurrence.event_id = old.id
    ) and row(
      old.starts_at,
      old.ends_at,
      old.capacity,
      old.recurrence_frequency,
      old.recurrence_interval,
      old.recurrence_weekdays,
      old.recurrence_month_day,
      old.recurrence_until,
      old.recurrence_count
    ) is distinct from row(
      new.starts_at,
      new.ends_at,
      new.capacity,
      new.recurrence_frequency,
      new.recurrence_interval,
      new.recurrence_weekdays,
      new.recurrence_month_day,
      new.recurrence_until,
      new.recurrence_count
    ) then
      raise exception 'event_schedule_locked_after_rsvp' using errcode = '55000';
    end if;
    if old.reminder_offsets_minutes is distinct from new.reminder_offsets_minutes
      and exists (
        select 1
        from public.event_occurrences as occurrence
        join private.event_reminder_deliveries as delivery
          on delivery.occurrence_id = occurrence.id
        where occurrence.event_id = old.id
      ) then
      raise exception 'event_reminders_locked_after_delivery' using errcode = '55000';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.validate_event_definition()
  from public, anon, authenticated;

create trigger events_validate_definition
before insert or update on public.events
for each row execute function private.validate_event_definition();

create trigger events_set_updated_at
before update on public.events
for each row execute function private.set_updated_at();

create trigger event_rsvps_set_updated_at
before update on public.event_rsvps
for each row execute function private.set_updated_at();

create or replace function private.rebuild_event_occurrences(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_event public.events%rowtype;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_start_date date;
  v_end_date date;
  v_candidate_date date;
  v_candidate_local timestamp without time zone;
  v_candidate_start timestamptz;
  v_duration interval;
  v_month_difference integer;
  v_generated integer := 0;
  v_target_count integer;
  v_matches boolean;
begin
  select * into v_event
  from public.events as event
  where event.id = p_event_id
  for update;

  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if exists (
    select 1
    from public.event_occurrences as occurrence
    join public.event_rsvps as rsvp on rsvp.occurrence_id = occurrence.id
    where occurrence.event_id = p_event_id
  ) then
    raise exception 'event_schedule_locked_after_rsvp' using errcode = '55000';
  end if;

  delete from public.event_occurrences where event_id = p_event_id;

  v_local_start := pg_catalog.timezone('Asia/Seoul', v_event.starts_at);
  v_local_end := pg_catalog.timezone('Asia/Seoul', v_event.ends_at);
  v_duration := v_local_end - v_local_start;
  v_start_date := v_local_start::date;

  if v_event.recurrence_frequency = 'none' then
    insert into public.event_occurrences (
      event_id, occurrence_index, starts_at, ends_at, status
    ) values (
      v_event.id,
      0,
      v_event.starts_at,
      v_event.ends_at,
      v_event.status
    );
    return 1;
  end if;

  v_end_date := case
    when v_event.recurrence_until is not null
      then pg_catalog.timezone('Asia/Seoul', v_event.recurrence_until)::date
    else (v_start_date + interval '2 years')::date
  end;
  v_target_count := coalesce(v_event.recurrence_count, 366);
  v_candidate_date := v_start_date;

  while v_candidate_date <= v_end_date and v_generated < v_target_count loop
    v_matches := false;

    if v_event.recurrence_frequency = 'daily' then
      v_matches := mod(
        v_candidate_date - v_start_date,
        v_event.recurrence_interval
      ) = 0;
    elsif v_event.recurrence_frequency = 'weekly' then
      v_matches := mod(
        ((v_candidate_date - v_start_date) / 7),
        v_event.recurrence_interval
      ) = 0
      and extract(isodow from v_candidate_date)::smallint = any(v_event.recurrence_weekdays);
    elsif v_event.recurrence_frequency = 'monthly' then
      v_month_difference := (
        extract(year from v_candidate_date)::integer
        - extract(year from v_start_date)::integer
      ) * 12 + (
        extract(month from v_candidate_date)::integer
        - extract(month from v_start_date)::integer
      );
      v_matches := mod(v_month_difference, v_event.recurrence_interval) = 0
        and extract(day from v_candidate_date)::smallint = v_event.recurrence_month_day;
    end if;

    if v_matches then
      v_candidate_local := v_candidate_date + v_local_start::time;
      v_candidate_start := v_candidate_local at time zone 'Asia/Seoul';
      if v_event.recurrence_until is null
        or v_candidate_start <= v_event.recurrence_until then
        insert into public.event_occurrences (
          event_id, occurrence_index, starts_at, ends_at, status
        ) values (
          v_event.id,
          v_generated,
          v_candidate_start,
          (v_candidate_local + v_duration) at time zone 'Asia/Seoul',
          v_event.status
        );
        v_generated := v_generated + 1;
      end if;
    end if;

    v_candidate_date := v_candidate_date + 1;
  end loop;

  if v_generated < 2 then
    raise exception 'recurrence_must_generate_at_least_two_occurrences' using errcode = '23514';
  end if;
  if v_event.recurrence_count is not null
    and v_generated <> v_event.recurrence_count then
    raise exception 'recurrence_count_exceeds_two_year_window' using errcode = '23514';
  end if;

  return v_generated;
end;
$$;

revoke all on function private.rebuild_event_occurrences(uuid)
  from public, anon, authenticated;

create or replace function private.capture_event_revision()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_action text;
begin
  v_action := case
    when tg_op = 'INSERT' then 'created'
    when new.status = 'cancelled' and old.status <> 'cancelled' then 'cancelled'
    else 'updated'
  end;

  insert into public.event_revisions (
    event_id,
    revision,
    action,
    snapshot,
    changed_by
  ) values (
    new.id,
    new.revision,
    v_action,
    pg_catalog.to_jsonb(new),
    coalesce(auth.uid(), new.updated_by, new.created_by)
  );

  return new;
end;
$$;

revoke all on function private.capture_event_revision()
  from public, anon, authenticated;

create trigger events_capture_revision
after insert or update on public.events
for each row execute function private.capture_event_revision();

alter table public.events enable row level security;
alter table public.event_occurrences enable row level security;
alter table public.event_rsvps enable row level security;
alter table public.event_revisions enable row level security;

create policy events_select_scope_members
on public.events for select to authenticated
using (private.can_read_event_scope(scope_id, auth.uid()));

create policy event_occurrences_select_scope_members
on public.event_occurrences for select to authenticated
using (
  exists (
    select 1
    from public.events as event
    where event.id = event_occurrences.event_id
      and private.can_read_event_scope(event.scope_id, auth.uid())
  )
);

create policy event_rsvps_select_self_or_manager
on public.event_rsvps for select to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1
    from public.event_occurrences as occurrence
    join public.events as event on event.id = occurrence.event_id
    where occurrence.id = event_rsvps.occurrence_id
      and private.can_manage_events(event.scope_id, auth.uid())
  )
);

create policy event_revisions_select_managers
on public.event_revisions for select to authenticated
using (
  exists (
    select 1
    from public.events as event
    where event.id = event_revisions.event_id
      and private.can_manage_events(event.scope_id, auth.uid())
  )
);

revoke all on table public.events from public, anon, authenticated;
revoke all on table public.event_occurrences from public, anon, authenticated;
revoke all on table public.event_rsvps from public, anon, authenticated;
revoke all on table public.event_revisions from public, anon, authenticated;

create or replace function public.save_event(
  p_id uuid,
  p_create boolean,
  p_scope_id uuid,
  p_title text,
  p_description text,
  p_location_text text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_capacity integer,
  p_recurrence_frequency text,
  p_recurrence_interval integer,
  p_recurrence_weekdays smallint[],
  p_recurrence_month_day integer,
  p_recurrence_until timestamptz,
  p_recurrence_count integer,
  p_reminder_offsets_minutes integer[]
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_existing public.events%rowtype;
  v_title text := nullif(pg_catalog.btrim(p_title), '');
  v_description text := nullif(pg_catalog.btrim(p_description), '');
  v_location text := nullif(pg_catalog.btrim(p_location_text), '');
  v_frequency text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_recurrence_frequency, 'none')));
  v_interval smallint := coalesce(p_recurrence_interval, 1)::smallint;
  v_weekdays smallint[] := coalesce(p_recurrence_weekdays, '{}'::smallint[]);
  v_month_day smallint := p_recurrence_month_day::smallint;
  v_count smallint := p_recurrence_count::smallint;
  v_reminders integer[] := coalesce(p_reminder_offsets_minutes, '{}'::integer[]);
  v_schedule_changed boolean;
  v_organization_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_id is null or p_create is null or p_scope_id is null then
    raise exception 'event_id_create_flag_and_scope_required' using errcode = '22023';
  end if;
  if v_title is null or char_length(v_title) > 200 then
    raise exception 'invalid_event_title' using errcode = '23514';
  end if;
  if v_description is not null and char_length(v_description) > 10000 then
    raise exception 'event_description_too_long' using errcode = '22001';
  end if;
  if v_location is not null and char_length(v_location) > 500 then
    raise exception 'event_location_too_long' using errcode = '22001';
  end if;
  if p_starts_at is null or p_ends_at is null then
    raise exception 'event_start_and_end_required' using errcode = '22023';
  end if;
  if v_frequency not in ('none', 'daily', 'weekly', 'monthly') then
    raise exception 'invalid_event_recurrence_frequency' using errcode = '23514';
  end if;
  if not private.event_smallint_array_is_unique_and_bounded(
      v_weekdays, 1::smallint, 7::smallint, 7
    )
    or not private.event_integer_array_is_unique_and_bounded(
      v_reminders, 0, 40320, 5
    ) then
    raise exception 'invalid_event_array_values' using errcode = '23514';
  end if;
  if not private.can_manage_events(p_scope_id, v_actor_id) then
    raise exception 'event_management_forbidden' using errcode = '42501';
  end if;

  perform private.require_aal2('event_save');
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('event:' || p_id::text, 0)
  );

  select * into v_existing
  from public.events as event
  where event.id = p_id
  for update;

  if found then
    if v_existing.scope_id <> p_scope_id then
      raise exception 'event_scope_is_immutable' using errcode = '42501';
    end if;
    if p_create and v_existing.created_by is distinct from v_actor_id then
      raise exception 'event_operation_id_conflict' using errcode = '42501';
    end if;
    if v_existing.status <> 'scheduled' then
      raise exception 'cancelled_event_is_immutable' using errcode = '42501';
    end if;

    if row(
      v_existing.title,
      v_existing.description,
      v_existing.location_text,
      v_existing.starts_at,
      v_existing.ends_at,
      v_existing.capacity,
      v_existing.recurrence_frequency,
      v_existing.recurrence_interval,
      v_existing.recurrence_weekdays,
      v_existing.recurrence_month_day,
      v_existing.recurrence_until,
      v_existing.recurrence_count,
      v_existing.reminder_offsets_minutes
    ) is not distinct from row(
      v_title,
      v_description,
      v_location,
      p_starts_at,
      p_ends_at,
      p_capacity,
      v_frequency,
      v_interval,
      v_weekdays,
      v_month_day,
      p_recurrence_until,
      v_count,
      v_reminders
    ) then
      return p_id;
    end if;

    v_schedule_changed := row(
      v_existing.starts_at,
      v_existing.ends_at,
      v_existing.capacity,
      v_existing.recurrence_frequency,
      v_existing.recurrence_interval,
      v_existing.recurrence_weekdays,
      v_existing.recurrence_month_day,
      v_existing.recurrence_until,
      v_existing.recurrence_count
    ) is distinct from row(
      p_starts_at,
      p_ends_at,
      p_capacity,
      v_frequency,
      v_interval,
      v_weekdays,
      v_month_day,
      p_recurrence_until,
      v_count
    );

    perform private.consume_rate_limit(v_actor_id, 'event_mutations', 30, 3600, 1);
    update public.events
    set
      title = v_title,
      description = v_description,
      location_text = v_location,
      starts_at = p_starts_at,
      ends_at = p_ends_at,
      capacity = p_capacity,
      recurrence_frequency = v_frequency,
      recurrence_interval = v_interval,
      recurrence_weekdays = v_weekdays,
      recurrence_month_day = v_month_day,
      recurrence_until = p_recurrence_until,
      recurrence_count = v_count,
      reminder_offsets_minutes = v_reminders,
      revision = revision + 1,
      updated_by = v_actor_id
    where id = p_id;

    if v_schedule_changed then
      perform private.rebuild_event_occurrences(p_id);
    end if;
  else
    if not p_create then
      raise exception 'event_not_found' using errcode = 'P0002';
    end if;
    perform private.consume_rate_limit(v_actor_id, 'event_mutations', 30, 3600, 1);
    insert into public.events (
      id,
      scope_id,
      title,
      description,
      location_text,
      starts_at,
      ends_at,
      capacity,
      recurrence_frequency,
      recurrence_interval,
      recurrence_weekdays,
      recurrence_month_day,
      recurrence_until,
      recurrence_count,
      reminder_offsets_minutes,
      created_by,
      updated_by
    ) values (
      p_id,
      p_scope_id,
      v_title,
      v_description,
      v_location,
      p_starts_at,
      p_ends_at,
      p_capacity,
      v_frequency,
      v_interval,
      v_weekdays,
      v_month_day,
      p_recurrence_until,
      v_count,
      v_reminders,
      v_actor_id,
      v_actor_id
    );
    perform private.rebuild_event_occurrences(p_id);
  end if;

  select scope.organization_id into v_organization_id
  from public.governance_scopes as scope
  where scope.id = p_scope_id;

  perform private.write_audit(
    v_actor_id,
    case when p_create then 'event.saved' else 'event.updated' end,
    'event',
    p_id,
    v_organization_id,
    null,
    pg_catalog.jsonb_build_object('scope_id', p_scope_id)
  );
  return p_id;
end;
$$;

revoke all on function public.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) from public, anon, authenticated;
grant execute on function public.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) to authenticated;

create or replace function public.cancel_event(
  p_event_id uuid,
  p_client_operation_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_event public.events%rowtype;
  v_reason text := nullif(pg_catalog.btrim(p_reason), '');
  v_fingerprint text;
  v_operation private.event_mutation_operations%rowtype;
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_event_id is null or p_client_operation_id is null then
    raise exception 'event_and_operation_id_required' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    raise exception 'invalid_event_cancellation_reason' using errcode = '23514';
  end if;

  v_fingerprint := pg_catalog.encode(
    extensions.digest(p_event_id::text || ':' || v_reason, 'sha256'),
    'hex'
  );
  select * into v_operation
  from private.event_mutation_operations as operation
  where operation.actor_id = v_actor_id
    and operation.operation_id = p_client_operation_id;
  if found then
    if v_operation.action <> 'cancel'
      or v_operation.event_id <> p_event_id
      or v_operation.request_fingerprint <> v_fingerprint then
      raise exception 'event_operation_id_conflict' using errcode = '42501';
    end if;
    return v_operation.result;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('event:' || p_event_id::text, 0)
  );
  select * into v_event
  from public.events as event
  where event.id = p_event_id
  for update;

  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_events(v_event.scope_id, v_actor_id) then
    raise exception 'event_management_forbidden' using errcode = '42501';
  end if;
  perform private.require_aal2('event_cancel');
  if v_event.status = 'cancelled' then
    raise exception 'event_already_cancelled' using errcode = '55000';
  end if;

  perform private.consume_rate_limit(v_actor_id, 'event_cancellations', 20, 3600, 1);
  update public.events
  set
    status = 'cancelled',
    cancellation_reason = v_reason,
    cancelled_at = pg_catalog.clock_timestamp(),
    revision = revision + 1,
    updated_by = v_actor_id
  where id = p_event_id;

  update public.event_occurrences
  set status = 'cancelled'
  where event_id = p_event_id
    and status = 'scheduled';

  v_result := pg_catalog.jsonb_build_object(
    'event_id', p_event_id,
    'status', 'cancelled',
    'reason', v_reason
  );
  insert into private.event_mutation_operations (
    actor_id,
    operation_id,
    action,
    event_id,
    request_fingerprint,
    result
  ) values (
    v_actor_id,
    p_client_operation_id,
    'cancel',
    p_event_id,
    v_fingerprint,
    v_result
  );

  perform private.write_audit(
    v_actor_id,
    'event.cancelled',
    'event',
    p_event_id,
    null,
    null,
    pg_catalog.jsonb_build_object('scope_id', v_event.scope_id)
  );
  return v_result;
end;
$$;

revoke all on function public.cancel_event(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.cancel_event(uuid, uuid, text)
  to authenticated;

create or replace function public.respond_to_event(
  p_occurrence_id uuid,
  p_response text,
  p_client_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_requested_response text := pg_catalog.lower(pg_catalog.btrim(p_response));
  v_occurrence public.event_occurrences%rowtype;
  v_event public.events%rowtype;
  v_existing public.event_rsvps%rowtype;
  v_operation private.event_rsvp_operations%rowtype;
  v_effective_response text;
  v_yes_count integer;
  v_waitlist_count integer;
  v_waitlist_position integer;
  v_promote_user_id uuid;
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_occurrence_id is null or p_client_operation_id is null then
    raise exception 'occurrence_and_operation_id_required' using errcode = '22023';
  end if;
  if v_requested_response not in ('yes', 'no', 'maybe') then
    raise exception 'invalid_event_response' using errcode = '23514';
  end if;

  select * into v_operation
  from private.event_rsvp_operations as operation
  where operation.actor_id = v_actor_id
    and operation.operation_id = p_client_operation_id;
  if found then
    if v_operation.occurrence_id <> p_occurrence_id
      or v_operation.requested_response <> v_requested_response then
      raise exception 'event_rsvp_operation_id_conflict' using errcode = '42501';
    end if;
    return v_operation.result;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('event-rsvp:' || p_occurrence_id::text, 0)
  );
  select * into v_occurrence
  from public.event_occurrences as occurrence
  where occurrence.id = p_occurrence_id
  for update;
  if not found then
    raise exception 'event_occurrence_not_found' using errcode = 'P0002';
  end if;

  select * into v_event
  from public.events as event
  where event.id = v_occurrence.event_id;
  if not private.can_read_event_scope(v_event.scope_id, v_actor_id) then
    raise exception 'event_read_forbidden' using errcode = '42501';
  end if;
  if v_event.status <> 'scheduled'
    or v_occurrence.status <> 'scheduled'
    or v_occurrence.starts_at <= pg_catalog.statement_timestamp() then
    raise exception 'event_rsvp_closed' using errcode = '55000';
  end if;

  select * into v_existing
  from public.event_rsvps as rsvp
  where rsvp.occurrence_id = p_occurrence_id
    and rsvp.user_id = v_actor_id
  for update;

  if v_requested_response = 'yes' and v_event.capacity is not null then
    select pg_catalog.count(*)::integer into v_yes_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = p_occurrence_id
      and rsvp.response = 'yes'
      and rsvp.user_id <> v_actor_id;
    v_effective_response := case
      when v_yes_count >= v_event.capacity then 'waitlist'
      else 'yes'
    end;
  else
    v_effective_response := v_requested_response;
  end if;

  perform private.consume_rate_limit(v_actor_id, 'event_rsvps', 30, 60, 1);
  insert into public.event_rsvps (
    occurrence_id,
    user_id,
    response,
    responded_at
  ) values (
    p_occurrence_id,
    v_actor_id,
    v_effective_response,
    pg_catalog.clock_timestamp()
  )
  on conflict (occurrence_id, user_id)
  do update set
    response = excluded.response,
    responded_at = case
      when event_rsvps.response is distinct from excluded.response
        then excluded.responded_at
      else event_rsvps.responded_at
    end;

  if found
    and v_existing.response = 'yes'
    and v_effective_response <> 'yes' then
    select rsvp.user_id into v_promote_user_id
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = p_occurrence_id
      and rsvp.response = 'waitlist'
    order by rsvp.responded_at, rsvp.user_id
    limit 1
    for update;

    if v_promote_user_id is not null then
      update public.event_rsvps
      set response = 'yes'
      where occurrence_id = p_occurrence_id
        and user_id = v_promote_user_id;

      insert into public.notifications (
        user_id,
        kind,
        title,
        body,
        entity_type,
        entity_id,
        metadata
      ) values (
        v_promote_user_id,
        'admin_action'::public.notification_kind,
        '일정 참석이 확정되었습니다',
        '대기 중이던 일정에 자리가 생겨 참석으로 변경되었습니다. 앱에서 일정을 확인해 주세요.',
        'event_occurrence',
        p_occurrence_id,
        pg_catalog.jsonb_build_object('event_id', v_event.id)
      );
    end if;
  end if;

  select
    pg_catalog.count(*) filter (where rsvp.response = 'yes')::integer,
    pg_catalog.count(*) filter (where rsvp.response = 'waitlist')::integer
  into v_yes_count, v_waitlist_count
  from public.event_rsvps as rsvp
  where rsvp.occurrence_id = p_occurrence_id;

  if v_effective_response = 'waitlist' then
    select position into v_waitlist_position
    from (
      select
        rsvp.user_id,
        row_number() over (order by rsvp.responded_at, rsvp.user_id)::integer as position
      from public.event_rsvps as rsvp
      where rsvp.occurrence_id = p_occurrence_id
        and rsvp.response = 'waitlist'
    ) as positions
    where positions.user_id = v_actor_id;
  end if;

  v_result := pg_catalog.jsonb_build_object(
    'occurrence_id', p_occurrence_id,
    'requested_response', v_requested_response,
    'response', v_effective_response,
    'yes_count', v_yes_count,
    'waitlist_count', v_waitlist_count,
    'waitlist_position', v_waitlist_position
  );
  insert into private.event_rsvp_operations (
    actor_id,
    operation_id,
    occurrence_id,
    requested_response,
    result
  ) values (
    v_actor_id,
    p_client_operation_id,
    p_occurrence_id,
    v_requested_response,
    v_result
  );

  perform private.write_audit(
    v_actor_id,
    'event.rsvp',
    'event_occurrence',
    p_occurrence_id,
    null,
    v_actor_id,
    pg_catalog.jsonb_build_object('response', v_effective_response)
  );
  return v_result;
end;
$$;

revoke all on function public.respond_to_event(uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.respond_to_event(uuid, text, uuid)
  to authenticated;

create or replace function public.get_my_event_scopes()
returns table (
  scope_id uuid,
  scope_type public.governance_scope_type,
  scope_name text,
  organization_id uuid,
  can_manage_events boolean,
  authority_source text
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

  return query
  select
    scope.id,
    scope.scope_type,
    scope.display_name,
    scope.organization_id,
    private.can_manage_events(scope.id, v_actor_id),
    case
      when private.is_platform_admin(v_actor_id) then 'platform_admin'
      when private.has_current_governance_office(
        scope.id,
        v_actor_id,
        array['president', 'pastor']::text[]
      ) then 'office'
      when private.has_active_governance_delegation(
        scope.id,
        v_actor_id,
        'manage_events'
      ) then 'delegation'
      else 'member'
    end
  from public.governance_scopes as scope
  where private.can_read_event_scope(scope.id, v_actor_id)
  order by
    case scope.scope_type
      when 'general_assembly'::public.governance_scope_type then 1
      when 'presbytery'::public.governance_scope_type then 2
      else 3
    end,
    scope.display_name;
end;
$$;

revoke all on function public.get_my_event_scopes()
  from public, anon, authenticated;
grant execute on function public.get_my_event_scopes()
  to authenticated;

create or replace function public.list_event_occurrences(
  p_from timestamptz,
  p_to timestamptz,
  p_scope_id uuid default null,
  p_limit integer default 100
)
returns table (
  occurrence_id uuid,
  event_id uuid,
  scope_id uuid,
  scope_type public.governance_scope_type,
  scope_name text,
  title text,
  description text,
  location_text text,
  starts_at timestamptz,
  ends_at timestamptz,
  capacity integer,
  event_status text,
  occurrence_status text,
  recurrence_frequency text,
  recurrence_interval smallint,
  recurrence_weekdays smallint[],
  recurrence_month_day smallint,
  recurrence_until timestamptz,
  recurrence_count smallint,
  reminder_offsets_minutes integer[],
  revision integer,
  own_response text,
  yes_count bigint,
  maybe_count bigint,
  waitlist_count bigint,
  waitlist_position bigint,
  can_manage boolean
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
  if p_from is null or p_to is null
    or p_to <= p_from
    or p_to > p_from + interval '366 days' then
    raise exception 'invalid_event_occurrence_range' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'invalid_event_occurrence_limit' using errcode = '22023';
  end if;
  if p_scope_id is not null
    and not private.can_read_event_scope(p_scope_id, v_actor_id) then
    raise exception 'event_read_forbidden' using errcode = '42501';
  end if;

  return query
  select
    occurrence.id,
    event.id,
    event.scope_id,
    scope.scope_type,
    scope.display_name,
    event.title,
    event.description,
    event.location_text,
    occurrence.starts_at,
    occurrence.ends_at,
    event.capacity,
    event.status,
    occurrence.status,
    event.recurrence_frequency,
    event.recurrence_interval,
    event.recurrence_weekdays,
    event.recurrence_month_day,
    event.recurrence_until,
    event.recurrence_count,
    event.reminder_offsets_minutes,
    event.revision,
    own_rsvp.response,
    coalesce(totals.yes_count, 0),
    coalesce(totals.maybe_count, 0),
    coalesce(totals.waitlist_count, 0),
    own_rsvp.waitlist_position,
    private.can_manage_events(event.scope_id, v_actor_id)
  from public.event_occurrences as occurrence
  join public.events as event on event.id = occurrence.event_id
  join public.governance_scopes as scope on scope.id = event.scope_id
  left join lateral (
    select
      pg_catalog.count(*) filter (where rsvp.response = 'yes') as yes_count,
      pg_catalog.count(*) filter (where rsvp.response = 'maybe') as maybe_count,
      pg_catalog.count(*) filter (where rsvp.response = 'waitlist') as waitlist_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = occurrence.id
  ) as totals on true
  left join lateral (
    select
      mine.response,
      case
        when mine.response = 'waitlist' then (
          select pg_catalog.count(*)
          from public.event_rsvps as ahead
          where ahead.occurrence_id = occurrence.id
            and ahead.response = 'waitlist'
            and row(ahead.responded_at, ahead.user_id)
              <= row(mine.responded_at, mine.user_id)
        )
        else null
      end as waitlist_position
    from public.event_rsvps as mine
    where mine.occurrence_id = occurrence.id
      and mine.user_id = v_actor_id
  ) as own_rsvp on true
  where occurrence.starts_at >= p_from
    and occurrence.starts_at < p_to
    and (p_scope_id is null or event.scope_id = p_scope_id)
    and private.can_read_event_scope(event.scope_id, v_actor_id)
  order by occurrence.starts_at, event.title, occurrence.id
  limit p_limit;
end;
$$;

revoke all on function public.list_event_occurrences(timestamptz, timestamptz, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.list_event_occurrences(timestamptz, timestamptz, uuid, integer)
  to authenticated;

create or replace function public.get_event_occurrence(p_occurrence_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'occurrence_id', occurrence.id,
    'event_id', event.id,
    'scope_id', event.scope_id,
    'scope_type', scope.scope_type,
    'scope_name', scope.display_name,
    'title', event.title,
    'description', event.description,
    'location_text', event.location_text,
    'starts_at', occurrence.starts_at,
    'ends_at', occurrence.ends_at,
    'capacity', event.capacity,
    'event_status', event.status,
    'occurrence_status', occurrence.status,
    'recurrence_frequency', event.recurrence_frequency,
    'recurrence_interval', event.recurrence_interval,
    'recurrence_weekdays', event.recurrence_weekdays,
    'recurrence_month_day', event.recurrence_month_day,
    'recurrence_until', event.recurrence_until,
    'recurrence_count', event.recurrence_count,
    'reminder_offsets_minutes', event.reminder_offsets_minutes,
    'revision', event.revision,
    'own_response', mine.response,
    'yes_count', coalesce(totals.yes_count, 0),
    'maybe_count', coalesce(totals.maybe_count, 0),
    'waitlist_count', coalesce(totals.waitlist_count, 0),
    'waitlist_position', case
      when mine.response = 'waitlist' then (
        select pg_catalog.count(*)
        from public.event_rsvps as ahead
        where ahead.occurrence_id = occurrence.id
          and ahead.response = 'waitlist'
          and row(ahead.responded_at, ahead.user_id)
            <= row(mine.responded_at, mine.user_id)
      )
      else null
    end,
    'can_manage', private.can_manage_events(event.scope_id, v_actor_id)
  ) into v_result
  from public.event_occurrences as occurrence
  join public.events as event on event.id = occurrence.event_id
  join public.governance_scopes as scope on scope.id = event.scope_id
  left join public.event_rsvps as mine
    on mine.occurrence_id = occurrence.id
   and mine.user_id = v_actor_id
  left join lateral (
    select
      pg_catalog.count(*) filter (where rsvp.response = 'yes') as yes_count,
      pg_catalog.count(*) filter (where rsvp.response = 'maybe') as maybe_count,
      pg_catalog.count(*) filter (where rsvp.response = 'waitlist') as waitlist_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = occurrence.id
  ) as totals on true
  where occurrence.id = p_occurrence_id
    and private.can_read_event_scope(event.scope_id, v_actor_id);

  if v_result is null then
    raise exception 'event_occurrence_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  return v_result;
end;
$$;

revoke all on function public.get_event_occurrence(uuid)
  from public, anon, authenticated;
grant execute on function public.get_event_occurrence(uuid)
  to authenticated;

create or replace function public.list_event_revisions(p_event_id uuid)
returns table (
  revision integer,
  action text,
  snapshot jsonb,
  changed_by uuid,
  changed_by_name text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select event.scope_id into v_scope_id
  from public.events as event
  where event.id = p_event_id;
  if v_scope_id is null then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_events(v_scope_id, v_actor_id) then
    raise exception 'event_revision_read_forbidden' using errcode = '42501';
  end if;

  return query
  select
    history.revision,
    history.action,
    history.snapshot,
    history.changed_by,
    profile.display_name,
    history.created_at
  from public.event_revisions as history
  left join public.profiles as profile on profile.id = history.changed_by
  where history.event_id = p_event_id
  order by history.revision desc;
end;
$$;

revoke all on function public.list_event_revisions(uuid)
  from public, anon, authenticated;
grant execute on function public.list_event_revisions(uuid)
  to authenticated;

create or replace function public.grant_event_management_delegation(
  p_scope_id uuid,
  p_delegate_user_id uuid,
  p_expires_at timestamptz,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_reason text := nullif(pg_catalog.btrim(p_reason), '');
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_rollover timestamptz;
  v_existing public.governance_authority_delegations%rowtype;
  v_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_scope_id is null or p_delegate_user_id is null or p_expires_at is null then
    raise exception 'delegation_scope_target_and_expiry_required' using errcode = '22023';
  end if;
  if p_delegate_user_id = v_actor_id then
    raise exception 'self_delegation_forbidden' using errcode = '42501';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'delegation_reason_too_long' using errcode = '22001';
  end if;
  if not private.has_native_governance_authority(p_scope_id, v_actor_id) then
    raise exception 'native_scope_authority_required_for_delegation' using errcode = '42501';
  end if;
  perform private.require_aal2('event_management_delegation');

  perform 1
  from public.organization_memberships as membership
  join public.organizations as organization on organization.id = membership.organization_id
  join public.profiles as profile on profile.id = membership.user_id
  where membership.user_id = p_delegate_user_id
    and membership.status = 'active'::public.membership_status
    and organization.status = 'active'::public.organization_status
    and profile.deactivated_at is null
    and private.scope_contains_organization(p_scope_id, membership.organization_id)
  limit 1;
  if not found then
    raise exception 'delegation_target_must_be_active_in_scope' using errcode = '23514';
  end if;

  v_rollover := pg_catalog.make_timestamptz(
    private.current_service_year() + 1, 1, 1, 0, 0, 0, 'Asia/Seoul'
  );
  if p_expires_at <= v_now
    or p_expires_at > v_now + interval '90 days'
    or p_expires_at > v_rollover then
    raise exception 'invalid_governance_delegation_expiry' using errcode = '23514';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'governance-delegation:' || p_scope_id::text || ':' || p_delegate_user_id::text,
      0
    )
  );
  select * into v_existing
  from public.governance_authority_delegations as delegation
  where delegation.scope_id = p_scope_id
    and delegation.delegate_user_id = p_delegate_user_id
    and delegation.revoked_at is null
    and delegation.starts_at <= v_now
    and delegation.expires_at > v_now
  limit 1
  for update;

  if found then
    if v_existing.grantor_user_id <> v_actor_id then
      raise exception 'active_delegation_owned_by_another_authority' using errcode = '42501';
    end if;
    update public.governance_authority_delegations
    set
      capabilities = case
        when 'manage_events' = any(capabilities) then capabilities
        else pg_catalog.array_append(capabilities, 'manage_events')
      end,
      expires_at = p_expires_at,
      reason = v_reason
    where id = v_existing.id
    returning id into v_id;
  else
    insert into public.governance_authority_delegations (
      scope_id,
      grantor_user_id,
      delegate_user_id,
      capabilities,
      starts_at,
      expires_at,
      reason
    ) values (
      p_scope_id,
      v_actor_id,
      p_delegate_user_id,
      array['manage_events']::text[],
      v_now,
      p_expires_at,
      v_reason
    ) returning id into v_id;
  end if;

  perform private.write_audit(
    v_actor_id,
    'event.delegation_granted',
    'governance_delegation',
    v_id,
    null,
    p_delegate_user_id,
    pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'capability', 'manage_events',
      'expires_at', p_expires_at
    )
  );
  return v_id;
end;
$$;

revoke all on function public.grant_event_management_delegation(uuid, uuid, timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.grant_event_management_delegation(uuid, uuid, timestamptz, text)
  to authenticated;

create or replace function public.service_dispatch_due_event_reminders(
  p_limit integer default 100
)
returns table (
  dispatched_count integer,
  checked_at timestamptz,
  has_more boolean
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.statement_timestamp();
  v_dispatched integer := 0;
  v_candidate record;
  v_event public.events%rowtype;
  v_occurrence public.event_occurrences%rowtype;
  v_response text;
  v_events_enabled boolean;
  v_due_at timestamptz;
  v_delivery_id uuid;
  v_notification_id uuid;
begin
  perform private.require_service_role('dispatch_due_event_reminders');
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_event_reminder_batch_limit' using errcode = '22023';
  end if;

  -- Serialize scheduler invocations. The per-event/occurrence row locks below
  -- establish a transaction order with edits, cancellations, and RSVP changes.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('event-reminder-dispatch', 0)
  );

  for v_candidate in
    select
      event.id as event_id,
      occurrence.id as occurrence_id,
      rsvp.user_id,
      reminder.minutes as reminder_offset_minutes,
      occurrence.starts_at
        - pg_catalog.make_interval(mins => reminder.minutes) as due_at
    from public.event_occurrences as occurrence
    join public.events as event on event.id = occurrence.event_id
    join public.event_rsvps as rsvp on rsvp.occurrence_id = occurrence.id
    cross join lateral pg_catalog.unnest(event.reminder_offsets_minutes)
      as reminder(minutes)
    left join public.notification_preferences as preference
      on preference.user_id = rsvp.user_id
    where event.status = 'scheduled'
      and occurrence.status = 'scheduled'
      and rsvp.response in ('yes', 'maybe')
      and coalesce(preference.events_enabled, true)
      and private.can_read_event_scope(event.scope_id, rsvp.user_id)
      and occurrence.starts_at
        - pg_catalog.make_interval(mins => reminder.minutes) <= v_now
      and (
        (reminder.minutes > 0 and occurrence.starts_at > v_now)
        or (
          reminder.minutes = 0
          and occurrence.starts_at <= v_now
          and occurrence.starts_at > v_now - interval '5 minutes'
          and occurrence.ends_at > v_now
        )
      )
      and not exists (
        select 1
        from private.event_reminder_deliveries as delivery
        where delivery.occurrence_id = occurrence.id
          and delivery.user_id = rsvp.user_id
          and delivery.reminder_offset_minutes = reminder.minutes
      )
    order by due_at, occurrence.starts_at, occurrence.id, rsvp.user_id, reminder.minutes
    limit p_limit
  loop
    -- Lock in the same event-first order used by save/cancel, then re-check
    -- every authoritative field so a stale candidate cannot be delivered.
    select * into v_event
    from public.events as event
    where event.id = v_candidate.event_id
    for share;
    if not found then
      continue;
    end if;

    select * into v_occurrence
    from public.event_occurrences as occurrence
    where occurrence.id = v_candidate.occurrence_id
      and occurrence.event_id = v_event.id
    for share;
    if not found then
      continue;
    end if;

    select rsvp.response into v_response
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = v_occurrence.id
      and rsvp.user_id = v_candidate.user_id
    for update;
    if not found then
      continue;
    end if;

    select coalesce(
      (
        select preference.events_enabled
        from public.notification_preferences as preference
        where preference.user_id = v_candidate.user_id
      ),
      true
    ) into v_events_enabled;

    v_due_at := v_occurrence.starts_at - pg_catalog.make_interval(
      mins => v_candidate.reminder_offset_minutes
    );
    if v_event.status <> 'scheduled'
      or v_occurrence.status <> 'scheduled'
      or v_response not in ('yes', 'maybe')
      or not v_events_enabled
      or not private.can_read_event_scope(v_event.scope_id, v_candidate.user_id)
      or not (v_candidate.reminder_offset_minutes = any(v_event.reminder_offsets_minutes))
      or v_due_at > v_now
      or (
        v_candidate.reminder_offset_minutes > 0
        and v_occurrence.starts_at <= v_now
      )
      or (
        v_candidate.reminder_offset_minutes = 0
        and (
          v_occurrence.starts_at > v_now
          or v_occurrence.starts_at <= v_now - interval '5 minutes'
          or v_occurrence.ends_at <= v_now
        )
      ) then
      continue;
    end if;

    v_delivery_id := null;
    insert into private.event_reminder_deliveries (
      occurrence_id,
      user_id,
      reminder_offset_minutes,
      scheduled_for,
      occurrence_starts_at,
      event_revision,
      dispatched_at
    ) values (
      v_occurrence.id,
      v_candidate.user_id,
      v_candidate.reminder_offset_minutes,
      v_due_at,
      v_occurrence.starts_at,
      v_event.revision,
      v_now
    )
    on conflict (occurrence_id, user_id, reminder_offset_minutes) do nothing
    returning id into v_delivery_id;
    if v_delivery_id is null then
      continue;
    end if;

    insert into public.notifications (
      user_id,
      kind,
      title,
      body,
      entity_type,
      entity_id,
      metadata
    ) values (
      v_candidate.user_id,
      'admin_action'::public.notification_kind,
      '일정 알림',
      '참석 예정인 일정이 곧 시작됩니다. 앱에서 확인해 주세요.',
      'event_occurrence',
      v_occurrence.id,
      pg_catalog.jsonb_build_object(
        'event_id', v_event.id,
        'reminder_offset_minutes', v_candidate.reminder_offset_minutes,
        'event_revision', v_event.revision
      )
    ) returning id into v_notification_id;

    update private.event_reminder_deliveries
    set notification_id = v_notification_id
    where id = v_delivery_id;
    v_dispatched := v_dispatched + 1;
  end loop;

  dispatched_count := v_dispatched;
  checked_at := v_now;
  select exists (
    select 1
    from public.event_occurrences as occurrence
    join public.events as event on event.id = occurrence.event_id
    join public.event_rsvps as rsvp on rsvp.occurrence_id = occurrence.id
    cross join lateral pg_catalog.unnest(event.reminder_offsets_minutes)
      as reminder(minutes)
    left join public.notification_preferences as preference
      on preference.user_id = rsvp.user_id
    where event.status = 'scheduled'
      and occurrence.status = 'scheduled'
      and rsvp.response in ('yes', 'maybe')
      and coalesce(preference.events_enabled, true)
      and private.can_read_event_scope(event.scope_id, rsvp.user_id)
      and occurrence.starts_at
        - pg_catalog.make_interval(mins => reminder.minutes) <= v_now
      and (
        (reminder.minutes > 0 and occurrence.starts_at > v_now)
        or (
          reminder.minutes = 0
          and occurrence.starts_at <= v_now
          and occurrence.starts_at > v_now - interval '5 minutes'
          and occurrence.ends_at > v_now
        )
      )
      and not exists (
        select 1
        from private.event_reminder_deliveries as delivery
        where delivery.occurrence_id = occurrence.id
          and delivery.user_id = rsvp.user_id
          and delivery.reminder_offset_minutes = reminder.minutes
      )
  ) into has_more;
  return next;
end;
$$;

revoke all on function public.service_dispatch_due_event_reminders(integer)
  from public, anon, authenticated;
grant execute on function public.service_dispatch_due_event_reminders(integer)
  to service_role;

comment on function public.service_dispatch_due_event_reminders(integer) is
  'Service-role-only bounded, idempotent dispatcher for due event reminders using the database server clock.';

comment on function public.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) is
  'Idempotently creates/updates a first-class event and finite Asia/Seoul occurrence set at one exact scope.';
comment on function public.respond_to_event(uuid, text, uuid) is
  'Idempotent yes/no/maybe RSVP; capacity is serialized and excess yes responses become a FIFO waitlist.';
comment on function public.cancel_event(uuid, uuid, text) is
  'Idempotently cancels an event while retaining RSVPs and append-only revision history.';

-- Route event notifications through the events preference instead of treating
-- the reused admin_action enum value as a security alert. Push contents remain
-- generic and carry only an opaque occurrence UUID.
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
  ) values (
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

revoke all on function private.enqueue_generic_push_notification()
  from public, anon, authenticated;
