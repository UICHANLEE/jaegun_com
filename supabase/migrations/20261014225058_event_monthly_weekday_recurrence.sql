-- Add monthly ordinal weekday rules without changing existing event authority.
alter table public.events add column recurrence_month_week smallint check (recurrence_month_week in (-1,1,2,3,4)),
 add column recurrence_month_weekday smallint check (recurrence_month_weekday between 1 and 7);
alter table public.events drop constraint events_recurrence_shape_check;
alter table public.events add constraint events_recurrence_shape_check check (
    (
      recurrence_frequency = 'none'
      and recurrence_interval = 1
      and pg_catalog.cardinality(recurrence_weekdays) = 0
      and recurrence_month_day is null
      and recurrence_month_week is null and recurrence_month_weekday is null
      and recurrence_until is null
      and recurrence_count is null
    )
    or (
      recurrence_frequency = 'daily'
      and recurrence_interval between 1 and 30
      and pg_catalog.cardinality(recurrence_weekdays) = 0
      and recurrence_month_day is null
      and recurrence_month_week is null and recurrence_month_weekday is null
      and ((recurrence_until is null) <> (recurrence_count is null))
    )
    or (
      recurrence_frequency = 'weekly'
      and recurrence_interval between 1 and 4
      and pg_catalog.cardinality(recurrence_weekdays) between 1 and 7
      and recurrence_month_day is null
      and recurrence_month_week is null and recurrence_month_weekday is null
      and ((recurrence_until is null) <> (recurrence_count is null))
    )
    or (
      recurrence_frequency = 'monthly'
      and recurrence_interval between 1 and 12
      and pg_catalog.cardinality(recurrence_weekdays) = 0
      and ((recurrence_month_day is not null and recurrence_month_week is null and recurrence_month_weekday is null)
        or (recurrence_month_day is null and recurrence_month_week is not null and recurrence_month_weekday is not null))
      and ((recurrence_until is null) <> (recurrence_count is null))
    )
  );
create function private.event_matches_month_weekday(p_date date,p_week integer,p_weekday integer) returns boolean
language sql immutable set search_path=pg_catalog as $$
 select coalesce(extract(isodow from p_date)::integer=p_weekday and
  case when p_week=-1 then extract(month from p_date+7)<>extract(month from p_date)
       else ((extract(day from p_date)::integer-1)/7)+1=p_week end,false);
$$;
revoke all on function private.event_matches_month_weekday(date,integer,integer) from public,anon,authenticated;
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
  if new.recurrence_frequency = 'monthly' and new.recurrence_month_week is null
    and new.recurrence_month_day <> extract(day from v_seoul_start)::smallint then
    raise exception 'monthly_recurrence_day_must_match_start' using errcode = '23514';
  end if;

  if new.recurrence_frequency='monthly' and new.recurrence_month_week is not null
    and not private.event_matches_month_weekday(v_seoul_start::date,new.recurrence_month_week,new.recurrence_month_weekday) then
    raise exception 'monthly_weekday_must_match_start' using errcode='23514';
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
      old.recurrence_month_week, old.recurrence_month_weekday,
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
      new.recurrence_month_week, new.recurrence_month_weekday,
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
        and case when v_event.recurrence_month_week is null then extract(day from v_candidate_date)::smallint = v_event.recurrence_month_day
          else private.event_matches_month_weekday(v_candidate_date,v_event.recurrence_month_week,v_event.recurrence_month_weekday) end;
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
create or replace function private.save_event_recurrence_v2(
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
  p_host_name text,
  p_recurrence_month_week integer,
  p_recurrence_month_weekday integer
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
  v_month_week smallint := p_recurrence_month_week::smallint;
  v_month_weekday smallint := p_recurrence_month_weekday::smallint;
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
      v_existing.recurrence_month_week, v_existing.recurrence_month_weekday,
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
      v_month_week, v_month_weekday,
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
      v_existing.recurrence_month_week, v_existing.recurrence_month_weekday,
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
      v_month_week, v_month_weekday,
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
      recurrence_month_week = v_month_week, recurrence_month_weekday = v_month_weekday,
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
      recurrence_month_week, recurrence_month_weekday,
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
      v_month_week, v_month_weekday,
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
revoke all on function private.save_event_recurrence_v2(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer,integer) from public,anon,authenticated;
create function public.save_event_recurrence_checked(
  p_id uuid, p_create boolean, p_scope_id uuid, p_title text,
  p_description text, p_location_text text, p_starts_at timestamptz,
  p_ends_at timestamptz, p_capacity integer, p_recurrence_frequency text,
  p_recurrence_interval integer, p_recurrence_weekdays smallint[],
  p_recurrence_month_day integer, p_recurrence_until timestamptz,
  p_recurrence_count integer, p_reminder_offsets_minutes integer[],
  p_host_name text, p_expected_revision integer,
  p_recurrence_month_week integer, p_recurrence_month_weekday integer
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
      'host', p_host_name, 'month_week',p_recurrence_month_week,'month_weekday',p_recurrence_month_weekday
    );
    if v_event.id is not null then
      select * into v_receipt from private.event_create_receipts where event_id = p_id;
      if v_receipt.actor_id is distinct from v_actor
        or ((v_receipt.request_payload || jsonb_build_object('month_week',null,'month_weekday',null)) is distinct from v_payload and v_receipt.request_payload is distinct from v_payload)
        or v_receipt.created_at < pg_catalog.statement_timestamp() - interval '90 days' then
        raise exception 'event_create_operation_conflict' using errcode = '40001';
      end if;
      -- Retry acknowledges original success; never rewrites subsequent edits/cancellation.
      return p_id;
    end if;
  end if;
  v_result := private.save_event_recurrence_v2(p_id, p_create, p_scope_id, p_title,
    p_description, p_location_text, p_starts_at, p_ends_at, p_capacity,
    p_recurrence_frequency, p_recurrence_interval, p_recurrence_weekdays,
    p_recurrence_month_day, p_recurrence_until, p_recurrence_count,
    p_reminder_offsets_minutes, p_host_name, p_recurrence_month_week,p_recurrence_month_weekday);
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
revoke all on function public.save_event_recurrence_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.save_event_recurrence_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer,integer,integer) to authenticated;
notify pgrst,'reload schema';
