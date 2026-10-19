begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
select ok(not has_function_privilege('anon','public.get_event_field(uuid)','execute'),'field RPC denies anonymous access');
select ok(not has_function_privilege('authenticated','private.can_event_field(uuid,uuid,text)','execute'),'staff helper is internal only');
select ok(not has_table_privilege('authenticated','private.event_badges','select,insert,update,delete'),'badge hashes have no client table grants');
select is((select count(*) from pg_class where oid in('private.event_staff'::regclass,'private.event_surveys'::regclass,'private.event_logistics_rooms'::regclass,'private.event_badges'::regclass,'private.event_checkins'::regclass) and relrowsecurity),5::bigint,'field tables fail closed with RLS');
insert into auth.users(id,email,raw_user_meta_data) values
 ('e1000000-0000-4000-8000-000000000001','event-field-manager@example.invalid','{"display_name":"관리자"}'),
 ('e1000000-0000-4000-8000-000000000002','event-field-attendee@example.invalid','{"display_name":"참석자"}'),
 ('e1000000-0000-4000-8000-000000000003','event-field-staff@example.invalid','{"display_name":"스태프"}'),
 ('e1000000-0000-4000-8000-000000000004','event-field-foreign@example.invalid','{"display_name":"다른 교회"}');
insert into public.platform_admins(user_id,note) values('e1000000-0000-4000-8000-000000000001','event field test');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'e1000000-0000-4000-8000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug in('jaegun-bupyeong','jaegun-busan');
insert into public.organization_memberships(user_id,organization_id,role)
select p.id,o.id,'member' from public.profiles p join public.organizations o on o.slug=case when p.id='e1000000-0000-4000-8000-000000000004' then 'jaegun-busan' else 'jaegun-bupyeong' end where p.id::text like 'e1000000-0000-4000-8000-%';
select set_config('field.scope',(select id::text from public.governance_scopes where scope_type='church' and organization_id=(select id from public.organizations where slug='jaegun-bupyeong')),true);
insert into public.events(id,scope_id,title,starts_at,ends_at,created_by,updated_by,host_name) values
 ('e2000000-0000-4000-8000-000000000001',current_setting('field.scope')::uuid,'현장 시험',statement_timestamp()+interval '1 hour',statement_timestamp()+interval '3 hours','e1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','주최'),
 ('e2000000-0000-4000-8000-000000000002',current_setting('field.scope')::uuid,'다른 행사',statement_timestamp()+interval '1 hour',statement_timestamp()+interval '3 hours','e1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','주최');
select private.rebuild_event_occurrences('e2000000-0000-4000-8000-000000000001');
select private.rebuild_event_occurrences('e2000000-0000-4000-8000-000000000002');
select set_config('field.occurrence',(select id::text from public.event_occurrences where event_id='e2000000-0000-4000-8000-000000000001'),true);
select set_config('field.other',(select id::text from public.event_occurrences where event_id='e2000000-0000-4000-8000-000000000002'),true);
insert into public.event_rsvps(occurrence_id,user_id,response) select current_setting('field.occurrence')::uuid,id,'yes' from public.profiles where id::text like 'e1000000-0000-4000-8000-%';
select set_config('field.proof_time',floor(extract(epoch from statement_timestamp()))::bigint::text,true);
insert into auth.identities(provider_id,user_id,identity_data,provider) select id::text,id,jsonb_build_object('sub',id::text),'google' from auth.users where id::text like 'e1000000-0000-4000-8000-%';
insert into auth.sessions(id,user_id,created_at,updated_at,aal) select id,id,to_timestamp(current_setting('field.proof_time')::bigint),to_timestamp(current_setting('field.proof_time')::bigint),'aal1' from auth.users where id::text like 'e1000000-0000-4000-8000-%';
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method) select gen_random_uuid(),id,to_timestamp(current_setting('field.proof_time')::bigint),to_timestamp(current_setting('field.proof_time')::bigint),'oauth' from auth.users where id::text like 'e1000000-0000-4000-8000-%';
create function pg_temp.field_login(a uuid) returns void language plpgsql as $$ begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',a,'role','authenticated','is_anonymous',false,'aud','authenticated','iat',current_setting('field.proof_time')::bigint,'exp',current_setting('field.proof_time')::bigint+3600,'aal','aal1','amr',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',current_setting('field.proof_time')::bigint)))::text,true);
end $$;
select pg_temp.field_login('e1000000-0000-4000-8000-000000000002');
set local role authenticated;
select is(jsonb_array_length(public.get_event_field(current_setting('field.occurrence')::uuid)->'participants'),0,'ordinary member cannot read roster');
select is(jsonb_array_length(public.get_event_field(current_setting('field.occurrence')::uuid)->'plan'->'vehicles'),0,'ordinary member cannot read vehicle driver identifiers');
select throws_ok($$select public.save_event_survey(current_setting('field.occurrence')::uuid,0,statement_timestamp(),statement_timestamp()+interval '2 hours','출발',4)$$,'23514','invalid_attendance_interval','partial interval cannot extend before event start');
select lives_ok($$select public.save_event_survey(current_setting('field.occurrence')::uuid,0,statement_timestamp()+interval '90 minutes',statement_timestamp()+interval '2 hours','교회',4)$$,'self partial attendance and volunteer seats saved');
select throws_ok($$select public.save_event_survey(current_setting('field.occurrence')::uuid,0,null,null,'덮어쓰기',4)$$,'40001','event_survey_revision_conflict','survey stale revision rejected');
select set_config('field.token',public.issue_event_badge(current_setting('field.occurrence')::uuid)->>'token',true);
select ok(current_setting('field.token') ~ '^jg3\.[a-f0-9]{48}$' and current_setting('field.token') not like '%e1000000%','QR has random opaque token and no raw attendee UUID');
select throws_ok($$select public.verify_event_badge(current_setting('field.occurrence')::uuid,current_setting('field.token'))$$,'42501','event_checkin_forbidden','attendee cannot scan own badge as staff');
reset role;
select pg_temp.field_login('e1000000-0000-4000-8000-000000000001');
set local role authenticated;
select throws_ok($$select public.set_event_staff(current_setting('field.occurrence')::uuid,'e1000000-0000-4000-8000-000000000004',array['checkin'],statement_timestamp()+interval '1 hour')$$,'23514','invalid_event_staff_grant','cross-church staff grant denied');
select throws_ok($$select public.set_event_staff(current_setting('field.occurrence')::uuid,'e1000000-0000-4000-8000-000000000003',array['checkin'],statement_timestamp()+interval '31 days')$$,'23514','invalid_event_staff_grant','unbounded staff grant denied');
select lives_ok($$select public.set_event_staff(current_setting('field.occurrence')::uuid,'e1000000-0000-4000-8000-000000000003',array['checkin'],statement_timestamp()+interval '1 hour')$$,'exact occurrence checkin staff grant succeeds');
select is(jsonb_array_length(public.get_event_field(current_setting('field.occurrence')::uuid)->'participants'),3,'foreign historical RSVP excluded from actual roster');
select set_config('field.revision',public.get_event_field(current_setting('field.occurrence')::uuid)->'plan'->>'revision',true);
select throws_ok($$select public.save_event_field_plan(current_setting('field.occurrence')::uuid,current_setting('field.revision')::integer,'[{"id":"e3000000-0000-4000-8000-000000000001","name":"조","capacity":1}]','[]','[]','[{"user_id":"e1000000-0000-4000-8000-000000000002","group_id":"e3000000-0000-4000-8000-000000000001"},{"user_id":"e1000000-0000-4000-8000-000000000003","group_id":"e3000000-0000-4000-8000-000000000001"}]')$$,'23514','event_plan_capacity_exceeded','group capacity enforced server-side');
select throws_ok($$select public.save_event_field_plan(current_setting('field.occurrence')::uuid,current_setting('field.revision')::integer,'[]','[]','[{"id":"e3000000-0000-4000-8000-000000000002","name":"방","capacity":1}]','[{"user_id":"e1000000-0000-4000-8000-000000000002","room_id":"e3000000-0000-4000-8000-000000000002"},{"user_id":"e1000000-0000-4000-8000-000000000003","room_id":"e3000000-0000-4000-8000-000000000002"}]')$$,'23514','event_plan_capacity_exceeded','room capacity enforced server-side');
select throws_ok($$select public.save_event_field_plan(current_setting('field.occurrence')::uuid,-1,'[]','[]','[]','[]')$$,'40001','event_logistics_revision_conflict','plan stale revision rejected');
select lives_ok($$select public.export_event_field(current_setting('field.occurrence')::uuid)$$,'authorized export audited and returns real eligible data');
reset role;
select pg_temp.field_login('e1000000-0000-4000-8000-000000000003');
select ok(private.can_event_field(current_setting('field.occurrence')::uuid,'e1000000-0000-4000-8000-000000000003','checkin'),'bounded staff has only granted capability');
select ok(not private.can_event_field(current_setting('field.other')::uuid,'e1000000-0000-4000-8000-000000000003','checkin'),'same event scope grants no other occurrence authority');
select ok(not private.can_event_field(current_setting('field.occurrence')::uuid,'e1000000-0000-4000-8000-000000000003','fees'),'checkin staff does not gain fee authority');
set local role authenticated;
select ok(not exists(select 1 from jsonb_array_elements(public.get_event_field(current_setting('field.occurrence')::uuid)->'participants') p where p->'survey'<>'null'::jsonb),'checkin-only staff cannot read movement surveys');
select throws_ok($$select public.export_event_field(current_setting('field.occurrence')::uuid)$$,'42501','event_export_forbidden','checkin staff cannot download roster');
select throws_ok($$select public.verify_event_badge(current_setting('field.other')::uuid,current_setting('field.token'))$$,'42501','event_checkin_forbidden','badge not accepted at another occurrence');
select lives_ok($$select public.verify_event_badge(current_setting('field.occurrence')::uuid,current_setting('field.token'))$$,'staff verifies token online');
select lives_ok($$select public.verify_event_badge(current_setting('field.occurrence')::uuid,current_setting('field.token'))$$,'duplicate scan returns existing checkin');
reset role;
select is((select count(*) from private.event_checkins where occurrence_id=current_setting('field.occurrence')::uuid),1::bigint,'duplicate checkin creates only one row');
update private.event_badges set expires_at=statement_timestamp()-interval '1 second';
set local role authenticated;
select throws_ok($$select public.verify_event_badge(current_setting('field.occurrence')::uuid,current_setting('field.token'))$$,'42501','expired_or_revoked_event_badge','expired opaque token cannot check in even with an existing checkin');
reset role;
select pg_temp.field_login('e1000000-0000-4000-8000-000000000002');
set local role authenticated;
select set_config('field.token',public.issue_event_badge(current_setting('field.occurrence')::uuid)->>'token',true);
reset role;
update private.event_staff set expires_at=statement_timestamp()-interval '1 second';
select ok(not private.can_event_field(current_setting('field.occurrence')::uuid,'e1000000-0000-4000-8000-000000000003','checkin'),'expired staff loses authority immediately');
update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='e1000000-0000-4000-8000-000000000002';
select is((select count(*) from private.event_badges where user_id='e1000000-0000-4000-8000-000000000002'),0::bigint,'consent withdrawal physically revokes badge');
select is((select role::text from public.organization_memberships where user_id='e1000000-0000-4000-8000-000000000003'),'member','event grant does not change base role');
select ok(exists(select 1 from public.audit_logs where action='event.staff_changed' and entity_id=current_setting('field.occurrence')::uuid),'staff grants audited');
select ok(exists(select 1 from public.audit_logs where action='event.roster_export' and entity_id=current_setting('field.occurrence')::uuid),'downloads audited');
select pg_temp.field_login('e1000000-0000-4000-8000-000000000003');
set local role authenticated;
select lives_ok($$select public.issue_event_badge(current_setting('field.occurrence')::uuid)$$,'expired staff can still issue only their own attendee badge');
reset role;
update public.organization_memberships set status='suspended',ended_at=clock_timestamp() where user_id='e1000000-0000-4000-8000-000000000003';
select is((select count(*) from private.event_badges where user_id='e1000000-0000-4000-8000-000000000003'),0::bigint,'membership suspension physically revokes badges');
select pg_temp.field_login('e1000000-0000-4000-8000-000000000001');
set local role authenticated;
select lives_ok($$select public.issue_event_badge(current_setting('field.occurrence')::uuid)$$,'manager attendee badge issued before cancellation');
select lives_ok($$select public.cancel_event('e2000000-0000-4000-8000-000000000001','e4000000-0000-4000-8000-000000000001','현장 행사 취소 시험')$$,'authorized event cancellation remains audited');
reset role;
select is((select count(*) from private.event_badges where occurrence_id=current_setting('field.occurrence')::uuid),0::bigint,'event cancellation revokes every outstanding occurrence badge');
do $tap_gate$
declare lines text[];
begin
 select array_agg(line) into lines from finish() line;
 if coalesce(cardinality(lines),0)<>1 or lines[1] !~ '^1\.\.[1-9][0-9]*$' then
  raise exception 'event_field_pgtap_failed' using detail=array_to_string(lines,E'\n');
 end if;
 perform set_config('test.event_field_plan',lines[1],true);
end;
$tap_gate$;
select current_setting('test.event_field_plan') as passed_plan;
rollback;
