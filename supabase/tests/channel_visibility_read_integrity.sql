begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
create function pg_temp.unread_count() returns int language sql as $$
  select (item->>'unreadCount')::int from jsonb_array_elements(public.channel_snapshot(current_setting('visibility.org')::uuid)->'channels') item where item->>'id'='e1200000-0000-4000-8000-000000000001';
$$;

insert into auth.users(id,email,raw_user_meta_data) values
('e1100000-0000-4000-8000-000000000001','visibility-owner@example.com','{"display_name":"원문 작성자"}'),
('e1100000-0000-4000-8000-000000000002','visibility-reader@example.com','{"display_name":"읽는 사람"}'),
('e1100000-0000-4000-8000-000000000003','visibility-reply@example.com','{"display_name":"답글 작성자"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'e1100000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug='jaegun-bupyeong';
select set_config('visibility.org',(select id::text from public.organizations where slug='jaegun-bupyeong'),true);
insert into public.organization_memberships(user_id,organization_id,role,status)
select id,current_setting('visibility.org')::uuid,'member','active' from public.profiles where id::text like 'e1100000-%';
insert into public.community_channels(id,organization_id,owner_id,name,visibility) values
('e1200000-0000-4000-8000-000000000001',current_setting('visibility.org')::uuid,'e1100000-0000-4000-8000-000000000001','안전한 원문 채널','private'),
('e1200000-0000-4000-8000-000000000002',current_setting('visibility.org')::uuid,'e1100000-0000-4000-8000-000000000001','안전한 전달 채널','public');
insert into public.channel_members(channel_id,user_id,status)
select c.id,p.id,'active' from public.community_channels c cross join public.profiles p where c.id::text like 'e1200000-%' and p.id::text like 'e1100000-%';
insert into public.channel_messages(id,channel_id,sender_id,body,parent_message_id) values
('e1300000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000001','원문',null),
('e1300000-0000-4000-8000-000000000002','e1200000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000003','별도 읽음이 필요한 답글','e1300000-0000-4000-8000-000000000001'),
('e1300000-0000-4000-8000-000000000003','e1200000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000001','더 늦게 온 원문',null);
select set_config('visibility.path',current_setting('visibility.org')||'/channels/e1200000-0000-4000-8000-000000000001/e1400000-0000-4000-8000-000000000001.jpg',true);
insert into storage.objects(bucket_id,name,owner,owner_id,metadata) values('community-media',current_setting('visibility.path'),'e1100000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000001','{"mimetype":"image/jpeg","size":1024}');
insert into public.channel_message_attachments(id,message_id,uploader_id,storage_path,kind,mime_type,byte_size,file_name) values
('e1500000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000001',current_setting('visibility.path'),'image','image/jpeg',1024,'사진.jpg');
select set_config('visibility.rootseq',(select seq::text from public.channel_messages where id='e1300000-0000-4000-8000-000000000003'),true);
select set_config('visibility.replyseq',(select seq::text from public.channel_messages where id='e1300000-0000-4000-8000-000000000002'),true);
select set_config('visibility.events',(select count(*)::text from public.channel_change_events where channel_id='e1200000-0000-4000-8000-000000000001'),true);
insert into public.notifications(id,user_id,kind,title,body,entity_type,entity_id,metadata) values
('e1600000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000002','new_message','답글 알림','새 답글','channel','e1200000-0000-4000-8000-000000000001','{"message_id":"e1300000-0000-4000-8000-000000000002"}');

select ok(not has_function_privilege('authenticated','private.channel_rich_command_before_visibility_integrity(text,uuid,jsonb)','execute'),'legacy rich command cannot bypass wrapper');
select ok(not has_function_privilege('authenticated','private.channel_thread_snapshot_before_visibility_integrity(uuid,uuid,bigint)','execute'),'legacy thread cannot bypass root visibility');
select ok(not has_table_privilege('authenticated','private.channel_thread_reads','select'),'thread read cursor is RPC-only');

set local role authenticated;
select set_config('request.jwt.claim.sub','e1100000-0000-4000-8000-000000000002',true);
select is((select count(*) from storage.objects where name=current_setting('visibility.path')),1::bigint,'participant may read visible attachment');
select is((select count(*) from public.notifications where id='e1600000-0000-4000-8000-000000000001'),1::bigint,'visible reply notification is available');
select is((public.channel_snapshot(current_setting('visibility.org')::uuid,'e1200000-0000-4000-8000-000000000001')->'messages'->0->>'unreadReplyCount')::int,1,'root exposes separate unread reply count');
select lives_ok($$select public.channel_command('read','e1200000-0000-4000-8000-000000000001',jsonb_build_object('seq',current_setting('visibility.rootseq')))$$,'read later root');
select is(pg_temp.unread_count(),1,'reading later root must not mark unseen reply read');
select is((select count(*) from public.channel_change_events where channel_id='e1200000-0000-4000-8000-000000000001'),current_setting('visibility.events')::bigint,'read receipt emits no broadcast feedback');
select lives_ok($$select public.channel_rich_command('read_thread','e1200000-0000-4000-8000-000000000001',jsonb_build_object('expectedActorId','e1100000-0000-4000-8000-000000000002','messageId','e1300000-0000-4000-8000-000000000001','seq',current_setting('visibility.replyseq')))$$,'mark displayed reply read');
select is((public.channel_thread_snapshot('e1200000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001')->>'lastReadSeq')::bigint,current_setting('visibility.replyseq')::bigint,'thread snapshot returns actor read cursor');
select is(public.channel_thread_snapshot('e1200000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001')->>'channelId','e1200000-0000-4000-8000-000000000001','thread snapshot returns channel identity');
select is(pg_temp.unread_count(),0,'opening and reading thread clears only its unread replies');
select lives_ok($$select public.channel_rich_command('preference','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","mode":"all"}')$$,'change notification preference');
select is((select count(*) from public.channel_change_events where channel_id='e1200000-0000-4000-8000-000000000001'),current_setting('visibility.events')::bigint,'private preference changes do not broadcast to channel');
select lives_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"👍","active":true}')$$,'explicit active true adds reaction');
select lives_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"👍","active":true}')$$,'repeated active true succeeds');
select is((public.channel_snapshot(current_setting('visibility.org')::uuid,'e1200000-0000-4000-8000-000000000001')->'messages'->0->'reactions'->0->>'count')::int,1,'repeated active true preserves exactly one reaction');
select lives_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"👍","active":false}')$$,'explicit active false removes reaction');
select lives_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"👍","active":false}')$$,'repeated active false succeeds');
select is(jsonb_array_length(public.channel_snapshot(current_setting('visibility.org')::uuid,'e1200000-0000-4000-8000-000000000001')->'messages'->0->'reactions'),0,'repeated active false keeps reaction absent');
select throws_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"👍","active":"false"}')$$,'22023','invalid_channel_reaction','string active value is rejected');
select throws_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"👍","active":null}')$$,'22023','invalid_channel_reaction','null active value is rejected');
select throws_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","emoji":"💣","active":false}')$$,'22023','invalid_channel_reaction','unsupported emoji is rejected even for absent-state no-op');
select throws_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","active":false}')$$,'22023','invalid_channel_reaction','missing emoji is rejected even for absent-state no-op');
reset role;

insert into public.user_blocks(blocker_id,blocked_user_id) values('e1100000-0000-4000-8000-000000000002','e1100000-0000-4000-8000-000000000001');
set local role authenticated;
select set_config('request.jwt.claim.sub','e1100000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.channel_thread_snapshot('e1200000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','known blocked root UUID cannot reveal replies');
select throws_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000002","emoji":"👍"}')$$,'42501','channel_access_denied','cannot react to reply under blocked root');
select throws_ok($$select public.channel_rich_command('react','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000002","emoji":"👍","active":false}')$$,'42501','channel_access_denied','desired-state no-op still requires message visibility');
select throws_ok($$select public.channel_rich_command('forward','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000001","targetChannelId":"e1200000-0000-4000-8000-000000000002","operationId":"e1300000-0000-4000-8000-000000000009"}')$$,'42501','channel_access_denied','known blocked source cannot be forwarded');
select throws_ok($$select public.channel_rich_command('send','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000002","messageId":"e1300000-0000-4000-8000-000000000009","body":"차단 우회 답글","parentMessageId":"e1300000-0000-4000-8000-000000000001"}')$$,'22023','invalid_channel_thread','known blocked root cannot receive new replies');
select is((select count(*) from storage.objects where name=current_setting('visibility.path')),0::bigint,'saved attachment path cannot bypass block through Storage');
select is((select count(*) from public.notifications where id='e1600000-0000-4000-8000-000000000001'),0::bigint,'blocked-root reply notifications are hidden even for unblocked reply author');
select is(pg_temp.unread_count(),0,'blocked-root replies do not leak in unread count');
reset role;
delete from public.user_blocks where blocker_id='e1100000-0000-4000-8000-000000000002';
update public.channel_messages set hidden_at=clock_timestamp() where id='e1300000-0000-4000-8000-000000000001';
set local role authenticated;
select is((select count(*) from storage.objects where name=current_setting('visibility.path')),0::bigint,'moderated root attachment cannot be resigned');
reset role;
update public.channel_messages set hidden_at=null where id='e1300000-0000-4000-8000-000000000001';
update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='e1100000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select public.channel_thread_snapshot('e1200000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','withdrawn root author hides thread');
select is((select count(*) from storage.objects where name=current_setting('visibility.path')),0::bigint,'withdrawn uploader hides saved attachment');
reset role;
update public.user_consents set accepted=true,withdrawn_at=null where user_id='e1100000-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub','e1100000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.channel_rich_command('send','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000001","messageId":"e1300000-0000-4000-8000-000000000001","body":"원문","attachments":[],"mentionUserIds":[]}')$$,'23505','channel_operation_conflict','retry cannot silently replace attachment payload');
select lives_ok($$select public.channel_rich_command('send','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000001","messageId":"e1300000-0000-4000-8000-000000000003","body":"더 늦게 온 원문","attachments":[],"mentionUserIds":[]}')$$,'exact send retry remains idempotent');
select throws_ok($$select public.channel_rich_command('send','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000001","messageId":"e1300000-0000-4000-8000-000000000003","body":"더 늦게 온 원문","attachments":[],"mentionUserIds":["e1100000-0000-4000-8000-000000000002"]}')$$,'23505','channel_operation_conflict','retry cannot silently replace mention recipients');
select is(jsonb_array_length(public.channel_rich_command('delete','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000001","messageId":"e1300000-0000-4000-8000-000000000001"}')->'deletedPaths'),1,'delete returns exact cleanup paths');
select is(jsonb_array_length(public.channel_rich_command('delete','e1200000-0000-4000-8000-000000000001','{"expectedActorId":"e1100000-0000-4000-8000-000000000001","messageId":"e1300000-0000-4000-8000-000000000001"}')->'deletedPaths'),1,'lost delete response can retrieve same cleanup paths');
select set_config('request.jwt.claim.sub','e1100000-0000-4000-8000-000000000002',true);
select is(public.channel_thread_snapshot('e1200000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001')->>'rootDeleted','true','deleted root preserves existing replies with explicit tombstone');
select is((select count(*) from storage.objects where name=current_setting('visibility.path')),0::bigint,'deleted attachment cannot be read by other participants');
reset role;
select lives_ok($$delete from public.community_channels where id='e1200000-0000-4000-8000-000000000001'$$,'channel cascade deletion does not insert dangling events');
select is((select count(*) from private.channel_thread_reads where channel_id='e1200000-0000-4000-8000-000000000001'),0::bigint,'channel deletion removes private read state');

select * from finish();
rollback;
