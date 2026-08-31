begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();

select ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'private.ugc_text_is_allowed(text)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'private.ugc_text_is_allowed(text)',
    'execute'
  ),
  'the comparison primitive is not client-callable'
);

select is(
  private.ugc_text_is_allowed('아 동 · 성 착 취 자료'),
  false,
  'separator-obfuscated child exploitation text is rejected'
);
select is(
  private.ugc_text_is_allowed('너를' || pg_catalog.chr(8203) || '죽여 버리겠어'),
  false,
  'zero-width-obfuscated targeted threat is rejected'
);
select is(
  private.ugc_text_is_allowed('I W1LL K!LL YOU'),
  false,
  'case, leetspeak, and punctuation do not bypass a direct threat rule'
);
select is(
  private.ugc_text_is_allowed('좆 같네'),
  false,
  'separator-obfuscated Korean abusive profanity is rejected'
);
select is(
  private.ugc_text_is_allowed('아동을 보호하기 위한 예배와 상담 안내입니다.'),
  true,
  'ordinary child-safety pastoral content remains allowed'
);
select is(
  private.ugc_text_is_allowed('환자와 가족을 위해 기도해 주세요.'),
  true,
  'ordinary prayer and care content remains allowed'
);

select is(
  (
    select count(*)
    from pg_catalog.pg_trigger as trigger_row
    where trigger_row.tgrelid in (
      'public.posts'::regclass,
      'public.comments'::regclass,
      'public.messages'::regclass
    )
      and trigger_row.tgname in (
        'posts_enforce_ugc_text_safety',
        'comments_enforce_ugc_text_safety',
        'messages_enforce_ugc_text_safety'
      )
      and not trigger_row.tgisinternal
  ),
  3::bigint,
  'post, comment, and message tables each enforce the server-side safety trigger'
);

insert into auth.users (id, email, raw_user_meta_data)
values
  (
    '01600000-0000-4000-8000-000000000001',
    'ugc-one@example.com',
    '{"display_name":"UGC 안전 하나"}'::jsonb
  ),
  (
    '01600000-0000-4000-8000-000000000002',
    'ugc-two@example.com',
    '{"display_name":"UGC 안전 둘"}'::jsonb
  );

insert into public.boards (
  id,
  organization_id,
  slug,
  name,
  description,
  created_by
)
values (
  '01610000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  'app-store-ugc-safety',
  'App Store UGC 안전 테스트',
  'pgTAP 전용 게시판',
  '01600000-0000-4000-8000-000000000001'
);

insert into public.posts (
  id,
  organization_id,
  board_id,
  author_id,
  title,
  body,
  status,
  published_at
)
values (
  '01620000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  '01610000-0000-4000-8000-000000000001',
  '01600000-0000-4000-8000-000000000001',
  '함께 드리는 기도',
  '서로를 존중하며 따뜻한 마음을 나누어요.',
  'published',
  pg_catalog.clock_timestamp()
);

insert into public.conversations (
  id,
  organization_id,
  participant_low,
  participant_high,
  created_by
)
values (
  '01630000-0000-4000-8000-000000000001',
  (select id from public.organizations where slug = 'jaegun-bupyeong'),
  '01600000-0000-4000-8000-000000000001',
  '01600000-0000-4000-8000-000000000002',
  '01600000-0000-4000-8000-000000000001'
);

select throws_ok(
  $sql$
    insert into public.posts (
      id, organization_id, board_id, author_id, title, body, status, published_at
    ) values (
      '01620000-0000-4000-8000-000000000002',
      (select id from public.organizations where slug = 'jaegun-bupyeong'),
      '01610000-0000-4000-8000-000000000001',
      '01600000-0000-4000-8000-000000000001',
      '공동체 소식',
      '아 동 성 착 취 자료를 공유합니다.',
      'published',
      pg_catalog.clock_timestamp()
    )
  $sql$,
  '22023',
  'unsafe_content_rejected',
  'a post insert cannot bypass the server-side severe-content gate'
);

select throws_ok(
  $sql$
    insert into public.comments (post_id, author_id, body)
    values (
      '01620000-0000-4000-8000-000000000001',
      '01600000-0000-4000-8000-000000000002',
      '너를 죽여 버리겠어'
    )
  $sql$,
  '22023',
  'unsafe_content_rejected',
  'a comment insert cannot bypass the server-side targeted-threat gate'
);

select throws_ok(
  $sql$
    insert into public.messages (
      conversation_id, sender_id, kind, body, client_nonce
    ) values (
      '01630000-0000-4000-8000-000000000001',
      '01600000-0000-4000-8000-000000000001',
      'text',
      'F U C K Y0U',
      '01640000-0000-4000-8000-000000000001'
    )
  $sql$,
  '22023',
  'unsafe_content_rejected',
  'a message insert cannot bypass the server-side abusive-text gate'
);

select is(
  (
    select count(*)
    from public.audit_logs as audit
    where audit.details::text like '%아 동 성 착 취%'
      or audit.details::text like '%너를 죽여 버리%'
      or audit.details::text like '%F U C K Y0U%'
  ),
  0::bigint,
  'rejected raw text is not copied into durable audit details'
);

select throws_ok(
  $sql$
    update public.posts
    set body = '널 죽이겠다'
    where id = '01620000-0000-4000-8000-000000000001'
  $sql$,
  '22023',
  'unsafe_content_rejected',
  'editing existing content cannot bypass the same server-side gate'
);

select lives_ok(
  $sql$
    insert into public.comments (post_id, author_id, body)
    values (
      '01620000-0000-4000-8000-000000000001',
      '01600000-0000-4000-8000-000000000002',
      '나눠 주셔서 감사합니다. 함께 기도할게요.'
    )
  $sql$,
  'ordinary respectful comments still pass the write boundary'
);

select lives_ok(
  $sql$
    insert into public.messages (
      conversation_id, sender_id, kind, body, client_nonce
    ) values (
      '01630000-0000-4000-8000-000000000001',
      '01600000-0000-4000-8000-000000000001',
      'text',
      '예배 후에 뵙겠습니다.',
      '01640000-0000-4000-8000-000000000002'
    )
  $sql$,
  'ordinary direct messages still pass the write boundary'
);

select * from finish();
rollback;
