begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
select has_function('public','admin_operations_snapshot',array[]::text[],'operations observation RPC exists');
select has_function('public','admin_operations_case',array['uuid','text'],'case evidence requires exact case and reason');
select ok(not has_function_privilege('anon','public.admin_operations_snapshot()','EXECUTE'),'anonymous cannot read metrics');
select ok(not has_function_privilege('anon','public.admin_operations_case(uuid,text)','EXECUTE'),'anonymous cannot investigate');
select ok(not has_function_privilege('authenticated','private.require_operations_admin()','EXECUTE'),'admin primitive not client callable');
select ok(not has_table_privilege('authenticated','private.operations_holds','SELECT'),'legal holds cannot be read directly');
select ok(not has_table_privilege('authenticated','private.operations_exports','UPDATE'),'archive verification cannot be forged directly');
select ok(not has_table_privilege('authenticated','private.operations_appeals','UPDATE'),'appeal decision cannot bypass RPC');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('private.operations_holds'::regclass,'private.operations_appeals'::regclass,'private.operations_exports'::regclass)),'all operations tables enable defense-in-depth RLS');
select throws_ok('select public.admin_operations_snapshot()','42501','operations_admin_required','unauthenticated observation fails closed');
select throws_ok($$select public.admin_operations_case(gen_random_uuid(),'specific incident investigation')$$,'42501','operations_admin_required','unauthenticated evidence fails closed');
select throws_ok($$select public.admin_operations_export(now()-interval '1 day',now(),'documented archive purpose')$$,'42501','operations_admin_required','unauthenticated export fails closed');
select throws_ok($$select public.operations_submit_appeal(gen_random_uuid(),'specific appeal explanation')$$,'42501','appeal_not_authorized','appeal requires case party');
select ok(position('chat_members' in pg_get_functiondef('public.admin_operations_case(uuid,text)'::regprocedure))=0,'incident view never adds chat membership');
select ok(position('retention_deletion_authorized'',false' in pg_get_functiondef('public.admin_operations_verify_export(uuid,jsonb)'::regprocedure))>0,'archive checksum validation never authorizes deletion');
select ok(not has_function_privilege('anon','public.operations_my_reports(integer)','EXECUTE'),'self-service report discovery requires authentication');
select throws_ok('select public.operations_my_reports()','42501','authentication_required','self-service report list cannot discover other actors anonymously');
-- Synthetic users and Auth-owned Google session evidence; all data rolls back.
insert into auth.users(id,email,raw_user_meta_data)
select ('0f150000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'ops-'||n||'@example.invalid',jsonb_build_object('display_name','Ops fixture '||n) from generate_series(1,4) n;
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like '0f150000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
insert into public.platform_admins(user_id,note) values('0f150000-0000-4000-8000-000000000001','rollback operations test');
update public.organizations set status='active' where slug='jaegun-bupyeong';
select set_config('ops.org',(select id::text from public.organizations where slug='jaegun-bupyeong'),true);
insert into public.organization_memberships(user_id,organization_id,role,status)
select id,current_setting('ops.org')::uuid,'member','active' from public.profiles where id::text like '0f150000-%' and id<>'0f150000-0000-4000-8000-000000000001';
insert into auth.identities(provider_id,user_id,identity_data,provider)
select id::text,id,jsonb_build_object('sub',id::text),'google' from auth.users where id::text like '0f150000-%';
select set_config('ops.now',floor(extract(epoch from statement_timestamp()))::bigint::text,true);
insert into auth.sessions(id,user_id,created_at,updated_at,aal)
select id,id,to_timestamp(current_setting('ops.now')::bigint),to_timestamp(current_setting('ops.now')::bigint),'aal1' from auth.users where id::text like '0f150000-%';
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
select gen_random_uuid(),id,to_timestamp(current_setting('ops.now')::bigint),to_timestamp(current_setting('ops.now')::bigint),'oauth' from auth.users where id::text like '0f150000-%';
create function pg_temp.ops_actor(n integer,oauth boolean default true) returns void language plpgsql as $$
declare actor uuid:=('0f150000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid; stamp bigint:=current_setting('ops.now')::bigint;
begin
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'session_id',actor,'role','authenticated','is_anonymous',false,'aud','authenticated','iat',stamp,'exp',stamp+3600,'aal','aal1','amr',jsonb_build_array(jsonb_build_object('method',case when oauth then 'oauth' else 'password' end,'timestamp',stamp)))::text,true);
end $$;
create temporary table ops_results(key text primary key,value jsonb);
grant all on ops_results to authenticated;
select pg_temp.ops_actor(3);
set local role authenticated;
select public.save_community_post_draft('0f150001-0000-4000-8000-000000000001',auth.uid(),current_setting('ops.org')::uuid,(select id from public.boards where organization_id=current_setting('ops.org')::uuid and slug='anonymous-qa'),'Reported anonymous question','Only this submitted evidence',true);
select public.publish_owned_post('0f150001-0000-4000-8000-000000000001',auth.uid(),'{}');
select pg_temp.ops_actor(2);
select set_config('ops.report',public.create_content_report('post','0f150001-0000-4000-8000-000000000001','harassment','Reporter submitted explanation')::text,true);
select is(jsonb_array_length(public.operations_my_reports()),1,'reporter discovers own case');
select pg_temp.ops_actor(4);
select is(jsonb_array_length(public.operations_my_reports()),0,'unrelated member cannot discover case');
select throws_ok($$select public.operations_submit_appeal(current_setting('ops.report')::uuid,'Unrelated actor tries to appeal')$$,'42501','appeal_not_authorized','unrelated actor cannot appeal');
select throws_ok($$select public.admin_operations_case(current_setting('ops.report')::uuid,'Unrelated actor investigates case')$$,'42501','operations_admin_required','nonadmin cannot investigate a known case UUID');
select pg_temp.ops_actor(1,false);
select throws_ok($$select public.admin_operations_case(current_setting('ops.report')::uuid,'Documented exact-case investigation')$$,'42501',null,'live Google proof is required even for current admin');
select pg_temp.ops_actor(1);
select throws_ok($$select public.admin_operations_case(current_setting('ops.report')::uuid,'short')$$,'P0001','investigation_reason_required','short evidence access reason denied');
select throws_ok($$select public.admin_operations_case('0f150001-0000-4000-8000-000000000099','Documented missing case investigation')$$,'P0002','query returned no rows','nonreported target cannot be investigated');
select lives_ok($$insert into ops_results values('case',public.admin_operations_case(current_setting('ops.report')::uuid,'Documented exact-case investigation'))$$,'fresh Google admin opens only reported evidence');
select is((select value#>>'{evidence,body}' from ops_results where key='case'),'Only this submitted evidence','incident view returns exact reported snapshot body');
select is((select value#>>'{reported_author,id}' from ops_results where key='case'),'0f150000-0000-4000-8000-000000000003','case exposes only actual reported author');
select ok((select value->'reported_author' = '{"id":"0f150000-0000-4000-8000-000000000003","display_name":"Ops fixture 3"}'::jsonb from ops_results where key='case'),'author projection contains no email contact or private-faith fields');
select lives_ok($$select public.admin_operations_action(current_setting('ops.report')::uuid,'hold','Documented legal preservation need')$$,'admin places legal hold');
reset role;
select is((select count(*) from public.audit_logs where action='operations.evidence_accessed' and entity_id=current_setting('ops.report')::uuid and details->>'reason'='Documented exact-case investigation'),1::bigint,'successful evidence read creates exact-case reason audit');
select throws_ok($$update public.content_reports set evidence_snapshot='{}' where id=current_setting('ops.report')::uuid$$,'42501','incident_evidence_under_legal_hold','legal hold prevents evidence modification');
select is((select count(*) from private.operations_holds where report_id=current_setting('ops.report')::uuid and released_at is null),1::bigint,'legal hold state is persisted');
set local role authenticated;
select lives_ok($$select public.admin_operations_action(current_setting('ops.report')::uuid,'warning_recorded','Documented warning after investigation')$$,'admin sanctions reported author');
reset role;
select is((select resolution_code from public.content_reports where id=current_setting('ops.report')::uuid),'warning_recorded','sanction updates actual case resolution');
select is((select count(*) from public.moderation_actions where report_id=current_setting('ops.report')::uuid and action_code='warning_recorded'),1::bigint,'sanction writes immutable moderation decision');
select pg_temp.ops_actor(3);
set local role authenticated;
select is(jsonb_array_length(public.operations_my_reports()),1,'reported author discovers actual sanction');
insert into ops_results values('appeal',to_jsonb(public.operations_submit_appeal(current_setting('ops.report')::uuid,'Please review this warning with context')));
select throws_ok($$select public.operations_submit_appeal(current_setting('ops.report')::uuid,'short')$$,'P0001','appeal_reason_required','appeal validates trimmed reason');
select throws_ok($$select public.operations_submit_appeal(current_setting('ops.report')::uuid,'Please review this warning with context')$$,'23505',null,'duplicate pending appeal cannot be submitted');
reset role;
update auth.sessions set not_after=statement_timestamp()-interval '1 minute' where id='0f150000-0000-4000-8000-000000000003';
set local role authenticated;
select throws_ok('select public.operations_my_reports()','42501','authentication_required','expired live session cannot discover even owned reports');
reset role;
update auth.sessions set not_after=null where id='0f150000-0000-4000-8000-000000000003';
update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='0f150000-0000-4000-8000-000000000003';
set local role authenticated;
select is(jsonb_array_length(public.operations_my_reports()),1,'minimal rights self-service remains available after consent withdrawal');
select pg_temp.ops_actor(1);
select lives_ok($$select public.admin_operations_action(current_setting('ops.report')::uuid,'reject_appeal','Independent documented review confirms warning',(select (value#>>'{}')::uuid from ops_results where key='appeal'))$$,'admin decides submitted appeal');
select lives_ok($$select public.admin_operations_action(current_setting('ops.report')::uuid,'release_hold','Legal preservation need has concluded')$$,'explicit release does not delete records');
select throws_ok($$select public.admin_operations_export(now()-interval '32 days',now(),'Documented audit archive request')$$,'P0001','bounded_export_and_reason_required','export range is bounded');
insert into ops_results values('archive',public.admin_operations_export(now()-interval '1 day',clock_timestamp()+interval '1 minute','Documented audit archive request'));
select ok((select jsonb_array_length(value->'records')>0 and length(value#>>'{manifest,sha256}')=64 from ops_results where key='archive'),'real audit records download includes SHA256 manifest');
select lives_ok($$select public.admin_operations_verify_export((value->>'id')::uuid,value->'records') from ops_results where key='archive'$$,'unchanged downloaded archive verifies');
select throws_ok($$select public.admin_operations_verify_export((value->>'id')::uuid,'[]') from ops_results where key='archive'$$,'P0001','archive_checksum_mismatch','tampered archive is rejected');
select is((select public.admin_operations_verify_export((value->>'id')::uuid,value->'records')->>'retention_deletion_authorized' from ops_results where key='archive'),'false','restore verification does not authorize deletion');
reset role;
select is((select count(*) from private.operations_exports where verified_at is not null and actor_id='0f150000-0000-4000-8000-000000000001'),1::bigint,'server records real verification transition');
select is((select status from private.operations_appeals where report_id=current_setting('ops.report')::uuid),'rejected','appeal decision transition is persisted');
select ok((select released_at is not null from private.operations_holds where report_id=current_setting('ops.report')::uuid),'explicit legal hold release is persisted');
select is((select count(*) from public.content_reports where id=current_setting('ops.report')::uuid),1::bigint,'release and verification never delete case');
insert into public.conversations(id,organization_id,participant_low,participant_high,created_by) values('0f150002-0000-4000-8000-000000000001',current_setting('ops.org')::uuid,'0f150000-0000-4000-8000-000000000002','0f150000-0000-4000-8000-000000000003','0f150000-0000-4000-8000-000000000002');
select pg_temp.ops_actor(2);
insert into public.messages(id,conversation_id,sender_id,body) values('0f150003-0000-4000-8000-000000000001','0f150002-0000-4000-8000-000000000001',auth.uid(),'Private unrelated DM never submitted');
select pg_temp.ops_actor(1);
set local role authenticated;
select is((select count(*) from public.messages where conversation_id='0f150002-0000-4000-8000-000000000001'),0::bigint,'incident admin gets no arbitrary DM read bypass');
select throws_ok($$select public.get_faith_community(current_setting('ops.org')::uuid)$$,'42501','faith_active_church_membership_required','incident admin gets no private faith bypass');
reset role;
select ok(not has_table_privilege('authenticated','private.audit_gateway_keys','SELECT'),'gateway HMAC secrets are never client-readable');
select ok(not has_function_privilege('authenticated','public.configure_audit_gateway(text,text,text,text,boolean)','EXECUTE'),'client cannot provision trusted gateway keys');
select ok(not has_table_privilege('authenticated','private.audit_provenance','SELECT'),'IP provenance has no raw table read grant');
select is((select count(*) from private.audit_provenance p join public.audit_logs a on a.id=p.audit_id where a.actor_id='0f150000-0000-4000-8000-000000000001' and p.status='verified'),0::bigint,'direct requests never fabricate verified IP');
insert into private.audit_gateway_keys values('ops-test','fixture-only-key-at-least-32-bytes-long','rollback-test-gateway','Synthetic rollback-only legal approval',true);
select set_config('ops.gateway_time',floor(extract(epoch from clock_timestamp()))::bigint::text,true);
select set_config('ops.gateway_request','0f150004-0000-4000-8000-000000000001',true);
select set_config('request.method','POST',true);
select set_config('request.path','/rpc/admin_operations_snapshot',true);
select set_config('request.headers',jsonb_build_object(
 'x-jaegun-audit-key','ops-test','x-jaegun-audit-ip','203.0.113.9','x-jaegun-audit-time',current_setting('ops.gateway_time'),'x-jaegun-audit-request',current_setting('ops.gateway_request'),
 'x-jaegun-audit-signature',encode(extensions.hmac(convert_to(
 'jaegun-audit-v1'||chr(10)||auth.uid()::text||chr(10)||(auth.jwt()->>'session_id')||chr(10)||'POST'||chr(10)||'/rpc/admin_operations_snapshot'||chr(10)||'203.0.113.9'||chr(10)||current_setting('ops.gateway_time')||chr(10)||current_setting('ops.gateway_request'),'UTF8'),convert_to('fixture-only-key-at-least-32-bytes-long','UTF8'),'sha256'),'hex'))::text,true);
set local role authenticated;
select lives_ok($$select public.admin_operations_snapshot()$$,'properly signed gateway request records real audit');
reset role;
select is((select count(*) from private.audit_provenance where request_id=current_setting('ops.gateway_request')::uuid and status='verified' and client_ip='203.0.113.9'::inet),1::bigint,'verified HMAC IP provenance is stored with source and nonce');
select set_config('ops.provenance_audit',(select audit_id::text from private.audit_provenance where request_id=current_setting('ops.gateway_request')::uuid),true);
-- This pgTAP transaction models a nonce already consumed by a prior HTTP transaction.
update private.audit_gateway_nonces set transaction_id=-1 where request_id=current_setting('ops.gateway_request')::uuid;
set local role authenticated;
select lives_ok($$select public.admin_operations_snapshot()$$,'envelope replay never breaks underlying authorized operation');
reset role;
select is((select count(*) from private.audit_provenance where request_id=current_setting('ops.gateway_request')::uuid and status='verified'),1::bigint,'nonce replay cannot manufacture another verified provenance');
select ok(exists(select 1 from private.audit_provenance where source='gateway_envelope_replayed' and status='unavailable' and client_ip is null),'replay explicitly records unavailable without retaining untrusted IP');
select set_config('request.headers',(current_setting('request.headers')::jsonb||'{"x-jaegun-audit-ip":"8.8.8.8"}'::jsonb)::text,true);
set local role authenticated;
select lives_ok($$select public.admin_operations_snapshot()$$,'forged address does not block normal action');
select throws_ok($$select public.admin_operations_audit_provenance(current_setting('ops.provenance_audit')::uuid,'short')$$,'P0001','investigation_reason_required','provenance is reason bound');
select is(public.admin_operations_audit_provenance(current_setting('ops.provenance_audit')::uuid,'Specific documented security investigation')->>'client_ip','203.0.113.9','Google-authorized exact audit view returns verified address only');
reset role;
select ok(not exists(select 1 from private.audit_provenance where client_ip='8.8.8.8'::inet),'forged forwarding address is never stored');
select pg_temp.ops_actor(4);
set local role authenticated;
select throws_ok($$select public.admin_operations_audit_provenance(current_setting('ops.provenance_audit')::uuid,'Unrelated member attempts IP access')$$,'42501','operations_admin_required','nonadmin cannot read verified audit IP');
reset role;
do $tap_gate$
declare lines text[];
begin
 select array_agg(line) into lines from finish() line;
 if coalesce(cardinality(lines),0)<>1 or lines[1] !~ '^1\.\.[1-9][0-9]*$' then
  raise exception 'operations_pgtap_failed' using detail=array_to_string(lines,E'\n');
 end if;
 perform set_config('test.operations_plan',lines[1],true);
end $tap_gate$;
select current_setting('test.operations_plan') as passed_plan;
rollback;
