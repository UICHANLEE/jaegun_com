begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions,pg_catalog;
select no_plan();
select ok((select relrowsecurity from pg_class where oid='private.faith_ranking_preferences'::regclass),'ranking preferences have RLS');
select ok((select relrowsecurity from pg_class where oid='private.faith_shared_posts'::regclass),'share metadata has RLS');
select ok(not has_table_privilege('authenticated','private.faith_ranking_preferences','select,insert,update,delete'),'no direct individual participation access');
select ok(not has_table_privilege('authenticated','private.faith_shared_posts','select,insert,update,delete'),'no direct private QT linkage access');
select ok(not has_function_privilege('anon','public.get_faith_community(uuid)','execute'),'anonymous ranking denied');
select ok(not has_function_privilege('anon','public.share_my_qt(uuid,uuid,uuid)','execute'),'anonymous sharing denied');
select ok(not has_function_privilege('anon','public.list_shared_qt(uuid,date,integer,integer)','execute'),'anonymous shared feed denied');
insert into auth.users(id,email,raw_user_meta_data)
select ('fc150000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'faith-community-'||n||'@example.com',jsonb_build_object('display_name','Faith fixture '||n) from generate_series(1,16) n;
insert into public.user_consents(user_id,document_key,document_version,accepted,source)
select p.id,d.document_key,d.version,true,'admin_migration' from public.profiles p cross join public.consent_documents d
where p.id::text like 'fc150000-0000-4000-8000-%' and d.required and d.retired_at is null and d.published_at<=statement_timestamp() and d.effective_at<=statement_timestamp();
update public.organizations set status='active' where slug='jaegun-bupyeong';
create temporary table faith_community_fixture as select n,('fc150000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid actor,
 ('fc150000-0000-4000-9000-'||lpad(n::text,12,'0'))::uuid session_id,o.id church,extract(year from statement_timestamp() at time zone 'Asia/Seoul')::integer as "year"
 from generate_series(1,16) n cross join public.organizations o where o.slug='jaegun-bupyeong';
insert into auth.sessions(id,user_id,created_at) select session_id,actor,statement_timestamp() from faith_community_fixture;
insert into public.organization_memberships(user_id,organization_id,role,status) select actor,church,'member','active' from faith_community_fixture where n<=5;
create function pg_temp.faith_community_actor(p_n integer) returns void language plpgsql as $$
declare r record;
begin
 select * into r from faith_community_fixture where n=p_n;
 perform set_config('request.jwt.claim.sub',r.actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',r.actor,'role','authenticated','is_anonymous',false,'aud','authenticated','iat',floor(extract(epoch from statement_timestamp())),'exp',floor(extract(epoch from statement_timestamp()+interval '1 hour')),'session_id',r.session_id)::text,true);
end; $$;
select pg_temp.faith_community_actor(6);
insert into public.platform_admins(user_id,note) select actor,'rollback faith community fixture' from faith_community_fixture where n=6;
select throws_ok($$select public.get_faith_community(church) from faith_community_fixture limit 1$$,'42501','faith_active_church_membership_required','platform admin has no private faith bypass');
select pg_temp.faith_community_actor(1);
select is((public.get_faith_community((select church from faith_community_fixture limit 1))->>'opted_in')::boolean,false,'private faith and ranking default off');
select throws_ok($$select public.set_faith_ranking_participation(church,year,true,'2026-10-15',0,auth.uid(),null) from faith_community_fixture limit 1$$,'42501','faith_optional_consent_required','ranking requires private faith consent but never accepts it');
select throws_ok($$select public.set_faith_ranking_participation(church,year-1,true,'2026-10-15',0,auth.uid(),null) from faith_community_fixture limit 1$$,'23514','invalid_faith_ranking_request','client cannot choose old service year');
select throws_ok($$select public.set_faith_ranking_participation(church,year,true,'wrong',0,auth.uid(),null) from faith_community_fixture limit 1$$,'23514','invalid_faith_ranking_request','exact independent notice required');
do $$ declare r record; begin
 for r in select * from faith_community_fixture where n<=4 order by n loop
  perform pg_temp.faith_community_actor(r.n);
  perform public.accept_faith_consent(r.church,'2026-10-14',private.faith_document_manifest()->>'content_sha256');
  perform public.set_my_reading_chapter(r.church,r.year,1,true);
  perform public.set_faith_ranking_participation(r.church,r.year,true,'2026-10-15',0,auth.uid(),null);
 end loop;
end; $$;
select is(jsonb_array_length(public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'),0,'four participant church and presbytery both suppressed');
select pg_temp.faith_community_actor(5);
select public.accept_faith_consent((select church from faith_community_fixture limit 1),'2026-10-14',private.faith_document_manifest()->>'content_sha256');
select public.set_my_reading_chapter((select church from faith_community_fixture limit 1),(select year from faith_community_fixture limit 1),1,true);
select is(jsonb_array_length(public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'),0,'faith consent alone never adds contribution');
select throws_ok($$select public.set_faith_ranking_participation(church,year,true,'2026-10-15',0,gen_random_uuid(),null) from faith_community_fixture limit 1$$,'42501','faith_actor_changed','cross-account pending participation rejected');
select is((public.set_faith_ranking_participation((select church from faith_community_fixture limit 1),(select year from faith_community_fixture limit 1),true,'2026-10-15',0,auth.uid(),null)->>'revision')::integer,1,'explicit fifth participant creates revision');
select is((public.set_faith_ranking_participation((select church from faith_community_fixture limit 1),(select year from faith_community_fixture limit 1),true,'2026-10-15',0,auth.uid(),null)->>'revision')::integer,1,'exact desired-state retry idempotent');
select is(jsonb_array_length(public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'),2,'five participants expose church and presbytery aggregate');
select ok(not exists(select 1 from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings') r where r ?| array['user_id','actor_id','reference','body','completed_chapters','completed_on']),'aggregate never returns individual fields');
select ok(not (public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings')::text like '%fc150000%','aggregate has no individual UUID');
select is((public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'->0->>'participants')::integer,5,'aggregate counts only opted in eligible actors');
select is((public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'->0->>'chapters')::integer,5,'chapter totals derived from canonical private records');
select is((public.set_faith_ranking_participation((select church from faith_community_fixture limit 1),(select year from faith_community_fixture limit 1),false,'2026-10-15',1,auth.uid(),null)->>'revision')::integer,2,'explicit optout increments revision');
select is(jsonb_array_length(public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'),0,'optout immediately removes contribution and small group');
select is((public.set_faith_ranking_participation((select church from faith_community_fixture limit 1),(select year from faith_community_fixture limit 1),false,'2026-10-15',1,auth.uid(),null)->>'revision')::integer,2,'optout retry is idempotent');
select throws_ok($$select public.set_faith_ranking_participation(church,year,true,'2026-10-15',0,auth.uid(),null) from faith_community_fixture limit 1$$,'40001','faith_ranking_revision_conflict','stale opt-in cannot undo newer optout');
select public.set_faith_ranking_participation((select church from faith_community_fixture limit 1),(select year from faith_community_fixture limit 1),true,'2026-10-15',2,auth.uid(),null);
select public.withdraw_faith_consent((select church from faith_community_fixture limit 1),true);
select is((select count(*) from private.faith_ranking_preferences where user_id=(select actor from faith_community_fixture where n=5)),0::bigint,'faith withdrawal deletes ranking preference');
select pg_temp.faith_community_actor(1);
select is(jsonb_array_length(public.get_faith_community((select church from faith_community_fixture limit 1))->'rankings'),0,'withdrawal removes contribution immediately');
create temporary table faith_share_fixture(qt uuid,post_id uuid);
insert into faith_share_fixture select public.create_my_qt((select church from faith_community_fixture limit 1),'fc150000-0000-4000-a000-000000000001','창세기 1장','명시적으로 공유할 묵상'),'fc150000-0000-4000-b000-000000000001';
select is(jsonb_array_length(public.list_shared_qt((select church from faith_community_fixture limit 1))->'items'),0,'private note never automatically enters daily public feed');
select is(public.share_my_qt((select church from faith_community_fixture limit 1),(select qt from faith_share_fixture),(select post_id from faith_share_fixture)),(select post_id from faith_share_fixture),'explicit sharing makes board copy');
select is(public.share_my_qt((select church from faith_community_fixture limit 1),(select qt from faith_share_fixture),(select post_id from faith_share_fixture)),(select post_id from faith_share_fixture),'shared retry returns same copy');
select is(jsonb_array_length(public.list_shared_qt((select church from faith_community_fixture limit 1))->'items'),1,'daily feed contains one explicit copy');
select throws_ok($$select public.share_my_qt((select church from faith_community_fixture limit 1),gen_random_uuid(),(select post_id from faith_share_fixture))$$,'23514','qt_share_payload_mismatch','request id cannot disclose a different QT');
select pg_temp.faith_community_actor(2);
select throws_ok($$select public.share_my_qt((select church from faith_community_fixture limit 1),(select qt from faith_share_fixture),'fc150000-0000-4000-b000-000000000002')$$,'P0002','private_qt_not_found','cannot share someone else private note');
select is((public.set_post_reaction((select post_id from faith_share_fixture),'amen',true,auth.uid())->>'amen_count')::integer,1,'shared QT amen is real board reaction');
select is((public.set_post_reaction((select post_id from faith_share_fixture),'amen',true,auth.uid())->>'amen_count')::integer,1,'amen same-state retry never increments');
select is((public.list_shared_qt((select church from faith_community_fixture limit 1))->'items'->0->>'amen_count')::integer,1,'feed exposes aggregate amen count');
select is((public.set_post_reaction((select post_id from faith_share_fixture),'amen',false,auth.uid())->>'amen_count')::integer,0,'amen can be explicitly removed');
select throws_ok($$select public.list_shared_qt((select church from faith_community_fixture limit 1),null,51,0)$$,'23514','invalid_qt_feed_pagination','feed page bounded');
select throws_ok($$select public.list_shared_qt((select church from faith_community_fixture limit 1),(statement_timestamp() at time zone 'Asia/Seoul')::date+1,25,0)$$,'23514','invalid_qt_feed_pagination','future client date denied');
select pg_temp.faith_community_actor(1);
select public.withdraw_faith_consent((select church from faith_community_fixture limit 1),true);
select is(jsonb_array_length(public.list_shared_qt((select church from faith_community_fixture limit 1))->'items'),1,'optional withdrawal leaves separately shared board copy intentionally');
select pg_temp.faith_community_actor(3);
delete from public.user_consents where user_id=(select actor from faith_community_fixture where n=3);
select throws_ok($$select public.get_faith_community(church) from faith_community_fixture limit 1$$,'42501','current_required_consents_required','core consent revocation blocks community aggregate');
select lives_ok($$select public.set_faith_ranking_participation(church,year,false,'2026-10-15',1,auth.uid(),null) from faith_community_fixture limit 1$$,'self optout remains available with stale core consent');
select throws_ok($$select public.list_shared_qt(church) from faith_community_fixture limit 1$$,'42501','current_required_consents_required','shared feed also enforces current core consent');

-- Challenge grouping is independently selected, exact-church, and never authority.
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','{}',true);
create temporary table faith_department_other as select id church from public.organizations where id<>(select church from faith_community_fixture limit 1) order by slug limit 1;
update public.organizations set status='active' where id=(select church from faith_department_other);
update faith_community_fixture set church=(select church from faith_department_other) where n>=12;
insert into public.organization_memberships(user_id,organization_id,role,status) select actor,church,'member','active' from faith_community_fixture where n>=7;
do $$ declare r record; begin
 for r in select * from faith_community_fixture where n>=7 order by n loop
  perform pg_temp.faith_community_actor(r.n);
  perform public.accept_faith_consent(r.church,'2026-10-14',private.faith_document_manifest()->>'content_sha256');
  perform public.set_my_reading_chapter(r.church,r.year,1,true);
  perform public.set_faith_ranking_participation(r.church,r.year,true,'2026-10-15',0,auth.uid(),case when r.n=11 then 'teen' else 'adult' end);
 end loop;
end; $$;
select pg_temp.faith_community_actor(7);
select is((public.get_faith_community((select church from faith_community_fixture where n=7))->>'challenge_department_code'),'adult','self sees only explicitly chosen challenge department');
select ok(not exists(select 1 from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=7))->'rankings') r where r->>'kind'='church' and (r->>'id')::uuid<>(select church from faith_community_fixture where n=7)),'aggregate response never exposes other church totals');
select ok(not exists(select 1 from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=7))->'rankings') r where r->>'kind'='presbytery' and (r->>'id')::uuid<>(select parent_scope_id from public.governance_scopes where organization_id=(select church from faith_community_fixture where n=7) and scope_type='church')),'aggregate response is confined to the current church presbytery');
select is((select count(*) from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=7))->'rankings') r where r->>'kind'='department'),0::bigint,'four adult plus one teen do not meet per-department minimum; sibling church five adults cannot fill it');
select pg_temp.faith_community_actor(12);
select is((select (r->>'participants')::integer from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=12))->'rankings') r where r->>'kind'='department'),5,'other church has only its own five-member group, not combined nine');
select pg_temp.faith_community_actor(11);
select throws_ok($$select public.set_faith_ranking_participation(church,year,true,'2026-10-15',1,auth.uid(),'executive') from faith_community_fixture where n=11$$,'23514','invalid_faith_challenge_department','arbitrary or authority codes cannot become challenge grouping');
select is((public.set_faith_ranking_participation((select church from faith_community_fixture where n=11),(select year from faith_community_fixture where n=11),true,'2026-10-15',1,auth.uid(),'adult')->>'revision')::integer,2,'explicit department change is revision-safe');
select is((public.set_faith_ranking_participation((select church from faith_community_fixture where n=11),(select year from faith_community_fixture where n=11),true,'2026-10-15',1,auth.uid(),'adult')->>'revision')::integer,2,'same department selection retry is idempotent');
select is((select (r->>'participants')::integer from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=11))->'rankings') r where r->>'kind'='department'),5,'fifth explicitly selected member reveals exact-church department');
select ok(not exists(select 1 from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=11))->'rankings') r where r->>'kind'='department' and (r->>'id')::uuid in(select d.id from public.church_departments d join public.governance_scopes s on s.id=d.church_scope_id where s.organization_id=(select church from faith_department_other))),'department rows never disclose sibling church groups');
select pg_temp.faith_community_actor(7);
select public.withdraw_faith_consent((select church from faith_community_fixture where n=7),true);
select is((select count(*) from private.faith_ranking_preferences where user_id=(select actor from faith_community_fixture where n=7)),0::bigint,'faith withdrawal removes challenge choice');
select pg_temp.faith_community_actor(8);
select is((select count(*) from jsonb_array_elements(public.get_faith_community((select church from faith_community_fixture where n=8))->'rankings') r where r->>'kind'='department'),0::bigint,'withdrawal immediately suppresses newly small department without exposing remaining members');
select public.set_faith_ranking_participation((select church from faith_community_fixture where n=8),(select year from faith_community_fixture where n=8),false,'2026-10-15',1,auth.uid(),null);
select is((select challenge_department_code from private.faith_ranking_preferences where user_id=(select actor from faith_community_fixture where n=8)),null::text,'optout clears self-selected grouping');
select public.set_faith_ranking_participation((select church from faith_community_fixture where n=8),(select year from faith_community_fixture where n=8),true,'2026-10-15',2,auth.uid(),null);
select is((public.get_faith_community((select church from faith_community_fixture where n=8))->>'challenge_department_code'),null::text,'reenrollment without explicit department does not restore previous challenge group');
select is((select count(*) from public.department_office_assignments where user_id in(select actor from faith_community_fixture where n>=7)),0::bigint,'challenge choices create no department office authority');
select ok(not exists(select 1 from public.organization_memberships where user_id in(select actor from faith_community_fixture where n>=7) and role<>'member'),'challenge choices never grant executive role');
-- Prior-year consent/grouping never silently enrolls the actor into this year.
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','{}',true);
insert into public.organization_memberships(user_id,organization_id,role,status) select actor,church,'member','active' from faith_community_fixture where n=6;
select pg_temp.faith_community_actor(6);
select public.accept_faith_consent((select church from faith_community_fixture where n=6),'2026-10-14',private.faith_document_manifest()->>'content_sha256');
insert into private.faith_ranking_preferences(user_id,organization_id,service_year,opted_in,challenge_department_code) select actor,church,year-1,true,'adult' from faith_community_fixture where n=6;
select is((public.get_faith_community((select church from faith_community_fixture where n=6))->>'opted_in')::boolean,false,'new service year resets participation despite prior-year optin');
select is(public.get_faith_community((select church from faith_community_fixture where n=6))->>'challenge_department_code',null::text,'new year never inherits prior challenge department');
select is((public.get_faith_community((select church from faith_community_fixture where n=6))->>'revision')::integer,0,'new year starts fresh revision');
select ok(not has_function_privilege('anon','public.set_faith_ranking_participation(uuid,integer,boolean,text,integer,uuid,text)','execute'),'anonymous department participation mutation denied');
-- The CLI can exit zero while pgTAP reports failures. Raise on any non-plan
-- finish output so a deployment cannot mistake a red TAP result for success.
do $tap_gate$
declare lines text[];
begin
 select array_agg(line) into lines from finish() line;
 if coalesce(cardinality(lines),0)<>1 or lines[1] !~ '^1\.\.[1-9][0-9]*$' then
  raise exception 'faith_community_pgtap_failed' using detail=array_to_string(lines,E'\n');
 end if;
 perform set_config('test.faith_community_plan',lines[1],true);
end;
$tap_gate$;
select current_setting('test.faith_community_plan') as passed_plan;
rollback;
