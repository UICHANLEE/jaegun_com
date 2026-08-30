begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();

select is(
  (
    select count(*)
    from public.consent_documents as document
    join (
      values
        ('privacy_policy'::text, '개인정보 수집·이용 동의'::text, '/legal/privacy/2026-08-30'::text, '5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d'::text),
        ('sensitive_information'::text, '종교 관련 민감정보 처리 동의'::text, '/legal/sensitive/2026-08-30'::text, 'a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b'::text),
        ('overseas_transfer'::text, '개인정보 국외 이전 동의'::text, '/legal/overseas/2026-08-30'::text, '8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684'::text),
        ('terms_of_service'::text, '이용약관 및 만 14세 이상 확인'::text, '/legal/terms/2026-08-30'::text, 'ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9'::text),
        ('community_guidelines'::text, '공동체 운영정책'::text, '/legal/community/2026-08-30'::text, 'e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d'::text)
    ) as expected(document_key, title, document_url, content_sha256)
      on expected.document_key = document.document_key
     and expected.title = document.title
     and expected.document_url = document.document_url
     and expected.content_sha256 = document.content_sha256
    where document.version = '2026-08-30'
      and document.locale = 'ko-KR'
      and document.required
      and document.retired_at is null
  ),
  5::bigint,
  'five active launch documents have exact canonical metadata and hashes'
);

select is(
  (
    select count(*)
    from public.consent_documents
    where version = '2026-08-27'
      and retired_at is not null
      and (
        (document_key = 'privacy_policy' and content_sha256 = '2eeac1f3dbaa45d8b2742aa9239aedf2507d67c02b397a6ac362ef20d9a2f829')
        or (document_key = 'community_guidelines' and content_sha256 = 'c587eae93255d82391ddd287a1737679f9a2823e598dd091fa4cb819eed3c59f')
      )
  ),
  2::bigint,
  'historical consent evidence retains both original hashes'
);

select ok(
  (
    select min(retired_at) = max(retired_at)
      and min(retired_at) = (
        select min(published_at)
        from public.consent_documents
        where version = '2026-08-30'
      )
    from public.consent_documents
    where version = '2026-08-27'
      and document_key in ('privacy_policy', 'community_guidelines')
  )
  and (
    select min(published_at) = max(published_at)
      and min(effective_at) = max(effective_at)
      and min(published_at) = min(effective_at)
    from public.consent_documents
    where version = '2026-08-30'
  ),
  'one runtime transition timestamp retires old and publishes/effects all new rows'
);

select ok(
  not exists (
    select 1
    from pg_catalog.pg_publication as publication
    where publication.pubname = 'supabase_realtime'
      and not publication.puballtables
  )
  or exists (
    select 1
    from pg_catalog.pg_publication_tables as published_table
    where published_table.pubname = 'supabase_realtime'
      and published_table.schemaname = 'public'
      and published_table.tablename = 'consent_documents'
  ),
  'consent document transitions are published to foreground clients when Realtime exists'
);

select ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.save_my_privacy_preferences_v2(jsonb,boolean,boolean,boolean,boolean)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.save_my_privacy_preferences_v2(jsonb,boolean,boolean,boolean,boolean)',
    'execute'
  ),
  'the five-document saver is authenticated-only'
);

insert into auth.users (id, email, raw_user_meta_data)
values
  (
    '01500000-0000-4000-8000-000000000001',
    'exact-five@example.com',
    '{
      "display_name":"정확한 다섯 동의",
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"2026-08-30"},
        "sensitive_information":{"accepted":true,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "terms_of_service":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":true,"version":"2026-08-30"}
      }
    }'::jsonb
  ),
  (
    '01500000-0000-4000-8000-000000000002',
    'missing-key@example.com',
    '{
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"2026-08-30"},
        "sensitive_information":{"accepted":true,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":true,"version":"2026-08-30"}
      }
    }'::jsonb
  ),
  (
    '01500000-0000-4000-8000-000000000003',
    'extra-key@example.com',
    '{
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"2026-08-30"},
        "sensitive_information":{"accepted":true,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "terms_of_service":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":true,"version":"2026-08-30"},
        "unexpected":{"accepted":true,"version":"2026-08-30"}
      }
    }'::jsonb
  ),
  (
    '01500000-0000-4000-8000-000000000004',
    'wrong-version@example.com',
    '{
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"2026-08-27"},
        "sensitive_information":{"accepted":true,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "terms_of_service":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":true,"version":"2026-08-30"}
      }
    }'::jsonb
  ),
  (
    '01500000-0000-4000-8000-000000000005',
    'partial-false@example.com',
    '{
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"2026-08-30"},
        "sensitive_information":{"accepted":false,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "terms_of_service":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":true,"version":"2026-08-30"}
      }
    }'::jsonb
  ),
  (
    '01500000-0000-4000-8000-000000000006',
    'stale-legacy-flat@example.com',
    '{
      "display_name":"구형 앱 두 동의",
      "accepted_privacy":true,
      "accepted_privacy_version":"2026-08-27",
      "accepted_community_policy":true,
      "accepted_community_policy_version":"2026-08-27"
    }'::jsonb
  );

select is(
  (
    select count(*)
    from public.user_consents
    where user_id = '01500000-0000-4000-8000-000000000001'
      and document_version = '2026-08-30'
      and accepted
  ),
  5::bigint,
  'exact nested signup metadata records five separate evidence rows'
);

select is(
  (
    select count(*)
    from public.user_consents
    where user_id in (
      '01500000-0000-4000-8000-000000000002',
      '01500000-0000-4000-8000-000000000003',
      '01500000-0000-4000-8000-000000000004',
      '01500000-0000-4000-8000-000000000005',
      '01500000-0000-4000-8000-000000000006'
    )
  ),
  0::bigint,
  'missing, extra, wrong-version, partial, and stale flat metadata record zero evidence atomically'
);

select ok(
  private.has_current_required_consents('01500000-0000-4000-8000-000000000001'),
  'the exact five signup events open the server gate'
);
select ok(
  not private.has_current_required_consents('01500000-0000-4000-8000-000000000002'),
  'partial signup metadata stays fail closed'
);
select ok(
  not private.has_current_required_consents('01500000-0000-4000-8000-000000000006'),
  'a cached legacy client with two flat 2026-08-27 decisions stays fail closed'
);

update public.consent_documents
set required = false
where document_key = 'terms_of_service' and version = '2026-08-30';
select ok(
  not private.has_current_required_consents('01500000-0000-4000-8000-000000000001'),
  'runtime drift to a four-key active required set fails closed'
);
update public.consent_documents
set required = true
where document_key = 'terms_of_service' and version = '2026-08-30';

select set_config(
  'request.jwt.claims',
  '{"sub":"01500000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', '01500000-0000-4000-8000-000000000002', true);
set local role authenticated;

select is(
  (public.get_my_safety_privacy_state() ->> 'consent_gate_open')::boolean,
  false,
  'state reports a closed gate before current re-consent'
);
select is(
  pg_catalog.jsonb_array_length(
    public.get_my_safety_privacy_state() -> 'required_consents'
  ),
  5,
  'state dynamically exposes five required consent decisions'
);
select is(
  public.get_my_safety_privacy_state() -> 'push_devices',
  '[]'::jsonb,
  'closed-gate state does not return protected push-device data'
);

select throws_ok(
  $$select public.save_my_privacy_preferences(
    '2026-08-30', '2026-08-30', false, false, false, false
  )$$,
  '23514',
  'required_consents_v2_required',
  'legacy two-document saver fails closed after the five-document transition'
);

select throws_ok(
  $$select public.upsert_my_privacy_preferences(
    'church_profile', true, true, '2026-08-30', '2026-08-30'
  )$$,
  '23514',
  'required_consents_v2_required',
  'legacy two-document upsert fails closed after the five-document transition'
);
select ok(
  not exists (
    select 1 from public.privacy_preferences
    where user_id = '01500000-0000-4000-8000-000000000002'
  )
  and not exists (
    select 1 from public.notification_preferences
    where user_id = '01500000-0000-4000-8000-000000000002'
  )
  and not exists (
    select 1 from public.user_consents
    where user_id = '01500000-0000-4000-8000-000000000002'
  ),
  'legacy upsert performs zero consent or preference mutations'
);

select throws_ok(
  $$select public.save_my_privacy_preferences_v2(
    '{"privacy_policy":"2026-08-30"}'::jsonb,
    false, false, false, false
  )$$,
  '23514',
  'current_required_consents_mismatch',
  'partial v2 save input is rejected atomically'
);

select is(
  (
    public.save_my_privacy_preferences_v2(
      '{
        "privacy_policy":"2026-08-30",
        "sensitive_information":"2026-08-30",
        "overseas_transfer":"2026-08-30",
        "terms_of_service":"2026-08-30",
        "community_guidelines":"2026-08-30"
      }'::jsonb,
      false, true, false, false
    ) ->> 'consent_gate_open'
  )::boolean,
  true,
  'exact v2 map records five consents and opens the gate'
);

select is(
  (
    select count(*)
    from public.user_consents
    where user_id = '01500000-0000-4000-8000-000000000002'
      and document_version = '2026-08-30'
      and accepted
  ),
  5::bigint,
  'v2 preference save persists five separate evidence rows'
);

reset role;
select * from finish();
rollback;
