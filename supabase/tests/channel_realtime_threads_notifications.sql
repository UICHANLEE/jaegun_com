begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();

insert into auth.users(id,email,raw_user_meta_data) values
('d1100000-0000-4000-8000-000000000001','thread-owner@example.com','{"display_name":"원문 작성자"}'),
('d1100000-0000-4000-8000-000000000002','thread-member@example.com','{"display_name":"답글 작성자"}'),
('d1100000-0000-4000-8000-000000000003','thread-outsider@example.com','{"display_name":"다른 교회"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'd1100000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug in ('jaegun-bupyeong','jaegun-namseoul');
select set_config('thread.org',(select id::text from public.organizations where slug='jaegun-bupyeong'),true);
select set_config('thread.other',(select id::text from public.organizations where slug='jaegun-namseoul'),true);
insert into public.organization_memberships(user_id,organization_id,role,status) values
('d1100000-0000-4000-8000-000000000001',current_setting('thread.org')::uuid,'member','active'),
('d1100000-0000-4000-8000-000000000002',current_setting('thread.org')::uuid,'member','active'),
('d1100000-0000-4000-8000-000000000003',current_setting('thread.other')::uuid,'member','active');

select ok(not has_function_privilege('anon','public.channel_thread_snapshot(uuid,uuid,bigint)','execute'),'anonymous cannot read reply threads');
select ok(not has_table_privilege('authenticated','public.channel_notification_preferences','select'),'preference rows have no direct client access');
select ok(has_table_privilege('authenticated','public.channel_change_events','select'),'authenticated clients may receive opaque change events');
select ok(not has_table_privilege('authenticated','public.channel_change_events','insert'),'clients cannot forge change events');
select ok((select relrowsecurity from pg_class where oid='public.channel_change_events'::regclass),'change events have RLS');
select ok(exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='channel_change_events'),'opaque change events are published to Realtime');

set local role authenticated;
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('create','d1200000-0000-4000-8000-000000000001',jsonb_build_object('organizationId',current_setting('thread.org'),'name','실시간 협업','visibility','private'))$$,'create private channel');
select lives_ok($$select public.channel_command('invite','d1200000-0000-4000-8000-000000000001','{"userId":"d1100000-0000-4000-8000-000000000002"}')$$,'invite participant');
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_command('join','d1200000-0000-4000-8000-000000000001')$$,'accept invitation');
select is(public.channel_snapshot(current_setting('thread.org')::uuid)->'channels'->0->>'notificationMode','mentions','safe notification default is mentions only');
select lives_ok($$select public.channel_rich_command('preference','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000002","mode":"all"}')$$,'participant enables all channel notifications');
select is(public.channel_snapshot(current_setting('thread.org')::uuid)->'channels'->0->>'notificationMode','all','preference is returned through the actor-bound snapshot');
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_rich_command('send','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000001","messageId":"d1300000-0000-4000-8000-000000000001","body":"회의 자료를 확인해 주세요","mentionUserIds":[],"attachments":[]}'::jsonb)$$,'send root message');
reset role;
select is((select count(*) from public.notifications where user_id='d1100000-0000-4000-8000-000000000002' and entity_type='channel'),1::bigint,'all mode creates a channel notification');

set local role authenticated;
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000002',true);
select ok((select count(*)>0 from public.channel_change_events where channel_id='d1200000-0000-4000-8000-000000000001'),'participant can receive opaque invalidation events');
select lives_ok($$select public.channel_rich_command('send','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000002","messageId":"d1300000-0000-4000-8000-000000000002","parentMessageId":"d1300000-0000-4000-8000-000000000001","body":"확인했습니다","mentionUserIds":[],"attachments":[]}'::jsonb)$$,'send one-level reply');
select is(jsonb_array_length(public.channel_thread_snapshot('d1200000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')->'messages'),1,'thread snapshot returns its reply');
select throws_ok($$select public.channel_rich_command('send','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000002","messageId":"d1300000-0000-4000-8000-000000000003","parentMessageId":"d1300000-0000-4000-8000-000000000002","body":"중첩 답글","mentionUserIds":[],"attachments":[]}'::jsonb)$$,'22023','invalid_channel_thread','nested reply is rejected');
select lives_ok($$select public.channel_rich_command('edit','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000002","messageId":"d1300000-0000-4000-8000-000000000002","body":"확인했고 준비하겠습니다"}')$$,'author edits own reply');
select is(public.channel_thread_snapshot('d1200000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')->'messages'->0->>'body','확인했고 준비하겠습니다','edited body is visible');
select ok((public.channel_thread_snapshot('d1200000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')->'messages'->0->>'editedAt') is not null,'edited timestamp is visible');
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.channel_rich_command('edit','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000001","messageId":"d1300000-0000-4000-8000-000000000002","body":"남의 답글 수정"}')$$,'22023','invalid_channel_edit','non-author cannot edit a reply');
reset role;
select is((select count(*) from public.notifications where user_id='d1100000-0000-4000-8000-000000000001' and metadata->>'channel_notice_type'='reply'),1::bigint,'root author receives one reply notification');

set local role authenticated;
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_rich_command('delete','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000002","messageId":"d1300000-0000-4000-8000-000000000002"}')$$,'author soft-deletes own reply');
select is(jsonb_array_length(public.channel_thread_snapshot('d1200000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')->'messages'),0,'deleted reply content is no longer returned');
select lives_ok($$select public.channel_rich_command('send','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000002","messageId":"d1300000-0000-4000-8000-000000000004","parentMessageId":"d1300000-0000-4000-8000-000000000001","body":"남겨 둘 답글","mentionUserIds":[],"attachments":[]}'::jsonb)$$,'send another reply');
select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_rich_command('delete','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000001","messageId":"d1300000-0000-4000-8000-000000000001"}')$$,'author soft-deletes root');
select is(public.channel_snapshot(current_setting('thread.org')::uuid,'d1200000-0000-4000-8000-000000000001')->'messages'->0->>'deleted','true','deleted root remains as a tombstone while replies exist');
select is((public.channel_snapshot(current_setting('thread.org')::uuid,'d1200000-0000-4000-8000-000000000001')->'messages'->0->>'replyCount')::int,1,'tombstone preserves live reply count');
select throws_ok($$select public.channel_rich_command('send','d1200000-0000-4000-8000-000000000001','{"expectedActorId":"d1100000-0000-4000-8000-000000000001","messageId":"d1300000-0000-4000-8000-000000000005","parentMessageId":"d1300000-0000-4000-8000-000000000001","body":"삭제 후 답글","mentionUserIds":[],"attachments":[]}'::jsonb)$$,'22023','invalid_channel_thread','deleted root rejects new replies');

select set_config('request.jwt.claim.sub','d1100000-0000-4000-8000-000000000003',true);
select is((select count(*) from public.channel_change_events where channel_id='d1200000-0000-4000-8000-000000000001'),0::bigint,'other church cannot receive private channel events');
select throws_ok($$select public.channel_thread_snapshot('d1200000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','other church cannot read thread');
reset role;

select * from finish();
rollback;
