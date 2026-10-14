begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select plan(60);
select ok((select relrowsecurity from pg_class where oid='private.faith_reading_chapters'::regclass),'reading has RLS');
select ok((select relrowsecurity from pg_class where oid='private.faith_qt_entries'::regclass),'QT has RLS');
select ok(not has_table_privilege('authenticated','private.faith_reading_chapters','select,insert,update,delete'),'no raw reading access');
select ok(not has_table_privilege('authenticated','private.faith_qt_entries','select,insert,update,delete'),'no raw QT access');
select ok(not has_function_privilege('anon','public.get_faith_snapshot(uuid)','execute'),'anonymous RPC denied');
insert into auth.users(id,email,raw_user_meta_data) values
('fa170000-0000-4000-8000-000000000001','faith-a@example.com','{"display_name":"Faith A"}'),
('fa170000-0000-4000-8000-000000000002','faith-b@example.com','{"display_name":"Faith B"}'),
('fa170000-0000-4000-8000-000000000003','faith-stale@example.com','{"display_name":"Faith stale"}'),
('fa170000-0000-4000-8000-000000000004','faith-outsider@example.com','{"display_name":"Faith outsider"}');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select profile.id,d.document_key,d.version,true,'admin_migration' from public.profiles profile cross join public.consent_documents d
where profile.id in('fa170000-0000-4000-8000-000000000001','fa170000-0000-4000-8000-000000000002','fa170000-0000-4000-8000-000000000003','fa170000-0000-4000-8000-000000000004')
and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug='jaegun-bupyeong';
insert into public.organization_memberships(user_id,organization_id,role,status)
select uid,id,'member','active' from public.organizations cross join unnest(array[
'fa170000-0000-4000-8000-000000000001'::uuid,'fa170000-0000-4000-8000-000000000002'::uuid,
'fa170000-0000-4000-8000-000000000003'::uuid]) uid where slug='jaegun-bupyeong';
delete from public.user_consents where user_id='fa170000-0000-4000-8000-000000000003';
create temporary table faith_fixture as select id church,extract(year from statement_timestamp() at time zone 'Asia/Seoul')::integer as "year" from public.organizations where slug='jaegun-bupyeong';
alter table faith_fixture add column qt uuid;
select set_config('request.jwt.claim.sub','',true);
select throws_ok($$select public.get_faith_snapshot((select church from faith_fixture))$$,'42501','authentication_required','no actor denied');
select set_config('request.jwt.claim.sub','fa170000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.get_faith_snapshot((select church from faith_fixture))$$,'42501','current_required_consents_required','stale consent denied');
select set_config('request.jwt.claim.sub','fa170000-0000-4000-8000-000000000004',true);
insert into public.platform_admins(user_id,note) values('fa170000-0000-4000-8000-000000000004','rollback faith fixture');
select throws_ok($$select public.get_faith_snapshot((select church from faith_fixture))$$,'42501','faith_active_church_membership_required','admin without membership denied');
select set_config('request.jwt.claim.sub','fa170000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.get_faith_snapshot(church) from faith_fixture$$,'42501','faith_optional_consent_required','core consent alone never opts into faith records');
select is((public.get_faith_consent_status((select church from faith_fixture))->>'accepted')::boolean,false,'status does not accept consent');
select throws_ok($$select public.accept_faith_consent(church,'wrong',private.faith_document_manifest()->>'content_sha256') from faith_fixture$$,'23514','faith_consent_document_mismatch','wrong version denied');
select throws_ok($$select public.accept_faith_consent(church,'2026-10-14',repeat('a',64)) from faith_fixture$$,'23514','faith_consent_document_mismatch','wrong hash denied');
select throws_ok($$select public.accept_faith_consent(church,'2026-10-14',null) from faith_fixture$$,'23514','faith_consent_document_mismatch','missing hash denied');
select is((public.accept_faith_consent((select church from faith_fixture),'2026-10-14',private.faith_document_manifest()->>'content_sha256')->>'accepted')::boolean,true,'explicit exact document acceptance works');
select is((public.accept_faith_consent((select church from faith_fixture),'2026-10-14',private.faith_document_manifest()->>'content_sha256')->>'accepted')::boolean,true,'exact consent retry remains accepted');
select throws_ok($$select public.get_faith_snapshot('fa170000-0000-4000-8000-000000000099')$$,'42501','faith_active_church_membership_required','other church denied');
select is((public.get_faith_snapshot((select church from faith_fixture))->>'total_chapters')::integer,1189,'chapter count factual');
select is((public.get_faith_snapshot((select church from faith_fixture))->>'completed_count')::integer,0,'initial no fake progress');
select throws_ok($$select public.set_my_reading_chapter(church,year,0,true) from faith_fixture$$,'23514','invalid_reading_chapter_year_or_state','chapter zero denied');
select throws_ok($$select public.set_my_reading_chapter(church,year,1190,true) from faith_fixture$$,'23514','invalid_reading_chapter_year_or_state','chapter overflow denied');
select throws_ok($$select public.set_my_reading_chapter(church,year-1,1,true) from faith_fixture$$,'23514','invalid_reading_chapter_year_or_state','past year denied');
select is((public.set_my_reading_chapter((select church from faith_fixture),(select year from faith_fixture),1,true)->>'completed_count')::integer,1,'marks own chapter');
select is((public.set_my_reading_chapter((select church from faith_fixture),(select year from faith_fixture),1,true)->>'completed_count')::integer,1,'same desired state no duplicate');
select is((public.get_faith_snapshot((select church from faith_fixture))->>'streak_days')::integer,1,'one server reading day');
update private.faith_reading_chapters set completed_on=(statement_timestamp() at time zone 'Asia/Seoul')::date-1 where user_id='fa170000-0000-4000-8000-000000000001';
select is((public.set_my_reading_chapter((select church from faith_fixture),(select year from faith_fixture),1,true)->>'last_read_date'),((statement_timestamp() at time zone 'Asia/Seoul')::date-1)::text,'retry never invents today activity');
select is((public.set_my_reading_chapter((select church from faith_fixture),(select year from faith_fixture),2,true)->>'streak_days')::integer,2,'two actual consecutive dates');
select is((public.set_my_reading_chapter((select church from faith_fixture),(select year from faith_fixture),2,false)->>'streak_days')::integer,1,'unmark removes only today activity');
update faith_fixture set qt=public.create_my_qt(church,'fa170000-0000-4000-8000-000000000010','요 1:1','오늘 묵상');
select is(public.create_my_qt((select church from faith_fixture),'fa170000-0000-4000-8000-000000000010','요 1:1','오늘 묵상'),(select qt from faith_fixture),'create retry same UUID');
select throws_ok($$select public.create_my_qt(church,'fa170000-0000-4000-8000-000000000010','요 1:1','수정') from faith_fixture$$,'23514','qt_client_payload_mismatch','retry changed payload denied');
select throws_ok($$select public.create_my_qt(church,'fa170000-0000-4000-8000-000000000011','요 1:1',repeat('x',501)) from faith_fixture$$,'23514','invalid_qt_reference_or_body','QT body bounded');
select is(jsonb_array_length(public.list_my_qt((select church from faith_fixture))),1,'own QT visible');
select set_config('request.jwt.claim.sub','fa170000-0000-4000-8000-000000000002',true);
select public.accept_faith_consent((select church from faith_fixture),'2026-10-14',private.faith_document_manifest()->>'content_sha256');
select is(jsonb_array_length(public.list_my_qt((select church from faith_fixture))),0,'others private QT absent');
select is(public.delete_my_qt((select church from faith_fixture),(select qt from faith_fixture)),false,'cannot delete other QT');
select is((public.get_faith_snapshot((select church from faith_fixture))->>'completed_count')::integer,0,'others reading absent');
select set_config('request.jwt.claim.sub','fa170000-0000-4000-8000-000000000001',true);
select is(public.delete_my_qt((select church from faith_fixture),(select qt from faith_fixture)),true,'own deletion works');
select is(public.delete_my_qt((select church from faith_fixture),(select qt from faith_fixture)),false,'deletion retry no-op');
select throws_ok($$select public.list_my_qt(church,101,0) from faith_fixture$$,'23514','invalid_faith_pagination','pagination bounded');
select throws_ok($$select public.set_my_reading_chapter(church,year+1,1,true) from faith_fixture$$,'23514','invalid_reading_chapter_year_or_state','future year denied');
select throws_ok($$select public.set_my_reading_chapter(church,year,1,null) from faith_fixture$$,'23514','invalid_reading_chapter_year_or_state','null state denied');
select throws_ok($$select public.create_my_qt(church,'fa170000-0000-4000-8000-000000000011',' ', 'body') from faith_fixture$$,'23514','invalid_qt_reference_or_body','empty reference denied');
select is(public.create_my_qt((select church from faith_fixture),'fa170000-0000-4000-8000-000000000010','요 1:1','오늘 묵상'),(select qt from faith_fixture),'deleted receipt retry stays idempotent');
select is(jsonb_array_length(public.list_my_qt((select church from faith_fixture))),0,'deleted QT not recreated by retry');
select ok(not exists(select 1 from information_schema.columns where table_schema='private' and table_name='faith_qt_receipts' and column_name in('payload','body','reference')),'receipt has no plaintext content columns');
select is(octet_length((select payload_hash from private.faith_qt_receipts where user_id='fa170000-0000-4000-8000-000000000001')),32,'receipt keeps SHA256 hash only');
select throws_ok($$select public.create_my_qt(church,'fa170000-0000-4000-8000-000000000010','요 1:1','다른 본문') from faith_fixture$$,'23514','qt_client_payload_mismatch','changed content hash denied even after deletion');
insert into private.faith_qt_receipts(user_id,client_request_id,payload_hash,qt_id)
select 'fa170000-0000-4000-8000-000000000001',gen_random_uuid(),extensions.digest('quota fixture','sha256'),gen_random_uuid() from generate_series(1,19);
select throws_ok($$select public.create_my_qt(church,'fa170000-0000-4000-8000-000000000015','요 1:1','새 QT') from faith_fixture$$,'23514','qt_daily_creation_limit','daily creation quota counts deleted records');
select is(public.create_my_qt((select church from faith_fixture),'fa170000-0000-4000-8000-000000000010','요 1:1','오늘 묵상'),(select qt from faith_fixture),'idempotent receipt acknowledgement bypasses quota only for exact prior request');
update private.faith_qt_receipts set created_at=statement_timestamp()-interval '2 days' where user_id='fa170000-0000-4000-8000-000000000001';
insert into private.faith_qt_entries(user_id,reference,body)
select 'fa170000-0000-4000-8000-000000000001','요 1:1','stored fixture' from generate_series(1,1000);
select throws_ok($$select public.create_my_qt(church,'fa170000-0000-4000-8000-000000000015','요 1:1','새 QT') from faith_fixture$$,'23514','qt_storage_limit','stored note quota denies without silent purge');
select is((select count(*) from private.faith_qt_entries where user_id='fa170000-0000-4000-8000-000000000001'),1000::bigint,'storage rejection preserves existing records');
insert into auth.sessions(id,user_id,created_at) values('fa170000-0000-4000-8000-000000000090','fa170000-0000-4000-8000-000000000001',statement_timestamp());
select set_config('request.jwt.claims',jsonb_build_object('sub','fa170000-0000-4000-8000-000000000001','role','authenticated','is_anonymous',false,'aud','authenticated',
 'iat',floor(extract(epoch from statement_timestamp())),'exp',floor(extract(epoch from statement_timestamp()+interval '1 hour')),'session_id','fa170000-0000-4000-8000-000000000090')::text,true);
select throws_ok($$select public.withdraw_faith_consent(church,false) from faith_fixture$$,'23514','faith_withdrawal_delete_confirmation_required','withdrawal needs explicit deletion confirmation');
select is((public.withdraw_faith_consent((select church from faith_fixture),true)->>'accepted')::boolean,false,'confirmed withdrawal works');
select is((select count(*) from private.faith_reading_chapters where user_id='fa170000-0000-4000-8000-000000000001'),0::bigint,'withdrawal erases all reading');
select is((select count(*) from private.faith_qt_entries where user_id='fa170000-0000-4000-8000-000000000001'),0::bigint,'withdrawal erases all notes');
select is((select count(*) from private.faith_qt_receipts where user_id='fa170000-0000-4000-8000-000000000001'),0::bigint,'withdrawal erases all hashes');
select is((public.get_faith_consent_status((select church from faith_fixture))->>'accepted')::boolean,false,'withdrawn status false');
select throws_ok($$select public.get_faith_snapshot(church) from faith_fixture$$,'42501','faith_optional_consent_required','withdrawn faith data denied');
delete from public.user_consents where user_id='fa170000-0000-4000-8000-000000000001';
select lives_ok($$select public.withdraw_faith_consent(church,true) from faith_fixture$$,'withdrawal remains possible after core consent becomes stale');
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select 'fa170000-0000-4000-8000-000000000001',d.document_key,d.version,true,'admin_migration' from public.consent_documents d
where d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organization_memberships set status='suspended',ended_at=statement_timestamp() where user_id='fa170000-0000-4000-8000-000000000001';
select throws_ok($$select public.get_faith_snapshot(church) from faith_fixture$$,'42501','faith_active_church_membership_required','inactive member denied');
delete from public.profiles where id='fa170000-0000-4000-8000-000000000001';
select is((select count(*) from private.faith_reading_chapters where user_id='fa170000-0000-4000-8000-000000000001'),0::bigint,'account deletion cascades reading');
select is((select count(*) from private.faith_qt_receipts where user_id='fa170000-0000-4000-8000-000000000001'),0::bigint,'account deletion cascades receipts');
select * from finish();
rollback;
