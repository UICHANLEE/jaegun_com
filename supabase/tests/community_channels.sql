begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
insert into auth.users(id,email,raw_user_meta_data) values
('cc000000-0000-4000-8000-000000000001','channel-one@example.com','{"display_name":"채널 소유자"}'),
('cc000000-0000-4000-8000-000000000002','channel-two@example.com','{"display_name":"일반 회원"}'),
('cc000000-0000-4000-8000-000000000003','channel-three@example.com','{"display_name":"다른 교회"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'cc000000-%' and d.required and d.retired_at is null
and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug in ('jaegun-bupyeong','jaegun-namseoul');
select set_config('test.org',(select id::text from public.organizations where slug='jaegun-bupyeong'),true);
select set_config('test.other',(select id::text from public.organizations where slug='jaegun-namseoul'),true);
insert into public.organization_memberships(user_id,organization_id,role,status) values
('cc000000-0000-4000-8000-000000000001',current_setting('test.org')::uuid,'member','active'),
('cc000000-0000-4000-8000-000000000002',current_setting('test.org')::uuid,'member','active'),
('cc000000-0000-4000-8000-000000000003',current_setting('test.other')::uuid,'member','active');
select ok(not has_table_privilege('authenticated','public.channel_messages','select'),'no raw message bypass');
select ok(not has_table_privilege('authenticated','public.channel_members','insert'),'cannot self-grant channel management');
select ok(not has_function_privilege('anon','public.channel_snapshot(uuid,uuid,bigint)','execute'),'anonymous cannot list channels');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.channel_messages'::regclass,'public.channel_members'::regclass,'public.community_channels'::regclass)),'all channel tables have RLS');
set local role authenticated;
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('create','cd000000-0000-4000-8000-000000000001',jsonb_build_object('organizationId',current_setting('test.org'),'name','찬양 준비','visibility','private'))$$,'ordinary member creates private channel');
select lives_ok($$select public.channel_command('create','cd000000-0000-4000-8000-000000000001',jsonb_build_object('organizationId',current_setting('test.org'),'name','찬양 준비','visibility','private'))$$,'create retry is idempotent');
select lives_ok($$select public.channel_command('create','cd000000-0000-4000-8000-000000000002',jsonb_build_object('organizationId',current_setting('test.org'),'name','일상 나눔','visibility','public'))$$,'ordinary member creates church-public channel');
select throws_ok($$select public.channel_command('create','cd000000-0000-4000-8000-000000000003',jsonb_build_object('organizationId',current_setting('test.org'),'name','x','visibility','public'))$$,'23514',null,'short name rejected');
select throws_ok($$select public.channel_command('leave','cd000000-0000-4000-8000-000000000001')$$,'23514','transfer_owner_first','owner cannot abandon active channel');
select lives_ok($$select public.channel_command('send','cd000000-0000-4000-8000-000000000001','{"messageId":"ce000000-0000-4000-8000-000000000001","body":"안녕하세요"}')$$,'member sends message');
select lives_ok($$select public.channel_command('send','cd000000-0000-4000-8000-000000000001','{"messageId":"ce000000-0000-4000-8000-000000000001","body":"안녕하세요"}')$$,'lost-response retry safe');
select is(jsonb_array_length(public.channel_snapshot(current_setting('test.org')::uuid,'cd000000-0000-4000-8000-000000000001')->'messages'),1,'no duplicate message');
select throws_ok($$select public.channel_command('send','cd000000-0000-4000-8000-000000000001','{"messageId":"ce000000-0000-4000-8000-000000000001","body":"다른 내용"}')$$,'23505','channel_operation_conflict','idempotency payload bound');
select throws_ok($$select public.channel_command('send','cd000000-0000-4000-8000-000000000001','{"messageId":"ce000000-0000-4000-8000-000000000002","body":" "}')$$,'22023','invalid_channel_message','blank message rejected');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000002',true);
select is(jsonb_array_length(public.channel_snapshot(current_setting('test.org')::uuid)->'channels'),1,'private channel metadata hidden from nonparticipant');
select throws_ok($$select public.channel_snapshot(current_setting('test.org')::uuid,'cd000000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','private messages hidden');
select throws_ok($$select public.channel_command('join','cd000000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','cannot self-join private channel');
select throws_ok($$select public.channel_command('leave','cd000000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','leave cannot probe an uninvited private channel');
select lives_ok($$select public.channel_command('join','cd000000-0000-4000-8000-000000000002')$$,'church member joins public channel');
select throws_ok($$select public.channel_command('archive','cd000000-0000-4000-8000-000000000002')$$,'42501','channel_access_denied','participant has no owner power');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('invite','cd000000-0000-4000-8000-000000000001','{"userId":"cc000000-0000-4000-8000-000000000002"}')$$,'owner invites church member');
select lives_ok($$select public.channel_command('manager','cd000000-0000-4000-8000-000000000002','{"userId":"cc000000-0000-4000-8000-000000000002","role":"manager"}')$$,'owner appoints channel manager');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.channel_command('archive','cd000000-0000-4000-8000-000000000002')$$,'42501','channel_owner_required','manager cannot archive owner channel');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('transfer','cd000000-0000-4000-8000-000000000002','{"userId":"cc000000-0000-4000-8000-000000000002"}')$$,'owner transfers only to active participant');
select throws_ok($$select public.channel_command('archive','cd000000-0000-4000-8000-000000000002')$$,'42501','channel_owner_required','previous owner loses ownership authority');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_command('archive','cd000000-0000-4000-8000-000000000002')$$,'new owner archives');
select throws_ok($$select public.channel_command('send','cd000000-0000-4000-8000-000000000002','{"messageId":"ce000000-0000-4000-8000-000000000009","body":"보관 후"}')$$,'23514','channel_archived','archived channel disallows messages');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.channel_command('invite','cd000000-0000-4000-8000-000000000001','{"userId":"cc000000-0000-4000-8000-000000000003"}')$$,'42501','channel_access_denied','cannot invite other church');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.channel_snapshot(current_setting('test.org')::uuid,'cd000000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','invitation is not message access');
select lives_ok($$select public.channel_command('join','cd000000-0000-4000-8000-000000000001')$$,'explicit invitation acceptance');
select is(jsonb_array_length(public.channel_snapshot(current_setting('test.org')::uuid,'cd000000-0000-4000-8000-000000000001')->'messages'),1,'accepted invite reads history');
select lives_ok($$select public.report_channel_message('ce000000-0000-4000-8000-000000000001','spam','테스트 신고')$$,'channel report reaches moderation');
select throws_ok($$select public.channel_command('send','cd000000-0000-4000-8000-000000000001','{"expectedActorId":"cc000000-0000-4000-8000-000000000001","messageId":"ce000000-0000-4000-8000-000000000002","body":"다른 계정"}')$$,'42501','channel_access_denied','stale account write rejected');
reset role;
insert into public.user_blocks(blocker_id,blocked_user_id) values('cc000000-0000-4000-8000-000000000002','cc000000-0000-4000-8000-000000000001');
set local role authenticated;
select is(jsonb_array_length(public.channel_snapshot(current_setting('test.org')::uuid,'cd000000-0000-4000-8000-000000000001')->'messages'),0,'blocked author messages are redacted');
reset role;
delete from public.user_blocks where blocker_id='cc000000-0000-4000-8000-000000000002';
delete from public.user_consents where user_id='cc000000-0000-4000-8000-000000000002';
set local role authenticated;
select throws_ok($$select public.channel_snapshot(current_setting('test.org')::uuid)$$,'42501','current_required_consents_required','consent closed means no channel metadata');
reset role;
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select 'cc000000-0000-4000-8000-000000000002',document_key,version,true,'admin_migration' from public.consent_documents
where required and retired_at is null and published_at<=statement_timestamp() and effective_at<=statement_timestamp();
update public.organization_memberships set status='suspended',ended_at=clock_timestamp() where user_id='cc000000-0000-4000-8000-000000000002';
select is((select count(*) from public.channel_members where user_id='cc000000-0000-4000-8000-000000000002'),0::bigint,'church suspension revokes channel invitations and memberships');
update public.organization_memberships set status='active',ended_at=null where user_id='cc000000-0000-4000-8000-000000000002';
set local role authenticated;
select throws_ok($$select public.channel_command('join','cd000000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','church reactivation does not restore private invite');
select set_config('request.jwt.claim.sub','cc000000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.channel_snapshot(current_setting('test.org')::uuid)$$,'42501','channel_access_denied','other church cannot enumerate channels');
select throws_ok($$select public.channel_command('join','cd000000-0000-4000-8000-000000000002')$$,'42501','channel_access_denied','other church cannot join public channel');
reset role;
select is((select count(*) from public.content_reports where target_type='channel_message' and target_id='ce000000-0000-4000-8000-000000000001'),1::bigint,'one scoped channel report stored');
select is((select role::text from public.organization_memberships where user_id='cc000000-0000-4000-8000-000000000001'),'member','channel owner remains ordinary church member');
select set_config('test.report',(select id::text from public.content_reports where target_id='ce000000-0000-4000-8000-000000000001'),true);
insert into public.platform_admins(user_id,note) values('cc000000-0000-4000-8000-000000000003','Synthetic channel moderator');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"cc000000-0000-4000-8000-000000000003","aal":"aal1","role":"authenticated"}',true);
select throws_ok($$select public.resolve_content_report(current_setting('test.report')::uuid,'content_hidden','테스트 숨김 사유')$$,'42501','aal2_required:moderation_sanction','channel sanctions require MFA');
select set_config('request.jwt.claims','{"sub":"cc000000-0000-4000-8000-000000000003","aal":"aal2","role":"authenticated"}',true);
select lives_ok($$select public.resolve_content_report(current_setting('test.report')::uuid,'content_hidden','테스트 숨김 사유')$$,'MFA moderator hides channel message');
reset role;
select ok((select hidden_at is not null from public.channel_messages where id='ce000000-0000-4000-8000-000000000001'),'moderation changes actual channel message');
select is((select count(*) from public.moderation_actions where report_id=current_setting('test.report')::uuid and action_code='content_hidden'),1::bigint,'channel sanction recorded in moderation audit');
delete from auth.users where id='cc000000-0000-4000-8000-000000000001';
select is((select count(*) from public.channel_messages where id='ce000000-0000-4000-8000-000000000001'),0::bigint,'account deletion removes authored channel messages');
select ok((select archived and owner_id is null from public.community_channels where id='cd000000-0000-4000-8000-000000000001'),'deleted owner channel archived');
select * from finish();
rollback;
