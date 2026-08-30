begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;

select plan(8);

insert into auth.users (id, email, raw_user_meta_data)
values
  ('f1000000-0000-4000-8000-000000000001', 'freeze-admin@example.com', '{"display_name":"동결 관리자"}'),
  ('f1000000-0000-4000-8000-000000000002', 'freeze-applicant@example.com', '{"display_name":"동결 신청자"}');

update public.organizations
set status = 'active'
where slug = 'jaegun-bupyeong';

insert into public.platform_admins (user_id, note)
values ('f1000000-0000-4000-8000-000000000001', 'authority freeze pgTAP');

insert into public.organization_memberships (
  user_id, organization_id, role, status
)
values (
  'f1000000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'executive',
  'active'
);

insert into public.membership_applications (
  user_id, organization_id, requested_role, status
)
values (
  'f1000000-0000-4000-8000-000000000002',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'member',
  'pending'
);

update public.profiles
set deactivated_at = pg_catalog.clock_timestamp()
where id in (
  'f1000000-0000-4000-8000-000000000001',
  'f1000000-0000-4000-8000-000000000002'
);

select ok(
  not exists (
    select 1 from public.platform_admins
    where user_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  'profile deactivation permanently removes the platform-admin grant'
);

select is(
  private.is_platform_admin('f1000000-0000-4000-8000-000000000001'),
  false,
  'a stale JWT cannot pass the platform-admin helper after deactivation'
);

select is(
  (
    select status::text from public.organization_memberships
    where user_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  'revoked',
  'profile deactivation revokes active organization membership'
);

select ok(
  (
    select ended_at is not null from public.organization_memberships
    where user_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  'revoked membership records its authority end time'
);

select is(
  (
    select status::text from public.membership_applications
    where user_id = 'f1000000-0000-4000-8000-000000000002'
  ),
  'withdrawn',
  'profile deactivation withdraws a pending membership application'
);

select throws_ok(
  $$
    update public.organization_memberships
    set status = 'active', ended_at = null
    where user_id = 'f1000000-0000-4000-8000-000000000001'
  $$,
  '42501',
  'active_profile_required_for_membership',
  'a deactivated profile cannot regain membership authority'
);

select throws_ok(
  format(
    'insert into public.membership_applications (user_id, organization_id, requested_role, status) values (%L, %L, %L, %L)',
    'f1000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member',
    'pending'
  ),
  '42501',
  'active_profile_required_for_application',
  'a deactivated profile cannot submit a fresh membership application'
);

update public.profiles
set deactivated_at = null
where id = 'f1000000-0000-4000-8000-000000000001';

select ok(
  not exists (
    select 1 from public.platform_admins
    where user_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  'reactivating a profile does not resurrect a platform-admin grant'
);

select * from finish();
rollback;
