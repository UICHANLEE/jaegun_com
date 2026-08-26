-- Make every governance office, including a church pastor, an explicit annual
-- assignment. Candidate filtering and single-office mutations remain
-- server-authoritative so large rosters and concurrent editors cannot lose data.

create or replace function private.is_current_church_pastor(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = p_scope_id
      and scope.scope_type = 'church'::public.governance_scope_type
      and scope.is_active
      and private.has_current_governance_office(
        p_scope_id,
        p_user_id,
        array['pastor']::text[]
      )
  );
$$;

revoke all on function private.is_current_church_pastor(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.list_governance_roster(
  p_scope_id uuid,
  p_service_year integer default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  display_name text,
  church_title_code text,
  church_title_name text,
  membership_role public.app_role,
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  office_codes text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_service_year smallint;
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = p_scope_id
      and scope.is_active
  ) then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;
  if not private.can_view_governance_roster(p_scope_id, v_actor_id) then
    raise exception 'governance_roster_forbidden' using errcode = '42501';
  end if;

  if p_service_year is not null and p_service_year not between 2000 and 2100 then
    raise exception 'invalid_governance_service_year' using errcode = '23514';
  end if;
  v_service_year := coalesce(p_service_year, private.current_service_year())::smallint;
  if v_search is not null and char_length(v_search) > 80 then
    raise exception 'governance_roster_search_too_long' using errcode = '22001';
  end if;
  if p_limit is null or p_limit not between 1 and 200
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_governance_roster_page' using errcode = '22023';
  end if;

  return query
  with roster as (
    select
      profile.id as user_id,
      profile.display_name,
      membership.church_title_code,
      title.display_name as church_title_name,
      membership.role as membership_role,
      organization.id as organization_id,
      organization.display_name as organization_name,
      organization.presbytery as presbytery_name,
      coalesce(
        (
          select pg_catalog.array_agg(
            assignment.office_code
            order by case assignment.office_code
              when 'pastor' then 1
              when 'president' then 2
              when 'vice_president' then 3
              when 'general_secretary' then 4
              when 'secretary' then 5
              else 6
            end
          )
          from public.governance_office_assignments as assignment
          where assignment.scope_id = p_scope_id
            and assignment.user_id = profile.id
            and assignment.service_year = v_service_year
            and assignment.ended_at is null
        ),
        '{}'::text[]
      ) as office_codes
    from public.organization_memberships as membership
    join public.profiles as profile on profile.id = membership.user_id
    join public.organizations as organization
      on organization.id = membership.organization_id
    left join public.church_title_catalog as title
      on title.code = membership.church_title_code
    where membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
      and profile.deactivated_at is null
      and private.scope_contains_organization(p_scope_id, membership.organization_id)
      and (
        v_search is null
        or profile.display_name ilike '%' || v_search || '%'
        or organization.display_name ilike '%' || v_search || '%'
        or organization.presbytery ilike '%' || v_search || '%'
        or coalesce(title.display_name, '') ilike '%' || v_search || '%'
      )
  )
  select
    roster.user_id,
    roster.display_name,
    roster.church_title_code,
    roster.church_title_name,
    roster.membership_role,
    roster.organization_id,
    roster.organization_name,
    roster.presbytery_name,
    roster.office_codes,
    pg_catalog.count(*) over () as total_count
  from roster
  order by
    (pg_catalog.cardinality(roster.office_codes) > 0) desc,
    roster.organization_name,
    roster.display_name,
    roster.user_id
  limit p_limit
  offset p_offset;
end;
$$;

create or replace function public.list_governance_office_candidates(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  display_name text,
  church_title_code text,
  church_title_name text,
  membership_role public.app_role,
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  office_codes text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope_type public.governance_scope_type;
  v_office_code text := pg_catalog.btrim(p_office_code);
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_service_year is null
    or p_service_year not between private.current_service_year() and private.current_service_year() + 1 then
    raise exception 'invalid_governance_service_year' using errcode = '23514';
  end if;
  if v_office_code is null or v_office_code not in (
    'pastor',
    'president',
    'vice_president',
    'general_secretary',
    'secretary',
    'treasurer'
  ) then
    raise exception 'invalid_governance_office_code' using errcode = '23514';
  end if;
  if v_search is not null and char_length(v_search) > 80 then
    raise exception 'governance_candidate_search_too_long' using errcode = '22001';
  end if;
  if p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_governance_candidate_page' using errcode = '22023';
  end if;

  select scope.scope_type into v_scope_type
  from public.governance_scopes as scope
  where scope.id = p_scope_id
    and scope.is_active;

  if not found then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_governance_offices(p_scope_id, v_actor_id) then
    raise exception 'governance_office_management_forbidden' using errcode = '42501';
  end if;

  return query
  with candidates as (
    select
      profile.id as user_id,
      profile.display_name,
      membership.church_title_code,
      title.display_name as church_title_name,
      membership.role as membership_role,
      organization.id as organization_id,
      organization.display_name as organization_name,
      organization.presbytery as presbytery_name,
      coalesce(
        (
          select pg_catalog.array_agg(
            assignment.office_code
            order by assignment.office_code
          )
          from public.governance_office_assignments as assignment
          where assignment.scope_id = p_scope_id
            and assignment.user_id = profile.id
            and assignment.service_year = p_service_year
            and assignment.ended_at is null
        ),
        '{}'::text[]
      ) as office_codes
    from public.organization_memberships as membership
    join public.profiles as profile on profile.id = membership.user_id
    join public.organizations as organization
      on organization.id = membership.organization_id
    left join public.church_title_catalog as title
      on title.code = membership.church_title_code
    where membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
      and profile.deactivated_at is null
      and private.scope_contains_organization(p_scope_id, membership.organization_id)
      and (
        (v_office_code = 'pastor' and membership.role = 'minister'::public.app_role)
        or (
          v_office_code <> 'pastor'
          and v_scope_type = 'church'::public.governance_scope_type
          and membership.role = 'executive'::public.app_role
        )
        or (
          v_office_code <> 'pastor'
          and v_scope_type <> 'church'::public.governance_scope_type
          and membership.role in ('minister'::public.app_role, 'executive'::public.app_role)
        )
      )
      and (
        v_search is null
        or profile.display_name ilike '%' || v_search || '%'
        or organization.display_name ilike '%' || v_search || '%'
        or organization.presbytery ilike '%' || v_search || '%'
        or coalesce(title.display_name, '') ilike '%' || v_search || '%'
      )
  )
  select
    candidates.user_id,
    candidates.display_name,
    candidates.church_title_code,
    candidates.church_title_name,
    candidates.membership_role,
    candidates.organization_id,
    candidates.organization_name,
    candidates.presbytery_name,
    candidates.office_codes,
    pg_catalog.count(*) over () as total_count
  from candidates
  order by candidates.organization_name, candidates.display_name, candidates.user_id
  limit p_limit
  offset p_offset;
end;
$$;

create or replace function public.assign_governance_office(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_office_code text := pg_catalog.btrim(p_office_code);
  v_office_codes text[];
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_scope_id is null or p_user_id is null or p_service_year is null then
    raise exception 'governance_scope_year_office_and_target_required' using errcode = '22023';
  end if;
  if p_service_year not between private.current_service_year() and private.current_service_year() + 1 then
    raise exception 'invalid_governance_service_year' using errcode = '23514';
  end if;
  if v_office_code is null or v_office_code not in (
    'pastor',
    'president',
    'vice_president',
    'general_secretary',
    'secretary',
    'treasurer'
  ) then
    raise exception 'invalid_governance_office_code' using errcode = '23514';
  end if;
  if not exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = p_scope_id
      and scope.is_active
  ) then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_governance_offices(p_scope_id, auth.uid()) then
    raise exception 'governance_office_management_forbidden' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'governance-office:' || p_scope_id::text || ':' || p_service_year::text,
      0
    )
  );

  select coalesce(pg_catalog.array_agg(assignment.office_code), '{}'::text[])
  into v_office_codes
  from public.governance_office_assignments as assignment
  where assignment.scope_id = p_scope_id
    and assignment.service_year = p_service_year
    and assignment.user_id = p_user_id
    and assignment.ended_at is null;

  if not (v_office_code = any(v_office_codes)) then
    v_office_codes := pg_catalog.array_append(v_office_codes, v_office_code);
  end if;

  return public.set_governance_offices(
    p_scope_id,
    p_service_year,
    p_user_id,
    v_office_codes
  );
end;
$$;

create or replace function public.clear_governance_office(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_office_code text := pg_catalog.btrim(p_office_code);
  v_holder_id uuid;
  v_office_codes text[];
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_scope_id is null or p_service_year is null then
    raise exception 'governance_scope_year_and_office_required' using errcode = '22023';
  end if;
  if p_service_year not between private.current_service_year() and private.current_service_year() + 1 then
    raise exception 'invalid_governance_service_year' using errcode = '23514';
  end if;
  if v_office_code is null or v_office_code not in (
    'pastor',
    'president',
    'vice_president',
    'general_secretary',
    'secretary',
    'treasurer'
  ) then
    raise exception 'invalid_governance_office_code' using errcode = '23514';
  end if;
  if not exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = p_scope_id
      and scope.is_active
  ) then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_governance_offices(p_scope_id, auth.uid()) then
    raise exception 'governance_office_management_forbidden' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'governance-office:' || p_scope_id::text || ':' || p_service_year::text,
      0
    )
  );

  select assignment.user_id into v_holder_id
  from public.governance_office_assignments as assignment
  where assignment.scope_id = p_scope_id
    and assignment.service_year = p_service_year
    and assignment.office_code = v_office_code
    and assignment.ended_at is null
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'service_year', p_service_year,
      'office_code', v_office_code,
      'cleared', false
    );
  end if;

  select coalesce(pg_catalog.array_agg(assignment.office_code), '{}'::text[])
  into v_office_codes
  from public.governance_office_assignments as assignment
  where assignment.scope_id = p_scope_id
    and assignment.service_year = p_service_year
    and assignment.user_id = v_holder_id
    and assignment.office_code <> v_office_code
    and assignment.ended_at is null;

  return public.set_governance_offices(
    p_scope_id,
    p_service_year,
    v_holder_id,
    v_office_codes
  );
end;
$$;

-- The legacy complete-set RPC is still available during rolling deploys. A
-- deferred guard prevents any non-platform caller from orphaning the current
-- service-year scope even when several rows are replaced in one transaction.
create or replace function private.enforce_governance_scope_authority()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_scope_id uuid := coalesce(new.scope_id, old.scope_id);
  v_service_year smallint := coalesce(new.service_year, old.service_year);
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null
    or v_service_year <> private.current_service_year()
    or private.is_platform_admin(v_actor_id) then
    return null;
  end if;

  if exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = v_scope_id
      and scope.is_active
  ) and not exists (
    select 1
    from public.governance_office_assignments as assignment
    where assignment.scope_id = v_scope_id
      and assignment.service_year = v_service_year
      and assignment.office_code in ('president', 'pastor')
      and assignment.ended_at is null
      and private.is_user_active_in_governance_scope(
        v_scope_id,
        assignment.user_id
      )
  ) then
    raise exception 'governance_scope_authority_cannot_be_orphaned' using errcode = '42501';
  end if;

  return null;
end;
$$;

revoke all on function private.enforce_governance_scope_authority()
  from public, anon, authenticated;

drop trigger if exists governance_scope_authority_guard
  on public.governance_office_assignments;
create constraint trigger governance_scope_authority_guard
after insert or update or delete on public.governance_office_assignments
deferrable initially deferred
for each row execute function private.enforce_governance_scope_authority();

comment on function public.list_governance_office_candidates(uuid, integer, text, text, integer, integer) is
  'Lists only role-eligible candidates before pagination for one exact scope, year, and office.';
comment on function public.assign_governance_office(uuid, integer, text, uuid) is
  'Assigns one exact-scope annual office without replacing the target other offices.';
comment on function public.clear_governance_office(uuid, integer, text) is
  'Clears one exact-scope annual office without replacing the holder other offices.';

revoke all on function public.list_governance_office_candidates(uuid, integer, text, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.assign_governance_office(uuid, integer, text, uuid)
  from public, anon, authenticated;
revoke all on function public.clear_governance_office(uuid, integer, text)
  from public, anon, authenticated;

grant execute on function public.list_governance_office_candidates(uuid, integer, text, text, integer, integer)
  to authenticated;
grant execute on function public.assign_governance_office(uuid, integer, text, uuid)
  to authenticated;
grant execute on function public.clear_governance_office(uuid, integer, text)
  to authenticated;
