begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;

select plan(47);

select has_table(
  'public',
  'church_departments',
  'church departments have a dedicated table'
);

select has_table(
  'public',
  'department_office_assignments',
  'department offices have a dedicated annual-assignment table'
);

select is(
  (
    select count(*)
    from public.church_departments
  ),
  (
    select count(*) * 4
    from public.governance_scopes
    where scope_type = 'church'::public.governance_scope_type
  ),
  'exactly four departments are seeded for every church scope'
);

select is(
  (
    select count(*)
    from public.church_departments
    where (department_code = 'adult' and (display_name <> '장년부' or sort_order <> 10))
      or (department_code = 'young_adult' and (display_name <> '청년부' or sort_order <> 20))
      or (department_code = 'teen' and (display_name <> '청소년부' or sort_order <> 30))
      or (department_code = 'elementary' and (display_name <> '초등부' or sort_order <> 40))
  ),
  0::bigint,
  'fixed department codes, names, and ordering cannot drift'
);

select ok(
  (
    select bool_and(class.relrowsecurity)
    from pg_catalog.pg_class as class
    join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
    where namespace.nspname = 'public'
      and class.relname in ('church_departments', 'department_office_assignments')
  ),
  'both department tables have RLS enabled'
);

select ok(
  not pg_catalog.has_table_privilege(
    'authenticated',
    'public.church_departments',
    'select'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated',
    'public.department_office_assignments',
    'select'
  ),
  'authenticated clients cannot bypass RPCs with direct table reads'
);

select ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.list_church_departments(uuid,integer)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated',
    'public.list_department_office_candidates(uuid,integer,text,integer,integer)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated',
    'public.assign_department_office(uuid,integer,text,uuid)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated',
    'public.clear_department_office(uuid,integer,text)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.assign_department_office(uuid,integer,text,uuid)',
    'execute'
  ),
  'only authenticated clients receive the department RPC contract'
);

insert into auth.users (id, email, raw_user_meta_data)
values
  ('d4000000-0000-4000-8000-000000000001', 'department-admin@example.com', '{"display_name":"부서 플랫폼 관리자"}'),
  ('d4000000-0000-4000-8000-000000000002', 'department-pastor@example.com', '{"display_name":"명시 담임목사"}'),
  ('d4000000-0000-4000-8000-000000000003', 'department-ordinary-minister@example.com', '{"display_name":"일반 목사"}'),
  ('d4000000-0000-4000-8000-000000000004', 'department-executive@example.com', '{"display_name":"교회 임원"}'),
  ('d4000000-0000-4000-8000-000000000005', 'department-member-one@example.com', '{"display_name":"일반회원1"}'),
  ('d4000000-0000-4000-8000-000000000006', 'department-member-two@example.com', '{"display_name":"일반회원2"}'),
  ('d4000000-0000-4000-8000-000000000007', 'department-other-member@example.com', '{"display_name":"다른교회 회원"}'),
  ('d4000000-0000-4000-8000-000000000008', 'department-other-pastor@example.com', '{"display_name":"다른교회 담임목사"}'),
  ('d4000000-0000-4000-8000-000000000009', 'department-revoked@example.com', '{"display_name":"종료 회원"}'),
  ('d4000000-0000-4000-8000-00000000000a', 'department-deactivated@example.com', '{"display_name":"비활성 회원"}');

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source
)
select profile.id, document.document_key, document.version, true, 'admin_migration'
from public.profiles as profile
cross join public.consent_documents as document
where profile.id::text like 'd4000000-0000-4000-8000-0000000000%'
  and document.required
  and document.retired_at is null
  and document.published_at <= pg_catalog.statement_timestamp()
  and document.effective_at <= pg_catalog.statement_timestamp();

update public.organizations
set status = 'active'
where slug in ('jaegun-bupyeong', 'jaegun-namseoul');

insert into public.platform_admins (user_id, note)
values (
  'd4000000-0000-4000-8000-000000000001',
  'department office pgTAP'
);

insert into public.organization_memberships (
  user_id,
  organization_id,
  role,
  status,
  church_title_code,
  ended_at
)
values
  (
    'd4000000-0000-4000-8000-000000000002',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'minister',
    'active',
    'pastor',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000003',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'minister',
    'active',
    'pastor',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000004',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'executive',
    'active',
    'elder',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000005',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member',
    'active',
    'deacon',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000006',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member',
    'active',
    'kwonsa',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000007',
    (select id from public.organizations where slug = 'jaegun-namseoul'),
    'member',
    'active',
    'deacon',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000008',
    (select id from public.organizations where slug = 'jaegun-namseoul'),
    'minister',
    'active',
    'pastor',
    null
  ),
  (
    'd4000000-0000-4000-8000-000000000009',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member',
    'revoked',
    'deacon',
    pg_catalog.clock_timestamp()
  ),
  (
    'd4000000-0000-4000-8000-00000000000a',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member',
    'active',
    'deacon',
    null
  );

update public.profiles
set deactivated_at = pg_catalog.clock_timestamp()
where id = 'd4000000-0000-4000-8000-00000000000a';

insert into public.governance_office_assignments (
  scope_id,
  user_id,
  service_year,
  office_code,
  assigned_by
)
values
  (
    (
      select id from public.governance_scopes
      where scope_type = 'church'
        and organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
    ),
    'd4000000-0000-4000-8000-000000000002',
    private.current_service_year(),
    'pastor',
    'd4000000-0000-4000-8000-000000000001'
  ),
  (
    (
      select id from public.governance_scopes
      where scope_type = 'church'
        and organization_id = (
          select id from public.organizations where slug = 'jaegun-namseoul'
        )
    ),
    'd4000000-0000-4000-8000-000000000008',
    private.current_service_year(),
    'pastor',
    'd4000000-0000-4000-8000-000000000001'
  );

select set_config(
  'test.governance_service_year',
  private.current_service_year()::text,
  true
);

-- This grant exists only inside the rolled-back pgTAP transaction. Production
-- clients continue to use public.get_service_year(), while assertions can keep
-- their expected year adjacent to each call under SET ROLE authenticated.
grant execute on function private.current_service_year() to authenticated;

-- Test assertions need stable department UUID fixtures while exercising RPCs
-- under SET ROLE authenticated. This read policy and grant are transaction-local
-- and roll back; the production privilege assertion above already verifies that
-- neither exists after the migration.
grant select on table public.church_departments to authenticated;
create policy church_departments_pgtap_fixture_lookup
on public.church_departments for select to authenticated
using (
  session_user in ('postgres', 'supabase_admin')
  and pg_catalog.current_setting('test.governance_service_year', true) is not null
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000005',
  true
);
set local role authenticated;

select throws_ok(
  format(
    'select * from public.list_church_departments(%L, %s)',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    private.current_service_year()
  ),
  '42501',
  'department_office_read_forbidden',
  'an ordinary same-church member cannot enumerate department management data'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000002',
  true
);

select ok(
  (
    select count(*) = 20
      and count(distinct department_code) = 4
    from public.list_church_departments(
      (select id from public.organizations where slug = 'jaegun-bupyeong'),
      private.current_service_year()
    )
  ),
  'the explicit pastor reads four departments by five fixed office slots'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000007',
  true
);

select throws_ok(
  format(
    'select * from public.list_church_departments(%L, %s)',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    private.current_service_year()
  ),
  '42501',
  'department_office_read_forbidden',
  'a member cannot read another church department roster'
);

select set_config('request.jwt.claim.sub', '', true);

select throws_ok(
  format(
    'select * from public.list_church_departments(%L, %s)',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    private.current_service_year()
  ),
  '42501',
  'authentication_required',
  'department listing requires authentication'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000002',
  true
);

select is(
  (
    select count(*)
    from public.list_department_office_candidates(
      (
        select department.id
        from public.church_departments as department
        join public.governance_scopes as scope
          on scope.id = department.church_scope_id
        where scope.organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
          and department.department_code = 'adult'
      ),
      private.current_service_year()
    )
  ),
  5::bigint,
  'the explicit church pastor sees only five active same-church candidates'
);

select is(
  (
    select count(*)
    from public.list_department_office_candidates(
      (
        select department.id
        from public.church_departments as department
        join public.governance_scopes as scope
          on scope.id = department.church_scope_id
        where scope.organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
          and department.department_code = 'adult'
      ),
      private.current_service_year(),
      '일반회원2'
    )
  ),
  1::bigint,
  'candidate search is applied before pagination'
);

select ok(
  not exists (
    select 1
    from public.list_department_office_candidates(
      (
        select department.id
        from public.church_departments as department
        join public.governance_scopes as scope
          on scope.id = department.church_scope_id
        where scope.organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
          and department.department_code = 'adult'
      ),
      private.current_service_year()
    ) as candidate
    where candidate.user_id in (
      'd4000000-0000-4000-8000-000000000007'::uuid,
      'd4000000-0000-4000-8000-000000000009'::uuid,
      'd4000000-0000-4000-8000-00000000000a'::uuid
    )
  ),
  'other-church, revoked, and deactivated users never become candidates'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000003',
  true
);

select throws_ok(
  format(
    'select * from public.list_department_office_candidates(%L, %s)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year()
  ),
  '42501',
  'department_office_management_forbidden',
  'a minister title alone cannot enumerate management candidates'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000001',
  true
);

select lives_ok(
  format(
    'select * from public.list_department_office_candidates(%L, %s)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year()
  ),
  'a platform administrator may enumerate exact-church candidates'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000008',
  true
);

select throws_ok(
  format(
    'select * from public.list_department_office_candidates(%L, %s)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year()
  ),
  '42501',
  'department_office_management_forbidden',
  'another church explicit pastor has no cross-church management authority'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000001',
  true
);

select lives_ok(
  format(
    'select public.assign_department_office(%L, %s, ''president'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000005'
  ),
  'platform administrator assigns a current-year department president'
);

reset role;

select is(
  (
    select membership.role::text
    from public.organization_memberships as membership
    where membership.user_id = 'd4000000-0000-4000-8000-000000000005'
      and membership.status = 'active'
  ),
  'member',
  'department office metadata does not promote a member app role'
);

select ok(
  not exists (
    select 1
    from public.governance_office_assignments
    where user_id = 'd4000000-0000-4000-8000-000000000005'
  )
  and not exists (
    select 1
    from public.executive_office_assignments as assignment
    join public.organization_memberships as membership
      on membership.id = assignment.membership_id
    where membership.user_id = 'd4000000-0000-4000-8000-000000000005'
  ),
  'department assignment creates neither governance nor executive authority'
);

set local role authenticated;

select is(
  (
    public.assign_department_office(
      (
        select department.id
        from public.church_departments as department
        join public.governance_scopes as scope on scope.id = department.church_scope_id
        where scope.organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
          and department.department_code = 'adult'
      ),
      private.current_service_year(),
      'president',
      'd4000000-0000-4000-8000-000000000005'
    ) ->> 'changed'
  ),
  'false',
  'repeating the same unit assignment is idempotent'
);

reset role;

select is(
  (
    select count(*)
    from public.department_office_assignments
    where department_id = (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    )
      and service_year = private.current_service_year()
      and office_code = 'president'
      and ended_at is null
  ),
  1::bigint,
  'the unit assignment has exactly one active holder'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000002',
  true
);
set local role authenticated;

select lives_ok(
  format(
    'select public.assign_department_office(%L, %s, ''vice_president'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'young_adult'
    ),
    private.current_service_year() + 1,
    'd4000000-0000-4000-8000-000000000006'
  ),
  'the current explicit pastor may prepare next-year department offices'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000003',
  true
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  '42501',
  'department_office_management_forbidden',
  'an ordinary minister with pastor display title cannot manage offices'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000004',
  true
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  '42501',
  'department_office_management_forbidden',
  'a church executive receives no implicit department management authority'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000005',
  true
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''treasurer'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  '42501',
  'department_office_management_forbidden',
  'a department president cannot manage another office or department'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000008',
  true
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''treasurer'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  '42501',
  'department_office_management_forbidden',
  'an explicit pastor remains confined to the exact church scope'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000002',
  true
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000007'
  ),
  'P0002',
  'department_office_target_must_be_active_church_member',
  'another church member cannot be assigned into this church department'
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000009'
  ),
  'P0002',
  'department_office_target_must_be_active_church_member',
  'a revoked member cannot be assigned to a department office'
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-00000000000a'
  ),
  'P0002',
  'department_office_target_must_be_active_church_member',
  'a deactivated member cannot be assigned to a department office'
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''pastor'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  '23514',
  'invalid_department_office_code',
  'department offices reject governance-only office codes'
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year() - 1,
    'd4000000-0000-4000-8000-000000000006'
  ),
  '23514',
  'invalid_department_service_year',
  'past department service years cannot be mutated'
);

select throws_ok(
  format(
    'select * from public.list_church_departments(%L, %s)',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    private.current_service_year() + 2
  ),
  '23514',
  'invalid_department_service_year',
  'department reads are bounded to current and next service year'
);

select set_config(
  'request.jwt.claims',
  pg_catalog.jsonb_build_object(
    'sub', 'd4000000-0000-4000-8000-000000000002',
    'role', 'authenticated',
    'aal', 'aal1'
  )::text,
  true
);

select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  '42501',
  'aal2_required:department_office_assignment',
  'signed AAL1 sessions cannot change department leadership'
);

select set_config(
  'request.jwt.claims',
  pg_catalog.jsonb_build_object(
    'sub', 'd4000000-0000-4000-8000-000000000002',
    'role', 'authenticated',
    'aal', 'aal2'
  )::text,
  true
);

select lives_ok(
  format(
    'select public.assign_department_office(%L, %s, ''secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  'signed AAL2 sessions may change department leadership'
);

select set_config('request.jwt.claims', '', true);

select lives_ok(
  format(
    'select public.assign_department_office(%L, %s, ''president'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  'the explicit pastor atomically replaces one office holder'
);

reset role;

select is(
  (
    select count(*)
    from public.department_office_assignments
    where department_id = (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    )
      and service_year = private.current_service_year()
      and office_code = 'president'
  ),
  2::bigint,
  'replacement retains one ended history row and one active row'
);

select is(
  (
    select count(*)
    from public.department_office_assignments
    where department_id = (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    )
      and service_year = private.current_service_year()
      and office_code = 'president'
      and ended_at is null
      and user_id = 'd4000000-0000-4000-8000-000000000006'
  ),
  1::bigint,
  'replacement leaves exactly the requested active holder'
);

set local role authenticated;

select is(
  (
    select member_display_name
    from public.list_church_departments(
      (select id from public.organizations where slug = 'jaegun-bupyeong'),
      private.current_service_year()
    )
    where department_code = 'adult'
      and office_code = 'president'
  ),
  '일반회원2',
  'flattened office output resolves the active holder safely'
);

select is(
  (
    public.clear_department_office(
      (
        select department.id
        from public.church_departments as department
        join public.governance_scopes as scope on scope.id = department.church_scope_id
        where scope.organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
          and department.department_code = 'adult'
      ),
      private.current_service_year(),
      'president'
    ) ->> 'cleared'
  ),
  'true',
  'the explicit pastor clears one exact office slot'
);

select is(
  (
    public.clear_department_office(
      (
        select department.id
        from public.church_departments as department
        join public.governance_scopes as scope on scope.id = department.church_scope_id
        where scope.organization_id = (
          select id from public.organizations where slug = 'jaegun-bupyeong'
        )
          and department.department_code = 'adult'
      ),
      private.current_service_year(),
      'president'
    ) ->> 'cleared'
  ),
  'false',
  'clearing an already-empty unit is idempotent'
);

reset role;

select ok(
  exists (
    select 1
    from public.audit_logs
    where action = 'department_office.assigned'
      and organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
  )
  and exists (
    select 1
    from public.audit_logs
    where action = 'department_office.cleared'
      and organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
  ),
  'department assignment and clearing are both audit logged'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000002',
  true
);
set local role authenticated;

select lives_ok(
  format(
    'select public.assign_department_office(%L, %s, ''treasurer'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000005'
  ),
  'an eligible active member may hold a department office'
);

reset role;

update public.organization_memberships
set
  status = 'revoked',
  ended_at = pg_catalog.clock_timestamp()
where user_id = 'd4000000-0000-4000-8000-000000000005'
  and status = 'active';

select ok(
  not exists (
    select 1
    from public.department_office_assignments
    where user_id = 'd4000000-0000-4000-8000-000000000005'
      and ended_at is null
  ),
  'membership revocation automatically ends active department offices'
);

select set_config(
  'request.jwt.claim.sub',
  'd4000000-0000-4000-8000-000000000002',
  true
);
set local role authenticated;

select lives_ok(
  format(
    'select public.assign_department_office(%L, %s, ''general_secretary'', %L)',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'teen'
    ),
    private.current_service_year(),
    'd4000000-0000-4000-8000-000000000006'
  ),
  'another active member can hold an exact department office'
);

reset role;

update public.profiles
set deactivated_at = pg_catalog.clock_timestamp()
where id = 'd4000000-0000-4000-8000-000000000006';

select ok(
  not exists (
    select 1
    from public.department_office_assignments
    where user_id = 'd4000000-0000-4000-8000-000000000006'
      and ended_at is null
  ),
  'profile deactivation immediately freezes every department office'
);

select throws_ok(
  format(
    'update public.church_departments set display_name = %L where id = %L',
    '장년선교회',
    (
      select department.id
      from public.church_departments as department
      join public.governance_scopes as scope on scope.id = department.church_scope_id
      where scope.organization_id = (
        select id from public.organizations where slug = 'jaegun-bupyeong'
      )
        and department.department_code = 'adult'
    )
  ),
  '42501',
  'church_department_identity_is_immutable',
  'fixed department identity cannot be renamed by a later write'
);

select * from finish();
rollback;
