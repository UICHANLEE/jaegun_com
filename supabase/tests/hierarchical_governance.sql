begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;

select plan(47);

create function pg_temp.clear_office_and_check_deferred_guard(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text
)
returns void
language plpgsql
as $$
begin
  perform public.clear_governance_office(
    p_scope_id,
    p_service_year,
    p_office_code
  );
  set constraints governance_scope_authority_guard immediate;
end;
$$;

select is(
  (select count(*) from public.governance_scopes where scope_type = 'general_assembly'),
  1::bigint,
  'exactly one general assembly is seeded'
);
select is(
  (select count(*) from public.governance_scopes where scope_type = 'presbytery'),
  5::bigint,
  'all five presbyteries are seeded'
);
select is(
  (select count(*) from public.governance_scopes where scope_type = 'church'),
  36::bigint,
  'all 36 church organizations are mapped'
);
select is(
  (
    select count(*)
    from public.governance_scopes as church
    join public.governance_scopes as presbytery on presbytery.id = church.parent_scope_id
    where church.scope_type = 'church'
      and presbytery.scope_type = 'presbytery'
  ),
  36::bigint,
  'every church has a presbytery parent'
);
select is(
  (
    select count(*)
    from public.governance_scopes as presbytery
    join public.governance_scopes as assembly on assembly.id = presbytery.parent_scope_id
    where presbytery.scope_type = 'presbytery'
      and assembly.scope_type = 'general_assembly'
  ),
  5::bigint,
  'every presbytery has the general assembly parent'
);

insert into auth.users (id, email, raw_user_meta_data)
values
  ('a0000000-0000-4000-8000-000000000001', 'governance-admin@example.com', '{"display_name":"플랫폼관리자"}'),
  ('b0000000-0000-4000-8000-000000000001', 'governance-president@example.com', '{"display_name":"노회장"}'),
  ('c0000000-0000-4000-8000-000000000001', 'governance-pastor@example.com', '{"display_name":"목사"}'),
  ('d0000000-0000-4000-8000-000000000001', 'governance-delegate@example.com', '{"display_name":"위임회원"}'),
  ('e0000000-0000-4000-8000-000000000001', 'governance-member@example.com', '{"display_name":"일반회원"}'),
  ('f0000000-0000-4000-8000-000000000001', 'governance-executive@example.com', '{"display_name":"다른교회임원"}'),
  ('a1000000-0000-4000-8000-000000000001', 'governance-assistant-pastor@example.com', '{"display_name":"보조목사"}');

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source
)
select profile.id, document.document_key, document.version, true, 'admin_migration'
from public.profiles as profile
cross join public.consent_documents as document
where profile.id in (
    'a0000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-8000-000000000001',
    'c0000000-0000-4000-8000-000000000001',
    'd0000000-0000-4000-8000-000000000001',
    'e0000000-0000-4000-8000-000000000001',
    'f0000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001'
  )
  and document.required
  and document.retired_at is null
  and document.published_at <= pg_catalog.statement_timestamp()
  and document.effective_at <= pg_catalog.statement_timestamp();

insert into public.platform_admins (user_id, note)
values ('a0000000-0000-4000-8000-000000000001', 'hierarchical governance test');

update public.organizations
set status = 'active'
where slug in ('jaegun-bupyeong', 'jaegun-namseoul', 'jaegun-busan');

insert into public.organization_memberships (user_id, organization_id, role)
values
  (
    'b0000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'executive'
  ),
  (
    'c0000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'minister'
  ),
  (
    'd0000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member'
  ),
  (
    'e0000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member'
  ),
  (
    'f0000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-namseoul'),
    'executive'
  ),
  (
    'a1000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'minister'
  );

select set_config(
  'test.governance_service_year',
  private.current_service_year()::text,
  true
);

select set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''president'']::text[])',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    'b0000000-0000-4000-8000-000000000001'
  ),
  'platform admin assigns the presbytery president'
);
select lives_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''pastor'']::text[])',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    'c0000000-0000-4000-8000-000000000001'
  ),
  'platform admin assigns the presbytery pastor authority'
);
select lives_ok(
  format(
    'select public.assign_governance_office(%L, %s, ''pastor'', %L)',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer,
    'c0000000-0000-4000-8000-000000000001'
  ),
  'platform admin explicitly assigns the annual church pastor'
);
select lives_ok(
  format(
    'select public.assign_governance_office(%L, %s, ''treasurer'', %L)',
    (select id from public.governance_scopes where scope_type = 'general_assembly'),
    current_setting('test.governance_service_year')::integer,
    'b0000000-0000-4000-8000-000000000001'
  ),
  'platform admin assigns an eligible general-assembly officer'
);
select ok(
  (
    select candidate.membership_role = 'minister'::public.app_role
    from public.list_governance_office_candidates(
      (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
      current_setting('test.governance_service_year')::integer,
      'pastor',
      null,
      1,
      0
    ) as candidate
  ),
  'office candidates are role-filtered before the page limit is applied'
);

reset role;
select set_config('request.jwt.claim.sub', 'b0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select ok(
  exists (
    select 1
    from jsonb_array_elements(public.get_my_governance_access()) as access(item)
    where item ->> 'scope_name' = '서울노회'
      and (item ->> 'can_manage_officers')::boolean
      and (item ->> 'can_manage_delegations')::boolean
  ),
  'current presbytery president receives native exact-scope authority'
);
select lives_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''manage_officers'', ''view_roster'']::text[], statement_timestamp() + interval ''7 days'', ''테스트 위임'')',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    'd0000000-0000-4000-8000-000000000001'
  ),
  'presbytery president grants a bounded delegation'
);
select throws_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''secretary'']::text[])',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer,
    'b0000000-0000-4000-8000-000000000001'
  ),
  '42501',
  'governance_office_management_forbidden',
  'parent-scope president cannot mutate a child church scope'
);
select throws_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''view_roster'']::text[], statement_timestamp() + interval ''91 days'', ''too long'')',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    'e0000000-0000-4000-8000-000000000001'
  ),
  '23514',
  'invalid_governance_delegation_expiry',
  'delegation expiry over 90 days fails closed'
);

reset role;
select set_config('request.jwt.claim.sub', 'c0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select ok(
  exists (
    select 1
    from jsonb_array_elements(public.get_my_governance_access()) as access(item)
    where item ->> 'scope_name' = '서울노회'
      and (item ->> 'can_manage_officers')::boolean
      and (item ->> 'can_manage_delegations')::boolean
  ),
  'assigned higher-scope pastor receives native authority'
);
select ok(
  exists (
    select 1
    from jsonb_array_elements(public.get_my_governance_access()) as access(item)
    where item ->> 'scope_type' = 'church'
      and (access.item -> 'office_codes') ? 'pastor'
      and (item ->> 'can_manage_officers')::boolean
  ),
  'explicitly assigned church pastor receives exact-scope authority'
);
select lives_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''secretary'']::text[])',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer,
    'b0000000-0000-4000-8000-000000000001'
  ),
  'church pastor can assign an eligible church executive'
);
select throws_ok(
  format(
    'select pg_temp.clear_office_and_check_deferred_guard(%L, %s, ''pastor'')',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer
  ),
  '42501',
  'governance_scope_authority_cannot_be_orphaned',
  'current native authority cannot leave an active scope without a president or pastor'
);

reset role;
select set_config('request.jwt.claim.sub', 'a1000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select is(
  jsonb_array_length(public.get_my_governance_access()),
  0,
  'an unassigned church minister receives no governance officer authority'
);
select throws_ok(
  format(
    'select public.assign_governance_office(%L, %s, ''secretary'', %L)',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer,
    'b0000000-0000-4000-8000-000000000001'
  ),
  '42501',
  'governance_office_management_forbidden',
  'an unassigned minister cannot manage church officers'
);

reset role;
select set_config('request.jwt.claim.sub', 'b0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select ok(
  exists (
    select 1
    from public.executive_office_assignments as assignment
    join public.list_visible_organization_memberships(
      (
        select organization.id
        from public.organizations as organization
        where organization.slug = 'jaegun-bupyeong'
      ),
      500,
      0
    ) as membership on membership.id = assignment.membership_id
    where membership.user_id = 'b0000000-0000-4000-8000-000000000001'
      and assignment.service_year = current_setting('test.governance_service_year')::integer
      and assignment.office_code = 'secretary'
      and assignment.ended_at is null
  ),
  'church governance offices mirror into legacy executive operations'
);

reset role;
select set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.assign_governance_office(%L, %s, ''treasurer'', %L)',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer,
    'b0000000-0000-4000-8000-000000000001'
  ),
  'single-office assignment preserves another office on the same person'
);
select ok(
  (
    select assignment.office_codes @> array['secretary', 'treasurer']::text[]
    from public.list_governance_roster(
      (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
      current_setting('test.governance_service_year')::integer,
      '노회장',
      10,
      0
    ) as assignment
  ),
  'the target retains both independently assigned church offices'
);
select lives_ok(
  format(
    'select public.clear_governance_office(%L, %s, ''treasurer'')',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer
  ),
  'single-office clear does not replace the holder complete office set'
);
select ok(
  (
    select assignment.office_codes = array['secretary']::text[]
    from public.list_governance_roster(
      (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
      current_setting('test.governance_service_year')::integer,
      '노회장',
      10,
      0
    ) as assignment
  ),
  'clearing one church office preserves the holder remaining office'
);

reset role;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select ok(
  exists (
    select 1
    from jsonb_array_elements(public.get_my_governance_access()) as access(item)
    where item ->> 'scope_name' = '서울노회'
      and item ->> 'authority_source' = 'delegation'
      and (item ->> 'can_manage_officers')::boolean
      and not (item ->> 'can_manage_delegations')::boolean
  ),
  'delegate receives only the granted capability without re-delegation authority'
);
select is(
  jsonb_array_length(public.get_my_governance_access()),
  1,
  'delegated access stays on one exact scope'
);
select ok(
  (select count(*) > 0 from public.list_governance_roster(
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    null,
    100,
    0
  )),
  'delegate can read the authorized presbytery roster'
);
select ok(
  not exists (
    select 1
    from public.list_governance_roster(
      (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
      current_setting('test.governance_service_year')::integer,
      null,
      100,
      0
    ) as roster
    where to_jsonb(roster) ?| array['email', 'phone', 'contact_phone']
  ),
  'authorized roster rows exclude private contact fields'
);
select ok(
  (select count(*) > 0 from public.list_governance_roster(
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    '서울노회',
    100,
    0
  )),
  'parent roster can filter people by presbytery name without child authority'
);
select lives_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''secretary'']::text[])',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    'f0000000-0000-4000-8000-000000000001'
  ),
  'delegated manager can assign a non-authority office to an eligible leader'
);
select throws_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''president'', ''secretary'']::text[])',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    'f0000000-0000-4000-8000-000000000001'
  ),
  '42501',
  'delegated_authority_positions_forbidden',
  'delegate cannot assign president or pastor authority'
);
select throws_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''view_roster'']::text[], statement_timestamp() + interval ''2 days'', ''chain attempt'')',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    'e0000000-0000-4000-8000-000000000001'
  ),
  '42501',
  'native_scope_authority_required_for_delegation',
  'delegated authority cannot be chained'
);

reset role;
select set_config('request.jwt.claim.sub', 'e0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select throws_ok(
  format(
    'select * from public.list_governance_roster(%L, %s, null, 100, 0)',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer
  ),
  '42501',
  'governance_roster_forbidden',
  'ordinary member cannot enumerate a governance roster'
);
select throws_ok(
  format(
    'select public.clear_governance_office(%L, %s, ''vice_president'')',
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    current_setting('test.governance_service_year')::integer
  ),
  '42501',
  'governance_office_management_forbidden',
  'ordinary member cannot clear even an already vacant office'
);

reset role;

select set_config('request.jwt.claim.sub', 'a0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.set_governance_offices(%L, %s, %L, array[''president'', ''secretary'']::text[])',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    current_setting('test.governance_service_year')::integer,
    'f0000000-0000-4000-8000-000000000001'
  ),
  'replacing a native president automatically ends that grantor delegation'
);

reset role;

select ok(
  (
    select delegation.revoked_at is not null
    from public.governance_authority_delegations as delegation
    where delegation.grantor_user_id = 'b0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'd0000000-0000-4000-8000-000000000001'
    order by delegation.created_at desc
    limit 1
  ),
  'office replacement persists automatic delegation revocation'
);
select is(
  (
    select count(*)
    from public.notifications as notification
    join public.governance_authority_delegations as delegation
      on delegation.id = notification.entity_id
    where delegation.grantor_user_id = 'b0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'd0000000-0000-4000-8000-000000000001'
      and notification.user_id = delegation.delegate_user_id
      and notification.entity_type = 'governance_delegation'
      and notification.title = '위임 권한이 종료되었습니다'
      and notification.metadata ->> 'reason' = '위임자의 원권한 종료로 자동 종료'
  ),
  1::bigint,
  'office replacement notifies the affected delegate exactly once'
);
select set_config(
  'test.office_revoked_delegation_id',
  (
    select delegation.id::text
    from public.governance_authority_delegations as delegation
    where delegation.grantor_user_id = 'b0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'd0000000-0000-4000-8000-000000000001'
    order by delegation.created_at desc
    limit 1
  ),
  true
);

select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.revoke_governance_delegation(%L, %L)',
    current_setting('test.office_revoked_delegation_id')::uuid,
    '이미 자동 종료된 위임 확인'
  ),
  'manual revoke remains idempotent after automatic office revocation'
);

reset role;

select is(
  (
    select count(*)
    from public.notifications as notification
    join public.governance_authority_delegations as delegation
      on delegation.id = notification.entity_id
    where delegation.grantor_user_id = 'b0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'd0000000-0000-4000-8000-000000000001'
      and notification.entity_type = 'governance_delegation'
      and notification.title = '위임 권한이 종료되었습니다'
  ),
  1::bigint,
  'idempotent manual revoke does not duplicate the automatic end notification'
);

select set_config('request.jwt.claim.sub', 'c0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''view_roster'']::text[], statement_timestamp() + interval ''2 days'', %L)',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    'e0000000-0000-4000-8000-000000000001',
    '회원 상태 변경 자동 종료 테스트'
  ),
  'native pastor grants a delegation before a membership-role change'
);

reset role;

select lives_ok(
  $$
    update public.organization_memberships
    set role = 'member'
    where user_id = 'c0000000-0000-4000-8000-000000000001'
  $$,
  'membership-role change ends ineligible governance authority'
);
select ok(
  (
    select delegation.revoked_at is not null
    from public.governance_authority_delegations as delegation
    where delegation.grantor_user_id = 'c0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'e0000000-0000-4000-8000-000000000001'
    order by delegation.created_at desc
    limit 1
  ),
  'membership-role change persists automatic delegation revocation'
);
select is(
  (
    select count(*)
    from public.notifications as notification
    join public.governance_authority_delegations as delegation
      on delegation.id = notification.entity_id
    where delegation.grantor_user_id = 'c0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'e0000000-0000-4000-8000-000000000001'
      and notification.user_id = delegation.delegate_user_id
      and notification.entity_type = 'governance_delegation'
      and notification.title = '위임 권한이 종료되었습니다'
      and notification.metadata ->> 'reason' = '소속 또는 역할 변경으로 자동 종료'
  ),
  1::bigint,
  'membership-role automatic revocation notifies the delegate exactly once'
);

select set_config('request.jwt.claim.sub', 'f0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''view_roster'']::text[], statement_timestamp() + interval ''1 day'', %L)',
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = '서울노회'),
    'e0000000-0000-4000-8000-000000000001',
    '수동 회수 회귀 테스트'
  ),
  'new native president can grant a delegation after prior automatic revocation'
);

reset role;

select set_config(
  'test.manual_delegation_id',
  (
    select delegation.id::text
    from public.governance_authority_delegations as delegation
    where delegation.grantor_user_id = 'f0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'e0000000-0000-4000-8000-000000000001'
    order by delegation.created_at desc
    limit 1
  ),
  true
);
select set_config('request.jwt.claim.sub', 'f0000000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.revoke_governance_delegation(%L, %L)',
    current_setting('test.manual_delegation_id')::uuid,
    '수동 회수 정상 동작 확인'
  ),
  'manual governance delegation revoke still succeeds'
);

reset role;

select is(
  (
    select count(*)
    from public.notifications as notification
    join public.governance_authority_delegations as delegation
      on delegation.id = notification.entity_id
    where delegation.grantor_user_id = 'f0000000-0000-4000-8000-000000000001'
      and delegation.delegate_user_id = 'e0000000-0000-4000-8000-000000000001'
      and notification.user_id = delegation.delegate_user_id
      and notification.entity_type = 'governance_delegation'
      and notification.title = '위임 권한이 종료되었습니다'
  ),
  1::bigint,
  'manual revocation still emits exactly one end notification'
);

select * from finish();
rollback;
