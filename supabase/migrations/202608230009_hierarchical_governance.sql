-- Hierarchical governance for the general assembly, presbyteries, and churches.
--
-- Existing organization_memberships, executive_office_assignments, and church
-- operations remain intact. This migration adds an exact-scope governance layer,
-- keeps legacy church offices synchronized, and exposes personal data only from
-- explicitly authorized SECURITY DEFINER roster RPCs.

create type public.governance_scope_type as enum (
  'general_assembly',
  'presbytery',
  'church'
);

create or replace function private.governance_office_codes_are_valid(p_codes text[])
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select p_codes is not null
    and pg_catalog.cardinality(p_codes) <= 6
    and pg_catalog.array_position(p_codes, null) is null
    and not exists (
      select 1
      from pg_catalog.unnest(p_codes) as office(code)
      where office.code not in (
        'president',
        'vice_president',
        'general_secretary',
        'secretary',
        'treasurer',
        'pastor'
      )
    )
    and pg_catalog.cardinality(p_codes) = (
      select pg_catalog.count(distinct office.code)
      from pg_catalog.unnest(p_codes) as office(code)
    );
$$;

create or replace function private.governance_capabilities_are_valid(p_capabilities text[])
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select p_capabilities is not null
    and pg_catalog.cardinality(p_capabilities) between 1 and 2
    and pg_catalog.array_position(p_capabilities, null) is null
    and not exists (
      select 1
      from pg_catalog.unnest(p_capabilities) as capability(code)
      where capability.code not in ('manage_officers', 'view_roster')
    )
    and pg_catalog.cardinality(p_capabilities) = (
      select pg_catalog.count(distinct capability.code)
      from pg_catalog.unnest(p_capabilities) as capability(code)
    );
$$;

revoke all on function private.governance_office_codes_are_valid(text[])
  from public, anon, authenticated;
revoke all on function private.governance_capabilities_are_valid(text[])
  from public, anon, authenticated;
grant execute on function private.governance_capabilities_are_valid(text[])
  to service_role;

create table public.governance_scopes (
  id uuid primary key default gen_random_uuid(),
  scope_type public.governance_scope_type not null,
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  display_name text not null check (nullif(btrim(display_name), '') is not null),
  parent_scope_id uuid references public.governance_scopes(id) on delete restrict,
  organization_id uuid references public.organizations(id) on delete cascade,
  legacy_presbytery_name text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint governance_scopes_shape_check check (
    (
      scope_type = 'general_assembly'::public.governance_scope_type
      and parent_scope_id is null
      and organization_id is null
      and legacy_presbytery_name is null
    )
    or (
      scope_type = 'presbytery'::public.governance_scope_type
      and parent_scope_id is not null
      and organization_id is null
      and nullif(btrim(legacy_presbytery_name), '') is not null
    )
    or (
      scope_type = 'church'::public.governance_scope_type
      and parent_scope_id is not null
      and organization_id is not null
      and legacy_presbytery_name is null
    )
  )
);

comment on table public.governance_scopes is
  'Exact, non-inheriting governance scopes: one general assembly, its presbyteries, and mapped church organizations.';

create unique index governance_scopes_one_general_assembly_idx
  on public.governance_scopes (scope_type)
  where scope_type = 'general_assembly'::public.governance_scope_type;
create unique index governance_scopes_presbytery_source_unique_idx
  on public.governance_scopes (legacy_presbytery_name)
  where scope_type = 'presbytery'::public.governance_scope_type;
create unique index governance_scopes_organization_unique_idx
  on public.governance_scopes (organization_id)
  where organization_id is not null;
create index governance_scopes_parent_name_idx
  on public.governance_scopes (parent_scope_id, display_name);

create or replace function private.validate_governance_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_parent public.governance_scopes%rowtype;
  v_organization_presbytery text;
begin
  if new.scope_type = 'general_assembly'::public.governance_scope_type then
    return new;
  end if;

  select * into v_parent
  from public.governance_scopes
  where id = new.parent_scope_id;

  if not found then
    raise exception 'governance_parent_scope_not_found' using errcode = '23503';
  end if;

  if new.scope_type = 'presbytery'::public.governance_scope_type
    and v_parent.scope_type <> 'general_assembly'::public.governance_scope_type then
    raise exception 'presbytery_parent_must_be_general_assembly' using errcode = '23514';
  end if;

  if new.scope_type = 'church'::public.governance_scope_type then
    if v_parent.scope_type <> 'presbytery'::public.governance_scope_type then
      raise exception 'church_parent_must_be_presbytery' using errcode = '23514';
    end if;

    select organization.presbytery into v_organization_presbytery
    from public.organizations as organization
    where organization.id = new.organization_id;

    if not found or v_organization_presbytery is distinct from v_parent.legacy_presbytery_name then
      raise exception 'church_presbytery_scope_mismatch' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.validate_governance_scope()
  from public, anon, authenticated;

create trigger governance_scopes_validate
before insert or update on public.governance_scopes
for each row execute function private.validate_governance_scope();

create trigger governance_scopes_set_updated_at
before update on public.governance_scopes
for each row execute function private.set_updated_at();

insert into public.governance_scopes (
  id,
  scope_type,
  slug,
  display_name
)
values (
  '20000000-0000-4000-8000-000000000001'::uuid,
  'general_assembly'::public.governance_scope_type,
  'jaegun-general-assembly',
  '재건교회 총회'
)
on conflict (slug) do update
set
  display_name = excluded.display_name,
  is_active = true;

insert into public.governance_scopes (
  scope_type,
  slug,
  display_name,
  parent_scope_id,
  legacy_presbytery_name
)
select
  'presbytery'::public.governance_scope_type,
  'presbytery-' || substr(pg_catalog.md5(source.presbytery), 1, 16),
  source.presbytery,
  assembly.id,
  source.presbytery
from (
  select distinct organization.presbytery
  from public.organizations as organization
) as source
cross join public.governance_scopes as assembly
where assembly.scope_type = 'general_assembly'::public.governance_scope_type
on conflict (legacy_presbytery_name)
  where scope_type = 'presbytery'::public.governance_scope_type
do update set
  display_name = excluded.display_name,
  parent_scope_id = excluded.parent_scope_id,
  is_active = true;

-- Supabase applies seed.sql after all migrations on a fresh reset. Keep later
-- seed/import/admin-created churches in the same hierarchy automatically without
-- importing any person data.
create or replace function private.sync_organization_governance_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_assembly_id uuid;
  v_presbytery_id uuid;
begin
  select scope.id into v_assembly_id
  from public.governance_scopes as scope
  where scope.scope_type = 'general_assembly'::public.governance_scope_type
  limit 1;

  if v_assembly_id is null then
    raise exception 'general_assembly_scope_not_found' using errcode = 'P0002';
  end if;

  insert into public.governance_scopes (
    scope_type,
    slug,
    display_name,
    parent_scope_id,
    legacy_presbytery_name
  )
  values (
    'presbytery'::public.governance_scope_type,
    'presbytery-' || substr(pg_catalog.md5(new.presbytery), 1, 16),
    new.presbytery,
    v_assembly_id,
    new.presbytery
  )
  on conflict (legacy_presbytery_name)
    where scope_type = 'presbytery'::public.governance_scope_type
  do update set
    display_name = excluded.display_name,
    parent_scope_id = excluded.parent_scope_id,
    is_active = true
  returning id into v_presbytery_id;

  insert into public.governance_scopes (
    scope_type,
    slug,
    display_name,
    parent_scope_id,
    organization_id,
    is_active
  )
  values (
    'church'::public.governance_scope_type,
    'church-' || new.slug,
    new.display_name,
    v_presbytery_id,
    new.id,
    new.status in (
      'seeded_unclaimed'::public.organization_status,
      'active'::public.organization_status
    )
  )
  on conflict (organization_id) where organization_id is not null
  do update set
    slug = excluded.slug,
    display_name = excluded.display_name,
    parent_scope_id = excluded.parent_scope_id,
    is_active = excluded.is_active;

  return new;
end;
$$;

revoke all on function private.sync_organization_governance_scope()
  from public, anon, authenticated;

create trigger organizations_sync_governance_scope
after insert or update of slug, display_name, presbytery, status
on public.organizations
for each row execute function private.sync_organization_governance_scope();

insert into public.governance_scopes (
  scope_type,
  slug,
  display_name,
  parent_scope_id,
  organization_id,
  is_active
)
select
  'church'::public.governance_scope_type,
  'church-' || organization.slug,
  organization.display_name,
  presbytery.id,
  organization.id,
  organization.status in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  )
from public.organizations as organization
join public.governance_scopes as presbytery
  on presbytery.scope_type = 'presbytery'::public.governance_scope_type
 and presbytery.legacy_presbytery_name = organization.presbytery
on conflict (organization_id) where organization_id is not null
do update set
  display_name = excluded.display_name,
  parent_scope_id = excluded.parent_scope_id,
  is_active = excluded.is_active;

create table public.governance_office_assignments (
  id uuid primary key default gen_random_uuid(),
  scope_id uuid not null references public.governance_scopes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  service_year smallint not null check (service_year between 2000 and 2100),
  office_code text not null check (
    office_code in (
      'president',
      'vice_president',
      'general_secretary',
      'secretary',
      'treasurer',
      'pastor'
    )
  ),
  assigned_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint governance_office_assignments_end_check check (
    ended_at is null or ended_at >= created_at
  )
);

comment on table public.governance_office_assignments is
  'Year-scoped offices at one exact governance scope. Parent and child authority never inherit implicitly.';

create unique index governance_office_assignments_one_holder_idx
  on public.governance_office_assignments (scope_id, service_year, office_code)
  where ended_at is null;
create index governance_office_assignments_user_year_idx
  on public.governance_office_assignments (user_id, service_year, ended_at);
create index governance_office_assignments_scope_user_idx
  on public.governance_office_assignments (scope_id, user_id, service_year, ended_at);

create table public.governance_authority_delegations (
  id uuid primary key default gen_random_uuid(),
  scope_id uuid not null references public.governance_scopes(id) on delete cascade,
  grantor_user_id uuid not null references public.profiles(id) on delete cascade,
  delegate_user_id uuid not null references public.profiles(id) on delete cascade,
  capabilities text[] not null,
  starts_at timestamptz not null default pg_catalog.clock_timestamp(),
  expires_at timestamptz not null,
  reason text check (reason is null or char_length(reason) <= 500),
  revoked_at timestamptz,
  revoked_by uuid references public.profiles(id) on delete set null,
  revocation_reason text check (
    revocation_reason is null or char_length(revocation_reason) <= 500
  ),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint governance_delegations_distinct_users_check check (
    grantor_user_id <> delegate_user_id
  ),
  constraint governance_delegations_capabilities_check check (
    private.governance_capabilities_are_valid(capabilities)
  ),
  constraint governance_delegations_expiry_check check (
    expires_at > starts_at
    and expires_at <= starts_at + interval '90 days'
  ),
  constraint governance_delegations_revocation_check check (
    (revoked_at is null and revoked_by is null and revocation_reason is null)
    or (
      revoked_at is not null
      and revoked_at >= starts_at
      and nullif(btrim(revocation_reason), '') is not null
    )
  )
);

comment on table public.governance_authority_delegations is
  'Non-chainable, exact-scope, capability-limited authority that expires within 90 days and the current Seoul service year.';

create index governance_delegations_delegate_scope_idx
  on public.governance_authority_delegations (
    delegate_user_id,
    scope_id,
    revoked_at,
    expires_at
  );
create index governance_delegations_scope_history_idx
  on public.governance_authority_delegations (scope_id, created_at desc);

create or replace function private.scope_contains_organization(
  p_scope_id uuid,
  p_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_scope_id is not null
    and p_organization_id is not null
    and exists (
      select 1
      from public.governance_scopes as scope
      where scope.id = p_scope_id
        and scope.is_active
        and (
          (
            scope.scope_type = 'church'::public.governance_scope_type
            and scope.organization_id = p_organization_id
          )
          or (
            scope.scope_type = 'presbytery'::public.governance_scope_type
            and exists (
              select 1
              from public.governance_scopes as church
              where church.parent_scope_id = scope.id
                and church.scope_type = 'church'::public.governance_scope_type
                and church.organization_id = p_organization_id
                and church.is_active
            )
          )
          or (
            scope.scope_type = 'general_assembly'::public.governance_scope_type
            and exists (
              select 1
              from public.governance_scopes as presbytery
              join public.governance_scopes as church
                on church.parent_scope_id = presbytery.id
               and church.scope_type = 'church'::public.governance_scope_type
               and church.is_active
              where presbytery.parent_scope_id = scope.id
                and presbytery.scope_type = 'presbytery'::public.governance_scope_type
                and presbytery.is_active
                and church.organization_id = p_organization_id
            )
          )
        )
    );
$$;

create or replace function private.is_user_enrolled_in_governance_scope(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_user_id is not null
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.profiles as profile on profile.id = membership.user_id
      where membership.user_id = p_user_id
        and membership.status = 'active'::public.membership_status
        and profile.deactivated_at is null
        and private.scope_contains_organization(
          p_scope_id,
          membership.organization_id
        )
    );
$$;

create or replace function private.is_user_active_in_governance_scope(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_user_id is not null
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      where membership.user_id = p_user_id
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and profile.deactivated_at is null
        and private.scope_contains_organization(
          p_scope_id,
          membership.organization_id
        )
    );
$$;

create or replace function private.governance_membership_role(
  p_scope_id uuid,
  p_user_id uuid
)
returns public.app_role
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select membership.role
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
  join public.profiles as profile on profile.id = membership.user_id
  where membership.user_id = p_user_id
    and membership.status = 'active'::public.membership_status
    and organization.status = 'active'::public.organization_status
    and profile.deactivated_at is null
    and private.scope_contains_organization(p_scope_id, membership.organization_id)
  limit 1;
$$;

create or replace function private.has_current_governance_office(
  p_scope_id uuid,
  p_user_id uuid,
  p_office_codes text[]
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_user_id is not null
    and private.is_user_active_in_governance_scope(p_scope_id, p_user_id)
    and exists (
      select 1
      from public.governance_office_assignments as assignment
      where assignment.scope_id = p_scope_id
        and assignment.user_id = p_user_id
        and assignment.service_year = private.current_service_year()
        and assignment.ended_at is null
        and assignment.office_code = any(coalesce(p_office_codes, '{}'::text[]))
    );
$$;

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
    join public.organization_memberships as membership
      on membership.organization_id = scope.organization_id
    join public.organizations as organization
      on organization.id = membership.organization_id
    join public.profiles as profile on profile.id = membership.user_id
    where scope.id = p_scope_id
      and scope.scope_type = 'church'::public.governance_scope_type
      and scope.is_active
      and membership.user_id = p_user_id
      and membership.role = 'minister'::public.app_role
      and membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
      and profile.deactivated_at is null
  );
$$;

create or replace function private.has_native_governance_authority(
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
      and scope.is_active
      and (
        private.is_platform_admin(p_user_id)
        or private.has_current_governance_office(
          p_scope_id,
          p_user_id,
          array['president', 'pastor']::text[]
        )
        or private.is_current_church_pastor(p_scope_id, p_user_id)
      )
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
  select p_capability in ('manage_officers', 'view_roster')
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

create or replace function private.can_manage_governance_offices(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_native_governance_authority(p_scope_id, p_user_id)
    or private.has_active_governance_delegation(
      p_scope_id,
      p_user_id,
      'manage_officers'
    );
$$;

create or replace function private.can_view_governance_roster(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_native_governance_authority(p_scope_id, p_user_id)
    or private.has_active_governance_delegation(
      p_scope_id,
      p_user_id,
      'view_roster'
    )
    or private.has_active_governance_delegation(
      p_scope_id,
      p_user_id,
      'manage_officers'
    );
$$;

revoke all on function private.scope_contains_organization(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.is_user_enrolled_in_governance_scope(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.is_user_active_in_governance_scope(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.governance_membership_role(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.has_current_governance_office(uuid, uuid, text[])
  from public, anon, authenticated;
revoke all on function private.is_current_church_pastor(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.has_native_governance_authority(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.has_active_governance_delegation(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function private.can_manage_governance_offices(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_view_governance_roster(uuid, uuid)
  from public, anon, authenticated;

-- An active assignment must always point to an eligible real member. Church
-- validation deliberately accepts a seeded-unclaimed church during the existing
-- executive approval transaction; operational authority still requires an active
-- organization through is_user_active_in_governance_scope().
create or replace function private.validate_governance_office_assignment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_scope_type public.governance_scope_type;
  v_role public.app_role;
begin
  if new.ended_at is not null then
    return new;
  end if;

  select scope.scope_type into v_scope_type
  from public.governance_scopes as scope
  where scope.id = new.scope_id
    and scope.is_active;

  if not found then
    raise exception 'active_governance_scope_required' using errcode = '23514';
  end if;

  select membership.role into v_role
  from public.organization_memberships as membership
  join public.profiles as profile on profile.id = membership.user_id
  where membership.user_id = new.user_id
    and membership.status = 'active'::public.membership_status
    and profile.deactivated_at is null
    and private.scope_contains_organization(
      new.scope_id,
      membership.organization_id
    )
  limit 1;

  if not found then
    raise exception 'governance_office_target_must_be_active_member' using errcode = '23514';
  end if;

  if v_scope_type <> 'church'::public.governance_scope_type
    and not private.is_user_active_in_governance_scope(new.scope_id, new.user_id) then
    raise exception 'governance_office_target_scope_not_active' using errcode = '23514';
  end if;

  if new.office_code = 'pastor' and v_role <> 'minister'::public.app_role then
    raise exception 'pastor_office_requires_minister_role' using errcode = '23514';
  end if;

  if new.office_code <> 'pastor'
    and v_scope_type = 'church'::public.governance_scope_type
    and v_role <> 'executive'::public.app_role then
    raise exception 'church_office_requires_executive_role' using errcode = '23514';
  end if;

  if new.office_code <> 'pastor'
    and v_scope_type <> 'church'::public.governance_scope_type
    and v_role not in ('minister'::public.app_role, 'executive'::public.app_role) then
    raise exception 'governance_office_requires_leadership_role' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.validate_governance_office_assignment()
  from public, anon, authenticated;

create trigger governance_office_assignments_validate
before insert or update on public.governance_office_assignments
for each row execute function private.validate_governance_office_assignment();

create or replace function private.validate_governance_delegation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_service_year smallint := private.current_service_year();
  v_rollover timestamptz;
begin
  if tg_op = 'UPDATE' and row(
    old.scope_id,
    old.grantor_user_id,
    old.delegate_user_id,
    old.capabilities,
    old.starts_at,
    old.expires_at,
    old.reason
  ) is distinct from row(
    new.scope_id,
    new.grantor_user_id,
    new.delegate_user_id,
    new.capabilities,
    new.starts_at,
    new.expires_at,
    new.reason
  ) then
    raise exception 'governance_delegation_grant_is_immutable' using errcode = '42501';
  end if;

  if new.revoked_at is not null then
    return new;
  end if;

  if not private.has_native_governance_authority(
    new.scope_id,
    new.grantor_user_id
  ) then
    raise exception 'native_scope_authority_required_for_delegation' using errcode = '42501';
  end if;

  if not private.is_user_active_in_governance_scope(
    new.scope_id,
    new.delegate_user_id
  ) then
    raise exception 'delegation_target_must_be_active_in_scope' using errcode = '23514';
  end if;

  v_rollover := pg_catalog.make_timestamptz(
    v_service_year + 1,
    1,
    1,
    0,
    0,
    0,
    'Asia/Seoul'
  );

  if new.starts_at > pg_catalog.clock_timestamp() + interval '1 minute'
    or new.expires_at > v_rollover then
    raise exception 'delegation_must_end_in_current_service_year' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.validate_governance_delegation()
  from public, anon, authenticated;

create trigger governance_authority_delegations_validate
before insert or update on public.governance_authority_delegations
for each row execute function private.validate_governance_delegation();

-- Existing active current/next-year church offices are imported. The legacy
-- schema permitted co-holders; the newest active assignment deterministically
-- wins because the hierarchy model has exactly one holder per office.
update public.executive_office_assignments as assignment
set ended_at = greatest(assignment.created_at, pg_catalog.clock_timestamp())
where assignment.ended_at is null
  and assignment.service_year between
    private.current_service_year()
    and private.current_service_year() + 1
  and not exists (
    select 1
    from public.organization_memberships as membership
    join public.organizations as organization
      on organization.id = membership.organization_id
    join public.profiles as profile on profile.id = membership.user_id
    join public.governance_scopes as church_scope
      on church_scope.scope_type = 'church'::public.governance_scope_type
     and church_scope.organization_id = membership.organization_id
     and church_scope.is_active
    where membership.id = assignment.membership_id
      and membership.role = 'executive'::public.app_role
      and membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
      and profile.deactivated_at is null
  );

with ranked_coholders as (
  select
    assignment.id,
    pg_catalog.row_number() over (
      partition by
        membership.organization_id,
        assignment.service_year,
        assignment.office_code
      order by assignment.created_at desc, assignment.id desc
    ) as holder_rank
  from public.executive_office_assignments as assignment
  join public.organization_memberships as membership
    on membership.id = assignment.membership_id
  where assignment.ended_at is null
    and assignment.service_year between
      private.current_service_year()
      and private.current_service_year() + 1
)
update public.executive_office_assignments as assignment
set ended_at = greatest(assignment.created_at, pg_catalog.clock_timestamp())
from ranked_coholders as ranked
where ranked.id = assignment.id
  and ranked.holder_rank > 1;

with ranked_legacy_assignments as (
  select
    church_scope.id as scope_id,
    membership.user_id,
    assignment.service_year,
    assignment.office_code,
    assignment.assigned_by,
    assignment.created_at,
    pg_catalog.row_number() over (
      partition by
        church_scope.id,
        assignment.service_year,
        assignment.office_code
      order by assignment.created_at desc, assignment.id desc
    ) as holder_rank
  from public.executive_office_assignments as assignment
  join public.organization_memberships as membership
    on membership.id = assignment.membership_id
  join public.organizations as organization
    on organization.id = membership.organization_id
   and organization.status = 'active'::public.organization_status
  join public.profiles as profile
    on profile.id = membership.user_id
   and profile.deactivated_at is null
  join public.governance_scopes as church_scope
    on church_scope.scope_type = 'church'::public.governance_scope_type
   and church_scope.organization_id = membership.organization_id
   and church_scope.is_active
  where assignment.ended_at is null
    and membership.role = 'executive'::public.app_role
    and membership.status = 'active'::public.membership_status
    and assignment.service_year between
      private.current_service_year()
      and private.current_service_year() + 1
)
insert into public.governance_office_assignments (
  scope_id,
  user_id,
  service_year,
  office_code,
  assigned_by,
  created_at
)
select
  legacy.scope_id,
  legacy.user_id,
  legacy.service_year,
  legacy.office_code,
  legacy.assigned_by,
  legacy.created_at
from ranked_legacy_assignments as legacy
where legacy.holder_rank = 1
on conflict (scope_id, service_year, office_code)
  where ended_at is null
do nothing;

-- Legacy church writes continue to update the hierarchy source of truth. A
-- later legacy co-holder replaces the previous hierarchy holder but does not
-- destructively rewrite historical legacy rows.
create or replace function private.sync_governance_office_from_legacy()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_old_scope_id uuid;
  v_old_user_id uuid;
  v_old_organization_id uuid;
  v_new_scope_id uuid;
  v_new_user_id uuid;
  v_new_organization_id uuid;
  v_fallback_user_id uuid;
  v_fallback_assigned_by uuid;
  v_fallback_created_at timestamptz;
  v_old_lock_key bigint;
  v_new_lock_key bigint;
  v_end_time timestamptz := pg_catalog.clock_timestamp();
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select church_scope.id, membership.user_id, membership.organization_id
    into v_old_scope_id, v_old_user_id, v_old_organization_id
    from public.organization_memberships as membership
    join public.governance_scopes as church_scope
      on church_scope.scope_type = 'church'::public.governance_scope_type
     and church_scope.organization_id = membership.organization_id
    where membership.id = old.membership_id;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select church_scope.id, membership.user_id, membership.organization_id
    into v_new_scope_id, v_new_user_id, v_new_organization_id
    from public.organization_memberships as membership
    join public.governance_scopes as church_scope
      on church_scope.scope_type = 'church'::public.governance_scope_type
     and church_scope.organization_id = membership.organization_id
    where membership.id = new.membership_id;
  end if;

  -- Use the same exact scope/year lock as set_governance_offices(). Legacy
  -- approvals can insert distinct membership rows concurrently, so a per-row
  -- uniqueness constraint cannot enforce one church holder by itself. Acquire
  -- both keys in numeric order for the rare direct update that moves a row.
  if v_old_scope_id is not null then
    v_old_lock_key := pg_catalog.hashtextextended(
      'governance-office:' || v_old_scope_id::text || ':' || old.service_year::text,
      0
    );
  end if;
  if v_new_scope_id is not null then
    v_new_lock_key := pg_catalog.hashtextextended(
      'governance-office:' || v_new_scope_id::text || ':' || new.service_year::text,
      0
    );
  end if;

  if v_old_lock_key is not null and v_new_lock_key is not null then
    if v_old_lock_key <= v_new_lock_key then
      perform pg_catalog.pg_advisory_xact_lock(v_old_lock_key);
      if v_new_lock_key <> v_old_lock_key then
        perform pg_catalog.pg_advisory_xact_lock(v_new_lock_key);
      end if;
    else
      perform pg_catalog.pg_advisory_xact_lock(v_new_lock_key);
      perform pg_catalog.pg_advisory_xact_lock(v_old_lock_key);
    end if;
  elsif v_old_lock_key is not null then
    perform pg_catalog.pg_advisory_xact_lock(v_old_lock_key);
  elsif v_new_lock_key is not null then
    perform pg_catalog.pg_advisory_xact_lock(v_new_lock_key);
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    if v_old_scope_id is not null and (
      tg_op = 'DELETE'
      or old.ended_at is distinct from new.ended_at
      or old.membership_id is distinct from new.membership_id
      or old.service_year is distinct from new.service_year
      or old.office_code is distinct from new.office_code
    ) then
      update public.governance_office_assignments as hierarchy_assignment
      set ended_at = greatest(
        hierarchy_assignment.created_at,
        coalesce(case when tg_op = 'DELETE' then null else new.ended_at end, v_end_time)
      )
      where hierarchy_assignment.scope_id = v_old_scope_id
        and hierarchy_assignment.user_id = v_old_user_id
        and hierarchy_assignment.service_year = old.service_year
        and hierarchy_assignment.office_code = old.office_code
        and hierarchy_assignment.ended_at is null;

      select
        fallback_membership.user_id,
        fallback_assignment.assigned_by,
        fallback_assignment.created_at
      into
        v_fallback_user_id,
        v_fallback_assigned_by,
        v_fallback_created_at
      from public.executive_office_assignments as fallback_assignment
      join public.organization_memberships as fallback_membership
        on fallback_membership.id = fallback_assignment.membership_id
      join public.profiles as fallback_profile
        on fallback_profile.id = fallback_membership.user_id
      where fallback_membership.organization_id = v_old_organization_id
        and fallback_membership.role = 'executive'::public.app_role
        and fallback_membership.status = 'active'::public.membership_status
        and fallback_profile.deactivated_at is null
        and fallback_assignment.service_year = old.service_year
        and fallback_assignment.office_code = old.office_code
        and fallback_assignment.ended_at is null
      order by fallback_assignment.created_at desc, fallback_assignment.id desc
      limit 1;

      if v_fallback_user_id is not null then
        update public.governance_office_assignments as previous_holder
        set ended_at = greatest(previous_holder.created_at, v_end_time)
        where previous_holder.scope_id = v_old_scope_id
          and previous_holder.service_year = old.service_year
          and previous_holder.office_code = old.office_code
          and previous_holder.user_id <> v_fallback_user_id
          and previous_holder.ended_at is null;

        insert into public.governance_office_assignments (
          scope_id,
          user_id,
          service_year,
          office_code,
          assigned_by,
          created_at
        )
        values (
          v_old_scope_id,
          v_fallback_user_id,
          old.service_year,
          old.office_code,
          v_fallback_assigned_by,
          v_fallback_created_at
        )
        on conflict (scope_id, service_year, office_code)
          where ended_at is null
        do update set assigned_by = excluded.assigned_by;
      end if;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') and new.ended_at is null then
    if v_new_scope_id is not null then
      update public.executive_office_assignments as legacy_coholder
      set ended_at = greatest(legacy_coholder.created_at, v_end_time)
      from public.organization_memberships as coholder_membership
      where coholder_membership.id = legacy_coholder.membership_id
        and coholder_membership.organization_id = v_new_organization_id
        and legacy_coholder.id <> new.id
        and legacy_coholder.service_year = new.service_year
        and legacy_coholder.office_code = new.office_code
        and legacy_coholder.ended_at is null;

      update public.governance_office_assignments as previous_holder
      set ended_at = greatest(previous_holder.created_at, v_end_time)
      where previous_holder.scope_id = v_new_scope_id
        and previous_holder.service_year = new.service_year
        and previous_holder.office_code = new.office_code
        and previous_holder.user_id <> v_new_user_id
        and previous_holder.ended_at is null;

      insert into public.governance_office_assignments (
        scope_id,
        user_id,
        service_year,
        office_code,
        assigned_by,
        created_at
      )
      values (
        v_new_scope_id,
        v_new_user_id,
        new.service_year,
        new.office_code,
        new.assigned_by,
        new.created_at
      )
      on conflict (scope_id, service_year, office_code)
        where ended_at is null
      do update set
        user_id = excluded.user_id,
        assigned_by = excluded.assigned_by;
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.sync_governance_office_from_legacy()
  from public, anon, authenticated;

create trigger executive_office_assignments_sync_governance
after insert or update or delete on public.executive_office_assignments
for each row execute function private.sync_governance_office_from_legacy();

create or replace function private.end_ineligible_governance_access()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_current_membership public.organization_memberships%rowtype;
begin
  select * into v_current_membership
  from public.organization_memberships as membership
  where membership.user_id = new.user_id
    and membership.status = 'active'::public.membership_status
  limit 1;

  -- A legacy assignment is membership-bound. End it before an organization move
  -- can make existing legacy authorization helpers interpret it in the new church.
  if old.organization_id is distinct from new.organization_id
    or new.role <> 'executive'::public.app_role
    or new.status <> 'active'::public.membership_status then
    update public.executive_office_assignments as legacy_assignment
    set ended_at = greatest(legacy_assignment.created_at, v_now)
    where legacy_assignment.membership_id = new.id
      and legacy_assignment.ended_at is null;
  end if;

  update public.governance_office_assignments as assignment
  set ended_at = greatest(assignment.created_at, v_now)
  from public.governance_scopes as scope
  where assignment.scope_id = scope.id
    and assignment.user_id = new.user_id
    and assignment.ended_at is null
    and (
      v_current_membership.id is null
      or not private.scope_contains_organization(
        scope.id,
        v_current_membership.organization_id
      )
      or (
        assignment.office_code = 'pastor'
        and v_current_membership.role <> 'minister'::public.app_role
      )
      or (
        assignment.office_code <> 'pastor'
        and scope.scope_type = 'church'::public.governance_scope_type
        and v_current_membership.role <> 'executive'::public.app_role
      )
      or (
        assignment.office_code <> 'pastor'
        and scope.scope_type <> 'church'::public.governance_scope_type
        and v_current_membership.role not in (
          'minister'::public.app_role,
          'executive'::public.app_role
        )
      )
    );

  with revoked_delegations as (
    update public.governance_authority_delegations as delegation
    set
      revoked_at = greatest(delegation.starts_at, v_now),
      revoked_by = null,
      revocation_reason = '소속 또는 역할 변경으로 자동 종료'
    where delegation.revoked_at is null
      and (
        (
          delegation.delegate_user_id = new.user_id
          and not private.is_user_active_in_governance_scope(
            delegation.scope_id,
            new.user_id
          )
        )
        or (
          delegation.grantor_user_id = new.user_id
          and not private.has_native_governance_authority(
            delegation.scope_id,
            new.user_id
          )
        )
      )
    returning delegation.id, delegation.scope_id, delegation.delegate_user_id
  )
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
    revoked.delegate_user_id,
    'admin_action'::public.notification_kind,
    '위임 권한이 종료되었습니다',
    coalesce(pg_catalog.left(scope.display_name, 1800), '조직')
      || ' 위임 권한이 소속 또는 역할 변경으로 자동 종료되었습니다.',
    'governance_delegation',
    revoked.id,
    pg_catalog.jsonb_build_object(
      'scope_id', revoked.scope_id,
      'reason', '소속 또는 역할 변경으로 자동 종료'
    )
  from revoked_delegations as revoked
  left join public.governance_scopes as scope on scope.id = revoked.scope_id;

  return new;
end;
$$;

revoke all on function private.end_ineligible_governance_access()
  from public, anon, authenticated;

create trigger organization_memberships_end_ineligible_governance_access
after update of organization_id, role, status on public.organization_memberships
for each row execute function private.end_ineligible_governance_access();

alter table public.governance_scopes enable row level security;
alter table public.governance_office_assignments enable row level security;
alter table public.governance_authority_delegations enable row level security;

create policy governance_scopes_select_directory
on public.governance_scopes for select to authenticated
using (is_active or private.is_platform_admin(auth.uid()));

revoke all on table public.governance_scopes
  from public, anon, authenticated;
revoke all on table public.governance_office_assignments
  from public, anon, authenticated;
revoke all on table public.governance_authority_delegations
  from public, anon, authenticated;

grant select on table public.governance_scopes to authenticated;

create or replace function public.get_governance_tree()
returns table (
  scope_id uuid,
  scope_type public.governance_scope_type,
  slug text,
  display_name text,
  parent_scope_id uuid,
  organization_id uuid,
  is_active boolean,
  church_count bigint,
  active_member_count bigint
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
    scope.slug,
    scope.display_name,
    scope.parent_scope_id,
    scope.organization_id,
    scope.is_active,
    (
      select pg_catalog.count(*)
      from public.governance_scopes as church
      where church.scope_type = 'church'::public.governance_scope_type
        and church.is_active
        and (
          church.id = scope.id
          or church.parent_scope_id = scope.id
          or exists (
            select 1
            from public.governance_scopes as presbytery
            where presbytery.id = church.parent_scope_id
              and presbytery.parent_scope_id = scope.id
              and presbytery.is_active
          )
        )
    ) as church_count,
    (
      select pg_catalog.count(*)
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile on profile.id = membership.user_id
      where membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and profile.deactivated_at is null
        and private.scope_contains_organization(
          scope.id,
          membership.organization_id
        )
    ) as active_member_count
  from public.governance_scopes as scope
  where scope.is_active or private.is_platform_admin(v_actor_id)
  order by
    case scope.scope_type
      when 'general_assembly'::public.governance_scope_type then 1
      when 'presbytery'::public.governance_scope_type then 2
      else 3
    end,
    scope.display_name;
end;
$$;

create or replace function public.list_scope_organizations(p_scope_id uuid)
returns table (
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  active_member_count bigint
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
  if not exists (
    select 1
    from public.governance_scopes as scope
    where scope.id = p_scope_id
      and scope.is_active
  ) then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;
  if not (
    private.is_platform_admin(v_actor_id)
    or private.is_user_active_in_governance_scope(p_scope_id, v_actor_id)
    or private.can_view_governance_roster(p_scope_id, v_actor_id)
  ) then
    raise exception 'governance_scope_directory_forbidden' using errcode = '42501';
  end if;

  return query
  select
    organization.id,
    organization.display_name,
    organization.presbytery,
    (
      select pg_catalog.count(*)
      from public.organization_memberships as membership
      join public.profiles as profile on profile.id = membership.user_id
      where membership.organization_id = organization.id
        and membership.status = 'active'::public.membership_status
        and profile.deactivated_at is null
    ) as active_member_count
  from public.organizations as organization
  where organization.status = 'active'::public.organization_status
    and private.scope_contains_organization(p_scope_id, organization.id)
  order by organization.display_name;
end;
$$;

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
  v_service_year := coalesce(
    p_service_year,
    private.current_service_year()
  )::smallint;
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
            position.office_code
            order by case position.office_code
              when 'president' then 1
              when 'vice_president' then 2
              when 'general_secretary' then 3
              when 'secretary' then 4
              when 'treasurer' then 5
              else 6
            end
          )
          from (
            select assignment.office_code
            from public.governance_office_assignments as assignment
            where assignment.scope_id = p_scope_id
              and assignment.user_id = profile.id
              and assignment.service_year = v_service_year
              and assignment.ended_at is null
            union
            select 'pastor'::text
            where v_service_year = private.current_service_year()
              and membership.role = 'minister'::public.app_role
              and exists (
                select 1
                from public.governance_scopes as selected_scope
                where selected_scope.id = p_scope_id
                  and selected_scope.scope_type = 'church'::public.governance_scope_type
              )
          ) as position
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
      and private.scope_contains_organization(
        p_scope_id,
        membership.organization_id
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

create or replace function public.get_my_governance_access()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_is_platform_admin boolean;
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  v_is_platform_admin := private.is_platform_admin(v_actor_id);

  with live_delegations as (
    select distinct on (delegation.scope_id)
      delegation.scope_id,
      delegation.capabilities,
      delegation.expires_at
    from public.governance_authority_delegations as delegation
    where delegation.delegate_user_id = v_actor_id
      and delegation.revoked_at is null
      and delegation.starts_at <= pg_catalog.statement_timestamp()
      and delegation.expires_at > pg_catalog.statement_timestamp()
      and private.is_user_active_in_governance_scope(
        delegation.scope_id,
        v_actor_id
      )
      and private.has_native_governance_authority(
        delegation.scope_id,
        delegation.grantor_user_id
      )
    order by delegation.scope_id, delegation.expires_at desc, delegation.created_at desc
  ),
  access_rows as (
    select
      scope.id as scope_id,
      scope.scope_type,
      scope.display_name as scope_name,
      coalesce(
        (
          select pg_catalog.array_agg(
            codes.office_code
            order by case codes.office_code
              when 'president' then 1
              when 'vice_president' then 2
              when 'general_secretary' then 3
              when 'secretary' then 4
              when 'treasurer' then 5
              else 6
            end
          )
          from (
            select assignment.office_code
            from public.governance_office_assignments as assignment
            where assignment.scope_id = scope.id
              and assignment.user_id = v_actor_id
              and assignment.service_year = private.current_service_year()
              and assignment.ended_at is null
            union
            select 'pastor'::text
            where private.is_current_church_pastor(scope.id, v_actor_id)
          ) as codes
        ),
        '{}'::text[]
      ) as office_codes,
      private.has_current_governance_office(
        scope.id,
        v_actor_id,
        array['president', 'pastor']::text[]
      ) as has_authority_office,
      private.is_current_church_pastor(scope.id, v_actor_id) as is_church_pastor,
      delegation.capabilities as delegated_capabilities,
      delegation.expires_at as delegation_expires_at
    from public.governance_scopes as scope
    left join live_delegations as delegation on delegation.scope_id = scope.id
    where scope.is_active
      and (
        v_is_platform_admin
        or private.has_current_governance_office(
          scope.id,
          v_actor_id,
          array['president', 'pastor']::text[]
        )
        or private.is_current_church_pastor(scope.id, v_actor_id)
        or delegation.scope_id is not null
      )
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'scope_id', access.scope_id,
        'scope_type', access.scope_type,
        'scope_name', access.scope_name,
        'authority_source', case
          when v_is_platform_admin then 'platform_admin'
          when access.has_authority_office then 'office'
          when access.is_church_pastor then 'church_pastor'
          else 'delegation'
        end,
        'office_codes', pg_catalog.to_jsonb(access.office_codes),
        'capabilities', pg_catalog.to_jsonb(
          case
            when v_is_platform_admin
              or access.has_authority_office
              or access.is_church_pastor
              then array[
                'manage_officers',
                'view_roster',
                'manage_delegations'
              ]::text[]
            else access.delegated_capabilities
          end
        ),
        'can_manage_officers', (
          v_is_platform_admin
          or access.has_authority_office
          or access.is_church_pastor
          or 'manage_officers' = any(
            coalesce(access.delegated_capabilities, '{}'::text[])
          )
        ),
        'can_manage_delegations', (
          v_is_platform_admin
          or access.has_authority_office
          or access.is_church_pastor
        ),
        'can_view_roster', (
          v_is_platform_admin
          or access.has_authority_office
          or access.is_church_pastor
          or 'manage_officers' = any(
            coalesce(access.delegated_capabilities, '{}'::text[])
          )
          or 'view_roster' = any(
            coalesce(access.delegated_capabilities, '{}'::text[])
          )
        ),
        'expires_at', case
          when v_is_platform_admin
            or access.has_authority_office
            or access.is_church_pastor then null
          else pg_catalog.to_jsonb(access.delegation_expires_at)
        end
      )
      order by
        case access.scope_type
          when 'general_assembly'::public.governance_scope_type then 1
          when 'presbytery'::public.governance_scope_type then 2
          else 3
        end,
        access.scope_name
    ),
    '[]'::jsonb
  ) into v_result
  from access_rows as access;

  return v_result;
end;
$$;

create or replace function public.list_governance_delegations(p_scope_id uuid)
returns table (
  delegation_id uuid,
  scope_id uuid,
  grantor_user_id uuid,
  grantor_name text,
  delegate_user_id uuid,
  delegate_name text,
  capabilities text[],
  starts_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  status text,
  reason text
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
  if not private.has_native_governance_authority(p_scope_id, v_actor_id) then
    raise exception 'native_scope_authority_required' using errcode = '42501';
  end if;

  return query
  select
    delegation.id,
    delegation.scope_id,
    delegation.grantor_user_id,
    grantor.display_name,
    delegation.delegate_user_id,
    delegate.display_name,
    delegation.capabilities,
    delegation.starts_at,
    delegation.expires_at,
    delegation.revoked_at,
    case
      when delegation.revoked_at is not null then 'revoked'
      when delegation.expires_at <= pg_catalog.statement_timestamp() then 'expired'
      when delegation.starts_at > pg_catalog.statement_timestamp() then 'scheduled'
      else 'active'
    end as status,
    case
      when delegation.revoked_at is not null
        then delegation.revocation_reason
      else delegation.reason
    end as reason
  from public.governance_authority_delegations as delegation
  join public.profiles as grantor on grantor.id = delegation.grantor_user_id
  join public.profiles as delegate on delegate.id = delegation.delegate_user_id
  where delegation.scope_id = p_scope_id
  order by
    case
      when delegation.revoked_at is null
        and delegation.expires_at > pg_catalog.statement_timestamp() then 0
      else 1
    end,
    delegation.created_at desc;
end;
$$;

-- p_office_codes is the target user's complete office set for this exact
-- scope/year. Empty clears the target. Selected offices atomically replace any
-- prior holder, while one user may hold several different offices.
create or replace function public.set_governance_offices(
  p_scope_id uuid,
  p_service_year integer,
  p_user_id uuid,
  p_office_codes text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope public.governance_scopes%rowtype;
  v_is_platform_admin boolean;
  v_has_native_authority boolean;
  v_has_delegated_authority boolean;
  v_target_membership public.organization_memberships%rowtype;
  v_office_codes text[];
  v_legacy_office_codes text[];
  v_previous_office_codes text[];
  v_displaced_assignments jsonb;
  v_office_code text;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_scope_id is null or p_user_id is null then
    raise exception 'governance_scope_and_target_required' using errcode = '22023';
  end if;
  if p_service_year is null
    or p_service_year not between
      private.current_service_year()
      and private.current_service_year() + 1 then
    raise exception 'invalid_governance_service_year' using errcode = '23514';
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
        'treasurer',
        'pastor'
      )
  ) then
    raise exception 'invalid_governance_office_code' using errcode = '23514';
  end if;

  select coalesce(
    pg_catalog.array_agg(
      normalized.code
      order by case normalized.code
        when 'president' then 1
        when 'vice_president' then 2
        when 'general_secretary' then 3
        when 'secretary' then 4
        when 'treasurer' then 5
        else 6
      end
    ),
    '{}'::text[]
  ) into v_office_codes
  from (
    select distinct pg_catalog.btrim(office.code) as code
    from pg_catalog.unnest(coalesce(p_office_codes, '{}'::text[])) as office(code)
  ) as normalized;

  select * into v_scope
  from public.governance_scopes
  where id = p_scope_id
    and is_active
  for update;

  if not found then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;

  v_is_platform_admin := private.is_platform_admin(v_actor_id);
  v_has_native_authority := private.has_native_governance_authority(
    p_scope_id,
    v_actor_id
  );
  v_has_delegated_authority := private.has_active_governance_delegation(
    p_scope_id,
    v_actor_id,
    'manage_officers'
  );

  if not (v_has_native_authority or v_has_delegated_authority) then
    raise exception 'governance_office_management_forbidden' using errcode = '42501';
  end if;

  select membership.* into v_target_membership
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
  join public.profiles as profile on profile.id = membership.user_id
  where membership.user_id = p_user_id
    and membership.status = 'active'::public.membership_status
    and organization.status = 'active'::public.organization_status
    and profile.deactivated_at is null
    and private.scope_contains_organization(
      p_scope_id,
      membership.organization_id
    )
  limit 1
  for update of membership;

  if not found then
    raise exception 'governance_office_target_must_be_active_member' using errcode = 'P0002';
  end if;

  if 'pastor' = any(v_office_codes)
    and v_target_membership.role <> 'minister'::public.app_role then
    raise exception 'pastor_office_requires_minister_role' using errcode = '23514';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(v_office_codes) as office(code)
    where office.code <> 'pastor'
  ) and (
    (
      v_scope.scope_type = 'church'::public.governance_scope_type
      and v_target_membership.role <> 'executive'::public.app_role
    )
    or (
      v_scope.scope_type <> 'church'::public.governance_scope_type
      and v_target_membership.role not in (
        'minister'::public.app_role,
        'executive'::public.app_role
      )
    )
  ) then
    raise exception 'governance_office_target_role_ineligible' using errcode = '23514';
  end if;

  if not v_has_native_authority then
    if p_user_id = v_actor_id then
      raise exception 'delegated_self_assignment_forbidden' using errcode = '42501';
    end if;
    if 'president' = any(v_office_codes)
      or 'pastor' = any(v_office_codes)
      or exists (
        select 1
        from public.governance_office_assignments as authority_assignment
        where authority_assignment.scope_id = p_scope_id
          and authority_assignment.user_id = p_user_id
          and authority_assignment.service_year = p_service_year
          and authority_assignment.office_code in ('president', 'pastor')
          and authority_assignment.ended_at is null
      ) then
      raise exception 'delegated_authority_positions_forbidden' using errcode = '42501';
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'governance-office:' || p_scope_id::text || ':' || p_service_year::text,
      0
    )
  );

  select coalesce(
    pg_catalog.array_agg(
      assignment.office_code
      order by case assignment.office_code
        when 'president' then 1
        when 'vice_president' then 2
        when 'general_secretary' then 3
        when 'secretary' then 4
        when 'treasurer' then 5
        else 6
      end
    ),
    '{}'::text[]
  ) into v_previous_office_codes
  from public.governance_office_assignments as assignment
  where assignment.scope_id = p_scope_id
    and assignment.user_id = p_user_id
    and assignment.service_year = p_service_year
    and assignment.ended_at is null;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'user_id', assignment.user_id,
        'office_code', assignment.office_code
      )
      order by assignment.office_code, assignment.user_id
    ),
    '[]'::jsonb
  ) into v_displaced_assignments
  from public.governance_office_assignments as assignment
  where assignment.scope_id = p_scope_id
    and assignment.user_id <> p_user_id
    and assignment.service_year = p_service_year
    and assignment.office_code = any(v_office_codes)
    and assignment.ended_at is null;

  update public.governance_office_assignments as assignment
  set ended_at = greatest(assignment.created_at, v_now)
  where assignment.scope_id = p_scope_id
    and assignment.service_year = p_service_year
    and assignment.ended_at is null
    and (
      (
        assignment.user_id = p_user_id
        and not (assignment.office_code = any(v_office_codes))
      )
      or (
        assignment.user_id <> p_user_id
        and assignment.office_code = any(v_office_codes)
      )
    );

  foreach v_office_code in array v_office_codes
  loop
    insert into public.governance_office_assignments (
      scope_id,
      user_id,
      service_year,
      office_code,
      assigned_by
    )
    values (
      p_scope_id,
      p_user_id,
      p_service_year,
      v_office_code,
      v_actor_id
    )
    on conflict (scope_id, service_year, office_code)
      where ended_at is null
    do update set
      user_id = excluded.user_id,
      assigned_by = excluded.assigned_by;
  end loop;

  -- Mirror standard church offices for the existing executive dashboard and
  -- annual records authorization. Pastor authority remains governance-only.
  if v_scope.scope_type = 'church'::public.governance_scope_type then
    select coalesce(
      pg_catalog.array_agg(code),
      '{}'::text[]
    ) into v_legacy_office_codes
    from pg_catalog.unnest(v_office_codes) as selected(code)
    where code <> 'pastor';

    update public.executive_office_assignments as legacy_assignment
    set ended_at = greatest(legacy_assignment.created_at, v_now)
    from public.organization_memberships as legacy_membership
    where legacy_membership.id = legacy_assignment.membership_id
      and legacy_membership.organization_id = v_scope.organization_id
      and legacy_assignment.service_year = p_service_year
      and legacy_assignment.ended_at is null
      and (
        (
          legacy_membership.user_id = p_user_id
          and not (legacy_assignment.office_code = any(v_legacy_office_codes))
        )
        or (
          legacy_membership.user_id <> p_user_id
          and legacy_assignment.office_code = any(v_legacy_office_codes)
        )
      );

    foreach v_office_code in array v_legacy_office_codes
    loop
      insert into public.executive_office_assignments (
        membership_id,
        service_year,
        office_code,
        assigned_by
      )
      values (
        v_target_membership.id,
        p_service_year,
        v_office_code,
        v_actor_id
      )
      on conflict (membership_id, service_year, office_code)
        where ended_at is null
      do update set assigned_by = excluded.assigned_by;
    end loop;
  end if;

  -- A non-platform actor may transfer authority atomically, but may not leave an
  -- operational scope with no president/pastor. Church ministers are native
  -- pastor authority even without a stored pastor marker.
  if p_service_year = private.current_service_year()
    and not v_is_platform_admin
    and not exists (
      select 1
      from public.governance_office_assignments as authority_assignment
      where authority_assignment.scope_id = p_scope_id
        and authority_assignment.service_year = p_service_year
        and authority_assignment.office_code in ('president', 'pastor')
        and authority_assignment.ended_at is null
        and private.is_user_active_in_governance_scope(
          p_scope_id,
          authority_assignment.user_id
        )
    )
    and not (
      v_scope.scope_type = 'church'::public.governance_scope_type
      and exists (
        select 1
        from public.organization_memberships as minister
        join public.organizations as organization
          on organization.id = minister.organization_id
        join public.profiles as profile on profile.id = minister.user_id
        where minister.organization_id = v_scope.organization_id
          and minister.role = 'minister'::public.app_role
          and minister.status = 'active'::public.membership_status
          and organization.status = 'active'::public.organization_status
          and profile.deactivated_at is null
      )
    ) then
    raise exception 'governance_scope_authority_cannot_be_orphaned' using errcode = '42501';
  end if;

  -- Delegations never outlive the native authority that granted them. This also
  -- covers a president/pastor replacement that does not change membership role.
  with revoked_delegations as (
    update public.governance_authority_delegations as delegation
    set
      revoked_at = greatest(delegation.starts_at, v_now),
      revoked_by = v_actor_id,
      revocation_reason = '위임자의 원권한 종료로 자동 종료'
    where delegation.scope_id = p_scope_id
      and delegation.revoked_at is null
      and not private.has_native_governance_authority(
        p_scope_id,
        delegation.grantor_user_id
      )
    returning delegation.id, delegation.delegate_user_id
  )
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
    revoked.delegate_user_id,
    'admin_action'::public.notification_kind,
    '위임 권한이 종료되었습니다',
    pg_catalog.left(v_scope.display_name, 1800)
      || ' 위임 권한이 위임자의 원권한 종료로 자동 종료되었습니다.',
    'governance_delegation',
    revoked.id,
    pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'reason', '위임자의 원권한 종료로 자동 종료'
    )
  from revoked_delegations as revoked;

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
    p_user_id,
    'membership_changed'::public.notification_kind,
    '임원 직책이 변경되었습니다',
    pg_catalog.left(v_scope.display_name, 1800)
      || ' ' || p_service_year::text || '년 직책을 확인해 주세요.',
    'governance_scope',
    p_scope_id,
    pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'scope_type', v_scope.scope_type,
      'service_year', p_service_year,
      'office_codes', v_office_codes
    )
  );

  insert into public.notifications (
    user_id,
    kind,
    title,
    body,
    entity_type,
    entity_id,
    metadata
  )
  select distinct
    (displaced.item ->> 'user_id')::uuid,
    'membership_changed'::public.notification_kind,
    '임원 직책이 변경되었습니다',
    pg_catalog.left(v_scope.display_name, 1800)
      || ' ' || p_service_year::text || '년 직책이 변경되었습니다.',
    'governance_scope',
    p_scope_id,
    pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'scope_type', v_scope.scope_type,
      'service_year', p_service_year,
      'replaced_office_code', displaced.item ->> 'office_code',
      'replacement_user_id', p_user_id
    )
  from pg_catalog.jsonb_array_elements(v_displaced_assignments) as displaced(item)
  where (displaced.item ->> 'user_id')::uuid <> p_user_id;

  perform private.write_audit(
    v_actor_id,
    'governance_offices.set',
    'governance_scope',
    p_scope_id,
    v_scope.organization_id,
    p_user_id,
    pg_catalog.jsonb_build_object(
      'scope_type', v_scope.scope_type,
      'service_year', p_service_year,
      'previous_office_codes', v_previous_office_codes,
      'office_codes', v_office_codes,
      'displaced_assignments', v_displaced_assignments,
      'authority_source', case
        when v_is_platform_admin then 'platform_admin'
        when v_has_native_authority then 'native'
        else 'delegation'
      end
    )
  );

  return pg_catalog.jsonb_build_object(
    'scope_id', p_scope_id,
    'user_id', p_user_id,
    'service_year', p_service_year,
    'office_codes', v_office_codes
  );
end;
$$;

create or replace function public.grant_governance_delegation(
  p_scope_id uuid,
  p_delegate_user_id uuid,
  p_capabilities text[],
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
  v_scope public.governance_scopes%rowtype;
  v_capabilities text[];
  v_reason text := nullif(pg_catalog.btrim(p_reason), '');
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_rollover timestamptz;
  v_delegation_id uuid;
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

  if exists (
    select 1
    from pg_catalog.unnest(coalesce(p_capabilities, '{}'::text[])) as capability(code)
    where capability.code is null
      or pg_catalog.btrim(capability.code) not in (
        'manage_officers',
        'view_roster'
      )
  ) then
    raise exception 'invalid_governance_delegation_capability' using errcode = '23514';
  end if;

  select coalesce(
    pg_catalog.array_agg(
      normalized.code
      order by case normalized.code
        when 'manage_officers' then 1
        else 2
      end
    ),
    '{}'::text[]
  ) into v_capabilities
  from (
    select distinct pg_catalog.btrim(capability.code) as code
    from pg_catalog.unnest(coalesce(p_capabilities, '{}'::text[])) as capability(code)
  ) as normalized;

  if not private.governance_capabilities_are_valid(v_capabilities) then
    raise exception 'governance_delegation_capability_required' using errcode = '23514';
  end if;

  select * into v_scope
  from public.governance_scopes
  where id = p_scope_id
    and is_active
  for update;

  if not found then
    raise exception 'governance_scope_not_found' using errcode = 'P0002';
  end if;
  if not private.has_native_governance_authority(p_scope_id, v_actor_id) then
    raise exception 'native_scope_authority_required_for_delegation' using errcode = '42501';
  end if;
  perform 1
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
  join public.profiles as profile
    on profile.id = membership.user_id
  where membership.user_id = p_delegate_user_id
    and membership.status = 'active'::public.membership_status
    and organization.status = 'active'::public.organization_status
    and profile.deactivated_at is null
    and private.scope_contains_organization(
      p_scope_id,
      membership.organization_id
    )
  limit 1
  for update of membership;

  if not found then
    raise exception 'delegation_target_must_be_active_in_scope' using errcode = '23514';
  end if;

  v_rollover := pg_catalog.make_timestamptz(
    private.current_service_year() + 1,
    1,
    1,
    0,
    0,
    0,
    'Asia/Seoul'
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

  if exists (
    select 1
    from public.governance_authority_delegations as active_delegation
    where active_delegation.scope_id = p_scope_id
      and active_delegation.delegate_user_id = p_delegate_user_id
      and active_delegation.revoked_at is null
      and active_delegation.starts_at <= v_now
      and active_delegation.expires_at > v_now
  ) then
    raise exception 'active_governance_delegation_already_exists' using errcode = '23505';
  end if;

  insert into public.governance_authority_delegations (
    scope_id,
    grantor_user_id,
    delegate_user_id,
    capabilities,
    starts_at,
    expires_at,
    reason
  )
  values (
    p_scope_id,
    v_actor_id,
    p_delegate_user_id,
    v_capabilities,
    v_now,
    p_expires_at,
    v_reason
  )
  returning id into v_delegation_id;

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
    p_delegate_user_id,
    'admin_action'::public.notification_kind,
    '운영 권한이 위임되었습니다',
    pg_catalog.left(v_scope.display_name, 1800)
      || ' 위임 권한과 만료일을 확인해 주세요.',
    'governance_delegation',
    v_delegation_id,
    pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'capabilities', v_capabilities,
      'expires_at', p_expires_at
    )
  );

  perform private.write_audit(
    v_actor_id,
    'governance_delegation.granted',
    'governance_delegation',
    v_delegation_id,
    v_scope.organization_id,
    p_delegate_user_id,
    pg_catalog.jsonb_build_object(
      'scope_id', p_scope_id,
      'scope_type', v_scope.scope_type,
      'capabilities', v_capabilities,
      'expires_at', p_expires_at,
      'reason', v_reason
    )
  );

  return v_delegation_id;
end;
$$;

create or replace function public.revoke_governance_delegation(
  p_delegation_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_delegation public.governance_authority_delegations%rowtype;
  v_scope public.governance_scopes%rowtype;
  v_reason text := nullif(pg_catalog.btrim(p_reason), '');
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_delegation_id is null then
    raise exception 'delegation_id_required' using errcode = '22023';
  end if;
  if v_reason is null then
    raise exception 'delegation_revocation_reason_required' using errcode = '23514';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'delegation_revocation_reason_too_long' using errcode = '22001';
  end if;

  select * into v_delegation
  from public.governance_authority_delegations
  where id = p_delegation_id
  for update;

  if not found then
    raise exception 'governance_delegation_not_found' using errcode = 'P0002';
  end if;

  if v_actor_id not in (
    v_delegation.grantor_user_id,
    v_delegation.delegate_user_id
  ) and not private.has_native_governance_authority(
    v_delegation.scope_id,
    v_actor_id
  ) then
    raise exception 'governance_delegation_revoke_forbidden' using errcode = '42501';
  end if;

  if v_delegation.revoked_at is not null then
    return;
  end if;

  select * into v_scope
  from public.governance_scopes
  where id = v_delegation.scope_id;

  update public.governance_authority_delegations
  set
    revoked_at = greatest(starts_at, v_now),
    revoked_by = v_actor_id,
    revocation_reason = v_reason
  where id = p_delegation_id;

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
    v_delegation.delegate_user_id,
    'admin_action'::public.notification_kind,
    '위임 권한이 종료되었습니다',
    coalesce(pg_catalog.left(v_scope.display_name, 1800), '조직')
      || ' 위임 권한이 종료되었습니다.',
    'governance_delegation',
    p_delegation_id,
    pg_catalog.jsonb_build_object(
      'scope_id', v_delegation.scope_id,
      'reason', v_reason
    )
  );

  perform private.write_audit(
    v_actor_id,
    'governance_delegation.revoked',
    'governance_delegation',
    p_delegation_id,
    v_scope.organization_id,
    v_delegation.delegate_user_id,
    pg_catalog.jsonb_build_object(
      'scope_id', v_delegation.scope_id,
      'reason', v_reason
    )
  );
end;
$$;

-- Preserve the existing context contract and add one additive key so a delegated
-- ordinary member can route before any governance page performs another fetch.
create or replace function public.get_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_profile jsonb;
  v_membership jsonb;
  v_organization jsonb;
  v_application jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select pg_catalog.to_jsonb(profile) into v_profile
  from public.profiles as profile
  where profile.id = v_actor_id;

  select pg_catalog.to_jsonb(membership), pg_catalog.to_jsonb(organization)
  into v_membership, v_organization
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
  where membership.user_id = v_actor_id
    and membership.status = 'active'::public.membership_status
  limit 1;

  select pg_catalog.to_jsonb(application) into v_application
  from public.membership_applications as application
  where application.user_id = v_actor_id
    and application.status in (
      'pending'::public.application_status,
      'rejected'::public.application_status
    )
  order by application.created_at desc
  limit 1;

  return pg_catalog.jsonb_build_object(
    'profile', v_profile,
    'is_platform_admin', private.is_platform_admin(v_actor_id),
    'membership', v_membership,
    'organization', v_organization,
    'pending_application', case
      when v_application ->> 'status' = 'pending' then v_application
      else null
    end,
    'latest_application', v_application,
    'governance_access', public.get_my_governance_access()
  );
end;
$$;

comment on function public.get_governance_tree() is
  'Returns the non-sensitive general-assembly/presbytery/church tree with aggregate counts.';
comment on function public.list_scope_organizations(uuid) is
  'Lists active churches and aggregate member counts within one authorized scope.';
comment on function public.list_governance_roster(uuid, integer, text, integer, integer) is
  'Returns a privacy-minimized active-member roster only after exact-scope authorization.';
comment on function public.get_my_governance_access() is
  'Returns exact-scope native or delegated governance capabilities for initial client routing.';
comment on function public.list_governance_delegations(uuid) is
  'Returns delegation history to native scope authorities; delegates cannot enumerate or re-delegate.';
comment on function public.set_governance_offices(uuid, integer, uuid, text[]) is
  'Atomically replaces one target user complete exact-scope office set; empty clears it and selected offices replace prior holders.';
comment on function public.grant_governance_delegation(uuid, uuid, text[], timestamptz, text) is
  'Grants one non-chainable exact-scope capability set through a required service-year-bounded expiry.';
comment on function public.revoke_governance_delegation(uuid, text) is
  'Revokes a governance delegation with a required audited reason.';

revoke all on function public.get_governance_tree()
  from public, anon, authenticated;
revoke all on function public.list_scope_organizations(uuid)
  from public, anon, authenticated;
revoke all on function public.list_governance_roster(uuid, integer, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.get_my_governance_access()
  from public, anon, authenticated;
revoke all on function public.list_governance_delegations(uuid)
  from public, anon, authenticated;
revoke all on function public.set_governance_offices(uuid, integer, uuid, text[])
  from public, anon, authenticated;
revoke all on function public.grant_governance_delegation(uuid, uuid, text[], timestamptz, text)
  from public, anon, authenticated;
revoke all on function public.revoke_governance_delegation(uuid, text)
  from public, anon, authenticated;
revoke all on function public.get_my_context()
  from public, anon, authenticated;

grant execute on function public.get_governance_tree()
  to authenticated;
grant execute on function public.list_scope_organizations(uuid)
  to authenticated;
grant execute on function public.list_governance_roster(uuid, integer, text, integer, integer)
  to authenticated;
grant execute on function public.get_my_governance_access()
  to authenticated;
grant execute on function public.list_governance_delegations(uuid)
  to authenticated;
grant execute on function public.set_governance_offices(uuid, integer, uuid, text[])
  to authenticated;
grant execute on function public.grant_governance_delegation(uuid, uuid, text[], timestamptz, text)
  to authenticated;
grant execute on function public.revoke_governance_delegation(uuid, text)
  to authenticated;
grant execute on function public.get_my_context()
  to authenticated;

-- Church operational capabilities now consult the one-holder hierarchy record.
-- This closes split-brain authorization if a trusted legacy writer ever leaves
-- stale co-holder rows behind.
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
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      join public.governance_scopes as church_scope
        on church_scope.scope_type = 'church'::public.governance_scope_type
       and church_scope.organization_id = membership.organization_id
       and church_scope.is_active
      join public.governance_office_assignments as assignment
        on assignment.scope_id = church_scope.id
       and assignment.user_id = membership.user_id
      where membership.organization_id = p_organization_id
        and membership.user_id = p_actor_id
        and membership.role = 'executive'::public.app_role
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and assignment.service_year = private.current_service_year()
        and assignment.ended_at is null
        and assignment.office_code = any(coalesce(p_office_codes, '{}'::text[]))
    );
$$;

revoke all on function private.has_current_executive_office(uuid, uuid, text[])
  from public, anon, authenticated;
grant execute on function private.has_current_executive_office(uuid, uuid, text[])
  to authenticated;

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
    join public.profiles as profile
      on profile.id = membership.user_id
     and profile.deactivated_at is null
    where membership.organization_id = p_organization_id
      and membership.user_id = p_actor_id
      and membership.role = 'executive'::public.app_role
      and membership.status = 'active'::public.membership_status
      and organization.status = 'active'::public.organization_status
  );
$$;

revoke all on function private.can_read_executive_operations(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.can_read_executive_operations(uuid, uuid)
  to authenticated;

-- Preserve the legacy public RPC signature, but route its writes through the
-- hierarchy source of truth so old clients cannot create a second active holder.
create or replace function public.set_executive_offices(
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
  v_scope_id uuid;
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_membership_id is null then
    raise exception 'membership_id_required' using errcode = '22023';
  end if;
  if p_office_codes is null or pg_catalog.cardinality(p_office_codes) = 0 then
    raise exception 'executive_office_required' using errcode = '23514';
  end if;
  if exists (
    select 1
    from pg_catalog.unnest(p_office_codes) as office(code)
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

  select * into v_membership
  from public.organization_memberships
  where id = p_membership_id
    and role = 'executive'::public.app_role
    and status = 'active'::public.membership_status
  for update;

  if not found then
    raise exception 'active_executive_membership_required' using errcode = 'P0002';
  end if;

  select scope.id into v_scope_id
  from public.governance_scopes as scope
  where scope.scope_type = 'church'::public.governance_scope_type
    and scope.organization_id = v_membership.organization_id
    and scope.is_active;

  if v_scope_id is null then
    raise exception 'church_governance_scope_not_found' using errcode = 'P0002';
  end if;

  v_result := public.set_governance_offices(
    v_scope_id,
    p_service_year,
    v_membership.user_id,
    p_office_codes
  );

  return v_result || pg_catalog.jsonb_build_object(
    'membership_id', p_membership_id
  );
end;
$$;

comment on function public.set_executive_offices(uuid, integer, text[]) is
  'Compatibility wrapper that routes church office writes through exact-scope one-holder governance enforcement.';

revoke all on function public.set_executive_offices(uuid, integer, text[])
  from public, anon, authenticated;
grant execute on function public.set_executive_offices(uuid, integer, text[])
  to authenticated;
