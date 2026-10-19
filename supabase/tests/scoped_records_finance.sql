begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
select ok(not has_table_privilege('authenticated','private.scoped_records','select,insert,update,delete'),'records are RPC-only');
select ok(not has_table_privilege('authenticated','private.event_fee_states','select,insert,update,delete'),'fee states are RPC-only');
select ok(not has_function_privilege('anon','public.get_scoped_records(uuid,uuid,integer,text)','execute'),'anonymous records blocked');
select ok(not has_function_privilege('authenticated','private.can_scoped_records(uuid,uuid,text,boolean)','execute'),'authorization helper not exposed');
select ok(to_regprocedure('public.save_ledger_entry(uuid,boolean,uuid,integer,date,text,text,text,numeric,text)') is null,'legacy divergent write RPC removed, not retained as an inactive shim');
select is((select public from storage.buckets where id='finance-receipts'),false,'receipt bucket private');
select is((select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private' and c.relname in ('scoped_records','scoped_record_history','scoped_record_operations','finance_period_closes','event_fee_states','finance_receipts') and c.relrowsecurity),6::bigint,'all records enable fail closed RLS');
insert into auth.users(id,email,raw_user_meta_data) values
 ('94000000-0000-4000-8000-000000000001','finance-exec@example.invalid','{"display_name":"회계"}'),
 ('94000000-0000-4000-8000-000000000002','finance-secretary@example.invalid','{"display_name":"서기"}'),
 ('94000000-0000-4000-8000-000000000003','finance-member@example.invalid','{"display_name":"성도"}'),
 ('94000000-0000-4000-8000-000000000004','finance-minister@example.invalid','{"display_name":"목사"}'),
 ('94000000-0000-4000-8000-000000000005','finance-foreign@example.invalid','{"display_name":"다른 교회 회계"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like '94000000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug in ('jaegun-bupyeong','jaegun-busan');
insert into public.organization_memberships(user_id,organization_id,role)
select id,(select id from public.organizations where slug=case when p.id='94000000-0000-4000-8000-000000000005' then 'jaegun-busan' else 'jaegun-bupyeong' end),
 case when p.id in ('94000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000005') then 'executive'::public.app_role when p.id='94000000-0000-4000-8000-000000000004' then 'minister'::public.app_role else 'member'::public.app_role end
from public.profiles p where id::text like '94000000-%';
select set_config('finance.scope',(select id::text from public.governance_scopes where organization_id=(select id from public.organizations where slug='jaegun-bupyeong')),true);
select set_config('finance.parent',(select parent_scope_id::text from public.governance_scopes where id=current_setting('finance.scope')::uuid),true);
select set_config('finance.today',timezone('Asia/Seoul',statement_timestamp())::date::text,true);
select set_config('finance.year',private.current_service_year()::text,true);
insert into public.governance_office_assignments(scope_id,user_id,service_year,office_code)
values(current_setting('finance.scope')::uuid,'94000000-0000-4000-8000-000000000001',private.current_service_year(),'treasurer'),
(current_setting('finance.scope')::uuid,'94000000-0000-4000-8000-000000000002',private.current_service_year(),'secretary');
insert into auth.identities(provider_id,user_id,identity_data,provider)
select id::text,id,jsonb_build_object('sub',id::text),'google' from auth.users where id::text like '94000000-%';
insert into auth.sessions(id,user_id,created_at,updated_at,aal)
select id,id,statement_timestamp(),statement_timestamp(),'aal1' from auth.users where id::text like '94000000-%';
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
select gen_random_uuid(),id,statement_timestamp(),statement_timestamp(),'oauth' from auth.users where id::text like '94000000-%';
create function pg_temp.finance_actor(a uuid,proof boolean default true) returns void language plpgsql as $$
declare n bigint:=floor(extract(epoch from statement_timestamp()));
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',a,'role','authenticated','aud','authenticated','is_anonymous',false,'iat',n,'exp',n+3600,'aal','aal1','amr',case when proof then jsonb_build_array(jsonb_build_object('method','oauth','timestamp',n)) else '[]'::jsonb end)::text,true);
end $$;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000003');
set local role authenticated;
select throws_ok($$select public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'finance')$$,'42501','record_scope_forbidden','ordinary member cannot read');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000004');
set local role authenticated;
select throws_ok($$select public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'minutes')$$,'42501','record_scope_forbidden','ordinary minister cannot read');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000005');
set local role authenticated;
select throws_ok($$select public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'finance')$$,'42501','record_scope_forbidden','foreign executive cannot read');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000001');
set local role authenticated;
select is(public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'finance')->>'can_write','true','treasurer can write finance');
select is(public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'minutes')->>'can_write','false','treasurer cannot write minutes');
select throws_ok($$select public.get_scoped_records(current_setting('finance.parent')::uuid,null,current_setting('finance.year')::integer,'finance')$$,'42501','record_scope_forbidden','church office does not inherit parent read');
select lives_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000001',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'기간 수입','메모','published','income','회비',100,'KRW','96000000-0000-4000-8000-000000000001',auth.uid())$$,'real income saved');
select lives_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000001',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'기간 수입','메모','published','income','회비',100,'KRW','96000000-0000-4000-8000-000000000001',auth.uid())$$,'same operation replay is idempotent');
select is(jsonb_array_length(public.get_scoped_record_history('95000000-0000-4000-8000-000000000001')),1,'retry creates one history');
select throws_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000001',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'수정','메모','published','income','회비',200,'KRW','96000000-0000-4000-8000-000000000002',auth.uid())$$,'40001','record_revision_conflict','stale revision rejected');
select throws_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000002',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'잘못된 금액','','published','income','회비',-1,'KRW',gen_random_uuid(),auth.uid())$$,'P0001','invalid_finance_amount','negative amount rejected');
select throws_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000002',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'소수 정밀도','','published','income','회비',1.001,'KRW',gen_random_uuid(),auth.uid())$$,'P0001','invalid_finance_amount','invalid precision rejected');
select throws_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000002',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'다른 통화','','published','income','회비',1,'USD',gen_random_uuid(),auth.uid())$$,'P0001','invalid_record_request','currency enforced');
select lives_ok($$select public.delete_scoped_record('95000000-0000-4000-8000-000000000001',1,'96000000-0000-4000-8000-000000000003','오입력 환불',auth.uid())$$,'finance cancellation appends reversal');
select is((public.export_finance_report(current_setting('finance.scope')::uuid,null,current_setting('finance.today')::date,current_setting('finance.today')::date,false,auth.uid())->>'income')::numeric,100::numeric,'original income preserved');
select is((public.export_finance_report(current_setting('finance.scope')::uuid,null,current_setting('finance.today')::date,current_setting('finance.today')::date,false,auth.uid())->>'expense')::numeric,100::numeric,'reversal balances original');
select lives_ok($$select public.prepare_finance_receipt('95000000-0000-4000-8000-000000000001','99000000-0000-4000-8000-000000000001','supabase',102400)$$,'receipt reservation can precede period close');
select throws_ok($$select public.export_finance_report(current_setting('finance.scope')::uuid,null,current_setting('finance.today')::date,current_setting('finance.today')::date,false,'94000000-0000-4000-8000-000000000005')$$,'42501','actor_changed','stale-account report request rejected');
select lives_ok($$select public.export_finance_report(current_setting('finance.scope')::uuid,null,current_setting('finance.today')::date,current_setting('finance.today')::date,true,auth.uid())$$,'period closes with immutable report');
select throws_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000002',current_setting('finance.scope')::uuid,null,'finance',0,current_setting('finance.today')::date,'마감 뒤','','published','income','회비',1,'KRW',gen_random_uuid(),auth.uid())$$,'P0001','finance_period_closed','closed period prevents mutation');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000002');
set local role authenticated;
select is(public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'minutes')->>'can_write','true','secretary can write minutes');
select is(public.get_scoped_records(current_setting('finance.scope')::uuid,null,current_setting('finance.year')::integer,'finance')->>'can_write','false','secretary cannot write finance');
select lives_ok($$select public.save_scoped_record('95000000-0000-4000-8000-000000000003',current_setting('finance.scope')::uuid,null,'minutes',0,current_setting('finance.today')::date,'회의','검토 내용','draft',null,null,null,'KRW',gen_random_uuid(),auth.uid())$$,'minutes CRUD available');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000002',false);
set local role authenticated;
select throws_ok($$select public.delete_scoped_record('95000000-0000-4000-8000-000000000003',1,gen_random_uuid(),'삭제 사유',auth.uid())$$,'42501',null,'missing recent Google proof blocks write');
reset role;
update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='94000000-0000-4000-8000-000000000002';
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000002');
set local role authenticated;
select throws_ok($$select public.get_scoped_record_history('95000000-0000-4000-8000-000000000003')$$,'42501','current_required_consents_required','stale consent blocks history before row lookup');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000001');
insert into public.events(id,scope_id,title,host_name,starts_at,ends_at,created_by,updated_by)
values('97000000-0000-4000-8000-000000000001',current_setting('finance.scope')::uuid,'회비 연동 행사','총무',statement_timestamp()+interval '1 day',statement_timestamp()+interval '1 day 1 hour','94000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000001');
insert into public.event_occurrences(id,event_id,occurrence_index,starts_at,ends_at)
values('97000000-0000-4000-8000-000000000002','97000000-0000-4000-8000-000000000001',0,statement_timestamp()+interval '1 day',statement_timestamp()+interval '1 day 1 hour');
insert into public.event_rsvps(occurrence_id,user_id,response)
values('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003','yes');
set local role authenticated;
select lives_ok($$select public.record_event_fee('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',true,15000,'98000000-0000-4000-8000-000000000001','현장 회비 납부',0,auth.uid())$$,'payment creates independent event income');
select lives_ok($$select public.record_event_fee('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',true,15000,'98000000-0000-4000-8000-000000000001','현장 회비 납부',0,auth.uid())$$,'payment operation retry reconciles before revision check');
select is((public.get_event_fee_status('97000000-0000-4000-8000-000000000002')->'rows'->0->>'revision')::integer,1,'retry does not advance fee revision');
select is(jsonb_array_length(public.get_scoped_records(current_setting('finance.scope')::uuid,'97000000-0000-4000-8000-000000000001',current_setting('finance.year')::integer,'finance')->'rows'),1,'one payment creates exactly one income');
select throws_ok($$select public.record_event_fee('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',false,14000,gen_random_uuid(),'환불 금액 불일치',1,auth.uid())$$,'40001','fee_revision_conflict','stale refund amount rejected');
select throws_ok($$select public.record_event_fee('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',true,16000,gen_random_uuid(),'이전 버전 정정',0,auth.uid())$$,'40001','fee_revision_conflict','stale concurrent amount correction rejected');
select lives_ok($$select public.record_event_fee('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',false,15000,'98000000-0000-4000-8000-000000000002','참가 취소 환불',1,auth.uid())$$,'refund appends reversal');
select is(public.get_event_fee_status('97000000-0000-4000-8000-000000000002')->'rows'->0->>'paid','false','refund clears fee state');
select is(jsonb_array_length(public.get_scoped_records(current_setting('finance.scope')::uuid,'97000000-0000-4000-8000-000000000001',current_setting('finance.year')::integer,'finance')->'rows'),2,'refund preserves income plus expense');
select throws_ok($$select public.prepare_finance_receipt('95000000-0000-4000-8000-000000000001',gen_random_uuid(),'supabase',102400)$$,'P0001','finance_period_closed','closed period rejects new receipt reservation');
select throws_ok($$select public.attach_finance_receipt('99000000-0000-4000-8000-000000000001',1)$$,'P0001','finance_period_closed','close wins race against previously prepared receipt attachment');
select throws_ok($$select public.delete_finance_receipt('99000000-0000-4000-8000-000000000001','첨부 취소')$$,'P0001','finance_period_closed','closed evidence cannot be removed');
select set_config('finance.event_income',(select item->>'id' from jsonb_array_elements(public.get_scoped_records(current_setting('finance.scope')::uuid,'97000000-0000-4000-8000-000000000001',current_setting('finance.year')::integer,'finance')->'rows') item where item->>'entry_type'='income'),true);
select throws_ok($$select public.prepare_finance_receipt(current_setting('finance.event_income')::uuid,gen_random_uuid(),'r2',10485761)$$,'P0001','invalid_receipt_size','oversize R2 reservation rejected before bytes or registry creation');
select throws_ok($$select public.prepare_finance_receipt(current_setting('finance.event_income')::uuid,gen_random_uuid(),'r2',1024)$$,'P0001','receipt_processing_notice_required','R2 reservation requires explicit processing notice evidence');
select lives_ok($$select public.prepare_finance_receipt(current_setting('finance.event_income')::uuid,'99000000-0000-4000-8000-000000000004','r2',1024,'test-notice-v1')$$,'R2 reservation records the explicitly approved notice version');
select is(public.get_finance_receipt_access('99000000-0000-4000-8000-000000000004',auth.uid(),true)->>'notice_version','test-notice-v1','processing approval version is revision-safe evidence');
select lives_ok($$select public.prepare_finance_receipt(current_setting('finance.event_income')::uuid,'99000000-0000-4000-8000-000000000002','supabase',102400)$$,'receipt path bound to actual event ledger and expected byte count');
select throws_ok($$select public.attach_finance_receipt('99000000-0000-4000-8000-000000000002',1)$$,'P0001','receipt_upload_required','metadata attachment cannot claim nonexistent object');
reset role;
insert into storage.objects(bucket_id,name,owner,owner_id,metadata)
values('finance-receipts','94000000-0000-4000-8000-000000000001/99000000-0000-4000-8000-000000000002.webp','94000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000001','{"mimetype":"image/webp","size":102400}');
set local role authenticated;
select is((select count(*) from storage.objects where bucket_id='finance-receipts'),0::bigint,'even authorized uploader cannot bypass fixed-TTL Edge signing via direct Storage reads');
select lives_ok($$select public.attach_finance_receipt('99000000-0000-4000-8000-000000000002',1)$$,'existing exact-size WebP attaches with revision audit');
select is(public.get_finance_receipt_access('99000000-0000-4000-8000-000000000002',auth.uid(),false)->>'provider','supabase','authorized receipt access truthfully identifies provider');
select is(public.abandon_unattached_finance_receipt('99000000-0000-4000-8000-000000000002',auth.uid())->>'abandoned','false','failed-upload cleanup cannot revoke a concurrently attached object');
select lives_ok($$select public.prepare_finance_receipt(current_setting('finance.event_income')::uuid,'99000000-0000-4000-8000-000000000003','supabase',102400)$$,'second uncommitted upload reservation exists');
select lives_ok($$select public.delete_finance_receipt('99000000-0000-4000-8000-000000000003','첨부 취소')$$,'open-period cancellation of upload reservation is audited');
select lives_ok($$select public.export_finance_report(current_setting('finance.scope')::uuid,'97000000-0000-4000-8000-000000000001',current_setting('finance.today')::date,current_setting('finance.today')::date,true,auth.uid())$$,'event period close includes receipt audit history');
select throws_ok($$select public.delete_finance_receipt('99000000-0000-4000-8000-000000000002','마감 뒤 삭제')$$,'P0001','finance_period_closed','finalized attached evidence cannot be deleted');
select throws_ok($$select public.attach_finance_receipt('99000000-0000-4000-8000-000000000002',3)$$,'P0001','finance_period_closed','closed evidence cannot be rewritten even by idempotent attachment call');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000003');
set local role authenticated;
select throws_ok($$select public.get_event_fee_status('97000000-0000-4000-8000-000000000002')$$,'42501','event_fee_forbidden','attendee cannot read other payments');
select throws_ok($$select public.prepare_finance_receipt('95000000-0000-4000-8000-000000000001',gen_random_uuid(),'r2',102400)$$,'42501','receipt_forbidden','ordinary member cannot upload receipts');
reset role;
select ok(not has_function_privilege('authenticated','public.service_confirm_r2_receipt(uuid,uuid,bigint,text,text)','execute'),'browser cannot forge trusted R2 HEAD confirmation');
select ok(position('pg_advisory_xact_lock' in pg_get_functiondef('public.prepare_finance_receipt(uuid,uuid,text,bigint,text)'::regprocedure))>0
 and position('pg_advisory_xact_lock' in pg_get_functiondef('public.attach_finance_receipt(uuid,integer)'::regprocedure))>0
 and position('pg_advisory_xact_lock' in pg_get_functiondef('public.delete_finance_receipt(uuid,text)'::regprocedure))>0
 and position('pg_advisory_xact_lock' in pg_get_functiondef('public.export_finance_report(uuid,uuid,date,date,boolean,uuid)'::regprocedure))>0,
 'receipt mutations and period close retain the same accounting serialization mechanism');
select is(private.can_scoped_records(current_setting('finance.scope')::uuid,'94000000-0000-4000-8000-000000000001',null,true),false,'null record kind cannot bypass office-specific capability');
select is(private.can_scoped_records(current_setting('finance.scope')::uuid,'94000000-0000-4000-8000-000000000001','finance',null),false,'null write mode fails closed');
update public.user_consents set accepted=true,withdrawn_at=null where user_id='94000000-0000-4000-8000-000000000002';
select is(private.can_manage_event_fees('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000002'),false,'secretary logistics authority is not financial fee authority');
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000001');
set local role authenticated;
select is(public.abandon_unattached_finance_receipt('99000000-0000-4000-8000-000000000001',auth.uid())->>'abandoned','true','failed uncommitted reservation cleanup remains possible without changing closed evidence');
select is(public.abandon_unattached_finance_receipt('99000000-0000-4000-8000-000000000002',auth.uid())->>'abandoned','false','cleanup cannot revoke attached evidence after period close');
reset role;
-- Full archives retain all years and events without exposing other scopes.
insert into private.event_staff(occurrence_id,user_id,capabilities,expires_at,granted_by)
values('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',array['fees','checkin'],statement_timestamp()+interval '1 hour','94000000-0000-4000-8000-000000000001');
select is(private.can_manage_event_fees('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003'),false,'delegated member cannot gain financial access');
select is(private.can_event_field('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003','checkin'),true,'nonfinancial volunteer delegation is preserved');
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000003');
set local role authenticated;
select throws_ok($$select public.get_event_fee_status('97000000-0000-4000-8000-000000000002')$$,'42501','event_fee_forbidden','direct fee API rejects non-executive volunteer');
reset role;
select ok(not has_function_privilege('anon','public.export_executive_records(text,uuid)','execute'),'anonymous full archive is denied');
insert into public.platform_admins(user_id,note) values('94000000-0000-4000-8000-000000000004','rollback-only admin without executive role');
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000004');
set local role authenticated;
select throws_ok($$select public.set_event_staff('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000003',array['fees'],statement_timestamp()+interval '1 hour')$$,'42501','fees_requires_executive','ordinary member cannot receive a new financial delegation');
select lives_ok($$select public.set_event_staff('97000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000002',array['fees'],statement_timestamp()+interval '1 hour')$$,'eligible executive can receive bounded fee delegation');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000003');
set local role authenticated;
select throws_ok($$select public.export_executive_records('minutes',auth.uid())$$,'42501','record_scope_forbidden','ordinary member cannot export');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000004');
set local role authenticated;
select throws_ok($$select public.export_executive_records('finance',auth.uid())$$,'42501','record_scope_forbidden','platform admin or pastor is not implicitly executive');
reset role;
insert into private.scoped_records(id,kind,scope_id,service_year,record_date,title,body,status,entry_type,category,amount)
values('95000000-0000-4000-8000-000000000099','finance',current_setting('finance.scope')::uuid,2025,'2025-03-01','prior year entry','preserved prior year memo','published','income','회비',50);
insert into private.scoped_record_history(record_id,revision,snapshot,action)
select id,revision,to_jsonb(r),'fixture.prior_year' from private.scoped_records r where id='95000000-0000-4000-8000-000000000099';
create temporary table full_archive(kind text primary key,payload jsonb);
grant all on full_archive to authenticated;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000001');
set local role authenticated;
select throws_ok($$select public.export_executive_records('finance','94000000-0000-4000-8000-000000000003')$$,'42501','actor_changed','archive is bound to verified actor');
select throws_ok($$select public.export_executive_records(null,auth.uid())$$,'P0001','invalid_record_kind','null kind fails closed');
insert into full_archive values('finance',public.export_executive_records('finance',auth.uid()));
select ok((select exists(select 1 from jsonb_array_elements(payload->'entries') x where x->>'id'='95000000-0000-4000-8000-000000000099') from full_archive where kind='finance'),'full archive includes previous years');
select ok((select exists(select 1 from jsonb_array_elements(payload->'entries') x where x->>'event_id'='97000000-0000-4000-8000-000000000001') from full_archive where kind='finance'),'full archive includes event-specific ledger');
select ok((select exists(select 1 from jsonb_array_elements(payload->'entries') x where nullif(x->>'reversal_of','') is not null) from full_archive where kind='finance'),'reversal entries are preserved');
select is((select (payload->>'record_count')::integer=jsonb_array_length(payload->'entries') from full_archive where kind='finance'),true,'record count never silently truncates');
select is((select (payload->>'history_count')::integer=jsonb_array_length(payload->'history') from full_archive where kind='finance'),true,'history count is complete');
reset role;
select is((select (payload->>'record_count')::bigint from full_archive where kind='finance'),(select count(*) from private.scoped_records where scope_id=current_setting('finance.scope')::uuid and kind='finance'),'all organization and event finance rows are included');
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000001',false);
set local role authenticated;
select throws_ok($$select public.export_executive_records('finance',auth.uid())$$,'42501',null,'fresh Google proof required for full archive');
reset role;
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000005');
set local role authenticated;
insert into full_archive values('foreign',public.export_executive_records('finance',auth.uid()));
select ok((select not exists(select 1 from jsonb_array_elements(payload->'entries') x where x->>'scope_id'=current_setting('finance.scope')) from full_archive where kind='foreign'),'foreign executive cannot export this church');
reset role;
insert into private.scoped_records(id,kind,scope_id,service_year,record_date,title,body,status,deleted_at)
values('95000000-0000-4000-8000-000000000098','minutes',current_setting('finance.scope')::uuid,2025,'2025-03-01','preserved meeting',repeat('긴',50000),'published',clock_timestamp());
select pg_temp.finance_actor('94000000-0000-4000-8000-000000000002');
set local role authenticated;
insert into full_archive values('minutes',public.export_executive_records('minutes',auth.uid()));
select ok((select exists(select 1 from jsonb_array_elements(payload->'entries') x where x->>'id'='95000000-0000-4000-8000-000000000098' and length(x->>'body')=50000 and x->>'deleted_at' is not null) from full_archive where kind='minutes'),'full minutes preserve long body and soft-deletion markers');
reset role;
update auth.sessions set not_after=statement_timestamp()-interval '1 minute' where id='94000000-0000-4000-8000-000000000002';
set local role authenticated;
select throws_ok($$select public.export_executive_records('minutes',auth.uid())$$,'42501','live_session_required','revoked or expired session cannot download');
reset role;
update auth.sessions set not_after=null where id='94000000-0000-4000-8000-000000000002';
insert into private.scoped_records(id,kind,scope_id,service_year,record_date,title,body,status)
select gen_random_uuid(),'minutes',current_setting('finance.scope')::uuid,2025,'2025-01-01','rollback-only limit fixture','','draft' from generate_series(1,10001);
set local role authenticated;
select throws_ok($$select public.export_executive_records('minutes',auth.uid())$$,'P0001','full_export_too_large_no_partial_file','oversized archive rejects rather than returning a partial file');
reset role;
do $tap_gate$
declare lines text[];
begin
 select array_agg(line) into lines from finish() line;
 if coalesce(cardinality(lines),0)<>1 or lines[1] !~ '^1\.\.[1-9][0-9]*$' then
  raise exception 'scoped_records_finance_pgtap_failed' using detail=array_to_string(lines,E'\n');
 end if;
 perform set_config('test.scoped_records_finance_plan',lines[1],true);
end;
$tap_gate$;
select current_setting('test.scoped_records_finance_plan') as passed_plan;
rollback;
