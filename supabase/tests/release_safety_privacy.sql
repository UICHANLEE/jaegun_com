begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
-- The Storage API enables this transaction-local guard only around its own
-- object DELETE statement. pgTAP uses the same guarded SQL path so RLS and our
-- advisory-lock predicates are exercised without bypassing Storage's trigger.
select set_config('storage.allow_delete_query', 'true', true);

select plan(387);

-- Structural release gates -------------------------------------------------
select ok(
  not exists (
    select 1
    from pg_catalog.unnest(array[
      'user_blocks',
      'consent_documents',
      'user_consents',
      'privacy_preferences',
      'notification_preferences',
      'conversation_preferences',
      'push_devices',
      'account_deletion_requests',
      'media_upload_intents',
      'media_scan_records',
      'content_reports',
      'moderation_actions'
    ]) as expected(table_name)
    left join pg_catalog.pg_class as relation
      on relation.oid = pg_catalog.to_regclass('public.' || expected.table_name)
    where relation.oid is null or not relation.relrowsecurity
  ),
  'every release-safety public table exists with RLS enabled'
);

select is(
  (
    select count(*)
    from pg_catalog.pg_constraint as constraint_row
    where constraint_row.conrelid = 'public.conversations'::regclass
      and constraint_row.contype = 'f'
      and constraint_row.confrelid = 'public.profiles'::regclass
  ),
  0::bigint,
  'conversations retain participant UUIDs without profile deletion cascades'
);

select columns_are(
  'public',
  'public_organization_directory',
  array['id', 'slug', 'display_name', 'presbytery', 'status'],
  'anonymous organization directory exposes exactly five approved fields'
);
select ok(
  not pg_catalog.has_table_privilege('anon', 'public.organizations', 'select'),
  'anonymous callers cannot select the private organizations base table'
);
select is(
  (
    select count(*)
    from public.consent_documents as document
    join (
      values
        ('privacy_policy'::text, '/legal/privacy/2026-08-30'::text, '5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d'::text),
        ('sensitive_information'::text, '/legal/sensitive/2026-08-30'::text, 'a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b'::text),
        ('overseas_transfer'::text, '/legal/overseas/2026-08-30'::text, '8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684'::text),
        ('terms_of_service'::text, '/legal/terms/2026-08-30'::text, 'ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9'::text),
        ('community_guidelines'::text, '/legal/community/2026-08-30'::text, 'e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d'::text)
    ) as expected(document_key, document_url, content_sha256)
      on expected.document_key = document.document_key
     and expected.document_url = document.document_url
     and expected.content_sha256 = document.content_sha256
    where document.version = '2026-08-30'
      and document.retired_at is null
      and document.required
      and document.locale = 'ko-KR'
  ),
  5::bigint,
  'the five launch consent documents expose exact canonical versions, URLs, and hashes'
);
select ok(
  (
    select count(*) = 2
      and min(retired_at) = max(retired_at)
      and min(retired_at) = (
        select min(published_at)
        from public.consent_documents
        where version = '2026-08-30'
      )
    from public.consent_documents
    where version = '2026-08-27'
      and document_key in ('privacy_policy', 'community_guidelines')
  ),
  'both prior consent documents retire at the actual five-document transition timestamp'
);
select ok(
  pg_catalog.has_table_privilege('anon', 'public.public_organization_directory', 'select'),
  'anonymous callers can select the minimized directory view'
);
select ok(
  pg_catalog.has_function_privilege('authenticated', 'public.block_user(uuid,text)', 'execute')
  and not pg_catalog.has_function_privilege('anon', 'public.block_user(uuid,text)', 'execute'),
  'block_user is authenticated-only'
);
select ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.save_my_privacy_preferences_v2(jsonb,boolean,boolean,boolean,boolean)',
    'execute'
  ),
  'five-document privacy settings contract is executable by authenticated users'
);
select ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.remove_my_push_device_by_installation(uuid)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.remove_my_push_device_by_installation(uuid)',
    'execute'
  ),
  'installation-scoped push detach is authenticated-only'
);
select ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'public.request_account_deletion_verified(uuid,text,text)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.request_account_deletion_verified(uuid,text,text)',
    'execute'
  ),
  'verified deletion request is service-role-only'
);
select ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'public.create_media_upload_intent(text,uuid,public.media_kind,text,bigint)',
    'execute'
  ),
  'future quarantine/scanner intent creation is dormant in direct-upload mode'
);
select ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'public.service_claim_push_jobs(integer)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.service_claim_media_cleanup_items(integer)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.service_claim_media_scan_intents(integer)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.service_claim_pending_identity_deletions(integer)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.service_claim_media_scan_intents(integer)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.service_record_media_scan(uuid,uuid,text,text,text,bigint,text,boolean,boolean,integer,integer,numeric,text,text)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.service_claim_pending_identity_deletions(integer)',
    'execute'
  ),
  'push, scan, and Storage cleanup worker contracts are service-only'
);
select is(
  pg_catalog.to_regprocedure(
    'public.service_record_media_scan(uuid,text,text,text,bigint,text,boolean,boolean,integer,integer,numeric,text,text)'
  ),
  null::regprocedure,
  'unfenced legacy media scan completion signature does not exist'
);
select is(
  (
    select count(*)
    from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname in (
        'jaegun_community_media_insert',
        'jaegun_community_media_delete',
        'jaegun_avatars_insert',
        'jaegun_avatars_delete'
      )
  ),
  4::bigint,
  'direct compatibility keeps bounded INSERT/DELETE while blocking overwrite quota bypasses'
);
select ok(
  (
    select bool_and(
      coalesce(with_check, qual, '') like '%authorize_direct_media_upload%'
      or coalesce(with_check, qual, '') like '%can_mutate_direct_media_object%'
    )
    from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname in (
        'jaegun_community_media_insert',
        'jaegun_community_media_delete',
        'jaegun_avatars_insert',
        'jaegun_avatars_delete'
      )
  ),
  'direct Storage policies reserve scanner paths and protect referenced objects'
);
select ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'private.require_owned_media_object(text,text,uuid,public.media_kind,text,bigint)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'private.media_object_path_metadata_allowed(text,text,jsonb)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'private.can_write_direct_media_object(text,text,uuid)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated',
    'private.authorize_direct_media_upload(text,text,uuid,jsonb)',
    'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated',
    'private.can_mutate_direct_media_object(text,text,uuid)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'private.authorize_direct_media_upload(text,text,uuid,jsonb)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'private.can_mutate_direct_media_object(text,text,uuid)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'private.can_write_quarantine_media(text,uuid,jsonb)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'private.lock_active_media_uploader(uuid)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'private.direct_media_path_attachable(text,text)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'private.media_path_is_referenced(text,text)',
    'execute'
  ),
  'only authenticated Storage policy entrypoints are executable; internal media helpers remain private'
);
select ok(
  (
    select bool_and(qual like '%owner_id%')
    from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'jaegun_avatars_delete'
  ),
  'avatar deletion requires exact Storage owner_id'
);
select is(
  (
    select count(*)
    from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and cmd = 'UPDATE'
      and policyname in ('jaegun_community_media_update', 'jaegun_avatars_update')
  ),
  0::bigint,
  'authenticated approved-bucket overwrite is disabled to prevent byte-quota inflation'
);
select ok(
  pg_catalog.to_regclass('public.profiles_avatar_path_lookup_idx') is not null
  and pg_catalog.to_regclass('public.messages_media_path_lookup_idx') is not null
  and pg_catalog.to_regclass('public.membership_applications_evidence_path_lookup_idx') is not null
  and pg_catalog.to_regclass('public.organizations_hero_path_lookup_idx') is not null,
  'every media reference checked by cleanup has a bounded lookup index'
);
select ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'private.retained_media_bytes_for_user(uuid)'::regprocedure
    ),
    'direct_media_upload_reservations'
  ) > 0
  and pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'private.retained_media_bytes_for_organization(uuid)'::regprocedure
    ),
    'direct_media_upload_reservations'
  ) > 0,
  'pending direct-upload reservations participate in user and organization retained quotas'
);
select ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'private.require_owned_media_object(text,text,uuid,public.media_kind,text,bigint)'::regprocedure
    ),
    'pg_advisory_xact_lock'
  ) > 0
  and pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'private.can_mutate_direct_media_object(text,text,uuid)'::regprocedure
    ),
    'pg_advisory_xact_lock'
  ) > 0,
  'attachment and Storage mutation serialize on the same object-path advisory lock'
);
select is(
  (
    select count(*)
    from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname in (
        'jaegun_quarantine_media_insert',
        'jaegun_quarantine_media_update',
        'jaegun_quarantine_media_delete'
      )
  ),
  3::bigint,
  'quarantine bucket has the three intent-scoped client policies'
);

-- Users, organizations, content, and pre-block DM history ------------------
insert into auth.users (id, email, raw_user_meta_data)
values
  (
    'a1100000-0000-4000-8000-000000000001',
    'release-admin@example.com',
    '{"display_name":"플랫폼관리자"}'::jsonb
  ),
  (
    'b1100000-0000-4000-8000-000000000001',
    'release-alice@example.com',
    '{"display_name":"앨리스"}'::jsonb
  ),
  (
    'c1100000-0000-4000-8000-000000000001',
    'release-bob@example.com',
    '{"display_name":"밥"}'::jsonb
  ),
  (
    'd1100000-0000-4000-8000-000000000001',
    'release-moderator@example.com',
    '{"display_name":"교회 사역자"}'::jsonb
  ),
  (
    'e1100000-0000-4000-8000-000000000001',
    'release-other-executive@example.com',
    '{"display_name":"다른 교회 임원"}'::jsonb
  ),
  (
    'a1200000-0000-4000-8000-000000000001',
    'release-deletion@example.com',
    '{"display_name":"탈퇴 예정 사역자"}'::jsonb
  ),
  (
    'b1200000-0000-4000-8000-000000000001',
    'release-consent-good@example.com',
    '{
      "display_name":"동의 완료 회원",
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"2026-08-30"},
        "sensitive_information":{"accepted":true,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "terms_of_service":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":true,"version":"2026-08-30"}
      },
      "accepted_at":"1900-01-01T00:00:00Z"
    }'::jsonb
  ),
  (
    'c1200000-0000-4000-8000-000000000001',
    'release-consent-bad@example.com',
    '{
      "display_name":"동의 미완료 회원",
      "consent_contract":"required-consents-v2",
      "accepted_required_consents":{
        "privacy_policy":{"accepted":true,"version":"forged-future-version"},
        "sensitive_information":{"accepted":true,"version":"2026-08-30"},
        "overseas_transfer":{"accepted":true,"version":"2026-08-30"},
        "terms_of_service":{"accepted":true,"version":"2026-08-30"},
        "community_guidelines":{"accepted":false,"version":"2026-08-30"}
      }
    }'::jsonb
  );

select is(
  (
    select count(*) from public.user_consents
    where user_id = 'b1200000-0000-4000-8000-000000000001'
      and accepted
      and source = 'signup_metadata'
  ),
  5::bigint,
  'signup metadata records all five exact active document versions'
);
select is(
  (
    select count(*) from public.user_consents
    where user_id = 'c1200000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'wrong versions or false booleans leave the signup consent gate closed'
);
select ok(
  (
    select min(recorded_at) > '2026-01-01'::timestamptz
    from public.user_consents
    where user_id = 'b1200000-0000-4000-8000-000000000001'
  ),
  'client-supplied consent timestamps are ignored in favor of server time'
);

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source
)
select profile.id, document.document_key, document.version, true, 'admin_migration'
from public.profiles as profile
cross join public.consent_documents as document
where profile.id in (
    'a1100000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    'c1100000-0000-4000-8000-000000000001',
    'd1100000-0000-4000-8000-000000000001',
    'e1100000-0000-4000-8000-000000000001',
    'a1200000-0000-4000-8000-000000000001'
  )
  and document.required
  and document.retired_at is null
  and document.published_at <= pg_catalog.statement_timestamp()
  and document.effective_at <= pg_catalog.statement_timestamp();

update public.organizations
set status = 'active'
where slug in ('jaegun-bupyeong', 'jaegun-namseoul');

insert into public.platform_admins (user_id, note)
values ('a1100000-0000-4000-8000-000000000001', 'release safety pgTAP');

insert into public.organization_memberships (user_id, organization_id, role)
values
  (
    'b1100000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member'
  ),
  (
    'c1100000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'member'
  ),
  (
    'd1100000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'minister'
  ),
  (
    'a1200000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'minister'
  ),
  (
    'e1100000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-namseoul'),
    'executive'
  );

select set_config(
  'test.release_service_year',
  private.current_service_year()::text,
  true
);

insert into public.boards (
  id, organization_id, slug, name, description, created_by
)
values (
  '90000000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'release-safety-board',
  '출시 안전 테스트',
  'pgTAP 전용 게시판',
  'd1100000-0000-4000-8000-000000000001'
);

insert into public.posts (
  id, organization_id, board_id, author_id, title, body, status, published_at
)
values
  (
    '91000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    '90000000-0000-4000-8000-000000000001',
    'c1100000-0000-4000-8000-000000000001',
    '밥의 게시글',
    '차단 가시성과 신고 증거를 검증하는 게시글입니다.',
    'published',
    pg_catalog.clock_timestamp()
  ),
  (
    '91000000-0000-4000-8000-000000000002',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    '90000000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    '앨리스의 초안',
    '미디어 승인 테스트 초안입니다.',
    'draft',
    null
  ),
  (
    '91000000-0000-4000-8000-000000000003',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    '90000000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    '앨리스의 게시글',
    '반대 방향 가시성을 검증합니다.',
    'published',
    pg_catalog.clock_timestamp()
  ),
  (
    '91000000-0000-4000-8000-000000000004',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    '90000000-0000-4000-8000-000000000001',
    'a1200000-0000-4000-8000-000000000001',
    '삭제 예정 게시글',
    '계정 삭제 시 서버가 tombstone 처리합니다.',
    'published',
    pg_catalog.clock_timestamp()
  );

insert into public.comments (id, post_id, author_id, body)
values (
  '92000000-0000-4000-8000-000000000001',
  '91000000-0000-4000-8000-000000000001',
  'c1100000-0000-4000-8000-000000000001',
  '밥의 댓글입니다.'
);

insert into public.conversations (
  id, organization_id, participant_low, participant_high, created_by
)
values
  (
    '93000000-0000-4000-8000-000000000001',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'b1100000-0000-4000-8000-000000000001',
    'c1100000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001'
  ),
  (
    '93000000-0000-4000-8000-000000000002',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'a1200000-0000-4000-8000-000000000001',
    'c1100000-0000-4000-8000-000000000001',
    'a1200000-0000-4000-8000-000000000001'
  );

insert into public.conversation_reads (conversation_id, user_id)
values
  ('93000000-0000-4000-8000-000000000001', 'b1100000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000001', 'c1100000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000002', 'a1200000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000002', 'c1100000-0000-4000-8000-000000000001');

insert into public.messages (
  id, conversation_id, sender_id, kind, body, client_nonce
)
values
  (
    '94000000-0000-4000-8000-000000000001',
    '93000000-0000-4000-8000-000000000001',
    'c1100000-0000-4000-8000-000000000001',
    'text',
    '차단 전 밥의 메시지',
    '94100000-0000-4000-8000-000000000001'
  ),
  (
    '94000000-0000-4000-8000-000000000002',
    '93000000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    'text',
    '차단 전 앨리스의 메시지',
    '94100000-0000-4000-8000-000000000002'
  ),
  (
    '94000000-0000-4000-8000-000000000003',
    '93000000-0000-4000-8000-000000000002',
    'a1200000-0000-4000-8000-000000000001',
    'text',
    '탈퇴 전에 남긴 보존 대상 대화',
    '94100000-0000-4000-8000-000000000003'
  );

-- Anonymous callers can read only the view after organizations become active.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role anon;
select ok(
  exists (
    select 1 from public.public_organization_directory
    where slug = 'jaegun-bupyeong'
  ),
  'anonymous signup can discover an active church through the safe view'
);
select throws_ok(
  'select * from public.organizations limit 1',
  '42501',
  'permission denied for table organizations',
  'anonymous signup cannot bypass the safe directory through the base table'
);

-- Legacy message batch must inherit approved-media and rate-limit enforcement.
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;

select throws_ok(
  format(
    'select public.send_message_batch(%L, %L, %L::jsonb)',
    '93000000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'kind', 'image',
        'body', null,
        'media_path',
          (select id::text from public.organizations where slug = 'jaegun-bupyeong')
          || '/messages/93000000-0000-4000-8000-000000000001/forged.jpg',
        'media_metadata', '{}'::jsonb,
        'client_nonce', '94200000-0000-4000-8000-000000000001'
      )
    )::text
  ),
  '42501',
  'direct_media_object_required',
  'legacy send_message_batch rejects a forged or missing direct object path'
);

select throws_ok(
  $$
    select public.send_message_batch(
      '93000000-0000-4000-8000-000000000001',
      'b1100000-0000-4000-8000-000000000001',
      '[
        {"kind":"text","body":"1","media_path":null,"media_metadata":{},"client_nonce":"94300000-0000-4000-8000-000000000001"},
        {"kind":"text","body":"2","media_path":null,"media_metadata":{},"client_nonce":"94300000-0000-4000-8000-000000000002"},
        {"kind":"text","body":"3","media_path":null,"media_metadata":{},"client_nonce":"94300000-0000-4000-8000-000000000003"},
        {"kind":"text","body":"4","media_path":null,"media_metadata":{},"client_nonce":"94300000-0000-4000-8000-000000000004"},
        {"kind":"text","body":"5","media_path":null,"media_metadata":{},"client_nonce":"94300000-0000-4000-8000-000000000005"}
      ]'::jsonb
    )
  $$,
  '22023',
  'message_batch_size_out_of_range',
  'legacy send_message_batch rejects more than four items atomically'
);

select throws_ok(
  $$
    insert into public.post_media (
      post_id, uploader_id, storage_path, kind, mime_type, byte_size, width, height
    ) values (
      '91000000-0000-4000-8000-000000000002',
      'b1100000-0000-4000-8000-000000000001',
      'forged/post.jpg',
      'image',
      'image/jpeg',
      100,
      10,
      10
    )
  $$,
  '42501',
  'direct_media_object_required',
  'post media rows require an exact owned Storage object or approved intent'
);

-- Direct media compatibility keeps current uploads working without trusting
-- caller paths or metadata. Scanner intents remain a separate strict path.
reset role;
create temporary table test_direct_media_paths (
  label text primary key,
  bucket_id text not null,
  storage_path text not null,
  mime_type text not null,
  byte_size bigint not null
);
grant select on table test_direct_media_paths to authenticated, service_role;
insert into test_direct_media_paths
select 'post', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000001.jpg',
       'image/jpeg', 1024
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'message', 'community-media',
       organization.id::text || '/messages/93000000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000002.mp4',
       'video/mp4', 2048
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'avatar', 'avatars',
       'b1100000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000003.jpg',
       'image/jpeg', 512
union all
select 'evidence', 'community-media',
       organization.id::text || '/applications/95000000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000004.png',
       'image/png', 768
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'hero', 'community-media',
       organization.id::text || '/organization/95100000-0000-4000-8000-000000000005.webp',
       'image/webp', 1536
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'foreign_message', 'community-media',
       organization.id::text || '/messages/93000000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000006.jpg',
       'image/jpeg', 640
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'foreign_post', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000097.jpg',
       'image/jpeg', 640
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'target_post', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000096.jpg',
       'image/jpeg', 640
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'owner_mismatch', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000090.jpg',
       'image/jpeg', 640
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'legacy_mismatch', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000098.png',
       'image/jpeg', 640
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'orphan', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000007.webp',
       'image/webp', 384
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'reuse', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000008.jpg',
       'image/jpeg', 256
from public.organizations as organization where organization.slug = 'jaegun-bupyeong'
union all
select 'fresh_after_delete', 'community-media',
       organization.id::text || '/posts/91000000-0000-4000-8000-000000000002/95100000-0000-4000-8000-000000000009.jpg',
       'image/jpeg', 256
from public.organizations as organization where organization.slug = 'jaegun-bupyeong';

insert into public.membership_applications (
  id, user_id, organization_id, requested_role, applicant_note
)
values (
  '95000000-0000-4000-8000-000000000001',
  'b1100000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'member',
  '직접 업로드 증빙 테스트'
);

-- Seed an exact-path object owned by the other participant. Alice may access
-- the conversation, but may never adopt Bob's bytes into her message.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  path.bucket_id,
  path.storage_path,
  'c1100000-0000-4000-8000-000000000001'::uuid,
  'c1100000-0000-4000-8000-000000000001',
  pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
from test_direct_media_paths as path
where path.label in ('foreign_message', 'foreign_post', 'target_post');

-- owner_id is authoritative when present. A corrupted/malicious row whose
-- legacy owner UUID disagrees is owned by neither identity for product flows.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  path.bucket_id,
  path.storage_path,
  'b1100000-0000-4000-8000-000000000001'::uuid,
  'c1100000-0000-4000-8000-000000000001',
  pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
from test_direct_media_paths as path
where path.label = 'owner_mismatch';

-- A pre-011 canonical UUID path may carry an original-filename suffix that
-- disagrees with Storage MIME. It cannot be newly uploaded after 011, but an
-- exact owner object already present at migration time remains attachable.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  path.bucket_id,
  path.storage_path,
  'b1100000-0000-4000-8000-000000000001'::uuid,
  'b1100000-0000-4000-8000-000000000001',
  pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
from test_direct_media_paths as path
where path.label = 'legacy_mismatch';

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;

select is(
  private.authorize_direct_media_upload(
    'avatars',
    'c1100000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000099.jpg',
    'c1100000-0000-4000-8000-000000000001',
    '{"mimetype":"image/jpeg","size":"128"}'::jsonb
  ),
  false,
  'Storage policy helper rejects a caller-supplied victim actor before locking or reserving'
);
reset role;
select ok(
  not exists (
    select 1
    from private.direct_media_upload_reservations as reservation
    where reservation.storage_path =
      'c1100000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000099.jpg'
  )
  and not exists (
    select 1
    from private.rate_limit_counters as counter
    where counter.actor_id = 'c1100000-0000-4000-8000-000000000001'
      and counter.action_key = 'uploads'
  ),
  'cross-user helper call cannot burn victim quota or rate allowance'
);
set local role authenticated;

select is(
  private.authorize_direct_media_upload(
    'community-media',
    (select storage_path from test_direct_media_paths where label = 'legacy_mismatch'),
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"640"}'::jsonb
  ),
  false,
  'new direct upload rejects a canonical legacy path whose MIME and suffix disagree'
);
select lives_ok(
  $$
    insert into public.post_media (
      post_id, uploader_id, storage_path, kind, mime_type, byte_size, width, height
    )
    select
      '91000000-0000-4000-8000-000000000002',
      auth.uid(),
      path.storage_path,
      'image',
      path.mime_type,
      path.byte_size,
      20,
      20
    from test_direct_media_paths as path
    where path.label = 'legacy_mismatch'
  $$,
  'pre-011 canonical owner object attaches using authoritative Storage MIME despite suffix mismatch'
);

select lives_ok(
  $$
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    select
      path.bucket_id,
      path.storage_path,
      auth.uid(),
      auth.uid()::text,
      pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
    from test_direct_media_paths as path
    where path.label in ('post', 'message', 'avatar', 'evidence', 'orphan')
  $$,
  'legacy client can directly upload exact owned post/message/avatar/evidence objects'
);
select lives_ok(
  $$
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    select
      path.bucket_id,
      path.storage_path,
      auth.uid(),
      auth.uid()::text,
      pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
    from test_direct_media_paths as path
    where path.label = 'reuse'
  $$,
  'direct upload creates a single-use reservation for its UUID path'
);
reset role;
create temporary table test_retained_bytes_before_delete (value bigint);
insert into test_retained_bytes_before_delete
values (private.retained_media_bytes_for_user('b1100000-0000-4000-8000-000000000001'));
set local role authenticated;
with removed as (
  delete from storage.objects as object
  using test_direct_media_paths as path
  where path.label = 'reuse'
    and object.bucket_id = path.bucket_id
    and object.name = path.storage_path
  returning object.id
)
select is(
  (select count(*) from removed),
  1::bigint,
  'unreferenced direct object can be deleted by its exact owner'
);
reset role;
select is(
  (select value from test_retained_bytes_before_delete)
    - private.retained_media_bytes_for_user('b1100000-0000-4000-8000-000000000001'),
  256::bigint,
  'deleting direct bytes releases retained-byte quota while daily history remains'
);
set local role authenticated;
select throws_ok(
  $$
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    select
      path.bucket_id,
      path.storage_path,
      auth.uid(),
      auth.uid()::text,
      pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
    from test_direct_media_paths as path
    where path.label = 'reuse'
  $$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'a committed direct UUID path cannot be recycled after deletion'
);
select lives_ok(
  $$
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    select
      path.bucket_id,
      path.storage_path,
      auth.uid(),
      auth.uid()::text,
      pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
    from test_direct_media_paths as path
    where path.label = 'fresh_after_delete'
  $$,
  'a fresh UUID upload succeeds after deleted bytes release retained quota'
);
select lives_ok(
  $$
    insert into public.post_media (
      post_id, uploader_id, storage_path, kind, mime_type, byte_size, width, height
    )
    select
      '91000000-0000-4000-8000-000000000002',
      auth.uid(),
      path.storage_path,
      'image',
      path.mime_type,
      path.byte_size,
      32,
      32
    from test_direct_media_paths as path
    where path.label = 'post'
  $$,
  'direct post object attaches without a scanner intent'
);
with changed as (
  update storage.objects as object
  set metadata = object.metadata || '{"cacheControl":"changed"}'::jsonb
  from test_direct_media_paths as path
  where path.label = 'post'
    and object.bucket_id = path.bucket_id
    and object.name = path.storage_path
  returning object.id
)
select is(
  (select count(*) from changed),
  0::bigint,
  'referenced post bytes cannot be overwritten through direct Storage policy'
);
with removed as (
  delete from storage.objects as object
  using test_direct_media_paths as path
  where path.label = 'post'
    and object.bucket_id = path.bucket_id
    and object.name = path.storage_path
  returning object.id
)
select is(
  (select count(*) from removed),
  0::bigint,
  'referenced post bytes cannot be deleted through direct Storage policy'
);
select lives_ok(
  format(
    'select public.send_message_batch(%L, %L, %L::jsonb)',
    '93000000-0000-4000-8000-000000000001',
    auth.uid(),
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'kind', 'video',
        'body', null,
        'media_path', (select storage_path from test_direct_media_paths where label = 'message'),
        'media_metadata', pg_catalog.jsonb_build_object(
          'mime_type', 'image/png',
          'byte_size', 1,
          'scan_approved', true,
          'upload_intent_id', gen_random_uuid()
        ),
        'client_nonce', '95200000-0000-4000-8000-000000000001'
      )
    )::text
  ),
  'legacy message batch attaches an exact uploader-owned direct object'
);
select is(
  (
    select (message.media_metadata ->> 'mime_type')
      || ':' || (message.media_metadata ->> 'byte_size')
      || ':' || (message.media_metadata ->> 'scan_approved')
      || ':' || (message.media_metadata ->> 'legacy_direct')
    from public.messages as message
    where message.client_nonce = '95200000-0000-4000-8000-000000000001'
  ),
  'video/mp4:2048:false:true',
  'direct message metadata is authoritative from Storage and never marked scanned'
);
select throws_ok(
  format(
    'select public.send_message(%L, ''image'', null, %L, ''{}''::jsonb, %L)',
    '93000000-0000-4000-8000-000000000001',
    (select storage_path from test_direct_media_paths where label = 'foreign_message'),
    '95200000-0000-4000-8000-000000000002'
  ),
  '42501',
  'direct_media_object_required',
  'conversation access cannot adopt another participant direct object'
);
select throws_ok(
  $$
    insert into public.post_media (
      post_id, uploader_id, storage_path, kind, mime_type, byte_size
    )
    select
      '91000000-0000-4000-8000-000000000002',
      auth.uid(),
      path.storage_path,
      'image',
      path.mime_type,
      path.byte_size
    from test_direct_media_paths as path
    where path.label = 'owner_mismatch'
  $$,
  '42501',
  'direct_media_object_required',
  'legacy owner and owner_id disagreement cannot be attached by owner UUID'
);
with removed as (
  delete from storage.objects as object
  using test_direct_media_paths as path
  where path.label = 'owner_mismatch'
    and object.bucket_id = path.bucket_id
    and object.name = path.storage_path
  returning object.id
)
select is(
  (select count(*) from removed),
  0::bigint,
  'legacy owner and owner_id disagreement cannot be deleted by owner UUID'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"c1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'c1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
with removed as (
  delete from storage.objects as object
  using test_direct_media_paths as path
  where path.label = 'owner_mismatch'
    and object.bucket_id = path.bucket_id
    and object.name = path.storage_path
  returning object.id
)
select is(
  (select count(*) from removed),
  0::bigint,
  'legacy owner and owner_id disagreement cannot be deleted by owner_id identity'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select lives_ok(
  $$
    update public.profiles
    set avatar_path = (select storage_path from test_direct_media_paths where label = 'avatar')
    where id = auth.uid()
  $$,
  'direct avatar object links to the uploader profile'
);
select lives_ok(
  $$
    select public.set_membership_application_evidence(
      '95000000-0000-4000-8000-000000000001',
      (select storage_path from test_direct_media_paths where label = 'evidence')
    )
  $$,
  'direct image evidence links through the existing application RPC'
);
select is(
  private.authorize_direct_media_upload(
    'community-media',
    pg_catalog.replace(
      (select storage_path from test_direct_media_paths where label = 'evidence'),
      '95100000-0000-4000-8000-000000000004.png',
      '95100000-0000-4000-8000-000000000094.mp4'
    ),
    auth.uid(),
    '{"mimetype":"video/mp4","size":"2048"}'::jsonb
  ),
  false,
  'application evidence rejects video before direct upload can create an orphan'
);
select is(
  private.authorize_direct_media_upload(
    'avatars',
    auth.uid()::text || '/95100000-0000-4000-8000-000000000095.mp4',
    auth.uid(),
    '{"mimetype":"video/mp4","size":"2048"}'::jsonb
  ),
  false,
  'avatar rejects video before direct upload can create an orphan'
);

-- Internal shape/metadata helpers are deliberately revoked from browser roles;
-- inspect their pure predicates as the migration owner.
reset role;
select is(
  private.can_write_direct_media_object(
    'community-media',
    (select storage_path from test_direct_media_paths where label = 'post')
      || '/95100000-0000-4000-8000-000000000099.jpg',
    auth.uid()
  ),
  false,
  'nested direct object paths are rejected'
);
select is(
  private.can_write_direct_media_object(
    'community-media',
    pg_catalog.replace(
      (select storage_path from test_direct_media_paths where label = 'post'),
      '.jpg',
      '.extra.jpg'
    ),
    auth.uid()
  ),
  false,
  'direct object leaf permits one UUID and exactly one extension dot'
);
select is(
  private.media_object_path_metadata_allowed(
    'community-media',
    (select storage_path from test_direct_media_paths where label = 'post'),
    '{"mimetype":"image/png","size":1024}'::jsonb
  ),
  false,
  'MIME and filename extension must match exactly'
);
select is(
  private.media_object_path_metadata_allowed(
    'community-media',
    (select storage_path from test_direct_media_paths where label = 'post'),
    '{"mimetype":"image/jpeg","size":15728641}'::jsonb
  ),
  false,
  'direct image metadata cannot exceed the production size ceiling'
);

set local role authenticated;
select is(
  private.can_mutate_direct_media_object(
    'community-media',
    (select storage_path from test_direct_media_paths where label = 'orphan'),
    auth.uid()
  ),
  true,
  'uploader may clean an exact unreferenced direct object'
);

reset role;
delete from private.rate_limit_counters
where actor_id = 'b1100000-0000-4000-8000-000000000001'
  and action_key = 'messages';
select set_config(
  'request.jwt.claims',
  '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  private.authorize_direct_media_upload(
    'community-media',
    pg_catalog.replace(
      (select storage_path from test_direct_media_paths where label = 'hero'),
      '95100000-0000-4000-8000-000000000005.webp',
      '95100000-0000-4000-8000-000000000096.mp4'
    ),
    auth.uid(),
    '{"mimetype":"video/mp4","size":"2048"}'::jsonb
  ),
  false,
  'organization hero rejects video before direct upload can create an orphan'
);
select lives_ok(
  $$
    insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
    select
      path.bucket_id,
      path.storage_path,
      auth.uid(),
      auth.uid()::text,
      pg_catalog.jsonb_build_object('mimetype', path.mime_type, 'size', path.byte_size)
    from test_direct_media_paths as path
    where path.label = 'hero'
  $$,
  'church manager can directly upload an exact organization hero image'
);
select lives_ok(
  $$
    select public.update_organization_profile(
      (select id from public.organizations where slug = 'jaegun-bupyeong'),
      pg_catalog.jsonb_build_object(
        'hero_path', (select storage_path from test_direct_media_paths where label = 'hero')
      )
    )
  $$,
  'direct organization hero links through the existing profile RPC'
);

reset role;
with generated as materialized (
  select series.n, gen_random_uuid() as intent_id
  from pg_catalog.generate_series(1, 119) as series(n)
)
insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status, rejection_code, expires_at
)
select
  generated.intent_id,
  'b1200000-0000-4000-8000-000000000001',
  null,
  'avatar',
  'b1200000-0000-4000-8000-000000000001',
  'image',
  'image/jpeg',
  1,
  'b1200000-0000-4000-8000-000000000001/' || generated.intent_id::text || '/upload.jpg',
  'avatars',
  'b1200000-0000-4000-8000-000000000001/' || generated.intent_id::text || '.jpg',
  'expired',
  'quota_regression_fixture',
  pg_catalog.clock_timestamp() + interval '1 hour'
from generated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b1200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  private.authorize_direct_media_upload(
    'avatars',
    'b1200000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000100.jpg',
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"1"}'::jsonb
  ),
  true,
  '119 expired scanner intents still allow only the final shared daily upload slot'
);
reset role;
select is(
  private.retained_media_bytes_for_user(
    'b1200000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'an unmaterialized direct reservation consumes retained user quota during its retry lease'
);
set local role authenticated;
select throws_ok(
  $$
    select private.authorize_direct_media_upload(
      'avatars',
      'b1200000-0000-4000-8000-000000000001/95100000-0000-4000-8000-000000000101.jpg',
      auth.uid(),
      '{"mimetype":"image/jpeg","size":"1"}'::jsonb
    )
  $$,
  '54000',
  'daily_media_upload_count_exceeded',
  'direct and scanner modes share a 120-per-day upload ceiling across terminal statuses'
);
reset role;
delete from public.media_upload_intents
where uploader_id = 'b1200000-0000-4000-8000-000000000001'
  and rejection_code = 'quota_regression_fixture';
delete from private.direct_media_upload_reservations
where uploader_id = 'b1200000-0000-4000-8000-000000000001';
delete from private.rate_limit_counters
where actor_id = 'b1200000-0000-4000-8000-000000000001'
  and action_key = 'uploads';

insert into private.rate_limit_counters (
  actor_id, action_key, window_started_at, event_count
)
values (
  'b1100000-0000-4000-8000-000000000001',
  'messages',
  pg_catalog.clock_timestamp(),
  60
);
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_ok(
  $$
    select public.send_message_batch(
      '93000000-0000-4000-8000-000000000001',
      'b1100000-0000-4000-8000-000000000001',
      '[{"kind":"text","body":"rate","media_path":null,"media_metadata":{},"client_nonce":"94400000-0000-4000-8000-000000000001"}]'::jsonb
    )
  $$,
  'P0001',
  'rate_limit_exceeded:messages',
  'legacy send_message_batch cannot bypass the server message rate limit'
);
reset role;
delete from private.rate_limit_counters
where actor_id = 'b1100000-0000-4000-8000-000000000001'
  and action_key = 'messages';

-- Bidirectional DM boundary plus one-way ordinary-content hiding ------------
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (public.block_user('c1100000-0000-4000-8000-000000000001', '테스트 차단') ->> 'blocked_user_id')::uuid,
  'c1100000-0000-4000-8000-000000000001'::uuid,
  'block_user records only auth.uid as blocker'
);
select throws_ok(
  $$select public.create_content_report(
    'profile',
    'c1100000-0000-4000-8000-000000000001',
    'harassment',
    'blocked profile replay probe'
  )$$,
  '42501',
  'report_target_not_accessible',
  'a blocked profile cannot be probed through an existing report replay'
);
select throws_ok(
  $$select public.create_content_report(
    'profile',
    'a1100000-0000-4000-8000-000000000001',
    'privacy',
    'foreign profile probe'
  )$$,
  '42501',
  'report_target_not_accessible',
  'a current foreign profile returns the same inaccessible report response'
);
select throws_ok(
  $$select public.get_or_create_conversation('c1100000-0000-4000-8000-000000000001')$$,
  '42501',
  'conversation_target_unavailable',
  'blocker cannot create or reopen a direct conversation'
);
select throws_ok(
  $$select public.get_or_create_conversation('a1100000-0000-4000-8000-000000000001')$$,
  '42501',
  'conversation_target_unavailable',
  'a current foreign target returns the same conversation eligibility error'
);
select throws_ok(
  $$select public.get_or_create_conversation('97000000-0000-4000-8000-000000000299')$$,
  '42501',
  'conversation_target_unavailable',
  'an unknown target returns the same conversation eligibility error'
);
select throws_ok(
  $$
    select public.send_message(
      '93000000-0000-4000-8000-000000000001',
      'text',
      '차단 후 메시지',
      null,
      '{}'::jsonb,
      '94500000-0000-4000-8000-000000000001'
    )
  $$,
  '42501',
  'user_block_boundary',
  'blocker cannot send into an existing direct conversation'
);
select is(
  (
    select count(*)
    from public.list_visible_profiles(
      array['c1100000-0000-4000-8000-000000000001'::uuid]
    )
  ),
  0::bigint,
  'blocker no longer sees the blocked profile in ordinary member views'
);
select is(
  (select count(*) from public.posts where id = '91000000-0000-4000-8000-000000000001'),
  0::bigint,
  'blocker no longer sees blocked-user posts'
);
select is(
  (select count(*) from public.comments where id = '92000000-0000-4000-8000-000000000001'),
  0::bigint,
  'blocker no longer sees blocked-user comments'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"c1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'c1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_ok(
  $$select public.get_or_create_conversation('b1100000-0000-4000-8000-000000000001')$$,
  '42501',
  'conversation_target_unavailable',
  'blocked user is also prevented from creating a direct conversation'
);
select throws_ok(
  $$
    select public.send_message(
      '93000000-0000-4000-8000-000000000001',
      'text',
      '반대 방향 차단 후 메시지',
      null,
      '{}'::jsonb,
      '94500000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'user_block_boundary',
  'blocked user cannot send into the existing conversation either'
);
select is(
  (
    select count(*)
    from public.list_visible_profiles(
      array['b1100000-0000-4000-8000-000000000001'::uuid]
    )
  ),
  1::bigint,
  'blocked user view is not silently altered by another user blocking them'
);
select is(
  (select count(*) from public.posts where id = '91000000-0000-4000-8000-000000000003'),
  1::bigint,
  'blocked user still sees blocker ordinary content'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (select count(*) from public.posts where id = '91000000-0000-4000-8000-000000000001'),
  1::bigint,
  'exact-scope moderator retains evidence visibility despite a reporter block'
);

reset role;
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000001',
  'b1100000-0000-4000-8000-000000000001',
  'new_message',
  '차단된 발신자 알림',
  '노출되면 안 됩니다.',
  'conversation',
  '93000000-0000-4000-8000-000000000001',
  '{"message_id":"94000000-0000-4000-8000-000000000001"}'::jsonb
);
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000002',
  'c1100000-0000-4000-8000-000000000001',
  'new_message',
  '반대 방향 알림',
  '차단하지 않은 수신자는 유지됩니다.',
  'conversation',
  '93000000-0000-4000-8000-000000000001',
  '{"message_id":"94000000-0000-4000-8000-000000000002"}'::jsonb
);
select is(
  (select count(*) from public.notifications where id = '95000000-0000-4000-8000-000000000001'),
  0::bigint,
  'blocker does not receive notifications sourced from the blocked user'
);
select is(
  (select count(*) from public.notifications where id = '95000000-0000-4000-8000-000000000002'),
  1::bigint,
  'one-way notification suppression does not alter the blocked user inbox'
);

-- Versioned preferences, self-only RLS, mute state, and report idempotency --
insert into public.user_consents (
  user_id, document_key, document_version, accepted, source
)
values
  (
    'b1100000-0000-4000-8000-000000000001',
    'privacy_policy',
    '2026-08-27',
    true,
    'admin_migration'
  ),
  (
    'b1100000-0000-4000-8000-000000000001',
    'community_guidelines',
    '2026-08-27',
    true,
    'admin_migration'
  );

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source, withdrawn_at
)
values (
  'b1100000-0000-4000-8000-000000000001',
  'privacy_policy',
  '2026-08-30',
  false,
  'app',
  pg_catalog.clock_timestamp()
);

select ok(
  exists (
    select 1
    from storage.objects as object
    join test_direct_media_paths as path
      on path.bucket_id = object.bucket_id
     and path.storage_path = object.name
    where path.label = 'fresh_after_delete'
      and object.owner_id = 'b1100000-0000-4000-8000-000000000001'
  ),
  'closed-gate Storage attack fixture exists before the authenticated attempt'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (public.get_my_safety_privacy_state() ->> 'consent_gate_open')::boolean,
  false,
  'retired 2026-08-27 acceptances do not satisfy the launch consent gate'
);
select is(
  (select count(*) from public.profiles),
  0::bigint,
  'closed-gate direct REST profile-id reads return zero rows under RLS'
);
select is(
  (select count(*) from public.organizations),
  0::bigint,
  'closed-gate direct REST organization reads return zero rows'
);
select is(
  (select count(*) from public.organization_memberships),
  0::bigint,
  'closed-gate direct REST roster reads return zero rows'
);
select is(
  (select count(*) from public.governance_scopes),
  0::bigint,
  'closed-gate direct REST governance reads return zero rows'
);
select is(
  (select count(*) from public.posts),
  0::bigint,
  'closed-gate direct REST post reads return zero rows'
);
select is(
  (select count(*) from public.messages),
  0::bigint,
  'closed-gate direct REST message reads return zero rows'
);
select is(
  (select count(*) from public.post_media),
  0::bigint,
  'closed-gate direct REST post-media reads return zero rows'
);
select is(
  (
    select count(*)
    from storage.objects
    where owner_id = auth.uid()::text
      and bucket_id in ('community-media', 'avatars')
  ),
  0::bigint,
  'closed-gate direct Storage reads return zero rows for previously accessible bytes'
);
with deleted as (
  delete from storage.objects as object
  using test_direct_media_paths as path
  where path.label = 'fresh_after_delete'
    and object.bucket_id = path.bucket_id
    and object.name = path.storage_path
  returning object.id
)
select is(
  (select count(*) from deleted),
  0::bigint,
  'closed-gate direct Storage DELETE changes zero existing rows'
);
select is(
  (select count(*) from public.notifications),
  0::bigint,
  'closed-gate direct REST notification reads return zero rows'
);
with changed as (
  update public.profiles
  set bio = '동의 없이 변경되면 안 됨'
  where id = auth.uid()
  returning id
)
select is(
  (select count(*) from changed),
  0::bigint,
  'closed-gate direct REST self-profile mutation changes zero rows'
);
select throws_ok(
  $$select public.get_my_context()$$,
  '42501',
  'current_required_consents_required',
  'closed-gate context SECURITY DEFINER RPC fails before protected reads'
);
select throws_ok(
  $$select * from public.get_governance_tree()$$,
  '42501',
  'current_required_consents_required',
  'closed-gate governance SECURITY DEFINER RPC fails before roster reads'
);
select throws_ok(
  $$select public.reconcile_post_operation(
    '91000000-0000-4000-8000-000000000003',
    'b1100000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate post reconciliation cannot replay protected status'
);
select throws_ok(
  $$select * from public.reconcile_message_batch(
    '93000000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    array['94100000-0000-4000-8000-000000000002']::uuid[]
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate message reconciliation cannot replay protected nonce existence'
);
select throws_ok(
  $$select public.mark_notifications_read(null)$$,
  '42501',
  'current_required_consents_required',
  'closed-gate notification mutation is rejected before reading rows'
);
select throws_ok(
  $$select public.block_user(
    'c1100000-0000-4000-8000-000000000001', null
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate block replay is rejected before probing its target'
);
select throws_ok(
  $$select * from public.list_my_security_activity(10)$$,
  '42501',
  'current_required_consents_required',
  'closed-gate security history read is rejected'
);
select throws_ok(
  $$select public.touch_my_push_device(
    '95100000-0000-4000-8000-000000000099', null
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate push device touch is rejected before probing device IDs'
);
select throws_ok(
  $$select public.create_content_report(
    'post',
    '91000000-0000-4000-8000-000000000001',
    'spam',
    null
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate report replay is rejected before returning a report UUID'
);
select throws_ok(
  $$select public.abandon_media_upload_intents(array['protected/intent.jpg']::text[])$$,
  '42501',
  'current_required_consents_required',
  'closed-gate upload-intent abandonment is rejected before reading cleanup state'
);
select throws_ok(
  $$select public.abandon_direct_media_objects(
    'community-media',
    array['protected/direct.jpg']::text[]
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate direct-media abandonment is rejected before reading Storage state'
);
select throws_ok(
  $$select public.submit_membership_application(
    '96000000-0000-4000-8000-000000000301', 'member', null, null,
    '{}'::text[], null
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate application submit rejects before organization or membership lookup'
);
select throws_ok(
  $$select public.set_membership_application_evidence(
    '96000000-0000-4000-8000-000000000302', 'protected/evidence.jpg'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate evidence mutation rejects before application lookup'
);
select throws_ok(
  $$select public.withdraw_membership_application(
    '96000000-0000-4000-8000-000000000302'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate application withdrawal rejects before application lookup'
);
select throws_ok(
  $$select public.review_membership_application(
    '96000000-0000-4000-8000-000000000302', 'reject', 'probe'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate review rejects before application lookup'
);
select throws_ok(
  $$select public.set_membership_status(
    '96000000-0000-4000-8000-000000000303', 'revoked', 'probe'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate membership status mutation rejects before membership lookup'
);
select throws_ok(
  $$select public.publish_owned_post(
    '96000000-0000-4000-8000-000000000304',
    'b1100000-0000-4000-8000-000000000001',
    '{}'::text[]
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate publish rejects before post lookup'
);
select throws_ok(
  $$select public.send_message(
    '96000000-0000-4000-8000-000000000305', 'text', 'probe', null,
    '{}'::jsonb, '96000000-0000-4000-8000-000000000306'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate message send rejects before conversation lookup'
);
select throws_ok(
  $$select public.send_message_batch(
    '96000000-0000-4000-8000-000000000305',
    'b1100000-0000-4000-8000-000000000001',
    '[]'::jsonb
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate message batch rejects before payload or conversation lookup'
);
select throws_ok(
  $$select public.mark_conversation_read(
    '96000000-0000-4000-8000-000000000305', null
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate read receipt rejects before conversation lookup'
);
select throws_ok(
  $$select public.resolve_content_report(
    '96000000-0000-4000-8000-000000000307', 'no_action', 'probe'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate moderation resolution rejects before report lookup'
);
select throws_ok(
  $$select public.revoke_governance_delegation(
    '96000000-0000-4000-8000-000000000308', 'probe'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate delegation revocation rejects before delegation lookup'
);
select throws_ok(
  $$select public.delete_meeting_minute(
    '96000000-0000-4000-8000-000000000309'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate minute deletion rejects before minute lookup'
);
select throws_ok(
  $$select public.delete_ledger_entry(
    '96000000-0000-4000-8000-000000000310'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate ledger deletion rejects before ledger lookup'
);
select throws_ok(
  $$select public.update_organization_profile(
    '96000000-0000-4000-8000-000000000311', '{}'::jsonb
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate organization mutation rejects before organization lookup'
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
      true,
      true,
      false,
      true
    ) #>> '{directory_visibility,avatar}'
  )::boolean,
  true,
  'privacy preference contract stores five exact consent versions and field visibility'
);
select is(
  (public.get_my_safety_privacy_state() ->> 'consent_gate_open')::boolean,
  true,
  'safety/privacy state opens only after all five current versions are accepted'
);
select ok(
  (
    select count(*)
    from public.list_visible_profiles(array[auth.uid()])
  ) = 1
    and (
      select count(*)
      from public.list_visible_organization_memberships(
        (select id from public.organizations where slug = 'jaegun-bupyeong'),
        500,
        0
      )
      where user_id = auth.uid()
    ) = 1
    and (select count(*) from public.posts where author_id = auth.uid()) >= 1
    and (select count(*) from public.messages where sender_id = auth.uid()) >= 1
    and (select count(*) from public.governance_scopes) >= 1,
  'five-document re-consent restores profile, roster, post, message, and governance access'
);
select lives_ok(
  $$select public.get_my_context()$$,
  'five-document re-consent restores the protected context RPC'
);
select is(
  (
    select count(*) from public.user_consents
    where user_id = 'b1200000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'user consent history is self-only under RLS'
);
select is(
  (
    public.save_my_notification_preferences(
      true, true, true, true, true, true, true,
      false, '21:00', '08:00', 'Asia/Seoul', 'hidden'
    ) ->> 'lock_screen_preview'
  ),
  'hidden',
  'notification settings persist categories and generic-only preview mode'
);
select is(
  (public.set_conversation_muted('93000000-0000-4000-8000-000000000001', true) ->> 'notifications_enabled')::boolean,
  false,
  'conversation mute is stored as a self-only preference'
);
select ok(
  (public.get_my_safety_privacy_state() -> 'muted_conversation_ids')
    @> '["93000000-0000-4000-8000-000000000001"]'::jsonb,
  'state adapter returns the muted conversation ID'
);
select lives_ok(
  $$select public.unblock_user('c1100000-0000-4000-8000-000000000001')$$,
  'report fixture restores ordinary profile visibility before capturing evidence'
);
select lives_ok(
  $$
    select public.create_content_report(
      'profile',
      'c1100000-0000-4000-8000-000000000001',
      'harassment',
      '반복적인 괴롭힘 신고'
    )
  $$,
  'member can create an exact-scope profile report'
);
reset role;
create temporary table test_reports as
select id
from public.content_reports
where reporter_id = 'b1100000-0000-4000-8000-000000000001'
  and target_type = 'profile'
  and target_id = 'c1100000-0000-4000-8000-000000000001';
select ok(
  (
    select report.evidence_snapshot -> 'bio_excerpt' = 'null'::jsonb
      and report.evidence_snapshot ->> 'display_name' = '밥'
    from public.content_reports as report
    join test_reports as fixture on fixture.id = report.id
  ),
  'profile reporting preserves the visible name but omits a hidden bio from evidence'
);
grant select on table test_reports to authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  public.create_content_report(
    'profile',
    'c1100000-0000-4000-8000-000000000001',
    'harassment',
    '재시도'
  ),
  (select id from test_reports),
  'same-reason duplicate report returns the existing active report ID'
);
select throws_ok(
  $$
    select public.create_content_report(
      'profile',
      'c1100000-0000-4000-8000-000000000001',
      'privacy',
      '다른 사유 중복'
    )
  $$,
  '23505',
  'active_report_already_exists',
  'different-reason duplicate report fails with a stable active-report error'
);
select is(
  (
    public.block_user(
      'c1100000-0000-4000-8000-000000000001',
      'moderation evidence fixture restored'
    ) ->> 'blocked_user_id'
  )::uuid,
  'c1100000-0000-4000-8000-000000000001'::uuid,
  'report fixture restores the existing block used by later withdrawal tests'
);
reset role;
select throws_ok(
  $$
    insert into public.content_reports (
      reporter_id, organization_id, target_type, target_id,
      reported_user_id, reason_code, evidence_snapshot
    ) values (
      'b1100000-0000-4000-8000-000000000001',
      (select id from public.organizations where slug = 'jaegun-bupyeong'),
      'profile',
      'c1100000-0000-4000-8000-000000000001',
      'c1100000-0000-4000-8000-000000000001',
      'spam',
      '{"target_type":"profile"}'::jsonb
    )
  $$,
  '23505',
  null,
  'partial unique index prevents concurrent duplicate active reports'
);
-- Exact moderator scope and AAL2 sanctions -------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"e1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (select count(*) from public.list_moderation_reports('open', 50)),
  0::bigint,
  'executive in another church cannot list this church reports'
);
select throws_ok(
  format(
    'select public.resolve_content_report(%L, ''no_action'', ''범위 밖 처리'')',
    (select id from test_reports)
  ),
  'P0002',
  'content_report_not_found_or_forbidden',
  'other-church executive cannot resolve a report outside the exact scope'
);
select throws_ok(
  $$select public.resolve_content_report(
    '97000000-0000-4000-8000-000000000291', 'no_action', 'missing probe'
  )$$,
  'P0002',
  'content_report_not_found_or_forbidden',
  'other-church moderator receives the same response for an unknown report'
);
select throws_ok(
  format(
    'select public.resolve_content_report(%L, ''invalid_action'', ''state probe'')',
    (select id from test_reports)
  ),
  'P0002',
  'content_report_not_found_or_forbidden',
  'report action validation cannot reveal a known foreign report'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (select count(*) from public.list_moderation_reports('open', 50)),
  1::bigint,
  'platform administrator can list reports across organizations'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (select count(*) from public.list_moderation_reports('open', 50)),
  1::bigint,
  'active minister can list reports only in the minister own church'
);
select throws_ok(
  format(
    'select public.resolve_content_report(%L, ''warning_recorded'', ''AAL1 제재 거부'')',
    (select id from test_reports)
  ),
  '42501',
  'aal2_required:moderation_sanction',
  'AAL1 moderator cannot record a sanction'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (
    public.resolve_content_report(
      (
        select id from test_reports
      ),
      'warning_recorded',
      '운영정책 경고 기록'
    ) ->> 'status'
  ),
  'resolved',
  'AAL2 exact-scope moderator can resolve with a bounded action'
);
select ok(
  exists (
    select 1 from public.list_my_security_activity(50)
    where action = 'moderation.report_resolved'
  ),
  'moderation resolution is audit logged'
);

-- High-risk governance mutation also fails at the DB AAL boundary.
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_ok(
  format(
    'select public.assign_governance_office(%L, %s, ''pastor'', %L)',
    (
      select id from public.governance_scopes
      where scope_type = 'church'
        and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')
    ),
    pg_catalog.current_setting('test.release_service_year')::integer,
    'd1100000-0000-4000-8000-000000000001'
  ),
  '42501',
  'aal2_required:governance_office_assignments.insert',
  'AAL1 platform administrator cannot assign a governance office'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select lives_ok(
  format(
    'select public.assign_governance_office(%L, %s, ''pastor'', %L)',
    (
      select id from public.governance_scopes
      where scope_type = 'church'
        and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')
    ),
    pg_catalog.current_setting('test.release_service_year')::integer,
    'd1100000-0000-4000-8000-000000000001'
  ),
  'AAL2 platform administrator can assign the explicit church pastor'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''view_roster'']::text[], pg_catalog.clock_timestamp() + interval ''1 day'', ''AAL1 거부'')',
    (
      select id from public.governance_scopes
      where scope_type = 'church'
        and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')
    ),
    'b1100000-0000-4000-8000-000000000001'
  ),
  '42501',
  'aal2_required:governance_authority_delegations.insert',
  'AAL1 pastor cannot grant a governance delegation'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select lives_ok(
  format(
    'select public.grant_governance_delegation(%L, %L, array[''view_roster'']::text[], pg_catalog.clock_timestamp() + interval ''1 day'', ''AAL2 위임'')',
    (
      select id from public.governance_scopes
      where scope_type = 'church'
        and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')
    ),
    'b1100000-0000-4000-8000-000000000001'
  ),
  'AAL2 pastor can grant a bounded exact-scope delegation'
);

-- Quarantine scanner leases, validation, and stale-worker fencing -----------
reset role;
create temporary table test_media_scan_intents (
  label text primary key,
  intent_id uuid,
  quarantine_path text,
  approved_path text
);
grant all on table test_media_scan_intents to authenticated, service_role;
create temporary table test_media_scan_claims (
  intent_id uuid,
  lease_token uuid,
  uploader_id uuid,
  organization_id uuid,
  purpose text,
  target_id uuid,
  kind public.media_kind,
  quarantine_bucket_id text,
  quarantine_path text,
  approved_bucket_id text,
  approved_path text,
  expected_mime_type text,
  expected_byte_size bigint,
  expires_at timestamptz,
  scan_attempts integer
);
grant all on table test_media_scan_claims to service_role;
create temporary table test_media_scan_reclaims (like test_media_scan_claims);
grant all on table test_media_scan_reclaims to service_role;

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
delete from private.rate_limit_counters
where actor_id = 'b1100000-0000-4000-8000-000000000001'
  and action_key = 'uploads';
insert into test_media_scan_intents
select
  'safe_image',
  (result ->> 'id')::uuid,
  result ->> 'quarantine_path',
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'image',
    'image/jpeg',
    1024
  ) as result
) as created;
insert into test_media_scan_intents
select
  'stale_image',
  (result ->> 'id')::uuid,
  result ->> 'quarantine_path',
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'image',
    'image/jpeg',
    2048
  ) as result
) as created;
insert into test_media_scan_intents
select
  'upload_missing',
  (result ->> 'id')::uuid,
  result ->> 'quarantine_path',
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'image',
    'image/jpeg',
    4096
  ) as result
) as created;
insert into test_media_scan_intents
select
  'safe_video',
  (result ->> 'id')::uuid,
  result ->> 'quarantine_path',
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'video',
    'video/mp4',
    8192
  ) as result
) as created;
insert into test_media_scan_intents
select
  'bad_size',
  (result ->> 'id')::uuid,
  result ->> 'quarantine_path',
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'image',
    'image/jpeg',
    1
  ) as result
) as created;
insert into test_media_scan_intents
select
  'bad_mime',
  (result ->> 'id')::uuid,
  result ->> 'quarantine_path',
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'image',
    'image/jpeg',
    1024
  ) as result
) as created;

set local role authenticated;
select is(
  private.can_write_quarantine_media(
    (select quarantine_path from test_media_scan_intents where label = 'safe_image'),
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"1024"}'::jsonb
  ),
  true,
  'quarantine upload accepts metadata that exactly matches its active intent'
);
select is(
  private.can_write_quarantine_media(
    (select quarantine_path from test_media_scan_intents where label = 'bad_size'),
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"500000000"}'::jsonb
  ),
  false,
  'quarantine upload cannot inflate bytes beyond its intent reservation'
);
select is(
  private.can_write_quarantine_media(
    (select quarantine_path from test_media_scan_intents where label = 'bad_mime'),
    auth.uid(),
    '{"mimetype":"video/mp4","size":"1024"}'::jsonb
  ),
  false,
  'quarantine upload MIME must exactly match its intent reservation'
);
select throws_ok(
  format(
    'insert into storage.objects (bucket_id,name,owner,owner_id,metadata) values (''community-media-quarantine'',%L,%L,%L,%L::jsonb)',
    (select quarantine_path from test_media_scan_intents where label = 'bad_size'),
    auth.uid(),
    auth.uid()::text,
    '{"mimetype":"image/jpeg","size":"500000000"}'
  ),
  '42501',
  'new row violates row-level security policy for table "objects"',
  'quarantine Storage INSERT rejects a byte-size mismatch'
);
select throws_ok(
  format(
    'insert into storage.objects (bucket_id,name,owner,owner_id,metadata) values (''community-media-quarantine'',%L,%L,%L,%L::jsonb)',
    (select quarantine_path from test_media_scan_intents where label = 'bad_mime'),
    auth.uid(),
    auth.uid()::text,
    '{"mimetype":"video/mp4","size":"1024"}'
  ),
  '42501',
  'new row violates row-level security policy for table "objects"',
  'quarantine Storage INSERT rejects a MIME mismatch'
);

reset role;
insert into storage.objects (
  bucket_id, name, owner, owner_id, metadata
)
select
  'community-media-quarantine',
  intent.quarantine_path,
  'b1100000-0000-4000-8000-000000000001'::uuid,
  'b1100000-0000-4000-8000-000000000001',
  case intent.label
    when 'safe_image' then '{"mimetype":"image/jpeg","size":"1024"}'::jsonb
    when 'stale_image' then '{"mimetype":"image/jpeg","size":"2048"}'::jsonb
    else '{"mimetype":"video/mp4","size":"8192"}'::jsonb
  end
from test_media_scan_intents as intent
where intent.label in ('safe_image', 'stale_image', 'safe_video');

-- Simulate legacy/service-created malformed rows that bypassed browser RLS.
-- The atomic claim must independently refuse them.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media-quarantine',
  intent.quarantine_path,
  'b1100000-0000-4000-8000-000000000001'::uuid,
  'b1100000-0000-4000-8000-000000000001',
  case intent.label
    when 'bad_size' then '{"mimetype":"image/jpeg","size":"500000000"}'::jsonb
    else '{"mimetype":"video/mp4","size":"1024"}'::jsonb
  end
from test_media_scan_intents as intent
where intent.label in ('bad_size', 'bad_mime');

insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media',
  intent.approved_path,
  'b1100000-0000-4000-8000-000000000001'::uuid,
  'b1100000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":"4096"}'::jsonb
from test_media_scan_intents as intent
where intent.label = 'upload_missing';

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  private.authorize_direct_media_upload(
    'community-media',
    (select approved_path from test_media_scan_intents where label = 'upload_missing'),
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"4096"}'::jsonb
  ),
  false,
  'any scanner intent reservation prevents fallback to direct upload mode'
);
select throws_ok(
  format(
    'insert into public.post_media (post_id,uploader_id,storage_path,kind,mime_type,byte_size) values (%L,%L,%L,''image'',''image/jpeg'',4096)',
    '91000000-0000-4000-8000-000000000002',
    auth.uid(),
    (select approved_path from test_media_scan_intents where label = 'upload_missing')
  ),
  '42501',
  'approved_media_required',
  'quarantine intent cannot downgrade to legacy attachment even when approved-path bytes exist'
);

reset role;

select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select throws_ok(
  'select * from public.service_claim_media_scan_intents(10)',
  '42501',
  'service_role_required:claim_media_scan_intents',
  'SET ROLE service_role without a signed service claim cannot claim scans'
);

reset role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_media_scan_claims
select * from public.service_claim_media_scan_intents(10);
select is(
  (select count(*) from test_media_scan_claims),
  3::bigint,
  'scanner claims only intents whose exact owned quarantine object exists'
);
select ok(
  not exists (
    select 1
    from test_media_scan_claims as claim
    join test_media_scan_intents as intent using (intent_id)
    where intent.label = 'upload_missing'
  ),
  'scanner does not claim an intent before upload completion'
);
select ok(
  not exists (
    select 1
    from test_media_scan_claims as claim
    join test_media_scan_intents as intent using (intent_id)
    where intent.label in ('bad_size', 'bad_mime')
  ),
  'scanner claim independently rejects malformed preexisting quarantine objects'
);
select ok(
  (select bool_and(lease_token is not null and scan_attempts = 1) from test_media_scan_claims),
  'first scan claim returns a fencing token and attempt one'
);

reset role;
update public.media_upload_intents
set status = 'expired',
    rejection_code = 'malformed_fixture_expired',
    updated_at = pg_catalog.clock_timestamp()
where id = (
  select intent_id from test_media_scan_intents where label = 'bad_size'
);
select ok(
  private.retained_media_bytes_for_organization(
    (select id from public.organizations where slug = 'jaegun-bupyeong')
  ) >= 500000000,
  'expired intent quarantine bytes remain in organization retained quota until cleanup'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  private.can_write_quarantine_media(
    (select quarantine_path from test_media_scan_intents where label = 'safe_image'),
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"1024"}'::jsonb
  ),
  false,
  'uploader cannot mutate quarantine bytes after the scanner claims them'
);

reset role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''image/svg+xml'',900,%L,true,true,100,100,null,null,null)',
    (select intent_id from test_media_scan_intents where label = 'safe_image'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_image'
    ),
    repeat('a', 64)
  ),
  '23514',
  'unsafe_media_cannot_be_approved',
  'scanner cannot approve SVG or a MIME outside the exact derivative allowlist'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''image/jpeg'',900,%L,true,false,100,100,null,null,null)',
    (select intent_id from test_media_scan_intents where label = 'safe_image'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_image'
    ),
    repeat('b', 64)
  ),
  '23514',
  'unsafe_media_cannot_be_approved',
  'scanner cannot approve an image before metadata is stripped'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''image/jpeg'',1025,%L,true,true,100,100,null,null,null)',
    (select intent_id from test_media_scan_intents where label = 'safe_image'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_image'
    ),
    repeat('1', 64)
  ),
  '23514',
  'unsafe_media_cannot_be_approved',
  'scanner cannot approve bytes exceeding the declared upload size'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''image/jpeg'',900,%L,true,true,12000,12000,null,null,null)',
    (select intent_id from test_media_scan_intents where label = 'safe_image'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_image'
    ),
    repeat('2', 64)
  ),
  '23514',
  'unsafe_media_cannot_be_approved',
  'scanner cannot approve an image decompression bomb beyond the pixel ceiling'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,E''bad\\nscanner'',''approved'',''image/jpeg'',900,%L,true,true,100,100,null,null,null)',
    (select intent_id from test_media_scan_intents where label = 'safe_image'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_image'
    ),
    repeat('c', 64)
  ),
  '22023',
  'invalid_media_scan_result',
  'scanner provenance rejects control characters'
);
select lives_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''image/jpeg'',900,%L,true,true,100,100,null,null,null)',
    (select intent_id from test_media_scan_intents where label = 'safe_image'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_image'
    ),
    repeat('d', 64)
  ),
  'sanitized exact-MIME image can be approved with the active lease'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''video/mp4'',8000,%L,true,true,1920,1080,7201,''h264'',null)',
    (select intent_id from test_media_scan_intents where label = 'safe_video'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_video'
    ),
    repeat('3', 64)
  ),
  '23514',
  'unsafe_media_cannot_be_approved',
  'scanner cannot approve video beyond the duration ceiling'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''video/mp4'',8000,%L,true,true,1920,1080,60,''mpeg2'',null)',
    (select intent_id from test_media_scan_intents where label = 'safe_video'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_video'
    ),
    repeat('4', 64)
  ),
  '23514',
  'unsafe_media_cannot_be_approved',
  'scanner cannot approve a video codec outside the exact allowlist'
);
select lives_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''approved'',''video/mp4'',8000,%L,true,true,1920,1080,60,''h264'',null)',
    (select intent_id from test_media_scan_intents where label = 'safe_video'),
    (
      select claim.lease_token
      from test_media_scan_claims as claim
      join test_media_scan_intents as intent using (intent_id)
      where intent.label = 'safe_video'
    ),
    repeat('5', 64)
  ),
  'sanitized bounded H.264 video can be approved with the active lease'
);

reset role;
select ok(
  exists (
    select 1
    from public.media_scan_records as scan
    join test_media_scan_intents as intent on intent.intent_id = scan.intent_id
    where intent.label = 'safe_image'
      and scan.decision = 'approved'
      and scan.malware_scan_clean
      and scan.metadata_stripped
  ),
  'approved scan retains clean and sanitized evidence'
);
update public.media_upload_intents as intent
set scan_claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes'
where intent.id = (
  select scan_intent.intent_id
  from test_media_scan_intents as scan_intent
  where scan_intent.label = 'stale_image'
);

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_media_scan_reclaims
select * from public.service_claim_media_scan_intents(10);
select is(
  (select count(*) from test_media_scan_reclaims),
  1::bigint,
  'expired scan lease is atomically reclaimed'
);
select ok(
  (
    select reclaimed.scan_attempts = 2
      and reclaimed.lease_token <> original.lease_token
    from test_media_scan_reclaims as reclaimed
    join test_media_scan_claims as original using (intent_id)
  ),
  'scan reclaim increments attempts and rotates the fencing token'
);
select throws_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''rejected'',''application/octet-stream'',1,%L,false,false,null,null,null,null,''decode_failed'')',
    (select intent_id from test_media_scan_reclaims),
    (
      select original.lease_token
      from test_media_scan_claims as original
      where original.intent_id = (select intent_id from test_media_scan_reclaims)
    ),
    repeat('e', 64)
  ),
  '55000',
  'media_scan_lease_invalid',
  'late scanner cannot complete with a stale fencing token'
);
select lives_ok(
  format(
    'select public.service_record_media_scan(%L,%L,''scanner-1.0'',''rejected'',''application/octet-stream'',1,%L,false,false,null,null,null,null,''decode_failed'')',
    (select intent_id from test_media_scan_reclaims),
    (select lease_token from test_media_scan_reclaims),
    repeat('f', 64)
  ),
  'current scan lease can record a bounded rejection'
);

reset role;
update public.media_upload_intents as intent
set status = 'scanning',
    scan_attempts = 5,
    scan_claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes',
    scan_lease_token = '96900000-0000-4000-8000-000000000001'
where intent.id = (
  select scan_intent.intent_id
  from test_media_scan_intents as scan_intent
  where scan_intent.label = 'upload_missing'
);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select is(
  (select count(*) from public.service_claim_media_scan_intents(10)),
  0::bigint,
  'scanner does not reclaim a lease after the bounded attempt ceiling'
);
reset role;
select is(
  (
    select intent.status || ':' || intent.rejection_code
    from public.media_upload_intents as intent
    join test_media_scan_intents as scan_intent on scan_intent.intent_id = intent.id
    where scan_intent.label = 'upload_missing'
  ),
  'rejected:scan_lease_exhausted',
  'five expired scan claims terminate in an auditable rejection state'
);
delete from public.media_upload_intents as intent
where intent.id in (select intent_id from test_media_scan_intents);

-- Approved/unattached media abandonment and service cleanup ----------------
reset role;
create temporary table test_media_intents (
  intent_id uuid,
  approved_path text
);
grant all on table test_media_intents to authenticated, service_role;
create temporary table test_media_cleanup_claims (
  item_id uuid,
  intent_id uuid,
  bucket_id text,
  storage_path text,
  reason text,
  attempts integer
);
grant all on table test_media_cleanup_claims to service_role;
create temporary table test_direct_cleanup_claims (like test_media_cleanup_claims);
grant all on table test_direct_cleanup_claims to service_role;

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (
    public.abandon_direct_media_objects(
      'community-media',
      array[(select storage_path from test_direct_media_paths where label = 'orphan')]
    ) ->> 'queued_count'
  )::integer,
  1,
  'owner can queue an unreferenced direct object for service cleanup'
);
select ok(
  (
    public.abandon_direct_media_objects(
      'community-media',
      array[(select storage_path from test_direct_media_paths where label = 'orphan')]
    ) ->> 'cleanup_queued'
  )::boolean,
  'direct cleanup retry is an idempotent success when the path is already queued'
);
select throws_ok(
  format(
    'insert into public.post_media (post_id,uploader_id,storage_path,kind,mime_type,byte_size) values (%L,%L,%L,''image'',''image/webp'',384)',
    '91000000-0000-4000-8000-000000000002',
    auth.uid(),
    (select storage_path from test_direct_media_paths where label = 'orphan')
  ),
  '55000',
  'direct_media_cleanup_pending',
  'cleanup tombstone prevents a queued direct path from being reattached'
);
select ok(
  (
    public.prepare_post_media_cleanup(
      '91000000-0000-4000-8000-000000000002',
      auth.uid(),
      array[(select storage_path from test_direct_media_paths where label = 'foreign_post')]
    ) #> '{protected_paths}'
  ) @> pg_catalog.jsonb_build_array(
    (select storage_path from test_direct_media_paths where label = 'foreign_post')
  ),
  'post cleanup protects another uploader direct object instead of queueing it'
);

reset role;
insert into private.media_cleanup_items (
  uploader_id, bucket_id, storage_path, reason
)
values (
  'b1100000-0000-4000-8000-000000000001',
  'community-media',
  (select storage_path from test_direct_media_paths where label = 'post'),
  'user_abandoned'
);
select ok(
  not exists (
    select 1
    from private.media_cleanup_items as cleanup
    where cleanup.storage_path =
      (select storage_path from test_direct_media_paths where label = 'foreign_post')
  ),
  'foreign-owned post path is absent from the service cleanup queue'
);

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_direct_cleanup_claims
select * from public.service_claim_media_cleanup_items(10);
select is(
  (select count(*) from test_direct_cleanup_claims),
  1::bigint,
  'cleanup worker claims the unreferenced direct path only'
);
delete from storage.objects as object
where object.bucket_id = 'community-media'
  and object.name = (select storage_path from test_direct_media_paths where label = 'orphan');
select lives_ok(
  format(
    'select public.service_complete_media_cleanup_item(%L, ''deleted'', null, 60)',
    (select item_id from test_direct_cleanup_claims)
  ),
  'direct cleanup worker records deletion after removing exact bytes'
);

reset role;
select is(
  (
    select cleanup.last_error_code
    from private.media_cleanup_items as cleanup
    where cleanup.storage_path =
      (select storage_path from test_direct_media_paths where label = 'post')
  ),
  'media_path_referenced',
  'cleanup claim rechecks references and defers a forced live path'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
delete from private.rate_limit_counters
where actor_id = 'b1100000-0000-4000-8000-000000000001'
  and action_key = 'uploads';
insert into test_media_intents (intent_id, approved_path)
select
  (result ->> 'id')::uuid,
  result ->> 'approved_path'
from (
  select public.create_media_upload_intent(
    'post',
    '91000000-0000-4000-8000-000000000002',
    'image',
    'image/jpeg',
    1024
  ) as result
) as created;
set local role authenticated;
select is(
  (
    public.abandon_media_upload_intents(
      array[(select approved_path from test_media_intents)]
    ) ->> 'abandoned_count'
  )::integer,
  1,
  'owner can abandon one unattached upload intent by approved path'
);
select is(
  (
    select status from public.media_upload_intents
    where id = (select intent_id from test_media_intents)
  ),
  'expired',
  'abandoned intent is no longer attachable or retained-quota-active'
);
select ok(
  exists (
    select 1
    from public.media_upload_intents
    where id = (select intent_id from test_media_intents)
      and created_at >= pg_catalog.clock_timestamp() - interval '24 hours'
      and expected_byte_size = 1024
  ),
  'abandoned intent remains in the 24-hour throughput history'
);

reset role;
select is(
  (
    select count(*) from private.media_cleanup_items
    where intent_id = (select intent_id from test_media_intents)
  ),
  2::bigint,
  'abandon queues both quarantine and approved paths for service cleanup'
);
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select throws_ok(
  'select * from public.service_claim_media_cleanup_items(10)',
  '42501',
  'service_role_required:claim_media_cleanup_items',
  'SET ROLE service_role without a signed service claim cannot run cleanup'
);

reset role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_media_cleanup_claims
select * from public.service_claim_media_cleanup_items(10);
select is(
  (select count(*) from test_media_cleanup_claims),
  2::bigint,
  'service cleanup worker claims one delivery per queued Storage path'
);
select lives_ok(
  format(
    'select public.service_complete_media_cleanup_item(%L, ''deleted'', null, 60)',
    (select item_id from test_media_cleanup_claims order by item_id limit 1)
  ),
  'service worker records successful media cleanup'
);
select lives_ok(
  format(
    'select public.service_complete_media_cleanup_item(%L, ''not_found'', null, 60)',
    (select item_id from test_media_cleanup_claims order by item_id desc limit 1)
  ),
  'service worker treats an already-missing object as terminal success'
);
reset role;
select is(
  (
    select count(*) from private.media_cleanup_items
    where intent_id = (select intent_id from test_media_intents)
      and status in ('deleted', 'not_found')
  ),
  2::bigint,
  'per-path cleanup terminal state is retained for idempotent retries'
);

create temporary table test_stale_media_cleanup_claims (
  item_id uuid,
  intent_id uuid,
  bucket_id text,
  storage_path text,
  reason text,
  attempts integer
);
grant all on table test_stale_media_cleanup_claims to service_role;
update private.media_cleanup_items as item
set status = 'processing',
    attempts = 1,
    claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes',
    completed_at = null
where item.id = (
  select cleanup.id
  from private.media_cleanup_items as cleanup
  where cleanup.intent_id = (select intent_id from test_media_intents)
  order by cleanup.id
  limit 1
);
update private.media_cleanup_items as item
set status = 'processing',
    attempts = 8,
    claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes',
    completed_at = null
where item.id = (
  select cleanup.id
  from private.media_cleanup_items as cleanup
  where cleanup.intent_id = (select intent_id from test_media_intents)
  order by cleanup.id desc
  limit 1
);
insert into private.media_cleanup_items (
  uploader_id, bucket_id, storage_path, reason, status, attempts, claimed_at
)
values (
  'b1100000-0000-4000-8000-000000000001',
  'community-media-quarantine',
  'release-tests/fresh-processing-object',
  'user_abandoned',
  'processing',
  1,
  pg_catalog.clock_timestamp() - interval '9 minutes'
);

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_stale_media_cleanup_claims
select * from public.service_claim_media_cleanup_items(10);
select is(
  (select count(*) from test_stale_media_cleanup_claims),
  1::bigint,
  'expired Storage cleanup lease is reclaimed without duplicating the item'
);
select is(
  (select attempts from test_stale_media_cleanup_claims),
  2,
  'Storage cleanup lease reclaim increments its attempt counter'
);
select lives_ok(
  format(
    'select public.service_complete_media_cleanup_item(%L, ''not_found'', null, 60)',
    (select item_id from test_stale_media_cleanup_claims)
  ),
  'reclaimed Storage cleanup item can complete idempotently'
);

reset role;
select is(
  (
    select count(*) from private.media_cleanup_items
    where intent_id = (select intent_id from test_media_intents)
      and status = 'dead'
      and attempts = 8
      and last_error_code = 'worker_lease_expired'
  ),
  1::bigint,
  'cleanup work at the retry ceiling moves to dead-letter state'
);
select is(
  (
    select status from private.media_cleanup_items
    where storage_path = 'release-tests/fresh-processing-object'
  ),
  'processing',
  'fresh nine-minute cleanup lease is not reclaimed early'
);

-- Push registration, self-only RLS, quiet hours, and per-device outcomes ----
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select lives_ok(
  $$select public.service_register_push_device(
    'b1100000-0000-4000-8000-000000000001',
    '97000000-0000-4000-8000-000000000001',
    'ios', 'ciphertext-a1', repeat('a', 64), 1, '1.0.0'
  )$$,
  'service registers Alice first encrypted push device'
);
select lives_ok(
  $$select public.service_register_push_device(
    'b1100000-0000-4000-8000-000000000001',
    '97000000-0000-4000-8000-000000000002',
    'android', 'ciphertext-a2', repeat('b', 64), 1, '1.0.0'
  )$$,
  'service registers Alice second encrypted push device'
);
select lives_ok(
  $$select public.service_register_push_device(
    'c1100000-0000-4000-8000-000000000001',
    '97000000-0000-4000-8000-000000000003',
    'web', 'ciphertext-b1', repeat('c', 64), 1, '1.0.0'
  )$$,
  'service registers a different user device'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (select count(*) from public.push_devices),
  2::bigint,
  'push device metadata is self-only under RLS'
);

reset role;
delete from private.push_outbox;
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000003',
  'b1100000-0000-4000-8000-000000000001',
  'admin_action',
  '원본 상세 알림',
  '이 민감할 수 있는 원문은 push outbox에 복사되면 안 됩니다.',
  'profile',
  'b1100000-0000-4000-8000-000000000001',
  '{}'::jsonb
);
select is(
  (select body from private.push_outbox where idempotency_key = 'notification:95000000-0000-4000-8000-000000000003'),
  '앱에서 내용을 확인해 주세요.',
  'push outbox payload is generic and excludes notification content'
);
select ok(
  (select is_silent from private.push_outbox where idempotency_key = 'notification:95000000-0000-4000-8000-000000000003'),
  'hidden lock-screen preview produces a silent/generic push job'
);
update public.notification_preferences
set events_enabled = false
where user_id = 'b1100000-0000-4000-8000-000000000001';
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000005',
  'b1100000-0000-4000-8000-000000000001',
  'admin_action',
  '일정 리마인더',
  '이벤트 원문',
  'event_occurrence',
  '95000000-0000-4000-8000-000000000105',
  '{}'::jsonb
);
select ok(
  not exists (
    select 1 from private.push_outbox
    where idempotency_key = 'notification:95000000-0000-4000-8000-000000000005'
  ),
  'event reminder respects events_enabled even when represented as admin_action'
);
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000006',
  'b1100000-0000-4000-8000-000000000001',
  'admin_action',
  '보안 조치',
  '원문',
  'profile',
  'b1100000-0000-4000-8000-000000000001',
  '{}'::jsonb
);
select is(
  (
    select event_code from private.push_outbox
    where idempotency_key = 'notification:95000000-0000-4000-8000-000000000006'
  ),
  'security_notice',
  'non-event admin action remains a security notice independent of event preference'
);
update public.notification_preferences
set events_enabled = true
where user_id = 'b1100000-0000-4000-8000-000000000001';
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000007',
  'b1100000-0000-4000-8000-000000000001',
  'admin_action',
  '일정 리마인더',
  '이벤트 원문',
  'event',
  '95000000-0000-4000-8000-000000000107',
  '{}'::jsonb
);
select is(
  (
    select event_code from private.push_outbox
    where idempotency_key = 'notification:95000000-0000-4000-8000-000000000007'
  ),
  'community_notice',
  'enabled event reminder uses a generic non-security push classification'
);
delete from private.push_outbox
where idempotency_key in (
  'notification:95000000-0000-4000-8000-000000000006',
  'notification:95000000-0000-4000-8000-000000000007'
);

create temporary table test_push_claims (
  delivery_id uuid,
  job_id uuid,
  device_id uuid,
  platform text,
  token_ciphertext text,
  encryption_key_version smallint,
  event_code text,
  entity_type text,
  entity_id uuid,
  title text,
  body text,
  is_silent boolean,
  collapse_key text,
  delivery_attempts integer
);
grant all on table test_push_claims to service_role;

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_push_claims
select * from public.service_claim_push_jobs(20);
select is(
  (select count(*) from test_push_claims),
  2::bigint,
  'one push job fans out into two independently claimable device deliveries'
);
select lives_ok(
  format(
    'select public.service_complete_push_delivery(%L, true, false, null, 60)',
    (select delivery_id from test_push_claims order by delivery_id limit 1)
  ),
  'first device delivery succeeds independently'
);
select lives_ok(
  format(
    'select public.service_complete_push_delivery(%L, false, true, ''invalid_token'', 60)',
    (select delivery_id from test_push_claims order by delivery_id desc limit 1)
  ),
  'second device invalid-token failure is recorded independently'
);
select is(
  (select count(*) from public.service_claim_push_jobs(20)),
  0::bigint,
  'successful device delivery is not duplicated on the next claim'
);

reset role;
select is(
  (
    select status from private.push_outbox
    where id = (select job_id from test_push_claims order by job_id limit 1)
  ),
  'delivered',
  'mixed success plus invalid-token terminal failure completes the parent job'
);
select is(
  (
    select count(*) from public.push_devices
    where user_id = 'b1100000-0000-4000-8000-000000000001'
      and disabled_reason = 'provider_token_invalid'
  ),
  1::bigint,
  'only the invalid provider token device is disabled'
);
select is(
  (
    select count(*) from public.push_devices
    where user_id = 'b1100000-0000-4000-8000-000000000001'
      and disabled_at is null
  ),
  1::bigint,
  'the successful sibling device remains active'
);

insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '95000000-0000-4000-8000-000000000004',
  'b1100000-0000-4000-8000-000000000001',
  'admin_action',
  'lease recovery source',
  'worker timeout recovery source',
  'profile',
  'b1100000-0000-4000-8000-000000000001',
  '{}'::jsonb
);
create temporary table test_stale_push_claims (
  delivery_id uuid,
  job_id uuid,
  device_id uuid,
  platform text,
  token_ciphertext text,
  encryption_key_version smallint,
  event_code text,
  entity_type text,
  entity_id uuid,
  title text,
  body text,
  is_silent boolean,
  collapse_key text,
  delivery_attempts integer
);
grant all on table test_stale_push_claims to service_role;

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_stale_push_claims
select * from public.service_claim_push_jobs(20);
select is(
  (select count(*) from test_stale_push_claims),
  1::bigint,
  'one remaining active device receives the lease-recovery test delivery'
);

reset role;
update private.push_deliveries
set claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes'
where id = (select delivery_id from test_stale_push_claims limit 1);
update private.push_outbox
set claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes'
where id = (select job_id from test_stale_push_claims limit 1);

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_stale_push_claims
select * from public.service_claim_push_jobs(20);
select is(
  (select count(distinct delivery_id) from test_stale_push_claims),
  1::bigint,
  'expired processing lease reclaims the same device delivery instead of duplicating it'
);
select is(
  (select max(delivery_attempts) from test_stale_push_claims),
  2,
  'stale-lease reclaim increments the per-device attempt count'
);
select lives_ok(
  format(
    'select public.service_complete_push_delivery(%L, true, false, null, 60)',
    (select delivery_id from test_stale_push_claims order by delivery_attempts desc limit 1)
  ),
  'reclaimed stale delivery can complete normally'
);

reset role;

update public.notification_preferences
set quiet_hours_start = '21:00'::time,
    quiet_hours_end = '08:00'::time,
    timezone = 'Asia/Seoul'
where user_id = 'b1100000-0000-4000-8000-000000000001';
select is(
  private.next_push_attempt_at(
    'b1100000-0000-4000-8000-000000000001',
    '2026-08-27 20:59:00+09'::timestamptz
  ),
  '2026-08-27 20:59:00+09'::timestamptz,
  '20:59 Asia/Seoul is delivered immediately before quiet hours'
);
select is(
  private.next_push_attempt_at(
    'b1100000-0000-4000-8000-000000000001',
    '2026-08-27 21:00:00+09'::timestamptz
  ),
  '2026-08-28 08:00:00+09'::timestamptz,
  '21:00 Asia/Seoul defers to the overnight quiet-hours end'
);
select is(
  private.next_push_attempt_at(
    'b1100000-0000-4000-8000-000000000001',
    '2026-08-28 07:59:00+09'::timestamptz
  ),
  '2026-08-28 08:00:00+09'::timestamptz,
  'overnight quiet hours continue through 07:59'
);
select is(
  private.next_push_attempt_at(
    'b1100000-0000-4000-8000-000000000001',
    '2026-08-28 08:00:00+09'::timestamptz
  ),
  '2026-08-28 08:00:00+09'::timestamptz,
  '08:00 Asia/Seoul is the immediate-delivery boundary'
);

-- Native installation ownership follows the currently signed-in account.
create temporary table test_account_switch_installation as
select id as old_device_id, installation_id
from public.push_devices
where user_id = 'b1100000-0000-4000-8000-000000000001'
  and disabled_at is null
limit 1;
grant all on table test_account_switch_installation to authenticated, service_role;

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select lives_ok(
  format(
    'select public.service_register_push_device(%L,%L,''ios'',''ciphertext-account-switch'',%L,1,''1.0.1'')',
    'c1100000-0000-4000-8000-000000000001',
    (select installation_id from test_account_switch_installation),
    repeat('d', 64)
  ),
  'service atomically rebinds one native installation to the new account'
);

reset role;
select ok(
  not exists (
    select 1
    from public.push_devices as device
    join test_account_switch_installation as switched
      on switched.installation_id = device.installation_id
    where device.user_id = 'b1100000-0000-4000-8000-000000000001'
  )
  and exists (
    select 1
    from public.push_devices as device
    join test_account_switch_installation as switched
      on switched.installation_id = device.installation_id
    where device.user_id = 'c1100000-0000-4000-8000-000000000001'
  ),
  'old account no longer owns the installation after account switching'
);
select ok(
  not exists (
    select 1
    from private.push_device_secrets as secret
    join test_account_switch_installation as switched
      on switched.old_device_id = secret.device_id
  ),
  'account switch removes the old encrypted token binding by cascade'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  public.remove_my_push_device_by_installation(
    (select installation_id from test_account_switch_installation)
  ),
  false,
  'a user cannot detach another account installation by UUID'
);

reset role;
select ok(
  exists (
    select 1
    from public.push_devices as device
    join test_account_switch_installation as switched
      on switched.installation_id = device.installation_id
    where device.user_id = 'c1100000-0000-4000-8000-000000000001'
  ),
  'cross-user detach attempt leaves the new owner binding intact'
);
insert into public.push_devices (
  user_id, installation_id, platform, token_fingerprint
)
select
  'c1100000-0000-4000-8000-000000000001',
  gen_random_uuid(),
  'ios',
  pg_catalog.encode(extensions.digest('device-cap-' || series.value::text, 'sha256'), 'hex')
from pg_catalog.generate_series(1, 8) as series(value);

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select throws_ok(
  format(
    'select public.service_register_push_device(%L,%L,''ios'',''ciphertext-over-cap'',%L,1,''1.0.1'')',
    'c1100000-0000-4000-8000-000000000001',
    '97000000-0000-4000-8000-000000000099',
    repeat('9', 64)
  ),
  '54000',
  'active_push_device_limit_exceeded',
  'service enforces the ten-active-device cap per user'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"c1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'c1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  public.remove_my_push_device_by_installation(
    (select installation_id from test_account_switch_installation)
  ),
  true,
  'current account can detach its installation during logout'
);

-- Account deletion requires AAL2 or independently verified service proof. ---
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', 'a1200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_ok(
  $$select public.request_account_deletion('계정 삭제', 'claims 없음', null)$$,
  '42501',
  'signed_authentication_context_required:account_deletion_request',
  'authenticated role without signed JWT claims fails closed for deletion'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_ok(
  $$select public.request_account_deletion('계정 삭제', 'AAL1 거부', 'untrusted-client-nonce')$$,
  '42501',
  'aal2_required:account_deletion_request',
  'client-provided reauth nonce cannot substitute for AAL2'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"a1200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (public.request_account_deletion('계정 삭제', 'AAL2 요청', null) ->> 'status'),
  'requested',
  'AAL2 member receives a cancellable deletion request with grace period'
);
select ok(
  (
    select scheduled_for >= requested_at + interval '14 days'
    from public.account_deletion_requests
    where user_id = 'a1200000-0000-4000-8000-000000000001'
      and status = 'requested'
  ),
  'account deletion request has at least a fourteen-day grace period'
);
select is(
  (public.cancel_account_deletion() ->> 'status'),
  'cancelled',
  'member can cancel during the grace period'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (
    select count(*) from public.account_deletion_requests
    where user_id = 'a1200000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'account deletion request history is self-only under RLS'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select throws_ok(
  $$
    select public.request_account_deletion_verified(
      'a1200000-0000-4000-8000-000000000001',
      '서비스 role 위조',
      '계정 삭제'
    )
  $$,
  '42501',
  'service_role_required:request_account_deletion_verified',
  'SET ROLE service_role alone cannot forge a verified deletion request'
);

reset role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select is(
  (
    public.request_account_deletion_verified(
      'a1200000-0000-4000-8000-000000000001',
      'Edge에서 GoTrue 재인증 완료',
      '계정 삭제'
    ) ->> 'status'
  ),
  'requested',
  'signed service worker can create a verified deletion request'
);

-- Processing deletion work uses a recoverable ten-minute lease.
reset role;
insert into auth.users (id, email, raw_user_meta_data)
values
  (
    'd1200000-0000-4000-8000-000000000001',
    'release-stale-deletion@example.com',
    '{"display_name":"stale deletion"}'::jsonb
  ),
  (
    'e1200000-0000-4000-8000-000000000001',
    'release-fresh-deletion@example.com',
    '{"display_name":"fresh deletion"}'::jsonb
  ),
  (
    'f1200000-0000-4000-8000-000000000001',
    'release-exhausted-deletion@example.com',
    '{"display_name":"exhausted deletion"}'::jsonb
  );
insert into public.account_deletion_requests (
  user_id, subject_fingerprint, status, reason, requested_at, scheduled_for,
  processing_started_at, processing_claimed_at, processing_attempts
)
values
  (
    'd1200000-0000-4000-8000-000000000001', repeat('1', 64), 'processing',
    'stale worker', pg_catalog.clock_timestamp() - interval '20 days',
    pg_catalog.clock_timestamp() - interval '19 days',
    pg_catalog.clock_timestamp() - interval '11 minutes',
    pg_catalog.clock_timestamp() - interval '11 minutes', 1
  ),
  (
    'e1200000-0000-4000-8000-000000000001', repeat('2', 64), 'processing',
    'fresh worker', pg_catalog.clock_timestamp() - interval '20 days',
    pg_catalog.clock_timestamp() - interval '19 days',
    pg_catalog.clock_timestamp() - interval '9 minutes',
    pg_catalog.clock_timestamp() - interval '9 minutes', 1
  ),
  (
    'f1200000-0000-4000-8000-000000000001', repeat('3', 64), 'processing',
    'exhausted worker', pg_catalog.clock_timestamp() - interval '20 days',
    pg_catalog.clock_timestamp() - interval '19 days',
    pg_catalog.clock_timestamp() - interval '11 minutes',
    pg_catalog.clock_timestamp() - interval '11 minutes', 8
  );
create temporary table test_stale_deletion_claims (
  request_id uuid,
  user_id uuid,
  subject_fingerprint text,
  cleanup_items jsonb
);
grant all on table test_stale_deletion_claims to service_role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_stale_deletion_claims
select * from public.service_claim_due_account_deletions(10);
select is(
  (select count(*) from test_stale_deletion_claims),
  1::bigint,
  'stale processing deletion lease is reclaimed exactly once'
);
select is(
  (select user_id from test_stale_deletion_claims),
  'd1200000-0000-4000-8000-000000000001'::uuid,
  'fresh processing deletion is not concurrently reclaimed'
);

reset role;
select is(
  (
    select processing_attempts from public.account_deletion_requests
    where user_id = 'd1200000-0000-4000-8000-000000000001'
  ),
  2,
  'reclaimed deletion increments its bounded processing attempt count'
);
select is(
  (
    select status from public.account_deletion_requests
    where user_id = 'e1200000-0000-4000-8000-000000000001'
  ),
  'processing',
  'nine-minute fresh deletion lease remains processing'
);
select is(
  (
    select status || ':' || failure_code from public.account_deletion_requests
    where user_id = 'f1200000-0000-4000-8000-000000000001'
  ),
  'failed:deletion_worker_lease_exhausted',
  'stale deletion at the retry ceiling moves to a stable failed state'
);
delete from public.account_deletion_requests
where user_id in (
  'd1200000-0000-4000-8000-000000000001',
  'e1200000-0000-4000-8000-000000000001',
  'f1200000-0000-4000-8000-000000000001'
);
delete from auth.users
where id in (
  'd1200000-0000-4000-8000-000000000001',
  'e1200000-0000-4000-8000-000000000001',
  'f1200000-0000-4000-8000-000000000001'
);

-- Build attached/unattached deletion inventory, including retained org hero.
reset role;
insert into public.membership_applications (
  id, user_id, organization_id, requested_role, applicant_note
)
values (
  '98000000-0000-4000-8000-000000000001',
  'a1200000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'executive',
  '삭제 테스트 증빙 신청'
);

insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status,
  approved_mime_type, approved_byte_size, approved_width, approved_height,
  expires_at, approved_at
)
select
  '96000000-0000-4000-8000-000000000001',
  'a1200000-0000-4000-8000-000000000001',
  null,
  'avatar',
  'a1200000-0000-4000-8000-000000000001',
  'image',
  'image/jpeg',
  1000,
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000001/upload.jpg',
  'avatars',
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000001.jpg',
  'approved',
  'image/jpeg',
  900,
  100,
  100,
  pg_catalog.clock_timestamp() + interval '1 hour',
  pg_catalog.clock_timestamp();

insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status,
  approved_mime_type, approved_byte_size, approved_width, approved_height,
  expires_at, approved_at
)
select
  '96000000-0000-4000-8000-000000000002',
  'a1200000-0000-4000-8000-000000000001',
  organization.id,
  'post',
  '91000000-0000-4000-8000-000000000004',
  'image',
  'image/jpeg',
  1000,
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000002/upload.jpg',
  'community-media',
  organization.id::text || '/posts/91000000-0000-4000-8000-000000000004/96000000-0000-4000-8000-000000000002.jpg',
  'approved',
  'image/jpeg',
  900,
  100,
  100,
  pg_catalog.clock_timestamp() + interval '1 hour',
  pg_catalog.clock_timestamp()
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';

insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media',
  organization.id::text || '/posts/91000000-0000-4000-8000-000000000004/96000000-0000-4000-8000-000000000089.jpg',
  'a1200000-0000-4000-8000-000000000001'::uuid,
  'c1100000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":"444"}'::jsonb
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';

insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status,
  approved_mime_type, approved_byte_size, approved_width, approved_height,
  expires_at, approved_at
)
select
  '96000000-0000-4000-8000-000000000003',
  'a1200000-0000-4000-8000-000000000001',
  organization.id,
  'organization_hero',
  organization.id,
  'image',
  'image/jpeg',
  1000,
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000003/upload.jpg',
  'community-media',
  organization.id::text || '/organization/96000000-0000-4000-8000-000000000003.jpg',
  'approved',
  'image/jpeg',
  900,
  100,
  100,
  pg_catalog.clock_timestamp() + interval '1 hour',
  pg_catalog.clock_timestamp()
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';

insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status,
  approved_mime_type, approved_byte_size, approved_width, approved_height,
  expires_at, approved_at
)
select
  '96000000-0000-4000-8000-000000000004',
  'a1200000-0000-4000-8000-000000000001',
  organization.id,
  'application_evidence',
  '98000000-0000-4000-8000-000000000001',
  'image',
  'image/jpeg',
  1000,
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000004/upload.jpg',
  'community-media',
  organization.id::text || '/applications/98000000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000004.jpg',
  'approved',
  'image/jpeg',
  900,
  100,
  100,
  pg_catalog.clock_timestamp() + interval '1 hour',
  pg_catalog.clock_timestamp()
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';

insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status,
  approved_mime_type, approved_byte_size, approved_width, approved_height,
  expires_at, approved_at
)
select
  '96000000-0000-4000-8000-000000000005',
  'a1200000-0000-4000-8000-000000000001',
  organization.id,
  'message',
  '93000000-0000-4000-8000-000000000002',
  'image',
  'image/jpeg',
  1000,
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000005/upload.jpg',
  'community-media',
  organization.id::text || '/messages/93000000-0000-4000-8000-000000000002/96000000-0000-4000-8000-000000000005.jpg',
  'approved',
  'image/jpeg',
  900,
  100,
  100,
  pg_catalog.clock_timestamp() + interval '1 hour',
  pg_catalog.clock_timestamp()
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';

insert into public.media_upload_intents (
  id, uploader_id, organization_id, purpose, target_id, kind,
  expected_mime_type, expected_byte_size, quarantine_path,
  approved_bucket_id, approved_path, status, expires_at
)
select
  '96000000-0000-4000-8000-000000000006',
  'a1200000-0000-4000-8000-000000000001',
  organization.id,
  'post',
  '91000000-0000-4000-8000-000000000004',
  'image',
  'image/jpeg',
  1000,
  'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000006/upload.jpg',
  'community-media',
  organization.id::text || '/posts/91000000-0000-4000-8000-000000000004/96000000-0000-4000-8000-000000000006.jpg',
  'quarantine',
  pg_catalog.clock_timestamp() + interval '1 hour'
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';

select set_config(
  'request.jwt.claims',
  '{"sub":"a1200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1200000-0000-4000-8000-000000000001', true);
update public.profiles
set avatar_path = (
  select approved_path from public.media_upload_intents
  where id = '96000000-0000-4000-8000-000000000001'
)
where id = 'a1200000-0000-4000-8000-000000000001';
insert into public.post_media (
  post_id, uploader_id, storage_path, kind, mime_type, byte_size, width, height
)
select
  '91000000-0000-4000-8000-000000000004',
  'a1200000-0000-4000-8000-000000000001',
  approved_path,
  'image',
  'image/jpeg',
  900,
  100,
  100
from public.media_upload_intents
where id = '96000000-0000-4000-8000-000000000002';
update public.organizations
set hero_path = (
  select approved_path from public.media_upload_intents
  where id = '96000000-0000-4000-8000-000000000003'
)
where slug = 'jaegun-bupyeong';
insert into storage.objects (
  bucket_id, name, owner, owner_id, metadata
)
select
  intent.approved_bucket_id,
  intent.approved_path,
  'a1200000-0000-4000-8000-000000000001'::uuid,
  'a1200000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":"900"}'::jsonb
from public.media_upload_intents as intent
where intent.id = '96000000-0000-4000-8000-000000000003';

-- Replace the scanner-intent hero with a current-production direct hero, and
-- leave one direct orphan. Deletion inventory must preserve/transfer only the
-- current hero while queueing both the orphan and retired scanned derivative.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media',
  organization.id::text || '/organization/96000000-0000-4000-8000-000000000007.webp',
  'a1200000-0000-4000-8000-000000000001'::uuid,
  'a1200000-0000-4000-8000-000000000001',
  '{"mimetype":"image/webp","size":"1200"}'::jsonb
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';
update public.organizations
set hero_path = id::text || '/organization/96000000-0000-4000-8000-000000000007.webp'
where slug = 'jaegun-bupyeong';

insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media',
  organization.id::text || '/posts/91000000-0000-4000-8000-000000000004/96000000-0000-4000-8000-000000000008.jpg',
  'a1200000-0000-4000-8000-000000000001'::uuid,
  'a1200000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":"700"}'::jsonb
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';
update public.membership_applications
set evidence_path = (
  select approved_path from public.media_upload_intents
  where id = '96000000-0000-4000-8000-000000000004'
)
where id = '98000000-0000-4000-8000-000000000001';

select set_config(
  'request.jwt.claims',
  '{"sub":"a1200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select lives_ok(
  format(
    'select public.send_message(%L, ''image'', null, %L, ''{}''::jsonb, %L)',
    '93000000-0000-4000-8000-000000000002',
    (
      select approved_path from public.media_upload_intents
      where id = '96000000-0000-4000-8000-000000000005'
    ),
    '94600000-0000-4000-8000-000000000001'
  ),
  'approved message media attaches through the validated send_message RPC'
);

reset role;
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media',
  organization.id::text || '/messages/93000000-0000-4000-8000-000000000002/96000000-0000-4000-8000-000000000099.jpg',
  'c1100000-0000-4000-8000-000000000001'::uuid,
  'c1100000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":"333"}'::jsonb
from public.organizations as organization
where organization.slug = 'jaegun-bupyeong';
update public.messages
set media_path = (
      select organization.id::text || '/messages/93000000-0000-4000-8000-000000000002/96000000-0000-4000-8000-000000000099.jpg'
      from public.organizations as organization
      where organization.slug = 'jaegun-bupyeong'
    ),
    media_metadata = '{"mime_type":"image/jpeg","byte_size":333}'::jsonb
where client_nonce = '94600000-0000-4000-8000-000000000001';

update public.account_deletion_requests
set requested_at = pg_catalog.clock_timestamp() - interval '15 days',
    scheduled_for = pg_catalog.clock_timestamp() - interval '1 day'
where user_id = 'a1200000-0000-4000-8000-000000000001'
  and status = 'requested';

create temporary table test_deletion_claims (
  request_id uuid,
  user_id uuid,
  subject_fingerprint text,
  cleanup_items jsonb
);
grant all on table test_deletion_claims to service_role;
create temporary table test_deletion_finalize (result jsonb);
grant all on table test_deletion_finalize to service_role;
create temporary table test_identity_deletion_claims (
  request_id uuid,
  user_id uuid,
  subject_fingerprint text,
  identity_attempts integer
);
grant all on table test_identity_deletion_claims to service_role;
create temporary table test_identity_deletion_reclaims (
  request_id uuid,
  user_id uuid,
  subject_fingerprint text,
  identity_attempts integer
);
grant all on table test_identity_deletion_reclaims to service_role;
create temporary table test_deletion_paths as
select
  max(approved_path) filter (
    where id = '96000000-0000-4000-8000-000000000002'
  ) as approved_post_path,
  max(approved_path) filter (
    where id = '96000000-0000-4000-8000-000000000003'
  ) as retired_scanned_hero_path,
  (
    select organization.hero_path
    from public.organizations as organization
    where organization.slug = 'jaegun-bupyeong'
  ) as attached_hero_path,
  (
    select object.name
    from storage.objects as object
    where object.owner_id = 'a1200000-0000-4000-8000-000000000001'
      and object.name like '%/96000000-0000-4000-8000-000000000008.jpg'
  ) as direct_orphan_path,
  (
    select object.name
    from storage.objects as object
    where object.owner_id = 'c1100000-0000-4000-8000-000000000001'
      and object.name like '%/96000000-0000-4000-8000-000000000099.jpg'
  ) as foreign_owned_message_path,
  (
    select organization.id::text || '/posts/91000000-0000-4000-8000-000000000004/96000000-0000-4000-8000-000000000089.jpg'
    from public.organizations as organization
    where organization.slug = 'jaegun-bupyeong'
  ) as mismatched_owner_path,
  max(quarantine_path) filter (
    where id = '96000000-0000-4000-8000-000000000006'
  ) as quarantined_post_path
from public.media_upload_intents;
grant all on table test_deletion_paths to service_role;
grant select on table test_deletion_paths to authenticated;

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_deletion_claims
select * from public.service_claim_due_account_deletions(10);
select is(
  (select count(*) from test_deletion_claims),
  1::bigint,
  'service worker claims the due verified account deletion request'
);
select ok(
  (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select approved_post_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'deletion cleanup inventory includes user-owned approved post media'
);
select ok(
  (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select quarantined_post_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'deletion cleanup inventory includes still-quarantined bytes'
);
select ok(
  (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select direct_orphan_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'deletion cleanup inventory includes a no-intent direct orphan object'
);
select ok(
  (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select retired_scanned_hero_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'retired scanned hero derivative is cleaned after direct hero replacement'
);
select ok(
  not (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select attached_hero_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'attached organization hero derivative is retained as organization-owned'
);
select ok(
  not (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select foreign_owned_message_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'forged legacy message reference cannot queue another member Storage object'
);
select ok(
  not (
    select cleanup_items @> pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'storage_path',
        (select mismatched_owner_path from test_deletion_paths)
      )
    )
    from test_deletion_claims
  ),
  'account deletion does not claim a corrupt object with disagreeing owner columns'
);
reset role;
delete from storage.objects as object
using test_deletion_paths as path
where object.bucket_id = 'community-media'
  and object.name = path.mismatched_owner_path;
select ok(
  exists (
    select 1
    from storage.objects as object
    join test_deletion_paths as path
      on path.attached_hero_path = object.name
    where object.bucket_id = 'community-media'
      and object.owner_id is null
      and object.owner is null
  ),
  'preserved organization hero remains while user Storage ownership is cleared'
);
select ok(
  exists (
    select 1 from public.audit_logs
    where action = 'account.storage_ownership_transferred'
      and target_user_id = 'a1200000-0000-4000-8000-000000000001'
  ),
  'organization hero ownership transfer is audit logged'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"a1200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',
  true
);
select set_config('request.jwt.claim.sub', 'a1200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  private.authorize_direct_media_upload(
    'avatars',
    'a1200000-0000-4000-8000-000000000001/96000000-0000-4000-8000-000000000098.jpg',
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"100"}'::jsonb
  ),
  false,
  'stale authenticated session cannot upload an avatar after deletion claim freeze'
);
select is(
  private.can_write_quarantine_media(
    (select quarantined_post_path from test_deletion_paths),
    auth.uid(),
    '{"mimetype":"image/jpeg","size":"1000"}'::jsonb
  ),
  false,
  'stale authenticated session cannot mutate quarantine bytes after deletion claim freeze'
);
reset role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
delete from storage.objects as object
using test_deletion_claims as claim,
      lateral pg_catalog.jsonb_array_elements(claim.cleanup_items) as cleanup(item)
where object.bucket_id = cleanup.item ->> 'bucket_id'
  and object.name = cleanup.item ->> 'storage_path';
select public.service_mark_account_cleanup_item(
  (item ->> 'id')::uuid,
  'deleted',
  null
)
from test_deletion_claims
cross join lateral pg_catalog.jsonb_array_elements(cleanup_items) as cleanup(item);

-- Simulate a response-loss/out-of-band service race after the worker reported
-- this path deleted. Finalize must reactivate the terminal cleanup row instead
-- of deleting the Auth identity while owned bytes remain.
insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
select
  'community-media',
  direct_orphan_path,
  'a1200000-0000-4000-8000-000000000001'::uuid,
  'a1200000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":"700"}'::jsonb
from test_deletion_paths;
insert into test_deletion_finalize (result)
select public.service_finalize_account_anonymization(request_id)
from test_deletion_claims;
select is(
  (select result ->> 'status' from test_deletion_finalize),
  'processing',
  'finalize refuses identity deletion when a terminal cleanup path reappears'
);
select is(
  (select result ->> 'error_code' from test_deletion_finalize),
  'storage_cleanup_incomplete',
  'late owner inventory persists a stable cleanup retry result'
);
reset role;
select is(
  (
    select cleanup.status
    from private.account_deletion_cleanup_items as cleanup
    join test_deletion_claims as claim on claim.request_id = cleanup.request_id
    where cleanup.storage_path =
      (select direct_orphan_path from test_deletion_paths)
  ),
  'pending',
  'finalize reactivates a deleted cleanup row when exact bytes exist again'
);
create temporary table test_reactivated_account_cleanup (item_id uuid primary key);
grant select on table test_reactivated_account_cleanup to service_role;
insert into test_reactivated_account_cleanup
select cleanup.id
from private.account_deletion_cleanup_items as cleanup
join test_deletion_claims as claim on claim.request_id = cleanup.request_id
where cleanup.storage_path = (select direct_orphan_path from test_deletion_paths);
delete from storage.objects as object
where object.bucket_id = 'community-media'
  and object.name = (select direct_orphan_path from test_deletion_paths);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select public.service_mark_account_cleanup_item(
  cleanup.item_id,
  'deleted',
  null
)
from test_reactivated_account_cleanup as cleanup;
delete from test_deletion_finalize;
insert into test_deletion_finalize (result)
select public.service_finalize_account_anonymization(request_id)
from test_deletion_claims;
select is(
  (select result ->> 'status' from test_deletion_finalize),
  'awaiting_identity_deletion',
  'Storage-complete account is anonymized before Auth identity deletion'
);
reset role;
select is(
  (
    select count(*)
    from private.direct_media_upload_reservations as reservation
    where reservation.uploader_id = 'a1200000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'account anonymization removes private direct-upload reservation history'
);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_identity_deletion_claims
select * from public.service_claim_pending_identity_deletions(10);
select is(
  (select user_id from test_identity_deletion_claims),
  'a1200000-0000-4000-8000-000000000001'::uuid,
  'identity worker receives the user ID for the Auth Admin deletion attempt'
);
select is(
  (select count(*) from public.service_claim_pending_identity_deletions(10)),
  0::bigint,
  'fresh identity deletion lease is not claimed concurrently'
);
select throws_ok(
  format(
    'select public.service_mark_account_cleanup_item(%L, ''deleted'', null)',
    (
      select (item ->> 'id')::uuid
      from test_deletion_claims
      cross join lateral pg_catalog.jsonb_array_elements(cleanup_items) as cleanup(item)
      limit 1
    )
  ),
  '55000',
  'cleanup_item_not_in_processing_request',
  'cleanup outcome cannot be changed after the request leaves processing'
);

reset role;
select is(
  (
    select status from public.posts
    where id = '91000000-0000-4000-8000-000000000004'
  )::text,
  'deleted',
  'account anonymization tombstones authored posts before Storage/Auth deletion'
);
select ok(
  exists (
    select 1 from public.messages
    where conversation_id = '93000000-0000-4000-8000-000000000002'
      and sender_id = 'a1200000-0000-4000-8000-000000000001'
      and deleted_at is not null
      and body is null
      and media_path is null
  ),
  'account anonymization tombstones authored messages and clears media references'
);
select is(
  (
    select hero_path from public.organizations
    where slug = 'jaegun-bupyeong'
  ),
  (
    select attached_hero_path from test_deletion_paths
  ),
  'direct organization hero remains attached after uploader anonymization'
);

delete from auth.users
where id = 'a1200000-0000-4000-8000-000000000001';
select is(
  (
    select count(*) from public.conversations
    where id = '93000000-0000-4000-8000-000000000002'
  ),
  1::bigint,
  'Auth/profile deletion does not delete the surviving participant conversation'
);
select ok(
  exists (
    select 1 from public.messages
    where conversation_id = '93000000-0000-4000-8000-000000000002'
      and sender_id is null
      and deleted_at is not null
  ),
  'tombstoned message history remains with an anonymized sender reference'
);
select ok(
  not exists (
    select 1
    from private.account_deletion_cleanup_items as cleanup
    join public.organizations as organization
      on organization.slug = 'jaegun-bupyeong'
     and cleanup.storage_path = organization.hero_path
    where cleanup.request_id = (select request_id from test_deletion_claims)
  ),
  'organization hero is deliberately absent from the user cleanup queue'
);

update public.account_deletion_requests as request
set identity_claimed_at = pg_catalog.clock_timestamp() - interval '11 minutes'
where request.id = (select request_id from test_deletion_claims);

select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
insert into test_identity_deletion_reclaims
select * from public.service_claim_pending_identity_deletions(10);
select ok(
  exists (
    select 1 from test_identity_deletion_reclaims
    where request_id = (select request_id from test_deletion_claims)
      and user_id is null
      and identity_attempts = 2
  ),
  'lost Auth deletion response is recoverable after the profile FK becomes null'
);
select is(
  (
    public.service_complete_account_deletion(
      (select request_id from test_deletion_claims)
    ) ->> 'status'
  ),
  'completed',
  'service records completion only after Auth deletion nulls the profile FK'
);

reset role;

-- Secondary actor columns are not direct REST surfaces. Authorized clients
-- retain the exact safe columns used by the production bootstrap.
select ok(
  not pg_catalog.has_column_privilege('authenticated', 'public.organizations', 'claimed_by', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.boards', 'created_by', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.organization_memberships', 'approved_by', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.organization_memberships', 'approved_from_application_id', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.membership_applications', 'reviewed_by', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.membership_applications', 'evidence_path', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.executive_office_assignments', 'assigned_by', 'select')
  and not pg_catalog.has_column_privilege('authenticated', 'public.platform_admins', 'granted_by', 'select')
  and not pg_catalog.has_table_privilege('authenticated', 'public.event_revisions', 'select')
  and not pg_catalog.has_table_privilege('authenticated', 'public.audit_logs', 'select')
  and not pg_catalog.has_table_privilege('authenticated', 'public.content_reports', 'select')
  and not pg_catalog.has_table_privilege('authenticated', 'public.moderation_actions', 'select'),
  'direct REST cannot select secondary UUIDs, raw revisions, audits, or moderation evidence'
);

select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select claimed_by from public.organizations limit 1$$,
  '42501',
  null,
  'organization claimer UUID is denied at the column privilege boundary'
);
select throws_ok(
  $$select created_by from public.boards limit 1$$,
  '42501',
  null,
  'board creator UUID is denied at the column privilege boundary'
);
select throws_ok(
  $$select approved_by from public.organization_memberships limit 1$$,
  '42501',
  null,
  'membership approver UUID is denied at the column privilege boundary'
);
select throws_ok(
  $$select reviewed_by from public.membership_applications limit 1$$,
  '42501',
  null,
  'application reviewer UUID is denied at the column privilege boundary'
);
select throws_ok(
  $$select assigned_by from public.executive_office_assignments limit 1$$,
  '42501',
  null,
  'executive assignment actor UUID is denied at the column privilege boundary'
);
select throws_ok(
  $$select snapshot from public.event_revisions limit 1$$,
  '42501',
  null,
  'raw event revision snapshots are RPC-only'
);
select throws_ok(
  $$select action from public.audit_logs limit 1$$,
  '42501',
  null,
  'raw audit records are not exposed through authenticated REST'
);
select throws_ok(
  $$select evidence_snapshot from public.content_reports limit 1$$,
  '42501',
  null,
  'raw moderation evidence is available only through the redacting RPC'
);
select throws_ok(
  $$select actor_id from public.moderation_actions limit 1$$,
  '42501',
  null,
  'raw moderation action actor metadata is not exposed through REST'
);
select lives_ok(
  $$select id, display_name, status from public.organizations limit 1$$,
  'authorized clients retain safe organization columns'
);
select lives_ok(
  $$select id, slug, name from public.boards limit 1$$,
  'authorized clients retain safe board columns'
);
select lives_ok(
  $$select id from public.organization_memberships limit 1$$,
  'authorized clients retain only the opaque membership id for Realtime invalidation'
);
reset role;

-- Target withdrawal hides live community relations and identifiers while
-- preserving authorized immutable moderation evidence.
insert into public.post_media (
  post_id, uploader_id, storage_path, kind, mime_type, byte_size, width, height
)
select
  '91000000-0000-4000-8000-000000000001',
  'c1100000-0000-4000-8000-000000000001',
  path.storage_path,
  'image',
  path.mime_type,
  path.byte_size,
  20,
  20
from test_direct_media_paths as path
where path.label = 'target_post';

insert into public.conversations (
  id, organization_id, participant_low, participant_high, created_by
)
values (
  '96000000-0000-4000-8000-000000000101',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'c1100000-0000-4000-8000-000000000001',
  'd1100000-0000-4000-8000-000000000001',
  'd1100000-0000-4000-8000-000000000001'
);
insert into public.conversation_reads (conversation_id, user_id)
values
  ('96000000-0000-4000-8000-000000000101', 'c1100000-0000-4000-8000-000000000001'),
  ('96000000-0000-4000-8000-000000000101', 'd1100000-0000-4000-8000-000000000001');
insert into public.messages (
  id, conversation_id, sender_id, kind, body, client_nonce
)
values (
  '96000000-0000-4000-8000-000000000102',
  '96000000-0000-4000-8000-000000000101',
  'c1100000-0000-4000-8000-000000000001',
  'text',
  '철회 전에 보낸 대상 경계 메시지',
  '96000000-0000-4000-8000-000000000104'
);
insert into public.notifications (
  id, user_id, kind, title, body, entity_type, entity_id, metadata
)
values (
  '96000000-0000-4000-8000-000000000103',
  'd1100000-0000-4000-8000-000000000001',
  'new_message',
  '밥님의 새 메시지',
  '앱에서 내용을 확인해 주세요.',
  'conversation',
  '96000000-0000-4000-8000-000000000101',
  '{"message_id":"96000000-0000-4000-8000-000000000102"}'::jsonb
);

update public.organization_memberships
set role = 'executive'::public.app_role
where user_id = 'c1100000-0000-4000-8000-000000000001'
  and status = 'active'::public.membership_status;

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source, withdrawn_at
)
values (
  'c1100000-0000-4000-8000-000000000001',
  'privacy_policy',
  '2026-08-30',
  false,
  'app',
  pg_catalog.clock_timestamp()
);

select set_config(
  'test.withdrawn_target_membership',
  (
    select id::text
    from public.organization_memberships
    where user_id = 'c1100000-0000-4000-8000-000000000001'
      and status = 'active'
  ),
  true
);
select set_config(
  'test.withdrawn_target_scope',
  (
    select scope.id::text
    from public.governance_scopes as scope
    join public.organizations as organization
      on organization.id = scope.organization_id
    where scope.scope_type = 'church'::public.governance_scope_type
      and organization.slug = 'jaegun-bupyeong'
      and scope.is_active
  ),
  true
);
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"e1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select public.set_governance_offices(
    current_setting('test.withdrawn_target_scope')::uuid,
    current_setting('test.release_service_year')::integer,
    'c1100000-0000-4000-8000-000000000001',
    array['secretary']::text[]
  )$$,
  '42501',
  'governance_office_management_forbidden',
  'foreign-scope office set cannot probe the withdrawn target consent state'
);
select throws_ok(
  $$select public.assign_governance_office(
    current_setting('test.withdrawn_target_scope')::uuid,
    current_setting('test.release_service_year')::integer,
    'secretary',
    'c1100000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'governance_office_management_forbidden',
  'foreign-scope single assignment cannot probe the withdrawn target'
);
select throws_ok(
  $$select public.set_executive_offices(
    current_setting('test.withdrawn_target_membership')::uuid,
    current_setting('test.release_service_year')::integer,
    array['secretary']::text[]
  )$$,
  '42501',
  'governance_office_management_forbidden',
  'foreign-scope legacy assignment cannot probe membership or target state'
);
select throws_ok(
  $$select public.grant_governance_delegation(
    current_setting('test.withdrawn_target_scope')::uuid,
    'c1100000-0000-4000-8000-000000000001',
    array['view_roster']::text[],
    statement_timestamp() + interval '1 day',
    'oracle probe'
  )$$,
  '42501',
  'native_scope_authority_required_for_delegation',
  'foreign-scope governance grant cannot probe target consent'
);
select throws_ok(
  $$select public.grant_event_management_delegation(
    current_setting('test.withdrawn_target_scope')::uuid,
    'c1100000-0000-4000-8000-000000000001',
    statement_timestamp() + interval '1 day',
    'oracle probe'
  )$$,
  '42501',
  'native_scope_authority_required_for_delegation',
  'foreign-scope event grant cannot probe target consent'
);
reset role;
select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select public.set_governance_offices(
    current_setting('test.withdrawn_target_scope')::uuid,
    current_setting('test.release_service_year')::integer,
    'c1100000-0000-4000-8000-000000000001',
    array['secretary']::text[]
  )$$,
  '42501',
  'target_current_required_consents_required',
  'governance office set rejects a withdrawn target before eligibility lookup'
);
select throws_ok(
  $$select public.assign_governance_office(
    current_setting('test.withdrawn_target_scope')::uuid,
    current_setting('test.release_service_year')::integer,
    'secretary',
    'c1100000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'target_current_required_consents_required',
  'single governance office assignment rejects a withdrawn target first'
);
select throws_ok(
  $$select public.set_executive_offices(
    current_setting('test.withdrawn_target_membership')::uuid,
    current_setting('test.release_service_year')::integer,
    array['secretary']::text[]
  )$$,
  '42501',
  'target_current_required_consents_required',
  'legacy executive office assignment rejects a withdrawn membership target first'
);
select throws_ok(
  $$select public.grant_governance_delegation(
    current_setting('test.withdrawn_target_scope')::uuid,
    'c1100000-0000-4000-8000-000000000001',
    array['view_roster']::text[],
    statement_timestamp() + interval '1 day',
    'target boundary probe'
  )$$,
  '42501',
  'target_current_required_consents_required',
  'governance delegation rejects a withdrawn target before membership probing'
);
select throws_ok(
  $$select public.grant_event_management_delegation(
    current_setting('test.withdrawn_target_scope')::uuid,
    'c1100000-0000-4000-8000-000000000001',
    statement_timestamp() + interval '1 day',
    'target boundary probe'
  )$$,
  '42501',
  'target_current_required_consents_required',
  'event delegation rejects a withdrawn target before membership probing'
);
reset role;

select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select ok(
  (
    select count(*)
    from public.list_visible_profiles(
      array['c1100000-0000-4000-8000-000000000001'::uuid]
    )
  ) = 0
  and (
    select count(*)
    from public.list_visible_organization_memberships(
      (select id from public.organizations where slug = 'jaegun-bupyeong'),
      500,
      0
    )
    where user_id = 'c1100000-0000-4000-8000-000000000001'
  ) = 0
  and (select count(*) from public.posts where author_id = 'c1100000-0000-4000-8000-000000000001') = 0
  and (select count(*) from public.comments where author_id = 'c1100000-0000-4000-8000-000000000001') = 0
  and (select count(*) from public.messages where conversation_id = '96000000-0000-4000-8000-000000000101') = 0,
  'target withdrawal hides profile, roster, posts, comments, and direct messages'
);
select is(
  (
    select count(*)
    from public.post_media
    where storage_path = (
      select storage_path from test_direct_media_paths where label = 'target_post'
    )
  ),
  0::bigint,
  'target withdrawal hides post-media metadata uploaded by that target'
);
select is(
  (
    select count(*)
    from storage.objects
    where bucket_id = 'community-media'
      and name = (
        select storage_path from test_direct_media_paths where label = 'target_post'
      )
  ),
  0::bigint,
  'target withdrawal blocks new Storage reads for that uploader bytes'
);
select is(
  (
    select count(*) from public.notifications
    where id = '96000000-0000-4000-8000-000000000103'
  ),
  0::bigint,
  'target withdrawal hides denormalized sender notification content'
);
select throws_ok(
  $$select * from public.reconcile_message_batch(
    '96000000-0000-4000-8000-000000000101',
    'd1100000-0000-4000-8000-000000000001',
    array['96000000-0000-4000-8000-000000000104']::uuid[]
  )$$,
  '42501',
  'conversation_access_forbidden',
  'target withdrawal closes message reconciliation for the conversation'
);
select ok(
  exists (
    select 1
    from public.list_moderation_reports(null, 50) as report
    where report.reported_user_id = 'c1100000-0000-4000-8000-000000000001'
  ),
  'authorized moderator retains immutable report evidence through the redacting RPC'
);
select ok(
  exists (
    select 1
    from public.list_moderation_reports(null, 50) as report
    where report.reported_user_id = 'c1100000-0000-4000-8000-000000000001'
      and report.target_author_name = '동의 갱신 필요 회원'
      and report.evidence_summary = '동의 갱신 필요 회원'
  ),
  'moderation RPC preserves evidence while pseudonymizing the withdrawn target'
);

reset role;
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select set_config(
  'test.withdrawn_source_push_claim_count',
  (select count(*)::text from public.service_claim_push_jobs(50)),
  true
);
reset role;
select is(
  (
    select status
    from private.push_outbox
    where idempotency_key = 'notification:96000000-0000-4000-8000-000000000103'
  ),
  'dead',
  'push claim suppresses a queued notification whose source target withdrew'
);

-- Existing executive membership and annual-office metadata cannot bypass the
-- exact current-consent boundary through direct REST or SECURITY DEFINER
-- save/delete paths.
reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config(
  'test.closed_exec_org',
  (select id::text from public.organizations where slug = 'jaegun-namseoul'),
  true
);
select set_config(
  'test.closed_exec_year',
  private.current_service_year()::text,
  true
);
select set_config(
  'test.closed_exec_date',
  pg_catalog.make_date(private.current_service_year(), 1, 2)::text,
  true
);
insert into public.executive_office_assignments (
  membership_id, service_year, office_code, assigned_by
)
select membership.id, private.current_service_year(), office.code,
       'a1100000-0000-4000-8000-000000000001'
from public.organization_memberships as membership
cross join (values ('secretary'), ('treasurer')) as office(code)
where membership.user_id = 'e1100000-0000-4000-8000-000000000001'
  and membership.status = 'active';
delete from public.governance_office_assignments as assignment
using public.governance_scopes as scope
where scope.id = assignment.scope_id
  and scope.scope_type = 'church'::public.governance_scope_type
  and scope.organization_id = current_setting('test.closed_exec_org')::uuid
  and assignment.service_year = private.current_service_year()
  and assignment.ended_at is null
  and assignment.office_code in ('secretary', 'treasurer');
insert into public.governance_office_assignments (
  scope_id, user_id, service_year, office_code, assigned_by
)
select scope.id,
       'e1100000-0000-4000-8000-000000000001',
       private.current_service_year(),
       office.code,
       'a1100000-0000-4000-8000-000000000001'
from public.governance_scopes as scope
cross join (values ('secretary'), ('treasurer')) as office(code)
where scope.scope_type = 'church'::public.governance_scope_type
  and scope.organization_id = current_setting('test.closed_exec_org')::uuid
  and scope.is_active;
insert into public.meeting_minutes (
  id, organization_id, meeting_year, meeting_date, title, body, status,
  author_id, author_name
)
values (
  '96000000-0000-4000-8000-000000000201',
  current_setting('test.closed_exec_org')::uuid,
  current_setting('test.closed_exec_year')::smallint,
  current_setting('test.closed_exec_date')::date,
  '동의 경계 회의록',
  '재동의 전후 접근 경계를 검증합니다.',
  'draft',
  'e1100000-0000-4000-8000-000000000001',
  '다른교회 임원'
);
insert into public.ledger_entries (
  id, organization_id, fiscal_year, entry_date, entry_type, category,
  description, amount, memo, author_id, author_name
)
values (
  '96000000-0000-4000-8000-000000000202',
  current_setting('test.closed_exec_org')::uuid,
  current_setting('test.closed_exec_year')::smallint,
  current_setting('test.closed_exec_date')::date,
  'income',
  '헌금',
  '동의 경계 회계 테스트',
  10000,
  null,
  'e1100000-0000-4000-8000-000000000001',
  '다른교회 임원'
);
insert into public.user_consents (
  user_id, document_key, document_version, accepted, source, withdrawn_at
)
values (
  'e1100000-0000-4000-8000-000000000001',
  'privacy_policy',
  '2026-08-30',
  false,
  'app',
  pg_catalog.clock_timestamp()
);

select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"e1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select ok(
  (select count(*) from public.executive_office_assignments) = 0
  and (select count(*) from public.meeting_minutes) = 0
  and (select count(*) from public.ledger_entries) = 0,
  'closed-gate executive sees zero assignment, minutes, and ledger rows'
);
select throws_ok(
  $$select public.save_meeting_minute(
    '96000000-0000-4000-8000-000000000201',
    false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    '변경 시도', '본문 변경 시도', 'draft'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate executive cannot update an existing meeting minute by RPC'
);
select throws_ok(
  $$select public.delete_meeting_minute(
    '96000000-0000-4000-8000-000000000201'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate executive cannot delete an existing meeting minute by RPC'
);
select throws_ok(
  $$select public.save_ledger_entry(
    '96000000-0000-4000-8000-000000000202',
    false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'income', '헌금', '변경 시도', 20000, null
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate executive cannot update an existing ledger entry by RPC'
);
select throws_ok(
  $$select public.delete_ledger_entry(
    '96000000-0000-4000-8000-000000000202'
  )$$,
  '42501',
  'current_required_consents_required',
  'closed-gate executive cannot delete an existing ledger entry by RPC'
);
reset role;
select ok(
  exists (
    select 1 from public.meeting_minutes
    where id = '96000000-0000-4000-8000-000000000201'
  )
  and exists (
    select 1 from public.ledger_entries
    where id = '96000000-0000-4000-8000-000000000202'
  ),
  'closed-gate executive RPC attempts leave both protected records unchanged'
);

-- A scoped executive must not distinguish another church's live records,
-- durable deletion tombstones, or never-used operation IDs. Restore the one
-- withdrawn consent first so this section exercises resource authorization,
-- not the actor-consent guard above.
insert into public.meeting_minutes (
  id, organization_id, meeting_year, meeting_date, title, body, status,
  author_id, author_name
)
values (
  '96000000-0000-4000-8000-000000000221',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  current_setting('test.closed_exec_year')::smallint,
  current_setting('test.closed_exec_date')::date,
  '타 교회 회의록',
  '교차 범위 UUID 오라클 검증용 원본입니다.',
  'draft',
  'd1100000-0000-4000-8000-000000000001',
  '교회 사역자'
);
insert into public.ledger_entries (
  id, organization_id, fiscal_year, entry_date, entry_type, category,
  description, amount, memo, author_id, author_name
)
values (
  '96000000-0000-4000-8000-000000000222',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  current_setting('test.closed_exec_year')::smallint,
  current_setting('test.closed_exec_date')::date,
  'income',
  '타 교회',
  '교차 범위 UUID 오라클 검증용 원본',
  12000,
  null,
  'd1100000-0000-4000-8000-000000000001',
  '교회 사역자'
);
insert into private.executive_operation_tombstones (
  entity_type, entity_id, organization_id, deleted_by
)
values
  (
    'meeting_minute',
    '96000000-0000-4000-8000-000000000223',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'a1100000-0000-4000-8000-000000000001'
  ),
  (
    'ledger_entry',
    '96000000-0000-4000-8000-000000000224',
    (select id from public.organizations where slug = 'jaegun-bupyeong'),
    'a1100000-0000-4000-8000-000000000001'
  );
insert into public.user_consents (
  user_id, document_key, document_version, accepted, source
)
values (
  'e1100000-0000-4000-8000-000000000001',
  'privacy_policy',
  '2026-08-30',
  true,
  'app'
);

select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"e1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select public.save_meeting_minute(
    '96000000-0000-4000-8000-000000000221', false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'foreign live probe', 'foreign live probe', 'draft'
  )$$,
  'P0002',
  'meeting_minute_not_found_or_forbidden',
  'meeting save hides a foreign live operation ID'
);
select throws_ok(
  $$select public.save_meeting_minute(
    '96000000-0000-4000-8000-000000000223', false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'foreign tombstone probe', 'foreign tombstone probe', 'draft'
  )$$,
  'P0002',
  'meeting_minute_not_found_or_forbidden',
  'meeting save gives the same response for a foreign tombstone'
);
select throws_ok(
  $$select public.save_meeting_minute(
    '96000000-0000-4000-8000-000000000225', false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'missing probe', 'missing probe', 'draft'
  )$$,
  'P0002',
  'meeting_minute_not_found_or_forbidden',
  'meeting save gives the same response for an unknown operation ID'
);
select throws_ok(
  $$select public.save_ledger_entry(
    '96000000-0000-4000-8000-000000000222', false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'income', 'foreign live probe', 'foreign live probe', 1000, null
  )$$,
  'P0002',
  'ledger_entry_not_found_or_forbidden',
  'ledger save hides a foreign live operation ID'
);
select throws_ok(
  $$select public.save_ledger_entry(
    '96000000-0000-4000-8000-000000000224', false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'income', 'foreign tombstone probe', 'foreign tombstone probe', 1000, null
  )$$,
  'P0002',
  'ledger_entry_not_found_or_forbidden',
  'ledger save gives the same response for a foreign tombstone'
);
select throws_ok(
  $$select public.save_ledger_entry(
    '96000000-0000-4000-8000-000000000226', false,
    current_setting('test.closed_exec_org')::uuid,
    current_setting('test.closed_exec_year')::integer,
    current_setting('test.closed_exec_date')::date,
    'income', 'missing probe', 'missing probe', 1000, null
  )$$,
  'P0002',
  'ledger_entry_not_found_or_forbidden',
  'ledger save gives the same response for an unknown operation ID'
);
select throws_ok(
  $$select public.delete_meeting_minute(
    '96000000-0000-4000-8000-000000000221'
  )$$,
  'P0002',
  'meeting_minute_not_found_or_forbidden',
  'meeting delete hides a foreign live record'
);
select throws_ok(
  $$select public.delete_meeting_minute(
    '96000000-0000-4000-8000-000000000225'
  )$$,
  'P0002',
  'meeting_minute_not_found_or_forbidden',
  'meeting delete gives the same response for an unknown record'
);
select throws_ok(
  $$select public.delete_ledger_entry(
    '96000000-0000-4000-8000-000000000222'
  )$$,
  'P0002',
  'ledger_entry_not_found_or_forbidden',
  'ledger delete hides a foreign live record'
);
select throws_ok(
  $$select public.delete_ledger_entry(
    '96000000-0000-4000-8000-000000000226'
  )$$,
  'P0002',
  'ledger_entry_not_found_or_forbidden',
  'ledger delete gives the same response for an unknown record'
);
reset role;

-- Privacy-field projection and search-oracle boundary ---------------------
reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config(
  'test.privacy_org',
  (select id::text from public.organizations where slug = 'jaegun-bupyeong'),
  true
);
select set_config(
  'test.privacy_scope',
  (
    select scope.id::text
    from public.governance_scopes as scope
    where scope.scope_type = 'church'::public.governance_scope_type
      and scope.organization_id = current_setting('test.privacy_org')::uuid
      and scope.is_active
  ),
  true
);
select set_config(
  'test.privacy_department',
  (
    select department.id::text
    from public.church_departments as department
    where department.church_scope_id = current_setting('test.privacy_scope')::uuid
      and department.department_code = 'adult'::public.church_department_code
      and department.is_active
  ),
  true
);

update public.profiles
set
  bio = case id
    when 'b1100000-0000-4000-8000-000000000001'::uuid
      then '앨리스 자기소개'
    else '사역자 비공개 자기소개'
  end
where id in (
  'b1100000-0000-4000-8000-000000000001',
  'd1100000-0000-4000-8000-000000000001'
);

update public.organization_memberships
set church_title_code = case user_id
  when 'b1100000-0000-4000-8000-000000000001'::uuid then 'deacon'
  else 'elder'
end
where organization_id = current_setting('test.privacy_org')::uuid
  and user_id in (
    'b1100000-0000-4000-8000-000000000001',
    'd1100000-0000-4000-8000-000000000001'
  );

delete from public.privacy_preferences
where user_id = 'd1100000-0000-4000-8000-000000000001';

insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
values (
  'avatars',
  'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg',
  'd1100000-0000-4000-8000-000000000001'::uuid,
  'd1100000-0000-4000-8000-000000000001',
  '{"mimetype":"image/jpeg","size":512}'::jsonb
);

select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
update public.profiles
set avatar_path = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
where id = 'd1100000-0000-4000-8000-000000000001';
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);

insert into public.conversations (
  id, organization_id, participant_low, participant_high, created_by
)
values (
  '97000000-0000-4000-8000-000000000002',
  current_setting('test.privacy_org')::uuid,
  'b1100000-0000-4000-8000-000000000001',
  'd1100000-0000-4000-8000-000000000001',
  'b1100000-0000-4000-8000-000000000001'
);
insert into public.conversation_reads (conversation_id, user_id)
values
  (
    '97000000-0000-4000-8000-000000000002',
    'b1100000-0000-4000-8000-000000000001'
  ),
  (
    '97000000-0000-4000-8000-000000000002',
    'd1100000-0000-4000-8000-000000000001'
  );

insert into public.department_office_assignments (
  department_id, user_id, service_year, office_code, assigned_by
)
values (
  current_setting('test.privacy_department')::uuid,
  'd1100000-0000-4000-8000-000000000001',
  private.current_service_year(),
  'president',
  'a1100000-0000-4000-8000-000000000001'
);

select ok(
  not pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'select')
  and not pg_catalog.has_table_privilege(
    'authenticated',
    'public.organization_memberships',
    'select'
  )
  and pg_catalog.has_column_privilege(
    'authenticated',
    'public.profiles',
    'id',
    'select'
  )
  and not pg_catalog.has_column_privilege(
    'authenticated',
    'public.profiles',
    'display_name',
    'select'
  )
  and pg_catalog.has_column_privilege(
    'authenticated',
    'public.organization_memberships',
    'id',
    'select'
  )
  and not pg_catalog.has_column_privilege(
    'authenticated',
    'public.organization_memberships',
    'church_title_code',
    'select'
  ),
  'semantic profile and membership columns are RPC-only while opaque ids retain self-update and Realtime compatibility'
);

select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select display_name from public.profiles limit 1$$,
  '42501',
  null,
  'authenticated direct profile SELECT is denied instead of bypassing field masks'
);
select throws_ok(
  $$select church_title_code from public.organization_memberships limit 1$$,
  '42501',
  null,
  'authenticated direct church-title SELECT is denied'
);
select lives_ok(
  $$select id from public.organization_memberships limit 1$$,
  'opaque membership id SELECT remains available for Realtime invalidation'
);
select throws_ok(
  $$select * from public.list_visible_profiles(array[]::uuid[])$$,
  '22023',
  'invalid_profile_directory_request',
  'profile projection rejects an empty UUID batch'
);
select throws_ok(
  $$select * from public.list_visible_profiles(
    pg_catalog.array_fill(
      'b1100000-0000-4000-8000-000000000001'::uuid,
      array[201]
    )
  )$$,
  '22023',
  'invalid_profile_directory_request',
  'profile projection rejects batches larger than 200 UUIDs'
);
select is(
  (
    select profile.bio
    from public.list_visible_profiles(
      array['b1100000-0000-4000-8000-000000000001'::uuid]
    ) as profile
  ),
  '앨리스 자기소개'::text,
  'profile projection always returns the authenticated user full self fields'
);
select ok(
  (
    select profile.avatar_path is null and profile.bio is null
    from public.list_visible_profiles(
      array['d1100000-0000-4000-8000-000000000001'::uuid]
    ) as profile
  ),
  'missing privacy preferences default peer avatar and bio visibility to false'
);
select is(
  (
    select count(*)
    from storage.objects
    where bucket_id = 'avatars'
      and name = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
  ),
  0::bigint,
  'missing avatar preference denies peer Storage reads'
);
reset role;

insert into public.privacy_preferences (
  user_id, avatar_visible, church_title_visible, bio_visible
)
values (
  'd1100000-0000-4000-8000-000000000001',
  false,
  false,
  false
);

select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select ok(
  (
    select profile.avatar_path is null and profile.bio is null
    from public.list_visible_profiles(
      array['d1100000-0000-4000-8000-000000000001'::uuid]
    ) as profile
  ),
  'explicit false avatar and bio preferences remain masked from peers'
);
select is(
  (
    select membership.church_title_code
    from public.list_visible_organization_memberships(
      current_setting('test.privacy_org')::uuid,
      500,
      0
    ) as membership
    where membership.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  null::text,
  'membership projection masks a peer church title when its toggle is false'
);
select is(
  (
    select participant.value ->> 'avatar_path'
    from public.get_conversation_summaries() as conversation
    cross join lateral pg_catalog.jsonb_array_elements(conversation.participants)
      as participant(value)
    where conversation.id = '97000000-0000-4000-8000-000000000002'
      and participant.value ->> 'id' = 'd1100000-0000-4000-8000-000000000001'
  ),
  null::text,
  'conversation summaries mask the peer avatar using the same preference boundary'
);
reset role;

select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"d1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select ok(
  (
    select profile.avatar_path = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
      and profile.bio = '사역자 비공개 자기소개'
    from public.list_visible_profiles(
      array['d1100000-0000-4000-8000-000000000001'::uuid]
    ) as profile
  ),
  'false public toggles do not redact the profile owner self view'
);
select is(
  (
    select membership.church_title_code
    from public.list_visible_organization_memberships(
      current_setting('test.privacy_org')::uuid,
      500,
      0
    ) as membership
    where membership.user_id = auth.uid()
  ),
  'elder'::text,
  'false public title toggle does not redact the membership owner self view'
);
select is(
  (
    select count(*)
    from storage.objects
    where bucket_id = 'avatars'
      and name = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
  ),
  1::bigint,
  'avatar owner retains self Storage read access while the public toggle is false'
);
reset role;

select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select lives_ok(
  $$select * from public.list_visible_organization_memberships(null, 500, 0)$$,
  'platform administrator can page the authorized cross-organization membership directory with a null organization filter'
);
select ok(
  (
    select roster.church_title_code is null
      and roster.church_title_name is null
    from public.list_governance_roster(
      current_setting('test.privacy_scope')::uuid,
      current_setting('test.release_service_year')::integer,
      null,
      200,
      0
    ) as roster
    where roster.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  'governance roster masks both church-title code and display name'
);
select is(
  (
    select count(*)
    from public.list_governance_roster(
      current_setting('test.privacy_scope')::uuid,
      current_setting('test.release_service_year')::integer,
      '장로',
      200,
      0
    ) as roster
    where roster.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'governance roster search cannot discover a hidden church title'
);
select ok(
  (
    select candidate.church_title_code is null
      and candidate.church_title_name is null
    from public.list_governance_office_candidates(
      current_setting('test.privacy_scope')::uuid,
      current_setting('test.release_service_year')::integer,
      'pastor',
      null,
      100,
      0
    ) as candidate
    where candidate.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  'governance office candidates mask both church-title fields'
);
select is(
  (
    select count(*)
    from public.list_governance_office_candidates(
      current_setting('test.privacy_scope')::uuid,
      current_setting('test.release_service_year')::integer,
      'pastor',
      '장로',
      100,
      0
    ) as candidate
    where candidate.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'governance candidate search cannot discover a hidden church title'
);
select is(
  (
    select candidate.church_title_code
    from public.list_department_office_candidates(
      current_setting('test.privacy_department')::uuid,
      current_setting('test.release_service_year')::integer,
      null,
      100,
      0
    ) as candidate
    where candidate.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  null::text,
  'department office candidates mask a hidden church title'
);
select is(
  (
    select count(*)
    from public.list_department_office_candidates(
      current_setting('test.privacy_department')::uuid,
      current_setting('test.release_service_year')::integer,
      '장로',
      100,
      0
    ) as candidate
    where candidate.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'department candidate search cannot discover a hidden church title'
);
select is(
  (
    select department.church_title_code
    from public.list_church_departments(
      current_setting('test.privacy_org')::uuid,
      current_setting('test.release_service_year')::integer
    ) as department
    where department.user_id = 'd1100000-0000-4000-8000-000000000001'
      and department.department_id = current_setting('test.privacy_department')::uuid
      and department.office_code = 'president'
  ),
  null::text,
  'department office holder projection masks the church title'
);
reset role;

update public.privacy_preferences
set avatar_visible = true,
    church_title_visible = true,
    bio_visible = true
where user_id = 'd1100000-0000-4000-8000-000000000001';

select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select ok(
  (
    select profile.avatar_path = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
      and profile.bio = '사역자 비공개 자기소개'
    from public.list_visible_profiles(
      array['d1100000-0000-4000-8000-000000000001'::uuid]
    ) as profile
  ),
  'true peer avatar and bio preferences restore both projected fields'
);
select is(
  (
    select membership.church_title_code
    from public.list_visible_organization_memberships(
      current_setting('test.privacy_org')::uuid,
      500,
      0
    ) as membership
    where membership.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  'elder'::text,
  'true peer title preference restores the membership title'
);
select is(
  (
    select count(*)
    from storage.objects
    where bucket_id = 'avatars'
      and name = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
  ),
  1::bigint,
  'true peer avatar preference restores Storage read access'
);
select is(
  (
    select participant.value ->> 'avatar_path'
    from public.get_conversation_summaries() as conversation
    cross join lateral pg_catalog.jsonb_array_elements(conversation.participants)
      as participant(value)
    where conversation.id = '97000000-0000-4000-8000-000000000002'
      and participant.value ->> 'id' = 'd1100000-0000-4000-8000-000000000001'
  ),
  'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'::text,
  'conversation summaries restore the peer avatar only after opt-in'
);
reset role;

select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select ok(
  (
    select roster.church_title_code = 'elder'
      and roster.church_title_name = '장로'
    from public.list_governance_roster(
      current_setting('test.privacy_scope')::uuid,
      current_setting('test.release_service_year')::integer,
      null,
      200,
      0
    ) as roster
    where roster.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  'governance roster restores both title fields after target opt-in'
);
select is(
  (
    select department.church_title_code
    from public.list_church_departments(
      current_setting('test.privacy_org')::uuid,
      current_setting('test.release_service_year')::integer
    ) as department
    where department.user_id = 'd1100000-0000-4000-8000-000000000001'
      and department.department_id = current_setting('test.privacy_department')::uuid
      and department.office_code = 'president'
  ),
  'elder'::text,
  'department holder title is restored after target opt-in'
);
reset role;

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source, withdrawn_at
)
values (
  'd1100000-0000-4000-8000-000000000001',
  'privacy_policy',
  '2026-08-30',
  false,
  'app',
  pg_catalog.clock_timestamp()
);

-- Oracle fixtures deliberately vary existence, scope, requested/assigned
-- role, review state, and target consent. An unrelated ordinary member must
-- receive one authority error before any of those attributes are exposed.
insert into public.membership_applications (
  id, user_id, organization_id, requested_role, status, applicant_note
)
values (
  '97000000-0000-4000-8000-000000000201',
  'b1200000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-namseoul'),
  'minister',
  'pending',
  'foreign leadership authority-oracle fixture'
);
insert into public.membership_applications (
  id, user_id, organization_id, requested_role, status, applicant_note,
  review_reason, reviewed_at
)
values (
  '97000000-0000-4000-8000-000000000202',
  'c1100000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'member',
  'rejected',
  'withdrawn target authority-oracle fixture',
  'fixture rejection',
  pg_catalog.statement_timestamp()
);
insert into public.organization_memberships (
  id, user_id, organization_id, role, status, ended_at
)
values (
  '97000000-0000-4000-8000-000000000203',
  'a1100000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'member',
  'suspended',
  pg_catalog.statement_timestamp()
);
insert into public.governance_authority_delegations (
  id, scope_id, grantor_user_id, delegate_user_id, capabilities,
  expires_at, reason
)
select
  '97000000-0000-4000-8000-000000000204',
  scope.id,
  'a1100000-0000-4000-8000-000000000001',
  'e1100000-0000-4000-8000-000000000001',
  array['view_roster']::text[],
  pg_catalog.statement_timestamp() + interval '1 day',
  'foreign delegation oracle fixture'
from public.governance_scopes as scope
join public.organizations as organization
  on organization.id = scope.organization_id
where scope.scope_type = 'church'::public.governance_scope_type
  and organization.slug = 'jaegun-namseoul'
  and scope.is_active;
select set_config(
  'test.privacy_actor_membership',
  (
    select membership.id::text
    from public.organization_memberships as membership
    where membership.user_id = 'b1100000-0000-4000-8000-000000000001'
      and membership.status = 'active'::public.membership_status
  ),
  true
);

select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select is(
  (
    select count(*)
    from public.list_visible_profiles(
      array['d1100000-0000-4000-8000-000000000001'::uuid]
    )
  ),
  0::bigint,
  'target consent withdrawal removes the profile projection row entirely'
);
select is(
  (
    select count(*)
    from public.list_visible_organization_memberships(
      current_setting('test.privacy_org')::uuid,
      500,
      0
    ) as membership
    where membership.user_id = 'd1100000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'target consent withdrawal removes the membership projection row entirely'
);
select is(
  (
    select count(*)
    from storage.objects
    where bucket_id = 'avatars'
      and name = 'd1100000-0000-4000-8000-000000000001/97000000-0000-4000-8000-000000000001.jpg'
  ),
  0::bigint,
  'target consent withdrawal closes peer avatar Storage reads again'
);
select throws_ok(
  format(
    'select public.assign_department_office(%L, %s, ''president'', %L)',
    current_setting('test.privacy_department')::uuid,
    current_setting('test.release_service_year')::integer,
    'a1100000-0000-4000-8000-000000000001'
  ),
  '42501',
  'department_office_management_forbidden',
  'unauthorized department assignment rejects a real current target before target inspection'
);
select throws_ok(
  $$select public.assign_department_office(
    '97000000-0000-4000-8000-000000000090',
    current_setting('test.release_service_year')::integer,
    'president',
    'd1100000-0000-4000-8000-000000000001'
  )$$,
  '42501',
  'department_office_management_forbidden',
  'unauthorized fake department assignment gives the same error for a withdrawn target'
);
select throws_ok(
  $$select public.assign_department_office(
    '97000000-0000-4000-8000-000000000090',
    current_setting('test.release_service_year')::integer,
    'president',
    '97000000-0000-4000-8000-000000000099'
  )$$,
  '42501',
  'department_office_management_forbidden',
  'unauthorized fake department assignment gives the same error for an unknown target'
);
select throws_ok(
  $$select public.block_user(
    'a1100000-0000-4000-8000-000000000001', null
  )$$,
  '42501',
  'block_target_unavailable',
  'block target eligibility hides a current foreign profile from an unrelated actor'
);
select throws_ok(
  $$select public.block_user(
    'd1100000-0000-4000-8000-000000000001', null
  )$$,
  '42501',
  'block_target_unavailable',
  'block target eligibility returns the same error for a withdrawn profile'
);
select throws_ok(
  $$select public.block_user(
    '97000000-0000-4000-8000-000000000099', null
  )$$,
  '42501',
  'block_target_unavailable',
  'block target eligibility returns the same error for an unknown UUID'
);
select is(
  (
    public.block_user(
      'c1100000-0000-4000-8000-000000000001',
      '철회 후에도 유지하는 기존 차단'
    ) ->> 'blocked_user_id'
  )::uuid,
  'c1100000-0000-4000-8000-000000000001'::uuid,
  'an existing block remains idempotently manageable after target consent withdrawal'
);
select throws_ok(
  $$select public.review_membership_application(
    '95000000-0000-4000-8000-000000000001', 'reject', 'oracle probe'
  )$$,
  '42501',
  'membership_application_review_forbidden',
  'unauthorized review hides a known pending self application'
);
select throws_ok(
  $$select public.review_membership_application(
    '97000000-0000-4000-8000-000000000201', 'reject', 'oracle probe'
  )$$,
  '42501',
  'membership_application_review_forbidden',
  'unauthorized review gives the same error for a foreign leadership request'
);
select throws_ok(
  $$select public.review_membership_application(
    '97000000-0000-4000-8000-000000000202', 'approve', 'oracle probe'
  )$$,
  '42501',
  'membership_application_review_forbidden',
  'unauthorized review gives the same error for a reviewed withdrawn target'
);
select throws_ok(
  $$select public.review_membership_application(
    '97000000-0000-4000-8000-000000000299', 'approve', 'oracle probe'
  )$$,
  '42501',
  'membership_application_review_forbidden',
  'unauthorized review gives the same error for an unknown application UUID'
);
select throws_ok(
  $$select public.set_membership_status(
    current_setting('test.privacy_actor_membership')::uuid,
    'revoked',
    'oracle probe'
  )$$,
  '42501',
  'membership_status_change_forbidden',
  'unauthorized status change hides a known self membership'
);
select throws_ok(
  $$select public.set_membership_status(
    current_setting('test.withdrawn_target_membership')::uuid,
    'suspended',
    'oracle probe'
  )$$,
  '42501',
  'membership_status_change_forbidden',
  'unauthorized status change gives the same error for withdrawn leadership'
);
select throws_ok(
  $$select public.set_membership_status(
    '97000000-0000-4000-8000-000000000203',
    'active',
    'oracle probe'
  )$$,
  '42501',
  'membership_status_change_forbidden',
  'unauthorized status change gives the same error for a suspended target'
);
select throws_ok(
  $$select public.set_membership_status(
    '97000000-0000-4000-8000-000000000299',
    'active',
    'oracle probe'
  )$$,
  '42501',
  'membership_status_change_forbidden',
  'unauthorized status change gives the same error for an unknown membership UUID'
);
select throws_ok(
  $$select public.set_membership_application_evidence(
    '97000000-0000-4000-8000-000000000201',
    'foreign/probe.jpg'
  )$$,
  '42501',
  'application_owner_forbidden',
  'application evidence hides a foreign owned application'
);
select throws_ok(
  $$select public.set_membership_application_evidence(
    '97000000-0000-4000-8000-000000000299',
    'missing/probe.jpg'
  )$$,
  '42501',
  'application_owner_forbidden',
  'application evidence gives the same error for an unknown UUID'
);
select throws_ok(
  $$select public.withdraw_membership_application(
    '97000000-0000-4000-8000-000000000201'
  )$$,
  '42501',
  'application_owner_forbidden',
  'application withdrawal hides a foreign owned application'
);
select throws_ok(
  $$select public.withdraw_membership_application(
    '97000000-0000-4000-8000-000000000299'
  )$$,
  '42501',
  'application_owner_forbidden',
  'application withdrawal gives the same error for an unknown UUID'
);
select throws_ok(
  $$select public.revoke_governance_delegation(
    '97000000-0000-4000-8000-000000000204', 'foreign delegation probe'
  )$$,
  'P0002',
  'governance_delegation_not_found_or_forbidden',
  'delegation revocation hides a known foreign delegation'
);
select throws_ok(
  $$select public.revoke_governance_delegation(
    '97000000-0000-4000-8000-000000000298', 'missing delegation probe'
  )$$,
  'P0002',
  'governance_delegation_not_found_or_forbidden',
  'delegation revocation gives the same response for an unknown UUID'
);
select throws_ok(
  $$select public.create_content_report(
    'profile',
    'd1100000-0000-4000-8000-000000000001',
    'privacy',
    'withdrawn profile probe'
  )$$,
  '42501',
  'report_target_not_accessible',
  'a withdrawn profile cannot be newly captured into report evidence'
);
select throws_ok(
  $$select public.create_content_report(
    'comment',
    '92000000-0000-4000-8000-000000000001',
    'privacy',
    'withdrawn comment probe'
  )$$,
  '42501',
  'report_target_not_accessible',
  'a withdrawn comment author cannot be recaptured through report evidence'
);
select throws_ok(
  $$select public.create_content_report(
    'profile',
    '97000000-0000-4000-8000-000000000299',
    'privacy',
    'unknown profile probe'
  )$$,
  '42501',
  'report_target_not_accessible',
  'an unknown report profile gives the same inaccessible response'
);
select throws_ok(
  $$select public.send_message(
    '93000000-0000-4000-8000-000000000001',
    'text',
    'hidden conversation probe',
    null,
    '{}'::jsonb,
    '97000000-0000-4000-8000-000000000211'
  )$$,
  'P0002',
  'conversation_not_found_or_forbidden',
  'message send hides a known conversation whose peer withdrew consent'
);
select throws_ok(
  $$select public.send_message(
    '97000000-0000-4000-8000-000000000299',
    'text',
    'missing conversation probe',
    null,
    '{}'::jsonb,
    '97000000-0000-4000-8000-000000000212'
  )$$,
  'P0002',
  'conversation_not_found_or_forbidden',
  'message send gives the same response for an unknown conversation'
);
select throws_ok(
  $$select public.send_message_batch(
    '93000000-0000-4000-8000-000000000001',
    'b1100000-0000-4000-8000-000000000001',
    '[{"kind":"text","body":"hidden batch probe","media_path":null,"media_metadata":{},"client_nonce":"97000000-0000-4000-8000-000000000213"}]'::jsonb
  )$$,
  'P0002',
  'conversation_not_found_or_forbidden',
  'message batch hides a known conversation whose peer withdrew consent'
);
select throws_ok(
  $$select public.send_message_batch(
    '97000000-0000-4000-8000-000000000299',
    'b1100000-0000-4000-8000-000000000001',
    '[{"kind":"text","body":"missing batch probe","media_path":null,"media_metadata":{},"client_nonce":"97000000-0000-4000-8000-000000000214"}]'::jsonb
  )$$,
  'P0002',
  'conversation_not_found_or_forbidden',
  'message batch gives the same response for an unknown conversation'
);
reset role;
select is(
  (
    select count(*)
    from public.content_reports as report
    where report.target_id in (
      'd1100000-0000-4000-8000-000000000001',
      '92000000-0000-4000-8000-000000000001',
      '97000000-0000-4000-8000-000000000299'
    )
      and report.details in (
        'withdrawn profile probe',
        'withdrawn comment probe',
        'unknown profile probe'
      )
  ),
  0::bigint,
  'inaccessible report attempts persist no new evidence snapshots'
);

select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"a1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select is(
  public.review_membership_application(
    '97000000-0000-4000-8000-000000000201',
    'approve',
    'authorized leadership approval'
  ) ->> 'status',
  'approved'::text,
  'authorized AAL2 platform admin can still approve a leadership application'
);
select throws_ok(
  $$select public.review_membership_application(
    '97000000-0000-4000-8000-000000000201',
    'approve',
    'idempotency replay'
  )$$,
  '40001',
  'application_already_reviewed',
  'authorized review preserves the established already-reviewed result'
);
select lives_ok(
  format(
    'select public.set_membership_status(%L, ''suspended'', ''authorized suspension'')',
    current_setting('test.withdrawn_target_membership')::uuid
  ),
  'authorized platform admin can still suspend a leadership member'
);
select lives_ok(
  format(
    'select public.set_membership_status(%L, ''suspended'', ''idempotency replay'')',
    current_setting('test.withdrawn_target_membership')::uuid
  ),
  'authorized membership status replay remains idempotent'
);
reset role;
select is(
  (
    select membership.status
    from public.organization_memberships as membership
    where membership.id = current_setting('test.withdrawn_target_membership')::uuid
  ),
  'suspended'::public.membership_status,
  'authorized status mutation retains the requested final state'
);

select * from finish();
rollback;
