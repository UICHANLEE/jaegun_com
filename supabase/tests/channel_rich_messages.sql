begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();

insert into auth.users(id,email,raw_user_meta_data) values
('cf100000-0000-4000-8000-000000000001','rich-one@example.com','{"display_name":"보낸 사람"}'),
('cf100000-0000-4000-8000-000000000002','rich-two@example.com','{"display_name":"태그 대상"}'),
('cf100000-0000-4000-8000-000000000003','rich-three@example.com','{"display_name":"외부 사람"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'cf100000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug in ('jaegun-bupyeong','jaegun-namseoul');
select set_config('rich.org',(select id::text from public.organizations where slug='jaegun-bupyeong'),true);
select set_config('rich.other',(select id::text from public.organizations where slug='jaegun-namseoul'),true);
insert into public.organization_memberships(user_id,organization_id,role,status) values
('cf100000-0000-4000-8000-000000000001',current_setting('rich.org')::uuid,'member','active'),
('cf100000-0000-4000-8000-000000000002',current_setting('rich.org')::uuid,'member','active'),
('cf100000-0000-4000-8000-000000000003',current_setting('rich.other')::uuid,'member','active');

select ok(not has_function_privilege('anon','public.channel_rich_command(text,uuid,jsonb)','execute'),'anonymous cannot call rich channel command');
select ok(not has_table_privilege('authenticated','public.channel_message_reactions','select'),'reaction rows have no direct client access');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.channel_message_reactions'::regclass,'public.channel_message_mentions'::regclass,'public.channel_message_attachments'::regclass)),'rich message tables all have RLS');

set local role authenticated;
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('create','cf200000-0000-4000-8000-000000000001',jsonb_build_object('organizationId',current_setting('rich.org'),'name','비공개 협업','visibility','private'))$$,'create source channel');
select lives_ok($$select public.channel_command('create','cf200000-0000-4000-8000-000000000002',jsonb_build_object('organizationId',current_setting('rich.org'),'name','공개 협업','visibility','public'))$$,'create forwarding target');
select lives_ok($$select public.channel_command('invite','cf200000-0000-4000-8000-000000000001','{"userId":"cf100000-0000-4000-8000-000000000002"}')$$,'invite mention target');
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_command('join','cf200000-0000-4000-8000-000000000001')$$,'accept private invitation');
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_rich_command('send','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000001","messageId":"cf300000-0000-4000-8000-000000000001","body":"@태그 대상 함께 준비해요","mentionUserIds":["cf100000-0000-4000-8000-000000000002","cf100000-0000-4000-8000-000000000002"],"attachments":[]}'::jsonb)$$,'send tagged text');
select is(jsonb_array_length(public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000001')->'messages'->0->'mentionUserIds'),1,'mention returned once');
reset role;
select is((select count(*) from public.notifications where user_id='cf100000-0000-4000-8000-000000000002' and entity_type='channel' and entity_id='cf200000-0000-4000-8000-000000000001'),1::bigint,'mention creates one channel notification');
set local role authenticated;
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.channel_rich_command('send','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000001","messageId":"cf300000-0000-4000-8000-000000000002","body":"외부 태그","mentionUserIds":["cf100000-0000-4000-8000-000000000003"],"attachments":[]}'::jsonb)$$,'22023','invalid_channel_mention','cannot mention another church');
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_rich_command('react','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000002","messageId":"cf300000-0000-4000-8000-000000000001","emoji":"🙏"}'::jsonb)$$,'participant reacts');
select is((public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000001')->'messages'->0->'reactions'->0->>'count')::int,1,'reaction count returned');
select lives_ok($$select public.channel_rich_command('react','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000002","messageId":"cf300000-0000-4000-8000-000000000001","emoji":"🙏"}'::jsonb)$$,'same reaction toggles off');
select is(jsonb_array_length(public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000001')->'messages'->0->'reactions'),0,'reaction removed');
select throws_ok($$select public.channel_rich_command('react','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000002","messageId":"cf300000-0000-4000-8000-000000000001","emoji":"💣"}'::jsonb)$$,'22023','invalid_channel_reaction','emoji allowlist enforced');
select lives_ok($$select public.channel_command('join','cf200000-0000-4000-8000-000000000002')$$,'join forward destination');
select lives_ok($$select public.channel_rich_command('forward','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000002","messageId":"cf300000-0000-4000-8000-000000000001","targetChannelId":"cf200000-0000-4000-8000-000000000002","operationId":"cf300000-0000-4000-8000-000000000003"}'::jsonb)$$,'forward text to joined same-church channel');
select is(public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000002')->'messages'->0->>'body','@태그 대상 함께 준비해요','forward copies text');
select is(public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000002')->'messages'->0->>'forwardedFromId','cf300000-0000-4000-8000-000000000001','forward preserves canonical source attribution');
select is(jsonb_array_length(public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000002')->'messages'->0->'mentionUserIds'),0,'forward does not copy mention notification');
reset role;

select ok(private.can_write_community_media(current_setting('rich.org')||'/channels/cf200000-0000-4000-8000-000000000001/cf400000-0000-4000-8000-000000000001.jpg','cf100000-0000-4000-8000-000000000001'),'participant can write channel media path');
select ok(not private.can_write_community_media(current_setting('rich.org')||'/channels/cf200000-0000-4000-8000-000000000001/cf400000-0000-4000-8000-000000000001.jpg','cf100000-0000-4000-8000-000000000003'),'other church cannot write channel media path');
insert into storage.objects(bucket_id,name,owner,owner_id,metadata) values('community-media',current_setting('rich.org')||'/channels/cf200000-0000-4000-8000-000000000001/cf400000-0000-4000-8000-000000000001.jpg','cf100000-0000-4000-8000-000000000001','cf100000-0000-4000-8000-000000000001','{"mimetype":"image/jpeg","size":1024}');
set local role authenticated;
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_rich_command('send','cf200000-0000-4000-8000-000000000001',jsonb_build_object('expectedActorId','cf100000-0000-4000-8000-000000000001','messageId','cf300000-0000-4000-8000-000000000004','body','','mentionUserIds','[]'::jsonb,'attachments',jsonb_build_array(jsonb_build_object('id','cf500000-0000-4000-8000-000000000001','path',current_setting('rich.org')||'/channels/cf200000-0000-4000-8000-000000000001/cf400000-0000-4000-8000-000000000001.jpg','kind','image','mimeType','image/jpeg','byteSize',1024,'fileName','찬양.jpg'))))$$,'send attachment-only message');
select is(jsonb_array_length(public.channel_snapshot(current_setting('rich.org')::uuid,'cf200000-0000-4000-8000-000000000001')->'messages'->1->'attachments'),1,'attachment returned through scoped snapshot');
select set_config('request.jwt.claim.sub','cf100000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.channel_rich_command('react','cf200000-0000-4000-8000-000000000001','{"expectedActorId":"cf100000-0000-4000-8000-000000000003","messageId":"cf300000-0000-4000-8000-000000000001","emoji":"👍"}'::jsonb)$$,'42501','channel_access_denied','outsider cannot react');
reset role;

select * from finish();
rollback;
