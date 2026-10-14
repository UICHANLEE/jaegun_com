begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();
select ok(not has_table_privilege('authenticated','private.event_create_receipts','select,insert,update,delete'), 'create receipts have no client grants');
select ok((select relrowsecurity from pg_class where oid='private.event_create_receipts'::regclass), 'private receipts enable RLS');
select ok(not has_function_privilege('anon','public.save_event_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer)','execute'), 'anonymous checked writes denied');
select ok(not has_function_privilege('authenticated','private.prune_event_create_receipts(integer)','execute'), 'internal retention helper not client-callable');

insert into auth.users(id,email,raw_user_meta_data) values
 ('81000000-0000-4000-8000-000000000001','checked-admin@example.invalid','{"display_name":"관리자"}'),
 ('81000000-0000-4000-8000-000000000002','checked-admin2@example.invalid','{"display_name":"다른 관리자"}'),
 ('81000000-0000-4000-8000-000000000003','checked-member@example.invalid','{"display_name":"성도"}'),
 ('81000000-0000-4000-8000-000000000004','checked-stale@example.invalid','{"display_name":"미동의 관리자"}');
insert into public.platform_admins(user_id,note) select id,'checked mutation regression' from auth.users where id in
 ('81000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000004');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select profile.id, doc.document_key, doc.version, true, 'admin_migration'
from public.profiles profile cross join public.consent_documents doc
where profile.id::text like '81000000-0000-4000-8000-%' and profile.id <> '81000000-0000-4000-8000-000000000004'
 and doc.required and doc.retired_at is null and doc.published_at <= statement_timestamp() and doc.effective_at <= statement_timestamp();
update public.organizations set status='active' where slug='jaegun-bupyeong';
insert into public.organization_memberships(user_id,organization_id,role)
select '81000000-0000-4000-8000-000000000003',id,'member' from public.organizations where slug='jaegun-bupyeong';
select set_config('checked.scope',(select id::text from public.governance_scopes where scope_type='church' and organization_id=(select id from public.organizations where slug='jaegun-bupyeong')),true);
select set_config('checked.now',floor(extract(epoch from statement_timestamp()))::bigint::text,true);
select set_config('checked.start',(statement_timestamp()+interval '2 days')::text,true);
select set_config('checked.end',(statement_timestamp()+interval '2 days 1 hour')::text,true);
insert into auth.identities(provider_id,user_id,identity_data,provider)
select id::text,id,jsonb_build_object('sub',id::text),'google' from auth.users where id::text like '81000000-0000-4000-8000-%';
insert into auth.sessions(id,user_id,created_at,updated_at,aal)
select id,id,to_timestamp(current_setting('checked.now')::bigint),to_timestamp(current_setting('checked.now')::bigint),'aal1' from auth.users where id::text like '81000000-0000-4000-8000-%';
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
select gen_random_uuid(),id,to_timestamp(current_setting('checked.now')::bigint),to_timestamp(current_setting('checked.now')::bigint),'oauth' from auth.users where id::text like '81000000-0000-4000-8000-%';

create function pg_temp.checked_claims(actor uuid, oauth boolean default true) returns text language sql as $$
 select jsonb_build_object('sub',actor,'session_id',actor,'role','authenticated','is_anonymous',false,'aud','authenticated','iat',current_setting('checked.now')::bigint,'exp',current_setting('checked.now')::bigint+3600,'aal','aal1','amr',jsonb_build_array(jsonb_build_object('method',case when oauth then 'oauth' else 'password' end,'timestamp',current_setting('checked.now')::bigint)))::text
$$;
create function pg_temp.checked_save(p_create boolean,p_id uuid,p_title text,p_revision integer,p_host text default '주최 교회') returns uuid language sql as $$
 select public.save_event_checked(p_id,p_create,current_setting('checked.scope')::uuid,p_title,null,null,current_setting('checked.start')::timestamptz,current_setting('checked.end')::timestamptz,null,'none',1,array[]::smallint[],null,null,null,array[60],p_host,p_revision)
$$;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000001'),true);
set local role authenticated;
select lives_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','원본 일정',null)$$,'fresh verified manager creates checked event');
select lives_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','원본 일정',null)$$,'exact actor and payload retry succeeds');
select throws_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','바뀐 요청',null)$$,'40001','event_create_operation_conflict','changed create payload rejected');
select throws_ok($$select pg_temp.checked_save(false,'82000000-0000-4000-8000-000000000001','바뀐 요청',null)$$,'22023','event_expected_revision_required','update requires expected revision');
select lives_ok($$select pg_temp.checked_save(false,'82000000-0000-4000-8000-000000000001','변경한 일정',1)$$,'matching locked revision updates event');
select throws_ok($$select pg_temp.checked_save(false,'82000000-0000-4000-8000-000000000001','유실될 변경',1)$$,'40001','event_revision_conflict','stale revision cannot overwrite');
select lives_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','원본 일정',null)$$,'original create retry acknowledges success without restoring old content');
select throws_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000002','잘못된 주최',null,' ')$$,'23514','invalid_event_host_name','original host validation remains');
reset role;
select is((select title from public.events where id='82000000-0000-4000-8000-000000000001'),'변경한 일정','create retry never undoes later edits');
select is((select revision from public.events where id='82000000-0000-4000-8000-000000000001'),2,'same payload retry does not increment revision');
select is((select count(*) from private.event_create_receipts where event_id='82000000-0000-4000-8000-000000000002'),0::bigint,'invalid create leaves no receipt');
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000002'),true);
set local role authenticated;
select throws_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','원본 일정',null)$$,'40001','event_create_operation_conflict','another authorized actor cannot adopt create receipt');
reset role;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000003',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000003'),true);
set local role authenticated;
select throws_ok($$select pg_temp.checked_save(false,'82000000-0000-4000-8000-000000000001','권한 없음',2)$$,'P0002','event_save_not_found_or_forbidden','ordinary member cannot update existing event');
select throws_ok($$select pg_temp.checked_save(false,'82000000-0000-4000-8000-000000000099','권한 없음',2)$$,'P0002','event_save_not_found_or_forbidden','same denied response for nonexistent event');
reset role;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000001',false),true);
set local role authenticated;
select throws_ok($$select pg_temp.checked_save(false,'82000000-0000-4000-8000-000000000001','재인증 누락',2)$$,'42501',null,'recent Google proof required before mutation');
reset role;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000004',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000004'),true);
set local role authenticated;
select throws_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000099','동의 누락',null)$$,'42501',null,'current required consent remains mandatory');
reset role;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000001'),true);
update private.event_create_receipts set created_at=statement_timestamp()-interval '91 days' where event_id='82000000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','원본 일정',null)$$,'40001','event_create_operation_conflict','expired receipt never permits overwrite');
reset role;
select is((select title from public.events where id='82000000-0000-4000-8000-000000000001'),'변경한 일정','denied operations leave stored content intact');
select is(private.prune_event_create_receipts(1),1,'bounded internal retention deletes expired receipt');
set local role authenticated;
select throws_ok($$select pg_temp.checked_save(true,'82000000-0000-4000-8000-000000000001','원본 일정',null)$$,'40001','event_create_operation_conflict','pruned receipt cannot cause overwrite or duplicate');
reset role;

-- New monthly rule path preserves the same real authenticated scope/proof boundaries.
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000001'),true);
select set_config('checked.month_start',((date_trunc('month',statement_timestamp() at time zone 'Asia/Seoul')+interval '1 month')::date + ((5-extract(isodow from date_trunc('month',statement_timestamp() at time zone 'Asia/Seoul')+interval '1 month')::integer+7)%7) +7 + time '10:00')::text,true);
create function pg_temp.monthly_save(p_id uuid,p_week integer default 2,p_weekday integer default 5,p_create boolean default true,p_revision integer default null) returns uuid language sql as $$
 select public.save_event_recurrence_checked(p_id,p_create,current_setting('checked.scope')::uuid,'매월 모임',null,null,current_setting('checked.month_start')::timestamp at time zone 'Asia/Seoul',(current_setting('checked.month_start')::timestamp+interval '1 hour') at time zone 'Asia/Seoul',null,'monthly',1,array[]::smallint[],null,null,6,array[60],'교회',p_revision,p_week,p_weekday)
$$;
select ok(not has_function_privilege('anon','public.save_event_recurrence_checked(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer,integer,integer)','execute'),'anonymous monthly writes denied');
select ok(not has_function_privilege('authenticated','private.save_event_recurrence_v2(uuid,boolean,uuid,text,text,text,timestamptz,timestamptz,integer,text,integer,smallint[],integer,timestamptz,integer,integer[],text,integer,integer)','execute'),'inner monthly save is private');
select ok(private.event_matches_month_weekday('2024-02-29',-1,4),'leap February last Thursday');
select ok(not private.event_matches_month_weekday('2024-02-22',-1,4),'previous Thursday is not the last');
select ok(private.event_matches_month_weekday('2026-05-01',1,5),'first Friday');
select ok(private.event_matches_month_weekday('2026-05-29',-1,5),'five-Friday month last means fifth');
select ok(not private.event_matches_month_weekday('2026-05-22',-1,5),'fourth is not last in five-week month');
set local role authenticated;
select lives_ok($$select pg_temp.monthly_save('83000000-0000-4000-8000-000000000001')$$,'authorized monthly second Friday creates');
select lives_ok($$select pg_temp.monthly_save('83000000-0000-4000-8000-000000000001')$$,'exact monthly create replay is idempotent');
select throws_ok($$select pg_temp.monthly_save('83000000-0000-4000-8000-000000000001',3)$$,'40001','event_create_operation_conflict','different ordinal cannot reuse create receipt');
select throws_ok($$select pg_temp.monthly_save('83000000-0000-4000-8000-000000000002',2,4)$$,'23514','monthly_weekday_must_match_start','first date must match selected weekday');
reset role;
select is((select count(*) from public.event_occurrences where event_id='83000000-0000-4000-8000-000000000001'),6::bigint,'exactly six actual monthly occurrences');
select ok((select bool_and(private.event_matches_month_weekday((starts_at at time zone 'Asia/Seoul')::date,2,5)) from public.event_occurrences where event_id='83000000-0000-4000-8000-000000000001'),'every generated occurrence is second Friday in Seoul');
select is((select revision from public.events where id='83000000-0000-4000-8000-000000000001'),1,'retry leaves revision unchanged');
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000003',true);
select set_config('request.jwt.claims',pg_temp.checked_claims('81000000-0000-4000-8000-000000000003'),true);
set local role authenticated;
select throws_ok($$select pg_temp.monthly_save('83000000-0000-4000-8000-000000000003')$$,'P0002','event_save_not_found_or_forbidden','ordinary members cannot create monthly rules');
reset role;

select * from finish();
rollback;
