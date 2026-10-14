begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();

select ok(to_regprocedure('public.save_event(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[])') is null,
  'old public save_event overload is removed, not retained as a host bypass');
select ok(has_function_privilege('authenticated', 'public.get_event_logistics(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.get_event_logistics(uuid)', 'execute'), 'roster RPC is authenticated-only');
select ok(not has_function_privilege('authenticated', 'private.event_logistics_snapshot(uuid)', 'execute'), 'unguarded snapshot helper is not callable');
select ok(not has_function_privilege('authenticated', 'private.sanitize_event_logistics(uuid,boolean)', 'execute'), 'sanitization helper is not callable');
select ok(not has_table_privilege('authenticated', 'private.event_logistics_assignments', 'select,insert,update,delete'), 'allocation rows have no raw grants');
select ok(not has_table_privilege('authenticated', 'private.event_logistics_vehicles', 'select,insert,update,delete'), 'driver rows have no raw grants');
select is((select count(*) from pg_class join pg_namespace on pg_namespace.oid = pg_class.relnamespace
  where pg_namespace.nspname = 'private' and relname in ('event_logistics_plans','event_logistics_groups','event_logistics_vehicles','event_logistics_assignments') and relrowsecurity), 4::bigint,
  'all logistics tables also enable fail-closed RLS');

insert into auth.users(id,email,raw_user_meta_data) values
  ('71000000-0000-4000-8000-000000000001','logistics-admin@example.com','{"display_name":"일정 관리자"}'),
  ('71000000-0000-4000-8000-000000000002','logistics-executive@example.com','{"display_name":"교회 임원"}'),
  ('71000000-0000-4000-8000-000000000003','logistics-driver@example.com','{"display_name":"운전자"}'),
  ('71000000-0000-4000-8000-000000000004','logistics-passenger@example.com','{"display_name":"동승자"}'),
  ('71000000-0000-4000-8000-000000000005','logistics-minister@example.com','{"display_name":"일반 교역자"}'),
  ('71000000-0000-4000-8000-000000000006','logistics-other-executive@example.com','{"display_name":"다른 교회 임원"}'),
  ('71000000-0000-4000-8000-000000000007','logistics-stale-executive@example.com','{"display_name":"동의 미갱신 임원"}'),
  ('71000000-0000-4000-8000-000000000008','logistics-withdrawing@example.com','{"display_name":"동의 철회 참석자"}'),
  ('71000000-0000-4000-8000-000000000009','logistics-maybe@example.com','{"display_name":"미정 참석자"}'),
  ('71000000-0000-4000-8000-000000000010','logistics-revoking@example.com','{"display_name":"소속 해제 참석자"}'),
  ('71000000-0000-4000-8000-000000000011','logistics-deactivating@example.com','{"display_name":"비활성 참석자"}'),
  ('71000000-0000-4000-8000-000000000012','logistics-other-member@example.com','{"display_name":"다른 교회 참석자"}'),
  ('71000000-0000-4000-8000-000000000013','logistics-parent-president@example.com','{"display_name":"노회 회장"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select profile.id, document.document_key, document.version, true, 'admin_migration'
from public.profiles as profile cross join public.consent_documents as document
where profile.id::text like '71000000-0000-4000-8000-%' and document.required
  and document.retired_at is null and document.published_at <= statement_timestamp() and document.effective_at <= statement_timestamp();
insert into public.platform_admins(user_id,note) values('71000000-0000-4000-8000-000000000001','event logistics pgTAP');
update public.organizations set status = 'active' where slug in ('jaegun-bupyeong','jaegun-busan');
insert into public.organization_memberships(user_id,organization_id,role)
select profile.id, (select organization.id from public.organizations as organization where organization.slug = case
  when profile.id::text in ('71000000-0000-4000-8000-000000000006','71000000-0000-4000-8000-000000000012') then 'jaegun-busan' else 'jaegun-bupyeong' end),
  case when profile.id::text in ('71000000-0000-4000-8000-000000000002','71000000-0000-4000-8000-000000000006','71000000-0000-4000-8000-000000000007') then 'executive'::public.app_role
    when profile.id::text in ('71000000-0000-4000-8000-000000000005','71000000-0000-4000-8000-000000000013') then 'minister'::public.app_role else 'member'::public.app_role end
from public.profiles as profile where profile.id::text like '71000000-0000-4000-8000-%' and profile.id <> '71000000-0000-4000-8000-000000000001';
select is((select organization_id from public.organization_memberships where user_id='71000000-0000-4000-8000-000000000006'),
  (select id from public.organizations where slug='jaegun-busan'),'other-church executive fixture belongs to the other exact organization');
select is((select organization_id from public.organization_memberships where user_id='71000000-0000-4000-8000-000000000012'),
  (select id from public.organizations where slug='jaegun-busan'),'foreign RSVP subject fixture belongs to the other exact organization');
select set_config('logistics.church_scope', (select id::text from public.governance_scopes where scope_type='church' and organization_id=(select id from public.organizations where slug='jaegun-bupyeong')), true);
select set_config('logistics.parent_scope', (select parent_scope_id::text from public.governance_scopes where id=current_setting('logistics.church_scope')::uuid), true);
insert into public.governance_office_assignments(scope_id,user_id,service_year,office_code,assigned_by)
values(current_setting('logistics.parent_scope')::uuid,'71000000-0000-4000-8000-000000000013',private.current_service_year(),'president','71000000-0000-4000-8000-000000000001');
select ok(private.has_native_governance_authority(current_setting('logistics.parent_scope')::uuid,'71000000-0000-4000-8000-000000000013')
  and not private.can_manage_event_logistics(current_setting('logistics.church_scope')::uuid,'71000000-0000-4000-8000-000000000013'),
  'parent president fixture has parent office authority but is not a church executive or exact-church manager');
update public.user_consents set accepted=false, withdrawn_at=clock_timestamp() where user_id='71000000-0000-4000-8000-000000000007';

select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
set local role authenticated;
select lives_ok($$select public.save_event('72000000-0000-4000-8000-000000000001',true,current_setting('logistics.church_scope')::uuid,
  '함께하는 모임',null,null,statement_timestamp()+interval '2 days',statement_timestamp()+interval '2 days 1 hour',5,
  'daily',1,array[]::smallint[],null,null,2,array[60], '  명시한 개최자  ')$$, 'hosted recurring event is saved through the only public signature');
select throws_ok($$select public.save_event('72000000-0000-4000-8000-000000000099',true,current_setting('logistics.church_scope')::uuid,
  '누락된 개최자',null,null,statement_timestamp()+interval '2 days',statement_timestamp()+interval '2 days 1 hour',null,
  'none',1,array[]::smallint[],null,null,null,array[60], '  ')$$, '23514','invalid_event_host_name','blank host aborts the entire event save');
select lives_ok($$select public.save_event('72000000-0000-4000-8000-000000000002',true,current_setting('logistics.parent_scope')::uuid,
  '노회 모임',null,null,statement_timestamp()+interval '3 days',statement_timestamp()+interval '3 days 1 hour',null,
  'none',1,array[]::smallint[],null,null,null,array[60], '노회')$$, 'parent-scope event is created only by its existing authorized manager');
reset role;
select is((select host_name from public.events where id='72000000-0000-4000-8000-000000000001'), '명시한 개최자', 'stored host is trimmed');
select is((select snapshot->>'host_name' from public.event_revisions where event_id='72000000-0000-4000-8000-000000000001' and revision=1), '명시한 개최자', 'created revision snapshot includes host atomically');
select is((select created_by from public.events where id='72000000-0000-4000-8000-000000000001'), '71000000-0000-4000-8000-000000000001'::uuid, 'typed host does not replace actual immutable creator');
select is((select count(*) from public.events where id='72000000-0000-4000-8000-000000000099'),0::bigint,'failed hosted save leaves no event row');
select is((select count(*) from public.event_occurrences where event_id='72000000-0000-4000-8000-000000000099'),0::bigint,'failed hosted save leaves no occurrences');
select set_config('logistics.occurrence',(select id::text from public.event_occurrences where event_id='72000000-0000-4000-8000-000000000001' and occurrence_index=0),true);
select set_config('logistics.other_occurrence',(select id::text from public.event_occurrences where event_id='72000000-0000-4000-8000-000000000001' and occurrence_index=1),true);
select set_config('logistics.parent_occurrence',(select id::text from public.event_occurrences where event_id='72000000-0000-4000-8000-000000000002'),true);
insert into public.events(id,scope_id,title,starts_at,ends_at,created_by,updated_by)
values('72000000-0000-4000-8000-000000000003',current_setting('logistics.church_scope')::uuid,'이전 일정',
  statement_timestamp()+interval '4 days',statement_timestamp()+interval '4 days 1 hour',
  '71000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001');
select private.rebuild_event_occurrences('72000000-0000-4000-8000-000000000003');
select set_config('logistics.legacy_occurrence',(select id::text from public.event_occurrences where event_id='72000000-0000-4000-8000-000000000003'),true);
insert into public.event_rsvps(occurrence_id,user_id,response)
select current_setting('logistics.occurrence')::uuid,id,case when id='71000000-0000-4000-8000-000000000009' then 'maybe' else 'yes' end
from public.profiles where id::text in ('71000000-0000-4000-8000-000000000003','71000000-0000-4000-8000-000000000004','71000000-0000-4000-8000-000000000008','71000000-0000-4000-8000-000000000009','71000000-0000-4000-8000-000000000010','71000000-0000-4000-8000-000000000011','71000000-0000-4000-8000-000000000012');

select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select is(public.get_event_occurrence(current_setting('logistics.occurrence')::uuid)->>'host_name','명시한 개최자','occurrence read returns explicit host');
select is(public.get_event_occurrence(current_setting('logistics.occurrence')::uuid)->>'can_manage_logistics','true','active exact-church executive sees logistics permission');
select is(public.get_event_occurrence(current_setting('logistics.occurrence')::uuid)->>'can_manage','false','logistics does not broaden event-definition authority');
select is(jsonb_array_length(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants'),6,'roster includes only eligible exact-scope existing RSVPs');
select ok(not exists(select 1 from jsonb_array_elements(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants') as item
  where item->>'user_id'='71000000-0000-4000-8000-000000000012'),'cross-church subject is excluded even if a privileged historical RSVP row exists');
select ok((select count(*) from jsonb_object_keys(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants'->0)) = 6
  and (public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants'->0 ?& array['user_id','display_name','response','responded_at','group_id','vehicle_id']),
  'roster contains exactly the six minimal contract fields');
select ok(not (public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants'->0 ?| array['email','phone','avatar_url','bio','church_title']), 'roster exposes no profile PII');
select throws_ok($$select public.save_event('72000000-0000-4000-8000-000000000098',true,current_setting('logistics.church_scope')::uuid,
  '임원 작성',null,null,statement_timestamp()+interval '2 days',statement_timestamp()+interval '2 days 1 hour',null,
  'none',1,array[]::smallint[],null,null,null,array[60], '개최자')$$,'P0002','event_save_not_found_or_forbidden','executive logistics permission does not grant event creation');
select throws_ok($$select public.cancel_event('72000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','임원 취소 시도')$$,
  'P0002','event_not_found_or_forbidden','executive logistics permission does not grant cancellation');
select throws_ok($$select public.get_event_logistics(current_setting('logistics.parent_occurrence')::uuid)$$,'P0002','event_logistics_not_found_or_forbidden','church executive gets no parent-scope logistics authority');
reset role;
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000003',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'P0002','event_logistics_not_found_or_forbidden','ordinary member cannot inspect roster');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,0,'[]','[]','[]')$$,'P0002','event_logistics_not_found_or_forbidden','ordinary member cannot save allocation');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000005',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'P0002','event_logistics_not_found_or_forbidden','minister without exact event office cannot inspect roster');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,0,'[]','[]','[]')$$,'P0002','event_logistics_not_found_or_forbidden','minister without exact event office cannot save allocation');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000006',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000006","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'P0002','event_logistics_not_found_or_forbidden','other-church executive cannot inspect roster');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,0,'[]','[]','[]')$$,'P0002','event_logistics_not_found_or_forbidden','other-church executive cannot save allocation');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000013',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000013","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'P0002','event_logistics_not_found_or_forbidden','parent-scope president cannot inspect roster');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,0,'[]','[]','[]')$$,'P0002','event_logistics_not_found_or_forbidden','parent-scope president cannot save allocation');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000007',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000007","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'42501','current_required_consents_required','stale-consent executive fails before any roster lookup');
select throws_ok($$select public.save_event_logistics(null,null,null,null,null)$$,'42501','current_required_consents_required','stale consent precedes invalid-payload validation');
reset role;
select set_config('logistics.groups','[{"id":"73000000-0000-4000-8000-000000000001","name":"1조"}]',true);
select set_config('logistics.vehicles','[{"id":"73000000-0000-4000-8000-000000000002","label":"1호차","seat_count":5,"driver_user_id":"71000000-0000-4000-8000-000000000003"}]',true);
select set_config('logistics.assignments',(select jsonb_agg(jsonb_build_object('user_id',id,'group_id','73000000-0000-4000-8000-000000000001','vehicle_id','73000000-0000-4000-8000-000000000002'))::text
  from public.profiles where id::text in ('71000000-0000-4000-8000-000000000003','71000000-0000-4000-8000-000000000004','71000000-0000-4000-8000-000000000008','71000000-0000-4000-8000-000000000010','71000000-0000-4000-8000-000000000011')),true);
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select is((public.save_event_logistics(current_setting('logistics.occurrence')::uuid,0,current_setting('logistics.groups')::jsonb,
  current_setting('logistics.vehicles')::jsonb,current_setting('logistics.assignments')::jsonb)->>'revision')::integer,1,'exact-church executive atomically saves valid groups and five-seat vehicle');
select set_config('logistics.saved_snapshot',public.get_event_logistics(current_setting('logistics.occurrence')::uuid)::text,true);
select is((select count(*) from jsonb_array_elements(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants') as item
  where item->>'vehicle_id'='73000000-0000-4000-8000-000000000002'),5::bigint,'driver occupies one of the five seats');
select is(public.get_event_logistics(current_setting('logistics.other_occurrence')::uuid)->'groups','[]'::jsonb,'other occurrence in same series has an independent empty plan');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,0,'[]','[]','[]')$$,
  '40001','event_logistics_revision_conflict','stale revision cannot replace a newer plan');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.other_occurrence')::uuid,0,current_setting('logistics.groups')::jsonb,'[]','[]')$$,
  '23514','event_logistics_cross_occurrence_id','group identifiers cannot be imported from another occurrence');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.other_occurrence')::uuid,0,'[]',current_setting('logistics.vehicles')::jsonb,'[]')$$,
  '23514','event_logistics_cross_occurrence_id','vehicle identifiers cannot be imported from another occurrence');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,
  current_setting('logistics.groups')::jsonb || current_setting('logistics.groups')::jsonb,'[]','[]')$$,
  '23514','invalid_event_logistics_groups','duplicate group identifiers fail');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]','[]',
  '[{"user_id":"71000000-0000-4000-8000-000000000003"},{"user_id":"71000000-0000-4000-8000-000000000003"}]')$$,
  '23514','invalid_event_logistics_assignments','duplicate participant assignments fail');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]',
  '[{"id":"73000000-0000-4000-8000-000000000002","label":"0석","seat_count":0}]','[]')$$,
  '23514','invalid_event_logistics_vehicles','zero seats fail before any plan write');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]',
  '[{"id":"73000000-0000-4000-8000-000000000002","label":"소수 좌석","seat_count":1.5}]','[]')$$,
  '23514','invalid_event_logistics_vehicles','fractional seats cannot be silently rounded');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]',
  '[{"id":"73000000-0000-4000-8000-000000000002","label":"1호차","seat_count":1,"driver_user_id":"71000000-0000-4000-8000-000000000003"}]',
  '[{"user_id":"71000000-0000-4000-8000-000000000003","vehicle_id":"73000000-0000-4000-8000-000000000002"},{"user_id":"71000000-0000-4000-8000-000000000004","vehicle_id":"73000000-0000-4000-8000-000000000002"}]')$$,
  '23514','event_logistics_vehicle_capacity_exceeded','overcapacity includes driver seat and fails atomically');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]',
  '[{"id":"73000000-0000-4000-8000-000000000002","label":"1호차","seat_count":2,"driver_user_id":"71000000-0000-4000-8000-000000000004"}]',
  '[{"user_id":"71000000-0000-4000-8000-000000000003","vehicle_id":"73000000-0000-4000-8000-000000000002"}]')$$,
  '23514','invalid_event_logistics_driver','driver must be explicitly assigned to own vehicle');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]',
  '[{"id":"73000000-0000-4000-8000-000000000002","label":"1호차","seat_count":2,"driver_user_id":"71000000-0000-4000-8000-000000000003"},{"id":"73000000-0000-4000-8000-000000000003","label":"2호차","seat_count":2,"driver_user_id":"71000000-0000-4000-8000-000000000003"}]','[]')$$,
  '23514','invalid_event_logistics_vehicles','same driver cannot drive two vehicles');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]','[]',
  '[{"user_id":"71000000-0000-4000-8000-000000000009"}]')$$,
  '23514','invalid_event_logistics_assignments','maybe response cannot receive even a null allocation entry');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]','[]',
  '[{"user_id":"71000000-0000-4000-8000-000000000012"}]')$$,
  '23514','invalid_event_logistics_assignments','cross-church participant cannot be assigned despite a historical RSVP');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,'[]','[]',
  '[{"user_id":"71000000-0000-4000-8000-000000000003","group_id":"73000000-0000-4000-8000-000000000099"}]')$$,
  '23514','invalid_event_logistics_assignments','missing group reference fails instead of partial allocation');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,
  (select jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'name','조')) from generate_series(1,51)),'[]','[]')$$,
  '23514','event_logistics_item_limit','51 groups exceed per-occurrence limit');
select is(public.get_event_logistics(current_setting('logistics.occurrence')::uuid),current_setting('logistics.saved_snapshot')::jsonb,
  'all failed submissions preserve exact saved groups, vehicles, assignments and revision');
reset role;
select is((select count(*) from public.audit_logs where entity_id=current_setting('logistics.occurrence')::uuid and action='event.logistics_saved'),1::bigint,'only successful atomic save produces a save audit');
select ok(exists(select 1 from public.audit_logs where entity_id=current_setting('logistics.occurrence')::uuid and action='event.logistics_read' and actor_id='71000000-0000-4000-8000-000000000002'),'minimal roster access is audited with actual actor');

update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='71000000-0000-4000-8000-000000000008';
select is((select count(*) from private.event_logistics_assignments where user_id='71000000-0000-4000-8000-000000000008'),0::bigint,'consent withdrawal immediately removes retained allocations');
update public.organization_memberships set status='revoked',ended_at=clock_timestamp() where user_id='71000000-0000-4000-8000-000000000010';
select is((select count(*) from private.event_logistics_assignments where user_id='71000000-0000-4000-8000-000000000010'),0::bigint,'membership revocation immediately removes retained allocations');
update public.profiles set deactivated_at=clock_timestamp() where id='71000000-0000-4000-8000-000000000011';
select is((select count(*) from private.event_logistics_assignments where user_id='71000000-0000-4000-8000-000000000011'),0::bigint,'deactivated subject cannot retain allocation');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select is(jsonb_array_length(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants'),3,'read hides withdrawn, revoked and deactivated participants');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,1,current_setting('logistics.groups')::jsonb,
  current_setting('logistics.vehicles')::jsonb,current_setting('logistics.assignments')::jsonb)$$,'40001','event_logistics_revision_conflict','eligibility changes invalidate previously loaded draft');
select set_config('logistics.current_revision',public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->>'revision',true);
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,current_setting('logistics.current_revision')::integer,'[]','[]',
  '[{"user_id":"71000000-0000-4000-8000-000000000008"}]')$$,'23514','invalid_event_logistics_assignments','withdrawn participant cannot be reallocated with current revision');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000003',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select is(public.respond_to_event(current_setting('logistics.occurrence')::uuid,'no','74000000-0000-4000-8000-000000000002')->>'response','no','driver changes RSVP through consent-gated existing RPC');
reset role;
select is((select count(*) from private.event_logistics_assignments where user_id='71000000-0000-4000-8000-000000000003'),0::bigint,'non-yes response immediately clears both group and vehicle allocation');
select is((select driver_user_id from private.event_logistics_vehicles where id='73000000-0000-4000-8000-000000000002'),null::uuid,'non-yes response clears unsafe driver reference');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select ok((public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->>'revision')::integer > current_setting('logistics.current_revision')::integer,'RSVP mutation invalidates manager revision under occurrence lock');
select ok(not exists(select 1 from jsonb_array_elements(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants') as item
  where item->>'response'<>'yes' and (item->>'group_id' is not null or item->>'vehicle_id' is not null)), 'read never exposes allocations for a non-yes response');
reset role;
insert into private.event_logistics_assignments(occurrence_id,user_id,group_id,vehicle_id)
values(current_setting('logistics.occurrence')::uuid,'71000000-0000-4000-8000-000000000012',
  '73000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002');
update private.event_logistics_vehicles set driver_user_id='71000000-0000-4000-8000-000000000012'
where id='73000000-0000-4000-8000-000000000002';
set local role authenticated;
select ok(not exists(select 1 from jsonb_array_elements(public.get_event_logistics(current_setting('logistics.occurrence')::uuid)->'participants') as item
  where item->>'user_id'='71000000-0000-4000-8000-000000000012'),'read sanitizes maintenance-created stale assignments without exposing foreign subject');
reset role;
select is((select count(*) from private.event_logistics_assignments where user_id='71000000-0000-4000-8000-000000000012'),0::bigint,'read removes stale allocations from persisted plan');
select is((select driver_user_id from private.event_logistics_vehicles where id='73000000-0000-4000-8000-000000000002'),null::uuid,'read removes unsafe stale driver reference');
delete from auth.users where id='71000000-0000-4000-8000-000000000004';
select is((select count(*) from private.event_logistics_assignments where user_id='71000000-0000-4000-8000-000000000004'),0::bigint,'account deletion cascades last participant allocation without retaining imported records');
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
set local role authenticated;
select is(public.get_event_occurrence(current_setting('logistics.legacy_occurrence')::uuid)->'host_name','null'::jsonb,'legacy events without host remain readable');
reset role;
select set_config('logistics.event_start',(select starts_at::text from public.events where id='72000000-0000-4000-8000-000000000001'),true);
select set_config('logistics.event_end',(select ends_at::text from public.events where id='72000000-0000-4000-8000-000000000001'),true);
set local role authenticated;
select lives_ok($$select public.save_event('72000000-0000-4000-8000-000000000001',false,current_setting('logistics.church_scope')::uuid,
  '함께하는 모임',null,null,current_setting('logistics.event_start')::timestamptz,current_setting('logistics.event_end')::timestamptz,5,
  'daily',1,array[]::smallint[],null,null,2,array[60],'수정 개최자')$$,'authorized host-only edit works without changing RSVP-locked schedule');
select is(public.get_event_occurrence(current_setting('logistics.occurrence')::uuid)->>'host_name','수정 개최자','host-only edit reads back atomically');
reset role;
select is((select snapshot->>'host_name' from public.event_revisions where event_id='72000000-0000-4000-8000-000000000001' and revision=2),'수정 개최자','edited host is captured in same event revision');
select is((select created_by from public.events where id='72000000-0000-4000-8000-000000000001'),'71000000-0000-4000-8000-000000000001'::uuid,'host edit keeps actual creator immutable');
set local role authenticated;
select lives_ok($$select public.get_event_logistics(current_setting('logistics.parent_occurrence')::uuid)$$,'existing exact-scope event manager retains parent logistics access');
select lives_ok($$select public.save_event_logistics(current_setting('logistics.parent_occurrence')::uuid,0,'[]','[]','[]')$$,'existing manager can save an empty parent plan without fabricated participants');
reset role;
update public.user_consents set accepted=false,withdrawn_at=clock_timestamp() where user_id='71000000-0000-4000-8000-000000000002';
reset role;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'42501','current_required_consents_required','executive access is removed when actor withdraws current consent');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,99,'[]','[]','[]')$$,'42501','current_required_consents_required','withdrawn executive cannot mutate plans or bypass consent with stale revision');
reset role;
update public.user_consents set accepted=true,withdrawn_at=null where user_id='71000000-0000-4000-8000-000000000002';
update public.organization_memberships set status='suspended',ended_at=clock_timestamp() where user_id='71000000-0000-4000-8000-000000000002';
set local role authenticated;
select throws_ok($$select public.get_event_logistics(current_setting('logistics.occurrence')::uuid)$$,'P0002','event_logistics_not_found_or_forbidden','current-consent but inactive executive cannot inspect exact-church roster');
select throws_ok($$select public.save_event_logistics(current_setting('logistics.occurrence')::uuid,99,'[]','[]','[]')$$,'P0002','event_logistics_not_found_or_forbidden','inactive executive cannot mutate allocation');
reset role;
select * from finish();
rollback;
