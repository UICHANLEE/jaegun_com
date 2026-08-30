-- Church department offices for minister-facing administration.
--
-- Department offices are annual display/operations metadata. They never mutate
-- organization_memberships.role, never create an executive app role, and never
-- authorize another department. Only a platform administrator or the explicitly
-- assigned current-year pastor at the exact church scope may change them.

create type public.church_department_code as enum (
  'adult',
  'young_adult',
  'teen',
  'elementary'
);

create table public.church_departments (
  id uuid primary key default gen_random_uuid(),
  church_scope_id uuid not null
    references public.governance_scopes(id) on delete cascade,
  department_code public.church_department_code not null,
  display_name text not null,
  sort_order smallint not null,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (church_scope_id, department_code),
  constraint church_departments_fixed_catalog_check check (
    (department_code = 'adult'::public.church_department_code
      and display_name = '장년부' and sort_order = 10)
    or (department_code = 'young_adult'::public.church_department_code
      and display_name = '청년부' and sort_order = 20)
    or (department_code = 'teen'::public.church_department_code
      and display_name = '청소년부' and sort_order = 30)
    or (department_code = 'elementary'::public.church_department_code
      and display_name = '초등부' and sort_order = 40)
  )
);

comment on table public.church_departments is
  'The four fixed ministry departments at one exact church governance scope.';
comment on column public.church_departments.department_code is
  'Immutable fixed code: adult, young_adult, teen, or elementary.';

create index church_departments_scope_sort_idx
  on public.church_departments (church_scope_id, sort_order, id);

create table public.department_office_assignments (
  id uuid primary key default gen_random_uuid(),
  department_id uuid not null
    references public.church_departments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
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
  assigned_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  ended_at timestamptz,
  constraint department_office_assignments_end_check check (
    ended_at is null or ended_at >= created_at
  )
);

comment on table public.department_office_assignments is
  'Year-scoped department office metadata. These rows never grant an app role or governance authority.';

create unique index department_offices_one_active_holder_idx
  on public.department_office_assignments (
    department_id,
    service_year,
    office_code
  )
  where ended_at is null;
create index department_offices_user_year_idx
  on public.department_office_assignments (user_id, service_year, ended_at);
create index department_offices_department_year_idx
  on public.department_office_assignments (
    department_id,
    service_year,
    ended_at,
    office_code
  );

create or replace function private.validate_church_department()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if tg_op = 'UPDATE' and (
    new.id is distinct from old.id
    or new.church_scope_id is distinct from old.church_scope_id
    or new.department_code is distinct from old.department_code
    or new.display_name is distinct from old.display_name
    or new.sort_order is distinct from old.sort_order
  ) then
    raise exception 'church_department_identity_is_immutable'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = new.church_scope_id
      and scope.scope_type = 'church'::public.governance_scope_type
      and scope.organization_id is not null
  ) then
    raise exception 'department_requires_church_scope' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger church_departments_validate
before insert or update on public.church_departments
for each row execute function private.validate_church_department();

create trigger church_departments_set_updated_at
before update on public.church_departments
for each row execute function private.set_updated_at();

create or replace function private.sync_church_departments_for_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if new.scope_type <> 'church'::public.governance_scope_type
    or new.organization_id is null then
    return new;
  end if;

  insert into public.church_departments (
    church_scope_id,
    department_code,
    display_name,
    sort_order,
    is_active
  )
  values
    (new.id, 'adult'::public.church_department_code, '장년부', 10, new.is_active),
    (new.id, 'young_adult'::public.church_department_code, '청년부', 20, new.is_active),
    (new.id, 'teen'::public.church_department_code, '청소년부', 30, new.is_active),
    (new.id, 'elementary'::public.church_department_code, '초등부', 40, new.is_active)
  on conflict (church_scope_id, department_code)
  do update set is_active = excluded.is_active;

  if not new.is_active then
    update public.department_office_assignments as assignment
    set ended_at = greatest(assignment.created_at, v_now)
    from public.church_departments as department
    where department.church_scope_id = new.id
      and assignment.department_id = department.id
      and assignment.ended_at is null;
  end if;

  return new;
end;
$$;

create trigger governance_scopes_sync_church_departments
after insert or update of scope_type, organization_id, is_active
on public.governance_scopes
for each row execute function private.sync_church_departments_for_scope();

insert into public.church_departments (
  church_scope_id,
  department_code,
  display_name,
  sort_order,
  is_active
)
select
  scope.id,
  catalog.department_code,
  catalog.display_name,
  catalog.sort_order,
  scope.is_active
from public.governance_scopes as scope
cross join (
  values
    ('adult'::public.church_department_code, '장년부'::text, 10::smallint),
    ('young_adult'::public.church_department_code, '청년부'::text, 20::smallint),
    ('teen'::public.church_department_code, '청소년부'::text, 30::smallint),
    ('elementary'::public.church_department_code, '초등부'::text, 40::smallint)
) as catalog(department_code, display_name, sort_order)
where scope.scope_type = 'church'::public.governance_scope_type
  and scope.organization_id is not null
on conflict (church_scope_id, department_code)
do update set is_active = excluded.is_active;

create or replace function private.can_manage_department_offices(
  p_department_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_department_id is not null
    and p_user_id is not null
    and exists (
      select 1
      from public.church_departments as department
      join public.governance_scopes as scope
        on scope.id = department.church_scope_id
      join public.organizations as organization
        on organization.id = scope.organization_id
      where department.id = p_department_id
        and department.is_active
        and scope.scope_type = 'church'::public.governance_scope_type
        and scope.is_active
        and organization.status = 'active'::public.organization_status
        and (
          private.is_platform_admin(p_user_id)
          or private.is_current_church_pastor(scope.id, p_user_id)
        )
    );
$$;

create or replace function private.can_view_church_departments(
  p_organization_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_organization_id is not null
    and p_user_id is not null
    and (
      private.is_platform_admin(p_user_id)
      or exists (
        select 1
        from public.governance_scopes as scope
        join public.organizations as organization
          on organization.id = scope.organization_id
        where scope.scope_type = 'church'::public.governance_scope_type
          and scope.organization_id = p_organization_id
          and scope.is_active
          and organization.status = 'active'::public.organization_status
          and private.is_current_church_pastor(scope.id, p_user_id)
      )
    );
$$;

create or replace function private.end_ineligible_department_offices()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  update public.department_office_assignments as assignment
  set ended_at = greatest(assignment.created_at, v_now)
  from public.church_departments as department
  join public.governance_scopes as scope
    on scope.id = department.church_scope_id
  where assignment.department_id = department.id
    and assignment.ended_at is null
    and (
      assignment.user_id = old.user_id
      or (tg_op = 'UPDATE' and assignment.user_id = new.user_id)
    )
    and not exists (
      select 1
      from public.organization_memberships as eligible_membership
      join public.organizations as organization
        on organization.id = eligible_membership.organization_id
      join public.profiles as profile
        on profile.id = eligible_membership.user_id
      where eligible_membership.user_id = assignment.user_id
        and eligible_membership.organization_id = scope.organization_id
        and eligible_membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and profile.deactivated_at is null
    );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger organization_memberships_end_department_offices
after update of user_id, organization_id, status or delete
on public.organization_memberships
for each row execute function private.end_ineligible_department_offices();

create or replace function private.freeze_deactivated_department_offices()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  update public.department_office_assignments as assignment
  set ended_at = greatest(
    assignment.created_at,
    pg_catalog.clock_timestamp()
  )
  where assignment.user_id = new.id
    and assignment.ended_at is null;

  return new;
end;
$$;

create trigger profiles_freeze_department_offices_on_deactivation
after update of deactivated_at on public.profiles
for each row
when (old.deactivated_at is null and new.deactivated_at is not null)
execute function private.freeze_deactivated_department_offices();

alter table public.church_departments enable row level security;
alter table public.department_office_assignments enable row level security;

revoke all on table public.church_departments
  from public, anon, authenticated;
revoke all on table public.department_office_assignments
  from public, anon, authenticated;

create or replace function public.list_church_departments(
  p_organization_id uuid,
  p_service_year integer default null
)
returns table (
  department_id uuid,
  department_code text,
  display_name text,
  sort_order smallint,
  office_code text,
  user_id uuid,
  member_display_name text,
  church_title_code text,
  membership_role public.app_role
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_service_year smallint;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_organization_id is null then
    raise exception 'organization_required' using errcode = '22023';
  end if;

  if p_service_year is not null and p_service_year not between
    private.current_service_year()
    and private.current_service_year() + 1 then
    raise exception 'invalid_department_service_year' using errcode = '23514';
  end if;
  v_service_year := coalesce(
    p_service_year,
    private.current_service_year()
  )::smallint;

  if not exists (
    select 1
    from public.governance_scopes as scope
    join public.organizations as organization
      on organization.id = scope.organization_id
    where scope.scope_type = 'church'::public.governance_scope_type
      and scope.organization_id = p_organization_id
      and scope.is_active
      and organization.status = 'active'::public.organization_status
  ) then
    raise exception 'active_church_not_found' using errcode = 'P0002';
  end if;

  if not private.can_view_church_departments(
    p_organization_id,
    v_actor_id
  ) then
    raise exception 'department_office_read_forbidden' using errcode = '42501';
  end if;

  return query
  select
    department.id as department_id,
    department.department_code::text as department_code,
    department.display_name,
    department.sort_order,
    office.office_code,
    holder.user_id,
    holder.member_display_name,
    holder.church_title_code,
    holder.membership_role
  from public.church_departments as department
  join public.governance_scopes as scope
    on scope.id = department.church_scope_id
  cross join (
    values
      ('president'::text, 10::smallint),
      ('vice_president'::text, 20::smallint),
      ('general_secretary'::text, 30::smallint),
      ('secretary'::text, 40::smallint),
      ('treasurer'::text, 50::smallint)
  ) as office(office_code, office_sort_order)
  left join lateral (
    select
      assignment.user_id,
      profile.display_name as member_display_name,
      membership.church_title_code,
      membership.role as membership_role
    from public.department_office_assignments as assignment
    join public.organization_memberships as membership
      on membership.user_id = assignment.user_id
     and membership.organization_id = scope.organization_id
     and membership.status = 'active'::public.membership_status
    join public.profiles as profile
      on profile.id = membership.user_id
     and profile.deactivated_at is null
    join public.organizations as organization
      on organization.id = membership.organization_id
     and organization.status = 'active'::public.organization_status
    where assignment.department_id = department.id
      and assignment.service_year = v_service_year
      and assignment.office_code = office.office_code
      and assignment.ended_at is null
    limit 1
  ) as holder on true
  where scope.scope_type = 'church'::public.governance_scope_type
    and scope.organization_id = p_organization_id
    and scope.is_active
    and department.is_active
  order by department.sort_order, office.office_sort_order;
end;
$$;

create or replace function public.list_department_office_candidates(
  p_department_id uuid,
  p_service_year integer,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  membership_id uuid,
  display_name text,
  church_title_code text,
  membership_role public.app_role,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_organization_id uuid;
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_department_id is null then
    raise exception 'department_required' using errcode = '22023';
  end if;
  if p_service_year is null or p_service_year not between
    private.current_service_year()
    and private.current_service_year() + 1 then
    raise exception 'invalid_department_service_year' using errcode = '23514';
  end if;
  if v_search is not null and char_length(v_search) > 80 then
    raise exception 'department_candidate_search_too_long' using errcode = '22001';
  end if;
  if p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_department_candidate_page' using errcode = '22023';
  end if;

  select scope.organization_id into v_organization_id
  from public.church_departments as department
  join public.governance_scopes as scope
    on scope.id = department.church_scope_id
  join public.organizations as organization
    on organization.id = scope.organization_id
  where department.id = p_department_id
    and department.is_active
    and scope.scope_type = 'church'::public.governance_scope_type
    and scope.is_active
    and organization.status = 'active'::public.organization_status;

  if not found then
    raise exception 'active_department_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_department_offices(
    p_department_id,
    v_actor_id
  ) then
    raise exception 'department_office_management_forbidden' using errcode = '42501';
  end if;

  return query
  with candidates as (
    select
      profile.id as user_id,
      membership.id as membership_id,
      profile.display_name,
      membership.church_title_code,
      membership.role as membership_role
    from public.organization_memberships as membership
    join public.profiles as profile
      on profile.id = membership.user_id
    join public.organizations as organization
      on organization.id = membership.organization_id
    left join public.church_title_catalog as title
      on title.code = membership.church_title_code
    where membership.organization_id = v_organization_id
      and membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
      and profile.deactivated_at is null
      and (
        v_search is null
        or profile.display_name ilike '%' || v_search || '%'
        or coalesce(title.display_name, '') ilike '%' || v_search || '%'
      )
  )
  select
    candidates.user_id,
    candidates.membership_id,
    candidates.display_name,
    candidates.church_title_code,
    candidates.membership_role,
    pg_catalog.count(*) over () as total_count
  from candidates
  order by candidates.display_name, candidates.user_id
  limit p_limit
  offset p_offset;
end;
$$;

create or replace function public.assign_department_office(
  p_department_id uuid,
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
  v_actor_id uuid := auth.uid();
  v_office_code text := nullif(pg_catalog.btrim(p_office_code), '');
  v_department_code public.church_department_code;
  v_organization_id uuid;
  v_target_membership_id uuid;
  v_existing public.department_office_assignments%rowtype;
  v_assignment_id uuid;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_department_id is null or p_user_id is null then
    raise exception 'department_and_target_required' using errcode = '22023';
  end if;
  if p_service_year is null or p_service_year not between
    private.current_service_year()
    and private.current_service_year() + 1 then
    raise exception 'invalid_department_service_year' using errcode = '23514';
  end if;
  if v_office_code is null or v_office_code not in (
    'president',
    'vice_president',
    'general_secretary',
    'secretary',
    'treasurer'
  ) then
    raise exception 'invalid_department_office_code' using errcode = '23514';
  end if;

  select
    department.department_code,
    scope.organization_id
  into v_department_code, v_organization_id
  from public.church_departments as department
  join public.governance_scopes as scope
    on scope.id = department.church_scope_id
  join public.organizations as organization
    on organization.id = scope.organization_id
  where department.id = p_department_id
    and department.is_active
    and scope.scope_type = 'church'::public.governance_scope_type
    and scope.is_active
    and organization.status = 'active'::public.organization_status
  for update of department;

  if not found then
    raise exception 'active_department_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_department_offices(
    p_department_id,
    v_actor_id
  ) then
    raise exception 'department_office_management_forbidden' using errcode = '42501';
  end if;

  perform private.require_aal2('department_office_assignment');

  select membership.id into v_target_membership_id
    from public.organization_memberships as membership
    join public.organizations as organization
      on organization.id = membership.organization_id
    join public.profiles as profile
      on profile.id = membership.user_id
    where membership.user_id = p_user_id
      and membership.organization_id = v_organization_id
      and membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
      and profile.deactivated_at is null
  for update of membership;

  if not found then
    raise exception 'department_office_target_must_be_active_church_member'
      using errcode = 'P0002';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'department-office:' || p_department_id::text || ':'
        || p_service_year::text || ':' || v_office_code,
      0
    )
  );

  select assignment.* into v_existing
  from public.department_office_assignments as assignment
  where assignment.department_id = p_department_id
    and assignment.service_year = p_service_year
    and assignment.office_code = v_office_code
    and assignment.ended_at is null
  for update;

  if found and v_existing.user_id = p_user_id then
    return pg_catalog.jsonb_build_object(
      'assignment_id', v_existing.id,
      'department_id', p_department_id,
      'service_year', p_service_year,
      'office_code', v_office_code,
      'user_id', p_user_id,
      'membership_id', v_target_membership_id,
      'changed', false
    );
  end if;

  if found then
    update public.department_office_assignments as assignment
    set ended_at = greatest(assignment.created_at, v_now)
    where assignment.id = v_existing.id;
  end if;

  insert into public.department_office_assignments (
    department_id,
    user_id,
    service_year,
    office_code,
    assigned_by
  )
  values (
    p_department_id,
    p_user_id,
    p_service_year,
    v_office_code,
    v_actor_id
  )
  returning id into v_assignment_id;

  perform private.write_audit(
    v_actor_id,
    'department_office.assigned',
    'department_office_assignment',
    v_assignment_id,
    v_organization_id,
    p_user_id,
    pg_catalog.jsonb_build_object(
      'department_id', p_department_id,
      'department_code', v_department_code,
      'service_year', p_service_year,
      'office_code', v_office_code,
      'target_membership_id', v_target_membership_id,
      'previous_user_id', v_existing.user_id
    )
  );

  return pg_catalog.jsonb_build_object(
    'assignment_id', v_assignment_id,
    'department_id', p_department_id,
    'service_year', p_service_year,
    'office_code', v_office_code,
    'user_id', p_user_id,
    'membership_id', v_target_membership_id,
    'changed', true
  );
end;
$$;

create or replace function public.clear_department_office(
  p_department_id uuid,
  p_service_year integer,
  p_office_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_office_code text := nullif(pg_catalog.btrim(p_office_code), '');
  v_department_code public.church_department_code;
  v_organization_id uuid;
  v_existing public.department_office_assignments%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_department_id is null then
    raise exception 'department_required' using errcode = '22023';
  end if;
  if p_service_year is null or p_service_year not between
    private.current_service_year()
    and private.current_service_year() + 1 then
    raise exception 'invalid_department_service_year' using errcode = '23514';
  end if;
  if v_office_code is null or v_office_code not in (
    'president',
    'vice_president',
    'general_secretary',
    'secretary',
    'treasurer'
  ) then
    raise exception 'invalid_department_office_code' using errcode = '23514';
  end if;

  select
    department.department_code,
    scope.organization_id
  into v_department_code, v_organization_id
  from public.church_departments as department
  join public.governance_scopes as scope
    on scope.id = department.church_scope_id
  join public.organizations as organization
    on organization.id = scope.organization_id
  where department.id = p_department_id
    and department.is_active
    and scope.scope_type = 'church'::public.governance_scope_type
    and scope.is_active
    and organization.status = 'active'::public.organization_status
  for update of department;

  if not found then
    raise exception 'active_department_not_found' using errcode = 'P0002';
  end if;
  if not private.can_manage_department_offices(
    p_department_id,
    v_actor_id
  ) then
    raise exception 'department_office_management_forbidden' using errcode = '42501';
  end if;

  perform private.require_aal2('department_office_clear');
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'department-office:' || p_department_id::text || ':'
        || p_service_year::text || ':' || v_office_code,
      0
    )
  );

  select assignment.* into v_existing
  from public.department_office_assignments as assignment
  where assignment.department_id = p_department_id
    and assignment.service_year = p_service_year
    and assignment.office_code = v_office_code
    and assignment.ended_at is null
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'department_id', p_department_id,
      'service_year', p_service_year,
      'office_code', v_office_code,
      'cleared', false
    );
  end if;

  update public.department_office_assignments as assignment
  set ended_at = greatest(assignment.created_at, v_now)
  where assignment.id = v_existing.id;

  perform private.write_audit(
    v_actor_id,
    'department_office.cleared',
    'department_office_assignment',
    v_existing.id,
    v_organization_id,
    v_existing.user_id,
    pg_catalog.jsonb_build_object(
      'department_id', p_department_id,
      'department_code', v_department_code,
      'service_year', p_service_year,
      'office_code', v_office_code
    )
  );

  return pg_catalog.jsonb_build_object(
    'assignment_id', v_existing.id,
    'department_id', p_department_id,
    'service_year', p_service_year,
    'office_code', v_office_code,
    'user_id', v_existing.user_id,
    'cleared', true
  );
end;
$$;

revoke all on function private.validate_church_department()
  from public, anon, authenticated;
revoke all on function private.sync_church_departments_for_scope()
  from public, anon, authenticated;
revoke all on function private.can_manage_department_offices(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_view_church_departments(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.end_ineligible_department_offices()
  from public, anon, authenticated;
revoke all on function private.freeze_deactivated_department_offices()
  from public, anon, authenticated;

revoke all on function public.list_church_departments(uuid, integer)
  from public, anon, authenticated;
revoke all on function public.list_department_office_candidates(uuid, integer, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.assign_department_office(uuid, integer, text, uuid)
  from public, anon, authenticated;
revoke all on function public.clear_department_office(uuid, integer, text)
  from public, anon, authenticated;

grant execute on function public.list_church_departments(uuid, integer)
  to authenticated;
grant execute on function public.list_department_office_candidates(uuid, integer, text, integer, integer)
  to authenticated;
grant execute on function public.assign_department_office(uuid, integer, text, uuid)
  to authenticated;
grant execute on function public.clear_department_office(uuid, integer, text)
  to authenticated;

comment on function public.list_church_departments(uuid, integer) is
  'Returns four fixed church departments flattened into five annual office slots each for the exact current pastor or platform administrator.';
comment on function public.list_department_office_candidates(uuid, integer, text, integer, integer) is
  'Lists only active members of the department exact church for an authorized current pastor or platform administrator.';
comment on function public.assign_department_office(uuid, integer, text, uuid) is
  'Concurrency-safe assignment of one department/year/office slot; does not grant an app role.';
comment on function public.clear_department_office(uuid, integer, text) is
  'Concurrency-safe clearing of one department/year/office slot.';
