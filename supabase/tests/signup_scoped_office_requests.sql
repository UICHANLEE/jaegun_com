begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public,extensions,pg_catalog;
select plan(41);
select has_table('public','membership_office_requests','scoped selections have a separate request table');
select ok((select relrowsecurity from pg_class where oid='public.membership_office_requests'::regclass),'request table has RLS');
select ok(not has_table_privilege('authenticated','public.membership_office_requests','select,insert,update,delete'),'no direct authenticated table bypass');
select ok(not has_table_privilege('anon','public.membership_office_requests','select,insert,update,delete'),'no anonymous table access');
select ok(not has_function_privilege('anon','public.list_signup_office_options(uuid)','execute'),'options are not anonymous');
select ok(has_function_privilege('authenticated','public.review_membership_office_request(uuid,public.review_decision,text)','execute'),'authenticated review contract available');

insert into auth.users(id,email,raw_user_meta_data) values
 ('e5100000-0000-4000-8000-000000000001','office-request-applicant@example.com','{"display_name":"직책 신청자"}'),
 ('e5100000-0000-4000-8000-000000000002','office-request-admin@example.com','{"display_name":"직책 검토자"}'),
 ('e5100000-0000-4000-8000-000000000003','office-request-stale@example.com','{"display_name":"동의 없음"}'),
 ('e5100000-0000-4000-8000-000000000004','office-request-validation@example.com','{"display_name":"입력 검증"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select profile.id,document.document_key,document.version,true,'admin_migration'
from public.profiles profile cross join public.consent_documents document
where profile.id in ('e5100000-0000-4000-8000-000000000001','e5100000-0000-4000-8000-000000000002','e5100000-0000-4000-8000-000000000004')
 and document.required and document.retired_at is null and document.published_at<=statement_timestamp()
 and document.effective_at<=statement_timestamp();
insert into public.platform_admins(user_id,note) values ('e5100000-0000-4000-8000-000000000002','rollback-only scoped request test');
update public.organizations set status='active' where slug='jaegun-bupyeong';
insert into public.organization_memberships(user_id,organization_id,role,status)
select 'e5100000-0000-4000-8000-000000000002',id,'minister','active'
from public.organizations where slug='jaegun-bupyeong';
select set_config('test.governance_service_year',private.current_service_year()::text,true);
create temporary table request_fixture as
select organization.id as church,scope.id as church_scope,department.id as department,
  (select id from public.governance_scopes where scope_type='general_assembly' and is_active limit 1) as assembly,
  private.current_service_year() as year
from public.organizations organization join public.governance_scopes scope on scope.organization_id=organization.id
join public.church_departments department on department.church_scope_id=scope.id
where organization.slug='jaegun-bupyeong' and department.department_code='adult';
alter table request_fixture add column application uuid;
select set_config('request.jwt.claim.sub','e5100000-0000-4000-8000-000000000001',true);
select is(jsonb_array_length(public.list_signup_office_options((select church from request_fixture))->'scopes'),3,'only exact church and its two ancestors offered');
select is(jsonb_array_length(public.list_signup_office_options((select church from request_fixture))->'departments'),4,'exact church fixed departments offered');
update request_fixture set application=public.submit_membership_with_office_requests(church,'member',
 'e5100000-0000-4000-8000-000000000010', p_office_requests=>jsonb_build_array(
 jsonb_build_object('scope_id',church_scope,'department_id',department,'service_year',year,'office_code','secretary'),
 jsonb_build_object('scope_id',assembly,'service_year',year,'office_code','president')));
select is((select count(*) from public.membership_office_requests where application_id=(select application from request_fixture)),2::bigint,'requests atomically attached');
select is((select requested_role::text from public.membership_applications where id=(select application from request_fixture)),'member','upper scope selection does not request executive role');
select is((select count(*) from public.organization_memberships where user_id='e5100000-0000-4000-8000-000000000001'),0::bigint,'signup never activates membership');
select is((select count(*) from public.department_office_assignments where user_id='e5100000-0000-4000-8000-000000000001'),0::bigint,'signup never assigns department office');
select is((select public.submit_membership_with_office_requests(church,'member','e5100000-0000-4000-8000-000000000010',
 p_office_requests=>jsonb_build_array(jsonb_build_object('scope_id',church_scope,'department_id',department,'service_year',year,'office_code','secretary'),
 jsonb_build_object('scope_id',assembly,'service_year',year,'office_code','president'))) from request_fixture),
 (select application from request_fixture),'same actor and payload replay is idempotent');
select throws_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000010',p_applicant_note=>'changed')$$,'23514','client_request_payload_mismatch','idempotency cannot mutate prior submission');
select is(jsonb_array_length(public.list_membership_office_requests()),2,'applicant can read own requests');
select set_config('request.jwt.claim.sub','e5100000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.list_membership_office_requests()$$,'42501','current_required_consents_required','stale consent cannot inspect office requests');
select set_config('request.jwt.claim.sub','e5100000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.review_membership_office_request((select id from public.membership_office_requests where department_id is not null limit 1),'approve')$$,
 '23514','office_request_requires_active_approved_membership','cannot approve office before membership');
select lives_ok($$select public.review_membership_application((select application from request_fixture),'approve')$$,'membership approval uses existing RPC');
select is((select count(*) from public.membership_office_requests where application_id=(select application from request_fixture) and status='pending'),2::bigint,'membership approval does not approve office requests');
select lives_ok($$select public.review_membership_office_request((select id from public.membership_office_requests where department_id is not null limit 1),'approve')$$,'department request is separately assignable');
select is((select role::text from public.organization_memberships where user_id='e5100000-0000-4000-8000-000000000001'),'member','department approval never grants executive role');
select throws_ok($$select public.review_membership_office_request((select id from public.membership_office_requests where department_id is null limit 1),'approve')$$,
 '23514','governance_office_target_role_ineligible','upper scope request preserves existing leadership eligibility');
select lives_ok($$select public.review_membership_office_request((select id from public.membership_office_requests where department_id is null limit 1),'reject','자격 확인 필요')$$,'explicit rejection stored');
select is((public.review_membership_office_request((select id from public.membership_office_requests where department_id is null limit 1),'reject','자격 확인 필요')->>'changed')::boolean,false,'duplicate review never repeats assignment');
select set_config('request.jwt.claim.sub','e5100000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.review_membership_office_request('e5100000-0000-4000-8000-000000000099','approve')$$,
 '42501','office_request_review_forbidden','unknown and unauthorized requests fail uniformly');
select set_config('request.jwt.claim.sub','e5100000-0000-4000-8000-000000000004',true);
select is(jsonb_array_length(public.list_membership_office_requests()),0,'consent-current outsider cannot see applicant or reviewer requests');
select throws_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000040',p_office_requests=>jsonb_build_array(jsonb_build_object(
 'scope_id','e5100000-0000-4000-8000-000000000099','service_year',(select year from request_fixture),'office_code','secretary')))$$,
 '23514','invalid_office_request_scope_year_or_code','foreign scope rejected');
select is((select count(*) from public.membership_applications where user_id='e5100000-0000-4000-8000-000000000004'),0::bigint,'invalid request rolls membership application back');
select throws_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000040',p_office_requests=>jsonb_build_array(jsonb_build_object(
 'scope_id',(select church_scope from request_fixture),'service_year',(select year-1 from request_fixture),'office_code','secretary')))$$,
 '23514','invalid_office_request_scope_year_or_code','expired year rejected by server clock');
select throws_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000040',p_office_requests=>jsonb_build_array(jsonb_build_object(
 'scope_id',(select church_scope from request_fixture),'department_id',(select department from request_fixture),
 'service_year',(select year from request_fixture),'office_code','pastor')))$$,
 '23514','invalid_office_request_department','department cannot request pastor governance authority');
select throws_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000040',p_office_requests=>'[{"role":"platform_admin"}]')$$,
 '23514','invalid_office_request_shape','extra authority-bearing properties rejected');
select throws_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000040',p_office_requests=>jsonb_build_array(jsonb_build_object(
 'scope_id',(select assembly from request_fixture),'department_id',(select department from request_fixture),
 'service_year',(select year from request_fixture),'office_code','secretary')))$$,
 '23514','invalid_office_request_department','department request cannot impersonate parent scope');
select lives_ok($$select public.submit_membership_with_office_requests((select church from request_fixture),'member',
 'e5100000-0000-4000-8000-000000000040',p_office_requests=>jsonb_build_array(jsonb_build_object(
 'scope_id',(select church_scope from request_fixture),'department_id',(select department from request_fixture),
 'service_year',(select year from request_fixture),'office_code','secretary')))$$,'new applicant may submit scoped request');
select lives_ok($$select public.withdraw_membership_application((select id from public.membership_applications
 where user_id='e5100000-0000-4000-8000-000000000004' and status='pending'))$$,'membership withdrawal uses existing owner flow');
select is((select request.status from public.membership_office_requests request join public.membership_applications application
 on application.id=request.application_id where application.user_id='e5100000-0000-4000-8000-000000000004'),'withdrawn','withdrawal atomically closes unreviewed office request');
select set_config('request.jwt.claim.sub','e5100000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"e5100000-0000-4000-8000-000000000002","role":"authenticated","is_anonymous":false}',true);
select throws_ok($$select public.review_membership_office_request((select id from public.membership_office_requests where department_id is not null limit 1),'approve')$$,
 '42501','recent_google_authentication_required:membership_office_request_review','editable metadata or stale auth cannot authorize even idempotent review');
select set_config('request.jwt.claims','',true);
update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='e5100000-0000-4000-8000-000000000001';
select is(jsonb_array_length(public.list_membership_office_requests((select application from request_fixture))),0,'reviewer cannot inspect revoked-consent target request details');
set local role authenticated;
select throws_ok($$select * from public.membership_office_requests$$,'42501',null,'authenticated direct reads blocked');
select throws_ok($$delete from public.membership_office_requests$$,'42501',null,'authenticated direct mutations blocked');
reset role;
set local role anon;
select throws_ok($$select public.list_membership_office_requests()$$,'42501',null,'anonymous request RPC blocked');
select throws_ok($$select * from public.membership_office_requests$$,'42501',null,'anonymous direct reads blocked');
reset role;
select * from finish();
rollback;
