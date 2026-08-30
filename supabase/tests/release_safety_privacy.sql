begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;

select no_plan();

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
    'public.save_my_privacy_preferences(text,text,boolean,boolean,boolean,boolean)',
    'execute'
  ),
  'frontend privacy settings contract is executable by authenticated users'
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
        'jaegun_community_media_update',
        'jaegun_community_media_delete',
        'jaegun_avatars_insert',
        'jaegun_avatars_update',
        'jaegun_avatars_delete'
      )
  ),
  0::bigint,
  'authenticated clients have no direct approved-bucket write policies'
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
      "accepted_privacy":true,
      "accepted_privacy_version":"2026-08-27",
      "accepted_community":true,
      "accepted_community_version":"2026-08-27",
      "accepted_at":"1900-01-01T00:00:00Z"
    }'::jsonb
  ),
  (
    'c1200000-0000-4000-8000-000000000001',
    'release-consent-bad@example.com',
    '{
      "display_name":"동의 미완료 회원",
      "accepted_privacy":true,
      "accepted_privacy_version":"forged-future-version",
      "accepted_community":false,
      "accepted_community_version":"2026-08-27"
    }'::jsonb
  );

select is(
  (
    select count(*) from public.user_consents
    where user_id = 'b1200000-0000-4000-8000-000000000001'
      and accepted
      and source = 'signup_metadata'
  ),
  2::bigint,
  'signup metadata records both exact active document versions'
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
  'approved_media_required',
  'legacy send_message_batch rejects a forged approved-bucket path'
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
  'approved_media_required',
  'post media rows require a scanner-approved upload intent'
);

reset role;
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
  $$select public.get_or_create_conversation('c1100000-0000-4000-8000-000000000001')$$,
  '42501',
  'user_block_boundary',
  'blocker cannot create or reopen a direct conversation'
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
  (select count(*) from public.profiles where id = 'c1100000-0000-4000-8000-000000000001'),
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
  'user_block_boundary',
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
  (select count(*) from public.profiles where id = 'b1100000-0000-4000-8000-000000000001'),
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
select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is(
  (
    public.save_my_privacy_preferences(
      '2026-08-27',
      '2026-08-27',
      true,
      true,
      false,
      true
    ) #>> '{directory_visibility,avatar}'
  )::boolean,
  true,
  'privacy preference contract stores exact consent versions and field visibility'
);
select is(
  (public.get_my_safety_privacy_state() ->> 'consent_gate_open')::boolean,
  true,
  'safety/privacy state opens only after both current versions are accepted'
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
select is(
  public.create_content_report(
    'profile',
    'c1100000-0000-4000-8000-000000000001',
    'harassment',
    '재시도'
  ),
  (
    select id from public.content_reports
    where reporter_id = 'b1100000-0000-4000-8000-000000000001'
      and target_type = 'profile'
      and target_id = 'c1100000-0000-4000-8000-000000000001'
      and status in ('open', 'reviewing', 'escalated')
  ),
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
create temporary table test_reports as
select id
from public.content_reports
where reporter_id = 'b1100000-0000-4000-8000-000000000001'
  and target_type = 'profile'
  and target_id = 'c1100000-0000-4000-8000-000000000001';
grant select on table test_reports to authenticated;

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
  '42501',
  'moderation_scope_forbidden',
  'other-church executive cannot resolve a report outside the exact scope'
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
    (
      select id from public.content_reports
      where reporter_id = 'b1100000-0000-4000-8000-000000000001'
        and target_type = 'profile'
    )
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
        select id from public.content_reports
        where reporter_id = 'b1100000-0000-4000-8000-000000000001'
          and target_type = 'profile'
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
set local role authenticated;
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

reset role;
insert into storage.objects (
  bucket_id, name, owner, owner_id, metadata
)
select
  'community-media-quarantine',
  intent.quarantine_path,
  'b1100000-0000-4000-8000-000000000001'::uuid,
  'b1100000-0000-4000-8000-000000000001',
  pg_catalog.jsonb_build_object('mimetype', 'image/jpeg', 'size', '1024')
from test_media_scan_intents as intent
where intent.label in ('safe_image', 'stale_image', 'safe_video');

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
  'scanner claims only intents whose owned quarantine object exists'
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
  (select bool_and(lease_token is not null and scan_attempts = 1) from test_media_scan_claims),
  'first scan claim returns a fencing token and attempt one'
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
  private.can_write_quarantine_media(
    (select quarantine_path from test_media_scan_intents where label = 'safe_image'),
    auth.uid()
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

select set_config(
  'request.jwt.claims',
  '{"sub":"b1100000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',
  true
);
select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
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
  'abandoned intent is no longer attachable or quota-active'
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
  ) as attached_hero_path,
  max(quarantine_path) filter (
    where id = '96000000-0000-4000-8000-000000000006'
  ) as quarantined_post_path
from public.media_upload_intents;
grant all on table test_deletion_paths to service_role;

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
reset role;
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
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
select set_config('request.jwt.claim.sub', '', true);
set local role service_role;
select public.service_mark_account_cleanup_item(
  (item ->> 'id')::uuid,
  'deleted',
  null
)
from test_deletion_claims
cross join lateral pg_catalog.jsonb_array_elements(cleanup_items) as cleanup(item);
insert into test_deletion_finalize (result)
select public.service_finalize_account_anonymization(request_id)
from test_deletion_claims;
select is(
  (select result ->> 'status' from test_deletion_finalize),
  'awaiting_identity_deletion',
  'Storage-complete account is anonymized before Auth identity deletion'
);
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
    select approved_path from public.media_upload_intents
    where id = '96000000-0000-4000-8000-000000000003'
  ),
  'organization hero remains attached after uploader anonymization'
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
select * from finish();
rollback;
