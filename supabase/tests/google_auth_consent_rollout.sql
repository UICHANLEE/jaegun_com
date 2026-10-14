-- Transactional pgTAP regression: no fixture or acceptance survives this test.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();

select is((select count(*) from public.consent_documents where required and retired_at is null), 5::bigint,
  'exactly five active documents');
select is((select count(*) from public.consent_documents where version = '2026-08-27' and retired_at is not null
  and ((document_key = 'privacy_policy' and content_sha256 = '2eeac1f3dbaa45d8b2742aa9239aedf2507d67c02b397a6ac362ef20d9a2f829')
    or (document_key = 'community_guidelines' and content_sha256 = 'c587eae93255d82391ddd287a1737679f9a2823e598dd091fa4cb819eed3c59f'))),
  2::bigint, 'original two consent evidence rows preserved');
select is((select count(*) from public.consent_documents where version = '2026-08-30' and retired_at is not null),
  5::bigint, 'all previous five documents retained as history');
select is((select count(*) from public.consent_documents d join (values
  ('privacy_policy','/legal/privacy/2026-10-14','67efb4d62726b98fc25ee47d35846cc22275089e3934e1a6928c1489ba4f28fb'),
  ('sensitive_information','/legal/sensitive/2026-10-14','4435c25cb223996ce37f9b756a0477d445d157cebbb3d11e8afff945d2726664'),
  ('overseas_transfer','/legal/overseas/2026-10-14','0e562b7b0c18ed61684aabebb6307152f5508ca4647d01dbd27cb3d444a47d62'),
  ('terms_of_service','/legal/terms/2026-10-14','5e40c29280f72f98d497220030fba13333808cf90e1350411d0c905871cc7908'),
  ('community_guidelines','/legal/community/2026-10-14','42399002842b5d3fb7d19c15ae4721deab99401d42790722f4825d9092bcd8a6')
  ) e(document_key,document_url,content_sha256)
  on e.document_key=d.document_key and e.document_url=d.document_url and e.content_sha256=d.content_sha256
  where d.version='2026-10-14' and d.locale='ko-KR' and d.required and d.retired_at is null),
  5::bigint, 'new version URLs and hashes match exact contract');

create temporary table consent_signup_fixtures (case_name text primary key, user_id uuid, provider text, metadata jsonb);
insert into consent_signup_fixtures
select 'valid-email','01410000-0000-4000-8000-000000000001'::uuid,'email',
  pg_catalog.jsonb_build_object('consent_contract','required-consents-v2','accepted_required_consents',
    (select pg_catalog.jsonb_object_agg(document_key,pg_catalog.jsonb_build_object('accepted',true,'version',version))
     from public.consent_documents where required and retired_at is null));
insert into consent_signup_fixtures
select 'oauth-spoof','01410000-0000-4000-8000-000000000002','google',metadata from consent_signup_fixtures where case_name='valid-email';
insert into consent_signup_fixtures
select 'missing','01410000-0000-4000-8000-000000000003','email',
  pg_catalog.jsonb_set(metadata,'{accepted_required_consents}',(metadata->'accepted_required_consents')-'privacy_policy')
  from consent_signup_fixtures where case_name='valid-email';
insert into consent_signup_fixtures
select 'false','01410000-0000-4000-8000-000000000004','email',
  pg_catalog.jsonb_set(metadata,'{accepted_required_consents,privacy_policy,accepted}','false')
  from consent_signup_fixtures where case_name='valid-email';
insert into consent_signup_fixtures
select 'unknown','01410000-0000-4000-8000-000000000005','email',
  pg_catalog.jsonb_set(metadata,'{accepted_required_consents,unknown}','{"accepted":true,"version":"2026-10-14"}')
  from consent_signup_fixtures where case_name='valid-email';
insert into consent_signup_fixtures
select 'old-version','01410000-0000-4000-8000-000000000006','email',
  pg_catalog.jsonb_set(metadata,'{accepted_required_consents,privacy_policy,version}','"2026-08-30"')
  from consent_signup_fixtures where case_name='valid-email';
insert into consent_signup_fixtures
select 'wrong-type','01410000-0000-4000-8000-000000000007','email',
  pg_catalog.jsonb_set(metadata,'{accepted_required_consents,privacy_policy}','true')
  from consent_signup_fixtures where case_name='valid-email';
insert into consent_signup_fixtures
select 'extra-nested','01410000-0000-4000-8000-000000000008','email',
  pg_catalog.jsonb_set(metadata,'{accepted_required_consents,privacy_policy,unknown}','true')
  from consent_signup_fixtures where case_name='valid-email';
insert into auth.users (id,email,raw_app_meta_data,raw_user_meta_data)
select user_id,case_name||'@consent-regression.invalid',pg_catalog.jsonb_build_object('provider',provider),metadata
from consent_signup_fixtures;

select is((select count(*) from public.user_consents where user_id='01410000-0000-4000-8000-000000000001'
  and accepted and document_version='2026-10-14' and source='signup_metadata'),5::bigint,
  'valid email signup atomically records all five');
select ok(private.has_current_required_consents('01410000-0000-4000-8000-000000000001'),
  'valid email current consent gate passes');
select is((select count(*) from public.user_consents where user_id in
  (select user_id from consent_signup_fixtures where case_name<>'valid-email')),0::bigint,
  'OAuth and invalid metadata record no consent, not partial evidence');
select ok(not private.has_current_required_consents(user_id),case_name||' has no protected consent access')
from consent_signup_fixtures where case_name<>'valid-email';
select is((select count(*) from public.memberships where user_id in (select user_id from consent_signup_fixtures)),0::bigint,
  'metadata cannot create memberships or roles');
select ok(not pg_catalog.has_function_privilege('anon','public.save_my_privacy_preferences_v2(jsonb,boolean,boolean,boolean,boolean)','execute'),
  'anonymous callers cannot record acceptance');

select pg_catalog.set_config('request.jwt.claims','{"sub":"01410000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select private.require_current_consent_actor()$$,'42501',null,
  'OAuth spoof cannot pass protected actor guard');
select throws_ok($$select public.save_my_privacy_preferences_v2('{"privacy_policy":"2026-10-14"}',false,false,false,false)$$,
  '23514','current_required_consents_mismatch','incomplete RPC acceptance rejects');
select public.save_my_privacy_preferences_v2(
  '{"privacy_policy":"2026-10-14","sensitive_information":"2026-10-14","overseas_transfer":"2026-10-14","terms_of_service":"2026-10-14","community_guidelines":"2026-10-14"}',
  false,false,false,false);
select ok(private.has_current_required_consents('01410000-0000-4000-8000-000000000002'),
  'OAuth records consent only through explicit authenticated RPC');
select throws_ok($$select public.update_my_display_name(E'bad\nname')$$,'23514','invalid_display_name',
  'self-service display name rejects control characters');
update public.consent_documents set content_sha256=repeat('0',64)
where document_key='privacy_policy' and version='2026-10-14';
select ok(not private.has_current_required_consents('01410000-0000-4000-8000-000000000001'),
  'hash drift fails closed even with valid five acceptance records');
select throws_ok($$select public.save_my_privacy_preferences_v2(
  '{"privacy_policy":"2026-10-14","sensitive_information":"2026-10-14","overseas_transfer":"2026-10-14","terms_of_service":"2026-10-14","community_guidelines":"2026-10-14"}',
  false,false,false,false)$$,'23514','current_required_consents_mismatch',
  'hash drift prevents recording new consent');
select * from finish();
rollback;
