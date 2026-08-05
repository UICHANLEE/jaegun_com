-- Annual executive offices and executive-only operational records.
-- app_role remains the approval/security hierarchy; annual office assignments add
-- narrower capabilities without promoting church titles into authorization roles.

create or replace function private.current_service_year()
returns smallint
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select extract(
    year from pg_catalog.timezone('Asia/Seoul', pg_catalog.statement_timestamp())
  )::smallint;
$$;

comment on function private.current_service_year() is
  'Returns the service year in Asia/Seoul so browser and database authorization switch together.';

revoke all on function private.current_service_year()
  from public, anon, authenticated;

create or replace function public.get_service_year()
returns smallint
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  return private.current_service_year();
end;
$$;

comment on function public.get_service_year() is
  'Returns the backend-authoritative annual operations year in Asia/Seoul for signed-in clients.';

revoke all on function public.get_service_year()
  from public, anon, authenticated;
grant execute on function public.get_service_year()
  to authenticated;

create or replace function public.get_service_clock()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.statement_timestamp();
  v_service_year smallint;
  v_next_rollover timestamptz;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  v_service_year := extract(
    year from pg_catalog.timezone('Asia/Seoul', v_now)
  )::smallint;
  v_next_rollover := pg_catalog.make_timestamptz(
    v_service_year + 1,
    1,
    1,
    0,
    0,
    0,
    'Asia/Seoul'
  );

  return pg_catalog.jsonb_build_object(
    'service_year', v_service_year,
    'milliseconds_until_rollover', greatest(
      1,
      pg_catalog.ceil(
        extract(epoch from (v_next_rollover - v_now)) * 1000
      )::bigint
    )
  );
end;
$$;

comment on function public.get_service_clock() is
  'Returns the backend service year and monotonic scheduling delay until the next Asia/Seoul year.';

revoke all on function public.get_service_clock()
  from public, anon, authenticated;
grant execute on function public.get_service_clock()
  to authenticated;

create or replace function private.executive_office_codes_are_valid(p_codes text[])
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select p_codes is not null
    and pg_catalog.cardinality(p_codes) <= 5
    and pg_catalog.array_position(p_codes, null) is null
    and not exists (
      select 1
      from pg_catalog.unnest(p_codes) as office(code)
      where office.code not in (
        'president',
        'vice_president',
        'general_secretary',
        'secretary',
        'treasurer'
      )
    )
    and pg_catalog.cardinality(p_codes) = (
      select pg_catalog.count(distinct office.code)
      from pg_catalog.unnest(p_codes) as office(code)
    );
$$;

revoke all on function private.executive_office_codes_are_valid(text[])
  from public, anon, authenticated;
grant execute on function private.executive_office_codes_are_valid(text[])
  to service_role;

alter table public.membership_applications
  add column requested_executive_office_codes text[] not null default '{}'::text[],
  add column requested_service_year smallint,
  add constraint membership_applications_executive_offices_valid_check check (
    private.executive_office_codes_are_valid(requested_executive_office_codes)
  ),
  add constraint membership_applications_service_year_check check (
    requested_service_year is null
    or requested_service_year between 2000 and 2100
  ),
  add constraint membership_applications_executive_request_scope_check check (
    (
      requested_role = 'executive'::public.app_role
      and (
        pg_catalog.cardinality(requested_executive_office_codes) = 0
        or requested_service_year is not null
      )
    )
    or (
      requested_role <> 'executive'::public.app_role
      and pg_catalog.cardinality(requested_executive_office_codes) = 0
      and requested_service_year is null
    )
  );

comment on column public.membership_applications.requested_executive_office_codes is
  'Requested annual executive offices. These are meaningful only with requested_role=executive.';
comment on column public.membership_applications.requested_service_year is
  'Service year for requested annual executive offices.';

create table public.executive_office_assignments (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null
    references public.organization_memberships(id) on delete cascade,
  service_year smallint not null check (service_year between 2000 and 2100),
  office_code text not null check (
    office_code in (
      'president',
      'vice_president',
      'general_secretary',
      'secretary',
      'treasurer'
    )
  ),
  assigned_from_application_id uuid
    references public.membership_applications(id) on delete set null,
  assigned_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint executive_office_assignments_end_check check (
    ended_at is null or ended_at >= created_at
  )
);

comment on table public.executive_office_assignments is
  'Normalized annual offices for approved executive memberships; independent from app_role and church display titles.';

create unique index executive_office_assignments_active_unique_idx
  on public.executive_office_assignments (membership_id, service_year, office_code)
  where ended_at is null;
create index executive_office_assignments_membership_year_idx
  on public.executive_office_assignments (membership_id, service_year, ended_at);

create table public.meeting_minutes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  meeting_year smallint not null check (meeting_year between 2000 and 2100),
  meeting_date date not null,
  title text not null check (char_length(title) between 1 and 200),
  body text not null check (char_length(body) between 1 and 50000),
  status text not null default 'draft' check (status in ('draft', 'published')),
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null check (char_length(author_name) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint meeting_minutes_year_matches_date_check check (
    meeting_year = extract(year from meeting_date)::smallint
  )
);

create index meeting_minutes_org_year_date_idx
  on public.meeting_minutes (organization_id, meeting_year desc, meeting_date desc);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  fiscal_year smallint not null check (fiscal_year between 2000 and 2100),
  entry_date date not null,
  entry_type text not null check (entry_type in ('income', 'expense')),
  category text not null check (char_length(category) between 1 and 80),
  description text not null check (char_length(description) between 1 and 500),
  amount numeric(15, 2) not null check (amount > 0),
  memo text check (memo is null or char_length(memo) <= 2000),
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null check (char_length(author_name) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ledger_entries_year_matches_date_check check (
    fiscal_year = extract(year from entry_date)::smallint
  )
);

create index ledger_entries_org_year_date_idx
  on public.ledger_entries (organization_id, fiscal_year desc, entry_date desc);

create trigger meeting_minutes_set_updated_at
before update on public.meeting_minutes
for each row execute function private.set_updated_at();

create trigger ledger_entries_set_updated_at
before update on public.ledger_entries
for each row execute function private.set_updated_at();

-- Assignment integrity is enforced at the database boundary even for trusted tools.
create or replace function private.validate_executive_office_assignment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.ended_at is null and not exists (
    select 1
    from public.organization_memberships as membership
    where membership.id = new.membership_id
      and membership.role = 'executive'::public.app_role
      and membership.status = 'active'::public.membership_status
  ) then
    raise exception 'active_executive_membership_required' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.validate_executive_office_assignment()
  from public, anon, authenticated;

create trigger executive_office_assignments_validate
before insert or update on public.executive_office_assignments
for each row execute function private.validate_executive_office_assignment();

create or replace function private.end_ineligible_executive_offices()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.role <> 'executive'::public.app_role
    or new.status <> 'active'::public.membership_status then
    update public.executive_office_assignments
    set ended_at = pg_catalog.clock_timestamp()
    where membership_id = new.id
      and ended_at is null;
  end if;

  return new;
end;
$$;

revoke all on function private.end_ineligible_executive_offices()
  from public, anon, authenticated;

create trigger organization_memberships_end_ineligible_executive_offices
after update of role, status on public.organization_memberships
for each row execute function private.end_ineligible_executive_offices();

-- The approval RPC remains the only approval path. This trigger observes its final
-- approved state and materializes only the requested offices for executive roles.
create or replace function private.sync_executive_offices_from_approved_application()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_membership public.organization_memberships%rowtype;
  v_service_year smallint;
  v_office_code text;
begin
  if new.status <> 'approved'::public.application_status
    or old.status = 'approved'::public.application_status then
    return new;
  end if;

  -- Applications created before annual offices existed carry an empty default.
  -- They must be rejected and resubmitted with an explicit office selection;
  -- otherwise an executive role would be activated without its scoped duties.
  if new.requested_role = 'executive'::public.app_role
    and pg_catalog.cardinality(new.requested_executive_office_codes) = 0 then
    raise exception 'executive_office_required' using errcode = '23514';
  end if;

  if new.requested_role = 'executive'::public.app_role
    and (
      new.requested_service_year is null
      or new.requested_service_year not between
        private.current_service_year()
        and private.current_service_year() + 1
    ) then
    raise exception 'invalid_executive_service_year' using errcode = '23514';
  end if;

  select * into v_membership
  from public.organization_memberships
  where approved_from_application_id = new.id
    and user_id = new.user_id
    and organization_id = new.organization_id
  for update;

  if not found then
    raise exception 'approved_membership_not_found' using errcode = 'P0002';
  end if;

  if new.requested_role <> 'executive'::public.app_role then
    update public.executive_office_assignments
    set ended_at = pg_catalog.clock_timestamp()
    where membership_id = v_membership.id
      and ended_at is null;
    return new;
  end if;

  v_service_year := coalesce(
    new.requested_service_year,
    private.current_service_year()
  );

  update public.executive_office_assignments
  set ended_at = pg_catalog.clock_timestamp()
  where membership_id = v_membership.id
    and service_year = v_service_year
    and ended_at is null
    and not (office_code = any(new.requested_executive_office_codes));

  foreach v_office_code in array new.requested_executive_office_codes
  loop
    insert into public.executive_office_assignments (
      membership_id,
      service_year,
      office_code,
      assigned_from_application_id,
      assigned_by
    )
    values (
      v_membership.id,
      v_service_year,
      v_office_code,
      new.id,
      new.reviewed_by
    )
    on conflict (membership_id, service_year, office_code)
      where ended_at is null
    do update set
      assigned_from_application_id = excluded.assigned_from_application_id,
      assigned_by = excluded.assigned_by;
  end loop;

  return new;
end;
$$;

revoke all on function private.sync_executive_offices_from_approved_application()
  from public, anon, authenticated;

create trigger membership_applications_sync_executive_offices
after update of status on public.membership_applications
for each row execute function private.sync_executive_offices_from_approved_application();

create or replace function private.can_read_executive_operations(
  p_organization_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.organization_memberships as membership
    join public.organizations as organization
      on organization.id = membership.organization_id
    where membership.organization_id = p_organization_id
      and membership.user_id = p_actor_id
      and membership.role = 'executive'::public.app_role
      and membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
  );
$$;

create or replace function private.can_read_executive_assignment(
  p_membership_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.is_platform_admin(p_actor_id)
    or exists (
      select 1
      from public.organization_memberships as target
      where target.id = p_membership_id
        and (
          target.user_id = p_actor_id
          or private.can_read_executive_operations(target.organization_id, p_actor_id)
        )
    );
$$;

create or replace function private.has_current_executive_office(
  p_organization_id uuid,
  p_actor_id uuid,
  p_office_codes text[]
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.executive_office_assignments as assignment
        on assignment.membership_id = membership.id
      where membership.organization_id = p_organization_id
        and membership.user_id = p_actor_id
        and membership.role = 'executive'::public.app_role
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and assignment.service_year = private.current_service_year()
        and assignment.ended_at is null
        and assignment.office_code = any(p_office_codes)
    );
$$;

create or replace function private.can_manage_meeting_minutes(
  p_organization_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_executive_office(
    p_organization_id,
    p_actor_id,
    array['president', 'vice_president', 'general_secretary', 'secretary']::text[]
  );
$$;

create or replace function private.can_manage_ledger(
  p_organization_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_executive_office(
    p_organization_id,
    p_actor_id,
    array['president', 'treasurer']::text[]
  );
$$;

revoke all on function private.can_read_executive_operations(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_read_executive_assignment(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.has_current_executive_office(uuid, uuid, text[])
  from public, anon, authenticated;
revoke all on function private.can_manage_meeting_minutes(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_manage_ledger(uuid, uuid)
  from public, anon, authenticated;

grant execute on function private.can_read_executive_operations(uuid, uuid)
  to authenticated;
grant execute on function private.can_read_executive_assignment(uuid, uuid)
  to authenticated;
grant execute on function private.has_current_executive_office(uuid, uuid, text[])
  to authenticated;
grant execute on function private.can_manage_meeting_minutes(uuid, uuid)
  to authenticated;
grant execute on function private.can_manage_ledger(uuid, uuid)
  to authenticated;

alter table public.executive_office_assignments enable row level security;
alter table public.meeting_minutes enable row level security;
alter table public.ledger_entries enable row level security;

create policy executive_office_assignments_select_authorized
on public.executive_office_assignments for select to authenticated
using (private.can_read_executive_assignment(membership_id, auth.uid()));

create policy meeting_minutes_select_executives
on public.meeting_minutes for select to authenticated
using (private.can_read_executive_operations(organization_id, auth.uid()));

create policy ledger_entries_select_executives
on public.ledger_entries for select to authenticated
using (private.can_read_executive_operations(organization_id, auth.uid()));

revoke all on table public.executive_office_assignments
  from public, anon, authenticated;
revoke all on table public.meeting_minutes
  from public, anon, authenticated;
revoke all on table public.ledger_entries
  from public, anon, authenticated;

grant select on table public.executive_office_assignments to authenticated;
grant select on table public.meeting_minutes to authenticated;
grant select on table public.ledger_entries to authenticated;

create function public.save_meeting_minute(
  p_id uuid,
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

  if p_id is null then
    insert into public.meeting_minutes (
      organization_id, meeting_year, meeting_date, title, body, status,
      author_id, author_name
    )
    values (
      p_organization_id, p_meeting_year, p_meeting_date, v_title, v_body,
      p_status, v_actor_id, v_author_name
    )
    returning id into v_id;
    v_action := 'meeting_minute.created';
  else
    select * into v_existing
    from public.meeting_minutes
    where id = p_id
    for update;
    if not found then
      raise exception 'meeting_minute_not_found' using errcode = 'P0002';
    end if;
    if v_existing.organization_id <> p_organization_id then
      raise exception 'meeting_minute_organization_mismatch' using errcode = '42501';
    end if;
    if v_existing.meeting_year <> private.current_service_year() then
      raise exception 'historical_meeting_minutes_are_read_only' using errcode = '42501';
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
    where id = p_id;
    v_id := p_id;
    v_action := 'meeting_minute.updated';
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

create function public.delete_meeting_minute(p_id uuid)
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

create function public.save_ledger_entry(
  p_id uuid,
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

  if p_id is null then
    insert into public.ledger_entries (
      organization_id, fiscal_year, entry_date, entry_type, category,
      description, amount, memo, author_id, author_name
    )
    values (
      p_organization_id, p_fiscal_year, p_entry_date, p_entry_type,
      v_category, v_description, p_amount, v_memo, v_actor_id, v_author_name
    )
    returning id into v_id;
    v_action := 'ledger_entry.created';
  else
    select * into v_existing
    from public.ledger_entries
    where id = p_id
    for update;
    if not found then
      raise exception 'ledger_entry_not_found' using errcode = 'P0002';
    end if;
    if v_existing.organization_id <> p_organization_id then
      raise exception 'ledger_entry_organization_mismatch' using errcode = '42501';
    end if;
    if v_existing.fiscal_year <> private.current_service_year() then
      raise exception 'historical_ledger_entries_are_read_only' using errcode = '42501';
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
    where id = p_id;
    v_id := p_id;
    v_action := 'ledger_entry.updated';
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

create function public.delete_ledger_entry(p_id uuid)
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

revoke all on function public.save_meeting_minute(uuid, uuid, integer, date, text, text, text)
  from public, anon, authenticated;
revoke all on function public.delete_meeting_minute(uuid)
  from public, anon, authenticated;
revoke all on function public.save_ledger_entry(uuid, uuid, integer, date, text, text, text, numeric, text)
  from public, anon, authenticated;
revoke all on function public.delete_ledger_entry(uuid)
  from public, anon, authenticated;

grant execute on function public.save_meeting_minute(uuid, uuid, integer, date, text, text, text)
  to authenticated;
grant execute on function public.delete_meeting_minute(uuid)
  to authenticated;
grant execute on function public.save_ledger_entry(uuid, uuid, integer, date, text, text, text, numeric, text)
  to authenticated;
grant execute on function public.delete_ledger_entry(uuid)
  to authenticated;

-- Annual office rollover is an explicit platform-admin action. It is separate
-- from membership role approval so an existing executive can be assigned for a
-- new service year without weakening the leadership approval hierarchy.
create function public.set_executive_offices(
  p_membership_id uuid,
  p_service_year integer,
  p_office_codes text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_membership public.organization_memberships%rowtype;
  v_organization_status public.organization_status;
  v_office_codes text[];
  v_previous_office_codes text[];
  v_office_code text;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.is_platform_admin(v_actor_id) then
    raise exception 'platform_admin_required_for_executive_offices' using errcode = '42501';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(coalesce(p_office_codes, '{}'::text[])) as office(code)
    where office.code is null
      or pg_catalog.btrim(office.code) not in (
        'president',
        'vice_president',
        'general_secretary',
        'secretary',
        'treasurer'
      )
  ) then
    raise exception 'invalid_executive_office_code' using errcode = '23514';
  end if;

  select coalesce(
    pg_catalog.array_agg(normalized.code order by normalized.first_position),
    '{}'::text[]
  ) into v_office_codes
  from (
    select
      pg_catalog.btrim(office.code) as code,
      min(office.position) as first_position
    from pg_catalog.unnest(coalesce(p_office_codes, '{}'::text[]))
      with ordinality as office(code, position)
    group by pg_catalog.btrim(office.code)
  ) as normalized;

  if pg_catalog.cardinality(v_office_codes) = 0 then
    raise exception 'executive_office_required' using errcode = '23514';
  end if;
  if p_service_year is null
    or p_service_year not between
      private.current_service_year()
      and private.current_service_year() + 1 then
    raise exception 'invalid_executive_service_year' using errcode = '23514';
  end if;

  select * into v_membership
  from public.organization_memberships
  where id = p_membership_id
  for update;

  if not found
    or v_membership.role <> 'executive'::public.app_role
    or v_membership.status <> 'active'::public.membership_status then
    raise exception 'active_executive_membership_required' using errcode = 'P0002';
  end if;

  select status into v_organization_status
  from public.organizations
  where id = v_membership.organization_id
  for update;

  if v_organization_status <> 'active'::public.organization_status then
    raise exception 'active_organization_required' using errcode = '42501';
  end if;

  select coalesce(
    pg_catalog.array_agg(assignment.office_code order by assignment.office_code),
    '{}'::text[]
  ) into v_previous_office_codes
  from public.executive_office_assignments as assignment
  where assignment.membership_id = p_membership_id
    and assignment.service_year = p_service_year
    and assignment.ended_at is null;

  update public.executive_office_assignments
  set ended_at = pg_catalog.clock_timestamp()
  where membership_id = p_membership_id
    and service_year = p_service_year
    and ended_at is null
    and not (office_code = any(v_office_codes));

  foreach v_office_code in array v_office_codes
  loop
    insert into public.executive_office_assignments (
      membership_id,
      service_year,
      office_code,
      assigned_by
    )
    values (
      p_membership_id,
      p_service_year,
      v_office_code,
      v_actor_id
    )
    on conflict (membership_id, service_year, office_code)
      where ended_at is null
    do update set assigned_by = excluded.assigned_by;
  end loop;

  insert into public.notifications (
    user_id,
    kind,
    title,
    body,
    entity_type,
    entity_id,
    metadata
  )
  values (
    v_membership.user_id,
    'membership_changed'::public.notification_kind,
    '임원 직책이 변경되었습니다',
    p_service_year::text || '년 임원 직책을 내 정보에서 확인해 주세요.',
    'organization_membership',
    p_membership_id,
    pg_catalog.jsonb_build_object(
      'organization_id', v_membership.organization_id,
      'service_year', p_service_year,
      'office_codes', v_office_codes
    )
  );

  perform private.write_audit(
    v_actor_id,
    'executive_offices.set',
    'organization_membership',
    p_membership_id,
    v_membership.organization_id,
    v_membership.user_id,
    pg_catalog.jsonb_build_object(
      'service_year', p_service_year,
      'previous_office_codes', v_previous_office_codes,
      'office_codes', v_office_codes
    )
  );

  return pg_catalog.jsonb_build_object(
    'membership_id', p_membership_id,
    'service_year', p_service_year,
    'office_codes', v_office_codes
  );
end;
$$;

revoke all on function public.set_executive_offices(uuid, integer, text[])
  from public, anon, authenticated;
grant execute on function public.set_executive_offices(uuid, integer, text[])
  to authenticated;

-- Replace the four-argument title-aware submit function with one six-argument
-- function. Defaults preserve every existing two-, three-, and four-argument call.
revoke all on function public.submit_membership_application(
  uuid,
  public.app_role,
  text,
  text
) from public, anon, authenticated;
drop function public.submit_membership_application(uuid, public.app_role, text, text);

create function public.submit_membership_application(
  p_organization_id uuid,
  p_requested_role public.app_role,
  p_applicant_note text default null,
  p_requested_church_title_code text default null,
  p_requested_executive_office_codes text[] default '{}'::text[],
  p_requested_service_year integer default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_application_id uuid;
  v_existing public.organization_memberships%rowtype;
  v_organization public.organizations%rowtype;
  v_title_code text := nullif(pg_catalog.btrim(p_requested_church_title_code), '');
  v_office_codes text[];
  v_service_year smallint;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(coalesce(p_requested_executive_office_codes, '{}'::text[])) as office(code)
    where office.code is null
      or pg_catalog.btrim(office.code) not in (
        'president',
        'vice_president',
        'general_secretary',
        'secretary',
        'treasurer'
      )
  ) then
    raise exception 'invalid_executive_office_code' using errcode = '23514';
  end if;

  select coalesce(
    pg_catalog.array_agg(normalized.code order by normalized.first_position),
    '{}'::text[]
  ) into v_office_codes
  from (
    select
      pg_catalog.btrim(office.code) as code,
      min(office.position) as first_position
    from pg_catalog.unnest(coalesce(p_requested_executive_office_codes, '{}'::text[]))
      with ordinality as office(code, position)
    group by pg_catalog.btrim(office.code)
  ) as normalized;

  if p_requested_role <> 'executive'::public.app_role
    and (
      pg_catalog.cardinality(v_office_codes) > 0
      or p_requested_service_year is not null
    ) then
    raise exception 'executive_offices_require_executive_role' using errcode = '23514';
  end if;

  if p_requested_role = 'executive'::public.app_role
    and pg_catalog.cardinality(v_office_codes) = 0 then
    raise exception 'executive_office_required' using errcode = '23514';
  end if;

  if p_requested_role = 'executive'::public.app_role
    and pg_catalog.cardinality(v_office_codes) > 0 then
    v_service_year := coalesce(
      p_requested_service_year,
      private.current_service_year()
    )::smallint;
  elsif p_requested_role = 'executive'::public.app_role
    and p_requested_service_year is not null then
    v_service_year := p_requested_service_year::smallint;
  else
    v_service_year := null;
  end if;

  if v_service_year is not null
    and v_service_year not between
      private.current_service_year()
      and private.current_service_year() + 1 then
    raise exception 'invalid_executive_service_year' using errcode = '23514';
  end if;

  select * into v_organization
  from public.organizations
  where id = p_organization_id;

  if not found or v_organization.status not in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  ) then
    raise exception 'organization_not_available' using errcode = 'P0002';
  end if;

  if p_applicant_note is not null and char_length(p_applicant_note) > 2000 then
    raise exception 'applicant_note_too_long' using errcode = '22001';
  end if;

  if v_title_code is not null and not exists (
    select 1
    from public.church_title_catalog as title
    where title.code = v_title_code
      and title.is_active
  ) then
    raise exception 'invalid_church_title_code' using errcode = '23514';
  end if;

  select * into v_existing
  from public.organization_memberships
  where user_id = v_actor_id
    and status = 'active'::public.membership_status
  for update;

  if found and v_existing.organization_id <> p_organization_id then
    raise exception 'active_membership_exists_in_another_organization' using errcode = '23505';
  end if;
  if found and v_existing.role = p_requested_role then
    raise exception 'requested_role_is_already_active' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.membership_applications as pending
    where pending.user_id = v_actor_id
      and pending.status = 'pending'::public.application_status
  ) then
    raise exception 'pending_application_already_exists' using errcode = '23505';
  end if;

  insert into public.membership_applications (
    user_id,
    organization_id,
    requested_role,
    requested_church_title_code,
    requested_executive_office_codes,
    requested_service_year,
    applicant_note
  )
  values (
    v_actor_id,
    p_organization_id,
    p_requested_role,
    v_title_code,
    v_office_codes,
    v_service_year,
    nullif(pg_catalog.btrim(p_applicant_note), '')
  )
  returning id into v_application_id;

  insert into public.notifications (
    user_id,
    kind,
    title,
    body,
    entity_type,
    entity_id,
    metadata
  )
  select
    recipients.user_id,
    'application_submitted'::public.notification_kind,
    '새 가입 승인 요청',
    v_organization.display_name || ' 가입 승인 요청이 도착했습니다.',
    'membership_application',
    v_application_id,
    pg_catalog.jsonb_build_object(
      'organization_id', p_organization_id,
      'requested_role', p_requested_role,
      'church_title_code', v_title_code,
      'executive_office_codes', v_office_codes,
      'service_year', v_service_year
    )
  from (
    select pa.user_id
    from public.platform_admins as pa
    where
      p_requested_role in (
        'minister'::public.app_role,
        'executive'::public.app_role
      )
      or coalesce(
        v_existing.role in (
          'minister'::public.app_role,
          'executive'::public.app_role
        ),
        false
      )
    union
    select membership.user_id
    from public.organization_memberships as membership
    where p_requested_role = 'member'::public.app_role
      and not coalesce(
        v_existing.role in (
          'minister'::public.app_role,
          'executive'::public.app_role
        ),
        false
      )
      and membership.organization_id = p_organization_id
      and membership.status = 'active'::public.membership_status
      and membership.role in (
        'minister'::public.app_role,
        'executive'::public.app_role
      )
  ) as recipients
  where recipients.user_id <> v_actor_id;

  perform private.write_audit(
    v_actor_id,
    'membership_application.submitted',
    'membership_application',
    v_application_id,
    p_organization_id,
    v_actor_id,
    pg_catalog.jsonb_build_object(
      'requested_role', p_requested_role,
      'church_title_code', v_title_code,
      'executive_office_codes', v_office_codes,
      'service_year', v_service_year
    )
  );

  return v_application_id;
end;
$$;

revoke all on function public.submit_membership_application(
  uuid,
  public.app_role,
  text,
  text,
  text[],
  integer
) from public, anon, authenticated;
grant execute on function public.submit_membership_application(
  uuid,
  public.app_role,
  text,
  text,
  text[],
  integer
) to authenticated;

-- Realtime delivers only rows visible through the authenticated subscriber's RLS.
do $$
declare
  v_table_name text;
begin
  if not exists (
    select 1
    from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) then
    raise notice 'supabase_realtime publication is unavailable; skipping executive operations publication setup';
    return;
  end if;

  foreach v_table_name in array array[
    'executive_office_assignments',
    'meeting_minutes',
    'ledger_entries'
  ]
  loop
    if not exists (
      select 1
      from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table_name
    ) then
      execute pg_catalog.format(
        'alter publication supabase_realtime add table public.%I',
        v_table_name
      );
    end if;
  end loop;
end;
$$;
