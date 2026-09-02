begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;

select plan(7);

select ok(
  coalesce((
    select relation.reloptions @> array['security_invoker=true', 'security_barrier=true']
    from pg_catalog.pg_class as relation
    where relation.oid = 'public.public_organization_directory'::regclass
  ), false),
  'public organization directory is a security-invoker barrier view'
);

select is(
  (
    select pg_catalog.jsonb_agg(privilege.column_name order by privilege.column_name)
    from information_schema.column_privileges as privilege
    where privilege.table_schema = 'public'
      and privilege.table_name = 'organizations'
      and privilege.grantee = 'anon'
      and privilege.privilege_type = 'SELECT'
  ),
  '["display_name", "id", "presbytery", "slug", "status"]'::jsonb,
  'anonymous callers hold select grants for exactly the five public columns'
);

select ok(
  not pg_catalog.has_table_privilege('anon', 'public.organizations', 'select'),
  'anonymous callers do not hold whole-table select on organizations'
);

select ok(
  exists (
    select 1
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'organizations'
      and policy.policyname = 'organizations_select_directory_anon'
      and policy.cmd = 'SELECT'
      and policy.roles = array['anon']::name[]
  ),
  'anonymous organization reads are guarded by a dedicated select policy'
);

insert into public.organizations (
  id,
  slug,
  source_name,
  display_name,
  presbytery,
  status
)
values
  (
    '19000000-0000-0000-0000-000000000001',
    'release-public-directory',
    '출시 공개 교회',
    '출시 공개 교회',
    '출시 노회',
    'active'
  ),
  (
    '19000000-0000-0000-0000-000000000002',
    'release-suspended-directory',
    '출시 중단 교회',
    '출시 중단 교회',
    '출시 노회',
    'suspended'
  );

select pg_catalog.set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_catalog.set_config('request.jwt.claim.sub', '', true);
set local role anon;

select results_eq(
  $$
    select id
    from public.public_organization_directory
    where id in (
      '19000000-0000-0000-0000-000000000001'::uuid,
      '19000000-0000-0000-0000-000000000002'::uuid
    )
    order by id
  $$,
  $$ values ('19000000-0000-0000-0000-000000000001'::uuid) $$,
  'the directory exposes an active organization and hides a suspended one'
);

select lives_ok(
  $$
    select id, slug, display_name, presbytery, status
    from public.organizations
    where id = '19000000-0000-0000-0000-000000000001'
  $$,
  'anonymous callers can read only the approved base-table columns through RLS'
);

select throws_ok(
  $$ select source_name from public.organizations limit 1 $$,
  '42501',
  'permission denied for table organizations',
  'anonymous callers cannot read a private organization column directly'
);

select * from finish();
rollback;
