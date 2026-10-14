begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();

-- Provider metadata is deliberately hostile: even a complete current consent
-- map and requested administrator roles must never become server evidence.
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
values
  ('01500000-0000-4000-8000-000000000001', null,
   '{"provider":"google","providers":["google"]}',
   '{"full_name":"Provider Name","role":"executive","approved":true,"consent_contract":"required-consents-v2","accepted_required_consents":{"privacy_policy":{"accepted":true,"version":"2026-10-14"},"sensitive_information":{"accepted":true,"version":"2026-10-14"},"overseas_transfer":{"accepted":true,"version":"2026-10-14"},"terms_of_service":{"accepted":true,"version":"2026-10-14"},"community_guidelines":{"accepted":true,"version":"2026-10-14"}}}'),
  ('01500000-0000-4000-8000-000000000002', 'social-google@example.com',
   '{"provider":"google","providers":["google"]}',
   '{"display_name":" ","full_name":"Google Name","avatar_url":"https://example.com/provider-photo"}'),
  ('01500000-0000-4000-8000-000000000003', null,
   '{"provider":"google"}', '{"name":"Name Fallback"}'),
  ('01500000-0000-4000-8000-000000000004', null,
   '{"provider":"google"}', '{}');

select is((select display_name from public.profiles where id = '01500000-0000-4000-8000-000000000001'), 'Provider Name', 'Google full_name is only a provisional display name');
select is((select display_name from public.profiles where id = '01500000-0000-4000-8000-000000000002'), 'Google Name', 'empty display name does not mask Google full_name');
select is((select display_name from public.profiles where id = '01500000-0000-4000-8000-000000000003'), 'Name Fallback', 'provider name fallback does not require email');
select is((select display_name from public.profiles where id = '01500000-0000-4000-8000-000000000004'), '사용자', 'provider accounts without names or email still get a safe profile');
select is((select count(*) from public.user_consents where user_id::text like '01500000-%'), 0::bigint, 'provider and signup metadata create no legal consent');
select is((select count(*) from public.organization_memberships where user_id::text like '01500000-%'), 0::bigint, 'provider metadata creates no memberships');
select is((select count(*) from public.platform_admins where user_id::text like '01500000-%'), 0::bigint, 'provider metadata creates no platform authority');
select ok(not exists(select 1 from public.profiles where id::text like '01500000-%' and avatar_path is not null), 'provider photo metadata is not automatically published');

insert into public.organizations (id, slug, source_name, display_name, presbytery, status)
values ('01500000-0000-4000-8000-000000000010', 'social-consent-test', '동의 테스트 교회', '동의 테스트 교회', '테스트 노회', 'active');

select set_config('request.jwt.claims', '{"sub":"01500000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
select set_config('request.jwt.claim.sub', '01500000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is((public.get_my_safety_privacy_state()->>'consent_gate_open')::boolean, false, 'OAuth session starts with closed community gate');
select is((select count(*) from public.profiles), 0::bigint, 'preconsent RLS denies even profile/community reads');
select is((select count(*) from public.posts), 0::bigint, 'preconsent RLS denies community posts');
select throws_ok($$select public.get_my_context()$$, '42501', 'current_required_consents_required', 'preconsent protected context RPC fails closed');
select throws_ok($$select public.update_my_display_name('실제 이름')$$, '42501', 'current_required_consents_required', 'preconsent name mutation fails closed');
select throws_ok($$select public.submit_membership_application('01500000-0000-4000-8000-000000000010', 'member')$$, '42501', 'current_required_consents_required', 'preconsent membership application is denied');
select throws_ok($$select public.save_my_privacy_preferences_v2(null, false,false,false,false)$$, '23514', 'current_required_consents_mismatch', 'SQL NULL cannot bypass exact consent validation');
select throws_ok($$select public.save_my_privacy_preferences_v2('null'::jsonb, false,false,false,false)$$, '23514', 'current_required_consents_mismatch', 'JSON null is not consent');
select throws_ok($$select public.save_my_privacy_preferences_v2('{"privacy_policy":"2026-10-14"}', false,false,false,false)$$, '23514', 'current_required_consents_mismatch', 'partial decisions record nothing');
select throws_ok($$select public.save_my_privacy_preferences_v2('{"privacy_policy":"2026-08-30","sensitive_information":"2026-08-30","overseas_transfer":"2026-08-30","terms_of_service":"2026-08-30","community_guidelines":"2026-08-30"}', false,false,false,false)$$, '23514', 'current_required_consents_mismatch', 'historical five-document decisions cannot open the new gate');
select is((select count(*) from public.user_consents where user_id = auth.uid()), 0::bigint, 'rejected saves are atomic');

select is((public.save_my_privacy_preferences_v2('{"privacy_policy":"2026-10-14","sensitive_information":"2026-10-14","overseas_transfer":"2026-10-14","terms_of_service":"2026-10-14","community_guidelines":"2026-10-14"}', false,true,false,false)->>'consent_gate_open')::boolean, true, 'authenticated email-less actor can record exact consent');
select is((select count(*) from public.user_consents where user_id = auth.uid() and accepted and document_version = '2026-10-14'), 5::bigint, 'explicit consent has five independent server records');
select is(public.update_my_display_name('  실제 이름  '), '실제 이름', 'pending actor explicitly enters trimmed real name');
select throws_ok($$select public.update_my_display_name('   ')$$, '23514', 'invalid_display_name', 'blank real name denied');
select throws_ok($$select public.update_my_display_name(repeat('가',81))$$, '23514', 'invalid_display_name', 'overlong real name denied');
select lives_ok($$select public.submit_membership_application('01500000-0000-4000-8000-000000000010', 'member')$$, 'consented OAuth actor uses existing approval onboarding');
select is((select count(*) from public.organization_memberships where user_id = auth.uid()), 0::bigint, 'consent and onboarding do not grant membership');
select is((select status::text from public.membership_applications where user_id = auth.uid()), 'pending', 'role-aware approval remains pending');
reset role;
select is((select display_name from public.profiles where id = '01500000-0000-4000-8000-000000000002'), 'Google Name', 'name update does not mutate another actor');
select is((select count(*) from public.user_consents where user_id = '01500000-0000-4000-8000-000000000002'), 0::bigint, 'consent records are actor-bound');

update public.consent_documents set required = false where document_key = 'terms_of_service' and version = '2026-10-14';
select ok(not private.has_current_required_consents('01500000-0000-4000-8000-000000000001'), 'partial active contract fails closed');
update public.consent_documents set required = true where document_key = 'terms_of_service' and version = '2026-10-14';
insert into public.user_consents (user_id, document_key, document_version, accepted, source, withdrawn_at)
values ('01500000-0000-4000-8000-000000000001', 'sensitive_information', '2026-10-14', false, 'app', pg_catalog.clock_timestamp());
select ok(not private.has_current_required_consents('01500000-0000-4000-8000-000000000001'), 'withdrawal recloses OAuth community access');
select * from finish();
rollback;
