-- Explicit hosts and minimal, exact-scope occurrence logistics.
-- Host labels are user input, never a replacement for the immutable audit actor.
alter table public.events add column host_name text
  check (host_name is null or (host_name = pg_catalog.btrim(host_name) and pg_catalog.char_length(host_name) between 1 and 100));
comment on column public.events.host_name is 'Explicit host label; legacy events may have no label. Actual created_by remains immutable.';

create function private.can_manage_event_logistics(p_scope_id uuid, p_actor_id uuid)
returns boolean language sql stable security definer set search_path = pg_catalog as $$
  select private.can_read_event_scope(p_scope_id, p_actor_id)
    and (
      private.can_manage_events(p_scope_id, p_actor_id)
      or exists (
        select 1 from public.governance_scopes as scope
        join public.organizations as organization on organization.id = scope.organization_id
        join public.organization_memberships as membership on membership.organization_id = organization.id
        join public.profiles as profile on profile.id = membership.user_id
        where scope.id = p_scope_id and scope.scope_type = 'church'::public.governance_scope_type
          and scope.is_active and organization.status = 'active'::public.organization_status
          and membership.user_id = p_actor_id and membership.status = 'active'::public.membership_status
          and membership.role = 'executive'::public.app_role and profile.deactivated_at is null
          and private.has_current_required_consents(p_actor_id)
      )
    );
$$;
revoke all on function private.can_manage_event_logistics(uuid, uuid) from public, anon, authenticated;

drop function public.save_event(uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer, text, integer, smallint[], integer, timestamptz, integer, integer[]);
drop function private.save_event_before_authority_gate(uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer, text, integer, smallint[], integer, timestamptz, integer, integer[]);

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
  p_reminder_offsets_minutes integer[],
  p_host_name text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_existing_scope_id uuid;
  v_host_name text;
  v_existing public.events%rowtype;
  v_title text := nullif(pg_catalog.btrim(p_title), '');
  v_description text := nullif(pg_catalog.btrim(p_description), '');
  v_location text := nullif(pg_catalog.btrim(p_location_text), '');
  v_frequency text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_recurrence_frequency, 'none')));
  v_interval smallint;
  v_weekdays smallint[] := coalesce(p_recurrence_weekdays, '{}'::smallint[]);
  v_month_day smallint;
  v_count smallint;
  v_reminders integer[] := coalesce(p_reminder_offsets_minutes, '{}'::integer[]);
  v_schedule_changed boolean;
  v_organization_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_id is null or p_create is null or p_scope_id is null then
    raise exception 'event_id_create_flag_and_scope_required' using errcode = '22023';
  end if;
  if not private.can_manage_events(p_scope_id, v_actor_id) then
    raise exception 'event_save_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  select event.scope_id into v_existing_scope_id from public.events as event where event.id = p_id;
  if found then
    if v_existing_scope_id is distinct from p_scope_id
      or not private.can_manage_events(v_existing_scope_id, v_actor_id) then
      raise exception 'event_save_not_found_or_forbidden' using errcode = 'P0002';
    end if;
  elsif not p_create then
    raise exception 'event_save_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  perform private.require_aal2('event_save');
  v_host_name := nullif(pg_catalog.btrim(p_host_name), '');
  if v_host_name is null or pg_catalog.char_length(v_host_name) > 100 then
    raise exception 'invalid_event_host_name' using errcode = '23514';
  end if;
  v_interval := coalesce(p_recurrence_interval, 1)::smallint;
  v_month_day := p_recurrence_month_day::smallint;
  v_count := p_recurrence_count::smallint;
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
      v_existing.host_name,
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
      v_host_name,
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
      host_name = v_host_name,
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
      host_name,
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
      v_host_name,
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

revoke all on function public.save_event(uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer, text, integer, smallint[], integer, timestamptz, integer, integer[], text) from public, anon, authenticated;
grant execute on function public.save_event(uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer, text, integer, smallint[], integer, timestamptz, integer, integer[], text) to authenticated;

drop function public.list_event_occurrences(timestamptz, timestamptz, uuid, integer);
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
  can_manage boolean,
  host_name text,
  can_manage_logistics boolean
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
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
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
    private.can_manage_events(event.scope_id, v_actor_id),
    event.host_name,
    private.can_manage_event_logistics(event.scope_id, v_actor_id)
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
      and private.has_current_required_consents(rsvp.user_id)
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
            and private.has_current_required_consents(ahead.user_id)
            and row(ahead.responded_at, ahead.user_id)
              <= row(mine.responded_at, mine.user_id)
        )
        else null
      end as waitlist_position
    from public.event_rsvps as mine
    where mine.occurrence_id = occurrence.id
      and mine.user_id = v_actor_id
      and private.has_current_required_consents(mine.user_id)
  ) as own_rsvp on true
  where occurrence.starts_at >= p_from
    and occurrence.starts_at < p_to
    and (p_scope_id is null or event.scope_id = p_scope_id)
    and private.can_read_event_scope(event.scope_id, v_actor_id)
  order by occurrence.starts_at, event.title, occurrence.id
  limit p_limit;
end;
$$;
revoke all on function public.list_event_occurrences(timestamptz, timestamptz, uuid, integer) from public, anon, authenticated;
grant execute on function public.list_event_occurrences(timestamptz, timestamptz, uuid, integer) to authenticated;

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
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'occurrence_id', occurrence.id,
    'event_id', event.id,
    'scope_id', event.scope_id,
    'scope_type', scope.scope_type,
    'scope_name', scope.display_name,
    'title', event.title,
    'host_name', event.host_name,
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
          and private.has_current_required_consents(ahead.user_id)
          and row(ahead.responded_at, ahead.user_id)
            <= row(mine.responded_at, mine.user_id)
      )
      else null
    end,
    'can_manage', private.can_manage_events(event.scope_id, v_actor_id),
    'can_manage_logistics', private.can_manage_event_logistics(event.scope_id, v_actor_id)
  ) into v_result
  from public.event_occurrences as occurrence
  join public.events as event on event.id = occurrence.event_id
  join public.governance_scopes as scope on scope.id = event.scope_id
  left join public.event_rsvps as mine
    on mine.occurrence_id = occurrence.id
   and mine.user_id = v_actor_id
   and private.has_current_required_consents(mine.user_id)
  left join lateral (
    select
      pg_catalog.count(*) filter (where rsvp.response = 'yes') as yes_count,
      pg_catalog.count(*) filter (where rsvp.response = 'maybe') as maybe_count,
      pg_catalog.count(*) filter (where rsvp.response = 'waitlist') as waitlist_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = occurrence.id
      and private.has_current_required_consents(rsvp.user_id)
  ) as totals on true
  where occurrence.id = p_occurrence_id
    and private.can_read_event_scope(event.scope_id, v_actor_id);

  if v_result is null then
    raise exception 'event_occurrence_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  return v_result;
end;
$$;

-- No direct grants or policies: only guarded SECURITY DEFINER RPCs touch plans.
create table private.event_logistics_plans (
  occurrence_id uuid primary key references public.event_occurrences(id) on delete cascade,
  revision integer not null default 0 check (revision >= 0),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default pg_catalog.clock_timestamp()
);
create table private.event_logistics_groups (
  id uuid primary key,
  occurrence_id uuid not null references private.event_logistics_plans(occurrence_id) on delete cascade,
  name text not null check (name = pg_catalog.btrim(name) and pg_catalog.char_length(name) between 1 and 100),
  unique (occurrence_id, id)
);
create table private.event_logistics_vehicles (
  id uuid primary key,
  occurrence_id uuid not null references private.event_logistics_plans(occurrence_id) on delete cascade,
  label text not null check (label = pg_catalog.btrim(label) and pg_catalog.char_length(label) between 1 and 100),
  seat_count integer not null check (seat_count between 1 and 100),
  driver_user_id uuid references public.profiles(id) on delete set null,
  unique (occurrence_id, id),
  unique (occurrence_id, driver_user_id)
);
create table private.event_logistics_assignments (
  occurrence_id uuid not null references private.event_logistics_plans(occurrence_id) on delete cascade,
  user_id uuid not null,
  group_id uuid,
  vehicle_id uuid,
  primary key (occurrence_id, user_id),
  foreign key (occurrence_id, user_id) references public.event_rsvps(occurrence_id, user_id) on delete cascade,
  foreign key (occurrence_id, group_id) references private.event_logistics_groups(occurrence_id, id),
  foreign key (occurrence_id, vehicle_id) references private.event_logistics_vehicles(occurrence_id, id)
);
create index event_logistics_assignments_user_idx on private.event_logistics_assignments(user_id, occurrence_id);
alter table private.event_logistics_plans enable row level security;
alter table private.event_logistics_groups enable row level security;
alter table private.event_logistics_vehicles enable row level security;
alter table private.event_logistics_assignments enable row level security;
revoke all on table private.event_logistics_plans, private.event_logistics_groups,
  private.event_logistics_vehicles, private.event_logistics_assignments from public, anon, authenticated;

create function private.is_eligible_event_attendee(p_scope_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = pg_catalog as $$
  select private.can_read_event_scope(p_scope_id, p_user_id)
    and private.is_user_active_in_governance_scope(p_scope_id, p_user_id);
$$;
revoke all on function private.is_eligible_event_attendee(uuid, uuid) from public, anon, authenticated;

-- Callers take the same advisory + occurrence row locks as RSVP writes. This
-- also invalidates a draft when roster/eligibility changes without allocation.
create function private.sanitize_event_logistics(p_occurrence_id uuid, p_invalidate boolean default false)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_scope_id uuid;
  v_removed integer;
  v_drivers integer;
begin
  if not exists (select 1 from private.event_logistics_plans where occurrence_id = p_occurrence_id) then
    return false;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('event-rsvp:' || p_occurrence_id::text, 0));
  select event.scope_id into v_scope_id
  from public.event_occurrences as occurrence join public.events as event on event.id = occurrence.event_id
  where occurrence.id = p_occurrence_id for update of occurrence;
  if not found then return false; end if;
  delete from private.event_logistics_assignments as assignment
  where assignment.occurrence_id = p_occurrence_id and not exists (
    select 1 from public.event_rsvps as rsvp
    where rsvp.occurrence_id = p_occurrence_id and rsvp.user_id = assignment.user_id
      and rsvp.response = 'yes' and private.is_eligible_event_attendee(v_scope_id, rsvp.user_id)
  );
  get diagnostics v_removed = row_count;
  update private.event_logistics_vehicles as vehicle set driver_user_id = null
  where vehicle.occurrence_id = p_occurrence_id and vehicle.driver_user_id is not null and not exists (
    select 1 from private.event_logistics_assignments as assignment
    where assignment.occurrence_id = p_occurrence_id and assignment.user_id = vehicle.driver_user_id
      and assignment.vehicle_id = vehicle.id
  );
  get diagnostics v_drivers = row_count;
  if p_invalidate or v_removed > 0 or v_drivers > 0 then
    update private.event_logistics_plans set revision = revision + 1, updated_at = pg_catalog.clock_timestamp()
    where occurrence_id = p_occurrence_id;
    if v_removed > 0 or v_drivers > 0 then
      perform private.write_audit(auth.uid(), 'event.logistics_sanitized', 'event_occurrence', p_occurrence_id,
        (select organization_id from public.governance_scopes where id = v_scope_id), null,
        pg_catalog.jsonb_build_object('removed_assignments', v_removed, 'cleared_drivers', v_drivers));
    end if;
    return true;
  end if;
  return false;
end;
$$;
revoke all on function private.sanitize_event_logistics(uuid, boolean) from public, anon, authenticated;

create function private.event_logistics_snapshot(p_occurrence_id uuid)
returns jsonb language sql stable security definer set search_path = pg_catalog as $$
  select pg_catalog.jsonb_build_object(
    'occurrence_id', occurrence.id,
    'revision', plan.revision,
    'groups', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', item.id, 'name', item.name) order by item.name, item.id)
      from private.event_logistics_groups as item where item.occurrence_id = occurrence.id), '[]'::jsonb),
    'vehicles', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', item.id, 'label', item.label,
      'seat_count', item.seat_count, 'driver_user_id', item.driver_user_id) order by item.label, item.id)
      from private.event_logistics_vehicles as item where item.occurrence_id = occurrence.id), '[]'::jsonb),
    'participants', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'user_id', rsvp.user_id, 'display_name', profile.display_name, 'response', rsvp.response, 'responded_at', rsvp.responded_at,
      'group_id', case when rsvp.response = 'yes' then assignment.group_id else null end,
      'vehicle_id', case when rsvp.response = 'yes' then assignment.vehicle_id else null end
    ) order by profile.display_name, rsvp.user_id)
    from public.event_rsvps as rsvp join public.profiles as profile on profile.id = rsvp.user_id
    left join private.event_logistics_assignments as assignment on assignment.occurrence_id = rsvp.occurrence_id and assignment.user_id = rsvp.user_id
    where rsvp.occurrence_id = occurrence.id and private.is_eligible_event_attendee(event.scope_id, rsvp.user_id)), '[]'::jsonb)
  )
  from public.event_occurrences as occurrence join public.events as event on event.id = occurrence.event_id
  join private.event_logistics_plans as plan on plan.occurrence_id = occurrence.id
  where occurrence.id = p_occurrence_id;
$$;
revoke all on function private.event_logistics_snapshot(uuid) from public, anon, authenticated;

create function public.get_event_logistics(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_actor_id uuid;
  v_scope_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  select event.scope_id into v_scope_id from public.event_occurrences as occurrence
    join public.events as event on event.id = occurrence.event_id
    where occurrence.id = p_occurrence_id and private.can_manage_event_logistics(event.scope_id, v_actor_id);
  if not found then raise exception 'event_logistics_not_found_or_forbidden' using errcode = 'P0002'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('event-rsvp:' || p_occurrence_id::text, 0));
  perform 1 from public.event_occurrences where id = p_occurrence_id for update;
  if not found or not private.can_manage_event_logistics(v_scope_id, v_actor_id) then
    raise exception 'event_logistics_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  perform private.consume_rate_limit(v_actor_id, 'event_logistics_reads', 120, 60, 1);
  insert into private.event_logistics_plans(occurrence_id) values(p_occurrence_id) on conflict do nothing;
  perform private.sanitize_event_logistics(p_occurrence_id);
  perform private.write_audit(v_actor_id, 'event.logistics_read', 'event_occurrence', p_occurrence_id,
    (select organization_id from public.governance_scopes where id = v_scope_id), null, '{}'::jsonb);
  return private.event_logistics_snapshot(p_occurrence_id);
end;
$$;
revoke all on function public.get_event_logistics(uuid) from public, anon, authenticated;
grant execute on function public.get_event_logistics(uuid) to authenticated;

create function public.save_event_logistics(
  p_occurrence_id uuid, p_revision integer, p_groups jsonb, p_vehicles jsonb, p_assignments jsonb
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_actor_id uuid;
  v_scope_id uuid;
  v_revision integer;
  v_status text;
  v_occurrence_status text;
begin
  v_actor_id := private.require_current_consent_actor();
  select event.scope_id into v_scope_id from public.event_occurrences as occurrence
    join public.events as event on event.id = occurrence.event_id
    where occurrence.id = p_occurrence_id and private.can_manage_event_logistics(event.scope_id, v_actor_id);
  if not found then raise exception 'event_logistics_not_found_or_forbidden' using errcode = 'P0002'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('event-rsvp:' || p_occurrence_id::text, 0));
  select event.status, occurrence.status into v_status, v_occurrence_status
    from public.event_occurrences as occurrence join public.events as event on event.id = occurrence.event_id
    where occurrence.id = p_occurrence_id for update of occurrence;
  if not found or not private.can_manage_event_logistics(v_scope_id, v_actor_id) then
    raise exception 'event_logistics_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  if v_status <> 'scheduled' or v_occurrence_status <> 'scheduled' then
    raise exception 'event_logistics_closed' using errcode = '55000';
  end if;
  if p_revision is null or p_revision < 0 or pg_catalog.jsonb_typeof(p_groups) is distinct from 'array'
    or pg_catalog.jsonb_typeof(p_vehicles) is distinct from 'array'
    or pg_catalog.jsonb_typeof(p_assignments) is distinct from 'array' then
    raise exception 'invalid_event_logistics_payload' using errcode = '22023';
  end if;
  if pg_catalog.jsonb_array_length(p_groups) > 50 or pg_catalog.jsonb_array_length(p_vehicles) > 50 then
    raise exception 'event_logistics_item_limit' using errcode = '23514';
  end if;
  if exists(select 1 from pg_catalog.jsonb_array_elements(p_groups) as item(value) where pg_catalog.jsonb_typeof(value) <> 'object')
    or exists(select 1 from pg_catalog.jsonb_array_elements(p_vehicles) as item(value) where pg_catalog.jsonb_typeof(value) <> 'object')
    or exists(select 1 from pg_catalog.jsonb_array_elements(p_assignments) as item(value) where pg_catalog.jsonb_typeof(value) <> 'object') then
    raise exception 'invalid_event_logistics_payload' using errcode = '22023';
  end if;
  insert into private.event_logistics_plans(occurrence_id) values(p_occurrence_id) on conflict do nothing;
  perform private.sanitize_event_logistics(p_occurrence_id);
  select revision into v_revision from private.event_logistics_plans where occurrence_id = p_occurrence_id;
  if p_revision <> v_revision then raise exception 'event_logistics_revision_conflict' using errcode = '40001'; end if;

  if exists(select 1 from pg_catalog.jsonb_array_elements(p_groups) as item(value)
    where pg_catalog.jsonb_typeof(value -> 'name') is distinct from 'string')
    or exists(select 1 from pg_catalog.jsonb_to_recordset(p_groups) as item(id uuid, name text)
    where id is null or nullif(pg_catalog.btrim(name), '') is null or pg_catalog.char_length(pg_catalog.btrim(name)) > 100)
    or (select count(*) <> count(distinct id) from pg_catalog.jsonb_to_recordset(p_groups) as item(id uuid)) then
    raise exception 'invalid_event_logistics_groups' using errcode = '23514';
  end if;
  if exists(select 1 from pg_catalog.jsonb_array_elements(p_vehicles) as item(value)
    where pg_catalog.jsonb_typeof(value -> 'label') is distinct from 'string'
      or pg_catalog.jsonb_typeof(value -> 'seat_count') is distinct from 'number'
      or (value ->> 'seat_count') !~ '^([1-9][0-9]?|100)$') then
    raise exception 'invalid_event_logistics_vehicles' using errcode = '23514';
  end if;
  if exists(select 1 from pg_catalog.jsonb_to_recordset(p_vehicles) as item(id uuid, label text, seat_count integer)
      where id is null or nullif(pg_catalog.btrim(label), '') is null or pg_catalog.char_length(pg_catalog.btrim(label)) > 100
        or seat_count is null or seat_count not between 1 and 100)
    or (select count(*) <> count(distinct id) from pg_catalog.jsonb_to_recordset(p_vehicles) as item(id uuid))
    or exists(select driver_user_id from pg_catalog.jsonb_to_recordset(p_vehicles) as item(driver_user_id uuid)
      where driver_user_id is not null group by driver_user_id having count(*) > 1) then
    raise exception 'invalid_event_logistics_vehicles' using errcode = '23514';
  end if;
  if exists(select 1 from pg_catalog.jsonb_to_recordset(p_groups) as requested(id uuid)
    join private.event_logistics_groups as existing on existing.id = requested.id where existing.occurrence_id <> p_occurrence_id)
    or exists(select 1 from pg_catalog.jsonb_to_recordset(p_vehicles) as requested(id uuid)
    join private.event_logistics_vehicles as existing on existing.id = requested.id where existing.occurrence_id <> p_occurrence_id) then
    raise exception 'event_logistics_cross_occurrence_id' using errcode = '23514';
  end if;
  if (select count(*) <> count(distinct user_id) from pg_catalog.jsonb_to_recordset(p_assignments) as item(user_id uuid))
    or exists(select 1 from pg_catalog.jsonb_to_recordset(p_assignments) as item(user_id uuid, group_id uuid, vehicle_id uuid)
      where user_id is null or not exists (
        select 1 from public.event_rsvps as rsvp where rsvp.occurrence_id = p_occurrence_id and rsvp.user_id = item.user_id
          and rsvp.response = 'yes' and private.is_eligible_event_attendee(v_scope_id, rsvp.user_id)
      ) or (group_id is not null and not exists(select 1 from pg_catalog.jsonb_to_recordset(p_groups) as requested(id uuid) where requested.id = item.group_id))
        or (vehicle_id is not null and not exists(select 1 from pg_catalog.jsonb_to_recordset(p_vehicles) as requested(id uuid) where requested.id = item.vehicle_id))) then
    raise exception 'invalid_event_logistics_assignments' using errcode = '23514';
  end if;
  if exists(select 1 from pg_catalog.jsonb_to_recordset(p_vehicles) as vehicle(id uuid, driver_user_id uuid)
    where driver_user_id is not null and not exists (
      select 1 from pg_catalog.jsonb_to_recordset(p_assignments) as assignment(user_id uuid, vehicle_id uuid)
      where assignment.user_id = vehicle.driver_user_id and assignment.vehicle_id = vehicle.id
    )) then raise exception 'invalid_event_logistics_driver' using errcode = '23514'; end if;
  if exists(select 1 from pg_catalog.jsonb_to_recordset(p_vehicles) as vehicle(id uuid, seat_count integer)
    where seat_count < (select count(*) from pg_catalog.jsonb_to_recordset(p_assignments) as assignment(vehicle_id uuid) where assignment.vehicle_id = vehicle.id)) then
    raise exception 'event_logistics_vehicle_capacity_exceeded' using errcode = '23514';
  end if;

  perform private.consume_rate_limit(v_actor_id, 'event_logistics_mutations', 30, 3600, 1);
  delete from private.event_logistics_assignments where occurrence_id = p_occurrence_id;
  delete from private.event_logistics_vehicles where occurrence_id = p_occurrence_id;
  delete from private.event_logistics_groups where occurrence_id = p_occurrence_id;
  insert into private.event_logistics_groups(id, occurrence_id, name)
    select id, p_occurrence_id, pg_catalog.btrim(name) from pg_catalog.jsonb_to_recordset(p_groups) as item(id uuid, name text);
  insert into private.event_logistics_vehicles(id, occurrence_id, label, seat_count, driver_user_id)
    select id, p_occurrence_id, pg_catalog.btrim(label), seat_count, driver_user_id
    from pg_catalog.jsonb_to_recordset(p_vehicles) as item(id uuid, label text, seat_count integer, driver_user_id uuid);
  insert into private.event_logistics_assignments(occurrence_id, user_id, group_id, vehicle_id)
    select p_occurrence_id, user_id, group_id, vehicle_id from pg_catalog.jsonb_to_recordset(p_assignments) as item(user_id uuid, group_id uuid, vehicle_id uuid);
  update private.event_logistics_plans set revision = revision + 1, updated_by = v_actor_id, updated_at = pg_catalog.clock_timestamp()
    where occurrence_id = p_occurrence_id;
  perform private.write_audit(v_actor_id, 'event.logistics_saved', 'event_occurrence', p_occurrence_id,
    (select organization_id from public.governance_scopes where id = v_scope_id), null,
    pg_catalog.jsonb_build_object('revision', v_revision + 1, 'groups', pg_catalog.jsonb_array_length(p_groups),
      'vehicles', pg_catalog.jsonb_array_length(p_vehicles), 'assignments', pg_catalog.jsonb_array_length(p_assignments)));
  return private.event_logistics_snapshot(p_occurrence_id);
end;
$$;
revoke all on function public.save_event_logistics(uuid, integer, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.save_event_logistics(uuid, integer, jsonb, jsonb, jsonb) to authenticated;

-- RSVP already acquires this exact lock before mutation. Row-level triggers
-- also protect privileged cleanup/deletion paths; no public write bypass exists.
create function private.invalidate_logistics_after_rsvp()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  if tg_op = 'UPDATE' and new.response is not distinct from old.response and new.responded_at is not distinct from old.responded_at then return new; end if;
  perform private.sanitize_event_logistics(case when tg_op = 'DELETE' then old.occurrence_id else new.occurrence_id end, true);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function private.invalidate_logistics_after_rsvp() from public, anon, authenticated;
create trigger event_rsvps_invalidate_logistics after insert or update or delete on public.event_rsvps
  for each row execute function private.invalidate_logistics_after_rsvp();

create function private.invalidate_logistics_for_subject()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
declare v_user_id uuid; v_old_user_id uuid; v_occurrence_id uuid;
begin
  if tg_table_name = 'profiles' then
    v_user_id := case when tg_op = 'DELETE' then old.id else new.id end;
    if tg_op = 'UPDATE' then v_old_user_id := old.id; end if;
  else
    v_user_id := case when tg_op = 'DELETE' then old.user_id else new.user_id end;
    if tg_op = 'UPDATE' then v_old_user_id := old.user_id; end if;
  end if;
  for v_occurrence_id in
    select distinct rsvp.occurrence_id from public.event_rsvps as rsvp
    join private.event_logistics_plans as plan on plan.occurrence_id = rsvp.occurrence_id
    where rsvp.user_id = v_user_id or rsvp.user_id = v_old_user_id order by rsvp.occurrence_id
  loop perform private.sanitize_event_logistics(v_occurrence_id, true); end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function private.invalidate_logistics_for_subject() from public, anon, authenticated;
create trigger memberships_invalidate_event_logistics after insert or update or delete on public.organization_memberships
  for each row execute function private.invalidate_logistics_for_subject();
create trigger consents_invalidate_event_logistics after insert or update or delete on public.user_consents
  for each row execute function private.invalidate_logistics_for_subject();
create trigger profiles_invalidate_event_logistics after update of deactivated_at, display_name on public.profiles
  for each row execute function private.invalidate_logistics_for_subject();

-- Document publication and organization/scope revocation can invalidate many
-- subjects at once. Future-effective documents are sanitized again on read.
create function private.invalidate_all_event_logistics()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
declare v_occurrence_id uuid;
begin
  for v_occurrence_id in select occurrence_id from private.event_logistics_plans order by occurrence_id
  loop perform private.sanitize_event_logistics(v_occurrence_id, true); end loop;
  return null;
end;
$$;
revoke all on function private.invalidate_all_event_logistics() from public, anon, authenticated;
create trigger consent_documents_invalidate_event_logistics after insert or update or delete on public.consent_documents
  for each statement execute function private.invalidate_all_event_logistics();
create trigger organizations_invalidate_event_logistics after update of status on public.organizations
  for each statement execute function private.invalidate_all_event_logistics();
create trigger governance_scopes_invalidate_event_logistics after update of is_active, organization_id, scope_type on public.governance_scopes
  for each statement execute function private.invalidate_all_event_logistics();
