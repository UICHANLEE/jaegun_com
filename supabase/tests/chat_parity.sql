begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
insert into auth.users(id,email,raw_user_meta_data) values
('ca600000-0000-4000-8000-000000000001','native-chat-owner@example.com','{"display_name":"소유자"}'),
('ca600000-0000-4000-8000-000000000002','native-chat-member@example.com','{"display_name":"참여자"}'),
('ca600000-0000-4000-8000-000000000003','native-chat-other@example.com','{"display_name":"다른 교회"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'ca600000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug in ('jaegun-bupyeong','jaegun-namseoul');
select set_config('chat.org',(select id::text from public.organizations where slug='jaegun-bupyeong'),true);
select set_config('chat.other',(select id::text from public.organizations where slug='jaegun-namseoul'),true);
insert into public.organization_memberships(user_id,organization_id,role,status) values
('ca600000-0000-4000-8000-000000000001',current_setting('chat.org')::uuid,'member','active'),
('ca600000-0000-4000-8000-000000000002',current_setting('chat.org')::uuid,'member','active'),
('ca600000-0000-4000-8000-000000000003',current_setting('chat.other')::uuid,'member','active');
select ok(not has_function_privilege('anon','public.validate_chat_access(uuid,uuid)','execute'),'anonymous cannot validate private chat scopes');
select ok(not has_function_privilege('anon','public.update_community_channel(uuid,uuid,text,text,text,text)','execute'),'anonymous cannot edit channel metadata');
set local role authenticated;
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000001',true);
select set_config('chat.dm',public.get_or_create_conversation('ca600000-0000-4000-8000-000000000002')::text,true);
select lives_ok($$select public.validate_chat_access(null,current_setting('chat.dm')::uuid)$$,'DM creator validates only their own conversation');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.validate_chat_access(null,current_setting('chat.dm')::uuid)$$,'other DM participant validates the shared conversation');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.validate_chat_access(null,current_setting('chat.dm')::uuid)$$,'42501','chat_access_denied','third party cannot validate a DM without joining');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('create','ca610000-0000-4000-8000-000000000001',jsonb_build_object('organizationId',current_setting('chat.org'),'name','준비 모임','visibility','private'))$$,'ordinary member creates private channel');
select is(public.validate_chat_access('ca610000-0000-4000-8000-000000000001')->>'actorId','ca600000-0000-4000-8000-000000000001','heartbeat scope check binds current actor');
select throws_ok($$select public.validate_chat_access('ca610000-0000-4000-8000-000000000001',current_setting('chat.dm')::uuid)$$,'22023','invalid_chat_scope','DM and channel scopes cannot be mixed');
select throws_ok($$select public.validate_chat_access(null,null)$$,'22023','invalid_chat_scope','heartbeat requires exactly one scope');
select lives_ok($$select public.update_community_channel('ca610000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','수정된 모임','설명','준비 모임','')$$,'owner edits channel');
select lives_ok($$select public.update_community_channel('ca610000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','수정된 모임','설명','준비 모임','')$$,'identical lost-response edit is a no-op');
select throws_ok($$select public.update_community_channel('ca610000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','오래된 수정','설명','준비 모임','')$$,'40001','channel_revision_conflict','stale edit cannot overwrite concurrent metadata');
select throws_ok($$select public.update_community_channel('ca610000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000002','잘못된 계정','','수정된 모임','설명')$$,'42501','channel_access_denied','actor-bound edits reject stale account');
select lives_ok($$select public.channel_command('invite','ca610000-0000-4000-8000-000000000001','{"userId":"ca600000-0000-4000-8000-000000000002"}')$$,'issue private invitation');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.validate_chat_access('ca610000-0000-4000-8000-000000000001')$$,'42501','chat_access_denied','invitation does not grant conversation access');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('remove','ca610000-0000-4000-8000-000000000001','{"userId":"ca600000-0000-4000-8000-000000000002"}')$$,'revoke pending invitation');
select lives_ok($$select public.channel_command('remove','ca610000-0000-4000-8000-000000000001','{"userId":"ca600000-0000-4000-8000-000000000002"}')$$,'revocation retry is idempotent');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.channel_command('join','ca610000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','revoked invitation cannot be accepted');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('invite','ca610000-0000-4000-8000-000000000001','{"userId":"ca600000-0000-4000-8000-000000000002"}')$$,'explicitly reinvite');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_command('join','ca610000-0000-4000-8000-000000000001')$$,'explicit acceptance enables participation');
select lives_ok($$select public.validate_chat_access('ca610000-0000-4000-8000-000000000001')$$,'accepted participant validates access');
select throws_ok($$select public.update_community_channel('ca610000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000002','임의 변경','','수정된 모임','설명')$$,'42501','channel_access_denied','participant has no metadata management authority');
select lives_ok($$select public.channel_command('leave','ca610000-0000-4000-8000-000000000001','{"expectedActorId":"ca600000-0000-4000-8000-000000000002","operationId":"ca620000-0000-4000-8000-000000000001"}')$$,'private channel departure succeeds');
select lives_ok($$select public.channel_command('leave','ca610000-0000-4000-8000-000000000001','{"expectedActorId":"ca600000-0000-4000-8000-000000000002","operationId":"ca620000-0000-4000-8000-000000000001"}')$$,'private departure lost-response retry succeeds without restoring membership');
select throws_ok($$select public.channel_command('join','ca610000-0000-4000-8000-000000000001')$$,'42501','channel_access_denied','departure retry never restores private invitation');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.channel_command('invite','ca610000-0000-4000-8000-000000000001','{"userId":"ca600000-0000-4000-8000-000000000002"}')$$,'owner issues a fresh invitation after departure');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.channel_command('join','ca610000-0000-4000-8000-000000000001')$$,'member explicitly accepts fresh invitation');
reset role;
update public.organization_memberships set status='suspended',ended_at=clock_timestamp() where user_id='ca600000-0000-4000-8000-000000000002';
update public.organization_memberships set status='active',ended_at=null where user_id='ca600000-0000-4000-8000-000000000002';
set local role authenticated;
select throws_ok($$select public.validate_chat_access('ca610000-0000-4000-8000-000000000001')$$,'42501','chat_access_denied','membership renewal never resurrects private participation');
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.validate_chat_access('ca610000-0000-4000-8000-000000000001')$$,'42501','chat_access_denied','other church cannot validate private access');
reset role;
select is((select role::text from public.organization_memberships where user_id='ca600000-0000-4000-8000-000000000001'),'member','channel ownership never promotes organization role');
select is((select count(*) from public.audit_logs where actor_id='ca600000-0000-4000-8000-000000000001' and action='channel.updated'),1::bigint,'metadata retry creates one audit event');
delete from public.user_consents where user_id='ca600000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','ca600000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.validate_chat_access('ca610000-0000-4000-8000-000000000001')$$,'42501','current_required_consents_required','heartbeat fails closed when current consent is withdrawn');
reset role;
select * from finish();
rollback;
