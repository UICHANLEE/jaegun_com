begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
select ok(not has_table_privilege('authenticated','private.union_department_members','select,insert,update,delete'),'union membership is RPC-only');
select ok((select relrowsecurity from pg_class where oid='private.union_departments'::regclass),'union departments have RLS');
select ok(not has_function_privilege('anon','public.mutate_union_department(uuid,uuid,bigint,text,jsonb)','execute'),'anonymous union mutations denied');
select is((select count(*)::integer from pg_enum where enumtypid='public.governance_scope_type'::regtype),3,'union does not change hierarchy/signup scope enum');
insert into auth.users(id,email,raw_user_meta_data) values
('6a150000-0000-4000-8000-000000000001','gov-admin@example.com','{"display_name":"Gov admin"}'),
('6a150000-0000-4000-8000-000000000002','gov-member@example.com','{"display_name":"Gov member"}'),
('6a150000-0000-4000-8000-000000000003','gov-delegate@example.com','{"display_name":"Gov delegate"}'),
('6a150000-0000-4000-8000-000000000004','gov-outside@example.com','{"display_name":"Gov outside"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like '6a150000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
insert into public.platform_admins(user_id,note) values('6a150000-0000-4000-8000-000000000001','rollback governance test');
insert into auth.identities(provider_id,user_id,identity_data,provider)
select id::text,id,jsonb_build_object('sub',id::text),'google' from auth.users where id::text like '6a150000-%';
insert into auth.sessions(id,user_id,created_at,updated_at,aal)
select id,id,statement_timestamp(),statement_timestamp(),'aal1' from auth.users where id::text like '6a150000-%';
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
select gen_random_uuid(),id,statement_timestamp(),statement_timestamp(),'oauth' from auth.users where id::text like '6a150000-%';
create function pg_temp.governance_actor(actor uuid,proof boolean default true) returns void language plpgsql as $$
declare issued bigint:=floor(extract(epoch from statement_timestamp())); oauth_time bigint;
begin
 select floor(extract(epoch from updated_at))::bigint into oauth_time from auth.mfa_amr_claims where session_id=actor and authentication_method='oauth';
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'session_id',actor,'role','authenticated','is_anonymous',false,
 'aud','authenticated','iat',issued,'exp',issued+3600,'aal','aal1',
 'amr',case when proof then jsonb_build_array(jsonb_build_object('method','oauth','timestamp',oauth_time)) else '[]'::jsonb end)::text,true);
end; $$;
update public.organizations set status='active' where slug in ('jaegun-bupyeong','jaegun-busan');
insert into public.organization_memberships(user_id,organization_id,role,status)
select u,id,'member','active' from public.organizations cross join unnest(array['6a150000-0000-4000-8000-000000000002'::uuid,'6a150000-0000-4000-8000-000000000003'::uuid]) u where slug='jaegun-bupyeong';
insert into public.organization_memberships(user_id,organization_id,role,status)
select '6a150000-0000-4000-8000-000000000004',id,'member','active' from public.organizations where slug='jaegun-busan';
create temporary table governance_fixture as select s.id as church,s.parent_scope_id as boundary,s.organization_id as organization,
 '6a150000-0000-4000-8000-000000000050'::uuid as department,private.current_service_year() as year from public.governance_scopes s join public.organizations o on o.id=s.organization_id where o.slug='jaegun-bupyeong';
create function pg_temp.union_change(action text,payload jsonb,request uuid default gen_random_uuid()) returns jsonb language sql as $$
 select public.mutate_union_department(request,f.department,d.revision,action,payload) from governance_fixture f join private.union_departments d on d.id=f.department;
$$;
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000001');
select ok(private.sensitive_action_auth_expiry() is not null,'fixture has live Auth-owned recent Google proof, not AAL2 bypass');
select lives_ok($$select public.mutate_union_department('6a150000-0000-4000-8000-000000000051',department,null,'create',jsonb_build_object('display_name','Union fixture','boundary_scope_id',boundary)) from governance_fixture$$,'admin creates union with exact presbytery boundary');
select lives_ok($$select public.mutate_union_department('6a150000-0000-4000-8000-000000000051',department,null,'create',jsonb_build_object('display_name','Union fixture','boundary_scope_id',boundary)) from governance_fixture$$,'same create request safely acknowledges original record');
select is((select count(*) from private.union_departments where id=(select department from governance_fixture)),1::bigint,'no duplicate department');
select throws_ok($$select public.mutate_union_department('6a150000-0000-4000-8000-000000000051',department,null,'create',jsonb_build_object('display_name','Changed','boundary_scope_id',boundary)) from governance_fixture$$,'23505','request_payload_conflict','request ID cannot change payload');
select throws_ok($$select pg_temp.union_change('add_member',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000004'))$$,'23514','union_target_outside_boundary','other presbytery member cannot join union');
select lives_ok($$select pg_temp.union_change('add_member',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000002'))$$,'admin explicitly adds member');
select lives_ok($$select pg_temp.union_change('add_member',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000003'))$$,'admin explicitly adds delegate');
select throws_ok($$select public.mutate_union_department(gen_random_uuid(),department,1,'rename','{"display_name":"stale"}') from governance_fixture$$,'40001','union_revision_conflict','stale revision cannot overwrite later membership changes');
select throws_ok($$select pg_temp.union_change('assign_office',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000002','office_code','president','service_year',year-1)) from governance_fixture$$,'23514','invalid_union_office_year','past year cannot be assigned');
select lives_ok($$select pg_temp.union_change('assign_office',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000002','office_code','president','service_year',year)) from governance_fixture$$,'explicit current annual union president');
select ok(private.union_native_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'current union president manages own union');
select ok(not private.has_native_governance_authority((select boundary from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'union president never gains parent executive authority');
select ok(not private.has_native_governance_authority((select church from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'union president never gains church authority');
select is((select role::text from public.organization_memberships where user_id='6a150000-0000-4000-8000-000000000002'),'member','union office never promotes base membership role');
update private.union_department_offices set service_year=(select year+1 from governance_fixture);
select ok(not private.union_native_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'next year office gives no current year authority');
update private.union_department_offices set service_year=(select year-1 from governance_fixture);
select ok(not private.union_native_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'previous year office gives no rollover authority');
update private.union_department_offices set service_year=(select year from governance_fixture);
select throws_ok($$select pg_temp.union_change('delegate',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000003','reason','long','expires_at',now()+interval '91 days'))$$,'23514','invalid_union_delegation_expiry','delegation bounded to 90 days');
select throws_ok($$select pg_temp.union_change('delegate',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000003','reason','rollover','expires_at',make_timestamptz(year+1,1,1,0,0,1,'Asia/Seoul'))) from governance_fixture$$,'23514','invalid_union_delegation_expiry','delegation cannot cross Seoul year boundary');
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000002');
select lives_ok($$select pg_temp.union_change('delegate',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000003','reason','bounded duties','expires_at',least(now()+interval '1 day',make_timestamptz(year+1,1,1,0,0,0,'Asia/Seoul')))) from governance_fixture$$,'union president delegates within own union');
select ok(private.union_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000003'),'delegate gains only union office management');
select ok(not private.union_native_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000003'),'delegate cannot become grantor');
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000003');
select throws_ok($$select pg_temp.union_change('delegate',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000002','reason','chain','expires_at',now()+interval '1 hour'))$$,'42501','union_native_authority_required','delegation cannot be chained');
select throws_ok($$select pg_temp.union_change('clear_office',jsonb_build_object('office_code','president','service_year',year)) from governance_fixture$$,'42501','delegated_authority_change_forbidden','delegate cannot remove source authority');
select throws_ok($$select pg_temp.union_change('add_member',jsonb_build_object('user_id','6a150000-0000-4000-8000-000000000002'))$$,'42501','union_native_authority_required','delegate cannot alter membership');
update private.union_department_delegations set starts_at=now()-interval '2 days',expires_at=now()-interval '1 day';
select ok(not private.union_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000003'),'expired delegation loses authority immediately');
update private.union_department_delegations set starts_at=now()-interval '1 minute',expires_at=least(now()+interval '1 hour',make_timestamptz(private.current_service_year()+1,1,1,0,0,0,'Asia/Seoul'));
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000002');
select lives_ok($$select pg_temp.union_change('revoke_delegation',jsonb_build_object('delegation_id',(select id from private.union_department_delegations limit 1),'reason','duties ended'))$$,'source authority revokes delegation');
select ok(not private.union_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000003'),'revoked delegation loses authority immediately');
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000004');
select is(jsonb_array_length(public.get_union_departments()),0,'outsider never sees union directory');
select throws_ok($$select public.get_union_department_detail(department,year) from governance_fixture$$,'42501','union_membership_required','outsider cannot retrieve union roster');
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000001',false);
select lives_ok($$select public.get_union_departments()$$,'read-only management never requires step-up or TOTP');
select throws_ok($$select pg_temp.union_change('rename','{"display_name":"without proof"}')$$,'42501','recent_google_authentication_required:union_department_management','sensitive union mutation requires server proof');
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000001');
select lives_ok($$select public.save_governance_organization('6a150000-0000-4000-8000-000000000080','6a150000-0000-4000-8000-000000000081',null,'presbytery',(select id from public.governance_scopes where scope_type='general_assembly'),'gov-fixture-presbytery','Governance fixture presbytery',true)$$,'admin creates real presbytery');
select lives_ok($$select public.save_governance_organization('6a150000-0000-4000-8000-000000000082','6a150000-0000-4000-8000-000000000083',null,'church','6a150000-0000-4000-8000-000000000081','gov-fixture-church','Governance fixture church',true)$$,'admin creates real church under selected presbytery');
select is((select count(*) from public.church_departments d join public.governance_scopes s on s.id=d.church_scope_id where s.organization_id='6a150000-0000-4000-8000-000000000083'),4::bigint,'new church receives existing four departments');
select throws_ok($$select public.save_governance_organization(gen_random_uuid(),'6a150000-0000-4000-8000-000000000081','2000-01-01','presbytery',(select id from public.governance_scopes where scope_type='general_assembly'),'gov-fixture-presbytery','stale edit',true)$$,'40001','organization_revision_conflict','organization stale edit rejected');
select throws_ok($$select public.mutate_governance_office(gen_random_uuid(),church,null,year,'secretary',null,'6a150000-0000-4000-8000-000000000002') from governance_fixture$$,'40001','office_holder_changed_reload_required','checked mutation rejects stale displayed holder');
select lives_ok($$select public.mutate_governance_office('6a150000-0000-4000-8000-000000000091',church,null,year,'secretary',null,null) from governance_fixture$$,'checked clear records real empty state');
select lives_ok($$select public.mutate_governance_office('6a150000-0000-4000-8000-000000000091',church,null,year,'secretary',null,null) from governance_fixture$$,'checked clear receipt safely handles response-loss retry');
select pg_temp.governance_actor('6a150000-0000-4000-8000-000000000002');
select throws_ok($$select public.save_governance_organization(gen_random_uuid(),gen_random_uuid(),null,'presbytery',(select id from public.governance_scopes where scope_type='general_assembly'),'forbidden-presbytery','Forbidden',true)$$,'42501','platform_admin_required','union president cannot create hierarchy organizations');
select throws_ok($$select public.mutate_governance_office(gen_random_uuid(),church,null,year,'secretary',null,null) from governance_fixture$$,'42501','governance_office_management_forbidden','union president cannot mutate hierarchy offices');
update public.organization_memberships set status='suspended',ended_at=now() where user_id='6a150000-0000-4000-8000-000000000002';
select ok(not private.union_member((select department from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'suspension ends explicit union membership');
update public.organization_memberships set status='active',ended_at=null where user_id='6a150000-0000-4000-8000-000000000002';
select ok(not private.union_member((select department from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'reactivation cannot resurrect union membership');
select ok(not private.union_native_manager((select department from governance_fixture),'6a150000-0000-4000-8000-000000000002'),'reactivation cannot resurrect union office authority');
do $tap_gate$
declare lines text[];
begin
 select array_agg(line) into lines from finish() line;
 if coalesce(cardinality(lines),0)<>1 or lines[1] !~ '^1\.\.[1-9][0-9]*$' then
  raise exception 'governance_complete_pgtap_failed' using detail=array_to_string(lines,E'\n');
 end if;
 perform set_config('test.governance_complete_plan',lines[1],true);
end;
$tap_gate$;
select current_setting('test.governance_complete_plan') as passed_plan;
rollback;
