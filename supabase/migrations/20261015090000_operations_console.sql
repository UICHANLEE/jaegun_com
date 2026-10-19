begin;
create table private.operations_holds (
 report_id uuid primary key references public.content_reports(id), reason text not null check(length(reason) between 10 and 2000),
 actor_id uuid not null references public.profiles(id), created_at timestamptz not null default now(), released_at timestamptz
);
create table private.operations_appeals (
 id uuid primary key default gen_random_uuid(), report_id uuid not null references public.content_reports(id),
 appellant_id uuid not null references public.profiles(id), reason text not null check(length(reason) between 10 and 2000),
 status text not null default 'pending' check(status in ('pending','accepted','rejected')), decision text, created_at timestamptz not null default now(), decided_at timestamptz
);
create unique index operations_pending_appeal on private.operations_appeals(report_id,appellant_id) where status='pending';
create table private.operations_exports (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null, created_at timestamptz not null default now(),
 checksum text not null, manifest jsonb not null, verified_at timestamptz
);
-- Private tables have no client grants or policies: RPCs are the only boundary.
alter table private.operations_holds enable row level security;
alter table private.operations_appeals enable row level security;
alter table private.operations_exports enable row level security;
revoke all on private.operations_holds,private.operations_appeals,private.operations_exports from public,anon,authenticated;
create index operations_appeals_actor_created on private.operations_appeals(appellant_id,created_at desc);
create or replace function private.operations_session_is_live() returns boolean
language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 return auth.uid() is not null
 and auth.jwt()->>'role'='authenticated'
 and auth.jwt()->'is_anonymous'='false'::jsonb
 and (auth.jwt()->>'exp')::bigint > extract(epoch from statement_timestamp())
 and exists(select 1 from auth.sessions s where s.id=(auth.jwt()->>'session_id')::uuid
   and s.user_id=auth.uid() and (s.not_after is null or s.not_after>statement_timestamp()));
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end $$;
revoke all on function private.operations_session_is_live() from public,anon,authenticated;
create or replace function private.require_operations_admin() returns void language plpgsql security definer set search_path=pg_catalog as $$
begin
 if not coalesce(private.is_platform_admin(auth.uid()),false) or not private.has_current_required_consents(auth.uid()) or not coalesce(private.operations_session_is_live(),false) then raise exception 'operations_admin_required' using errcode='42501'; end if;
end $$;
create or replace function public.admin_operations_snapshot() returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare result jsonb;
begin
 perform private.require_operations_admin();
 select jsonb_build_object('collected_at',clock_timestamp(),'database_bytes',pg_database_size(current_database()),
 'organizations',(select count(*) from public.organizations),'registered_memberships',(select count(*) from public.organization_memberships),
 'posts',(select count(*) from public.posts),'open_cases',(select count(*) from public.content_reports where status in ('open','reviewing','escalated')),
 'activity',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (select organization_id,count(*) as posts_last_30_days from public.posts where created_at>=now()-interval '30 days' group by organization_id) x),
 'church_registration',(select coalesce(jsonb_agg(x),'[]') from (select organization_id,count(*) registered_memberships,count(*) filter(where status='active') active_memberships from public.organization_memberships group by organization_id) x),
 'presbytery_registration',(select coalesce(jsonb_agg(x),'[]') from (select c.parent_scope_id as presbytery_id,count(distinct c.id) churches,count(m.id) registered_memberships from public.governance_scopes c left join public.organization_memberships m on m.organization_id=c.organization_id where c.scope_type='church' group by c.parent_scope_id) x)) into result;
 perform private.write_audit(auth.uid(),'operations.snapshot_read','operations',null,null,null,'{}');
 return result;
end $$;
create or replace function public.admin_operations_cases(p_query text default '',p_status text default '',p_offset integer default 0) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
begin
 perform private.require_operations_admin();
 return jsonb_build_object('cases',(select coalesce(jsonb_agg(x),'[]') from (select id,target_type,reason_code,status,created_at,resolution_code from public.content_reports where (p_status='' or status=p_status) and (p_query='' or id::text ilike '%'||left(p_query,100)||'%' or reason_code ilike '%'||left(p_query,100)||'%') order by created_at desc,id limit 100 offset greatest(0,least(p_offset,10000))) x),
 'appeals',(select coalesce(jsonb_agg(x),'[]') from (select id,report_id,reason,status,created_at from private.operations_appeals where status='pending' order by created_at limit 100) x));
end $$;
create or replace function public.admin_operations_case(p_report_id uuid,p_reason text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare r public.content_reports%rowtype; evidence jsonb;
begin
 perform private.require_operations_admin(); perform private.require_aal2('incident_evidence');
 if p_reason is null or length(btrim(p_reason)) not between 10 and 2000 then raise exception 'investigation_reason_required'; end if;
 select * into strict r from public.content_reports where id=p_report_id;
 -- Only the evidence submitted with this report, never a conversation lookup.
 evidence:=jsonb_build_object('body',left(coalesce(r.evidence_snapshot->>'body_excerpt',r.evidence_snapshot->>'body',r.evidence_snapshot->>'display_name',''),4000),'title',left(r.evidence_snapshot->>'title',300),'target_type',r.target_type);
 perform private.write_audit(auth.uid(),'operations.evidence_accessed','content_report',r.id,r.organization_id,r.reported_user_id,jsonb_build_object('reason',p_reason,'author_fields',jsonb_build_array('id','display_name')));
 return jsonb_build_object('id',r.id,'details',r.details,'evidence',evidence,'status',r.status,'resolution_note',r.resolution_note,
 'author_reference',case when r.reported_user_id is null then null else 'case-'||left(md5(r.id::text||r.reported_user_id::text),12) end,
 'reported_author',(select jsonb_build_object('id',p.id,'display_name',p.display_name) from public.profiles p where p.id=r.reported_user_id),
 'hold',(select jsonb_build_object('reason',reason,'created_at',created_at) from private.operations_holds where report_id=r.id and released_at is null));
end $$;
create or replace function public.operations_submit_appeal(p_report_id uuid,p_reason text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare result uuid;
begin
 if not coalesce(private.operations_session_is_live(),false) or not exists(select 1 from public.content_reports where id=p_report_id and (reporter_id=auth.uid() or reported_user_id=auth.uid())) then raise exception 'appeal_not_authorized' using errcode='42501'; end if;
 if p_reason is null or length(btrim(p_reason)) not between 10 and 2000 then raise exception 'appeal_reason_required'; end if;
 perform private.consume_rate_limit(auth.uid(),'operations:appeal',5,3600);
 insert into private.operations_appeals(report_id,appellant_id,reason) values(p_report_id,auth.uid(),btrim(p_reason)) returning id into result;
 perform private.write_audit(auth.uid(),'operations.appeal_submitted','content_report',p_report_id,null,null,'{}'); return result;
end $$;
create or replace function public.admin_operations_action(p_report_id uuid,p_action text,p_reason text,p_appeal_id uuid default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
begin
 perform private.require_operations_admin(); perform private.require_aal2('incident_action');
 if p_reason is null or length(btrim(p_reason)) not between 10 and 2000 then raise exception 'decision_reason_required'; end if;
 perform 1 from public.content_reports where id=p_report_id for update; if not found then raise exception 'case_not_found'; end if;
 if p_action='hold' then
 insert into private.operations_holds(report_id,actor_id,reason) values(p_report_id,auth.uid(),p_reason) on conflict(report_id) do update set reason=excluded.reason,actor_id=excluded.actor_id,created_at=now(),released_at=null;
 elsif p_action='release_hold' then update private.operations_holds set released_at=now() where report_id=p_report_id;
 elsif p_action in ('accept_appeal','reject_appeal') then
 update private.operations_appeals set status=case when p_action='accept_appeal' then 'accepted' else 'rejected' end,decision=p_reason,decided_at=now() where id=p_appeal_id and report_id=p_report_id and status='pending';
 if not found then raise exception 'pending_appeal_not_found'; end if;
 else return public.resolve_content_report(p_report_id,p_action,p_reason); end if;
 perform private.write_audit(auth.uid(),'operations.'||p_action,'content_report',p_report_id,null,null,jsonb_build_object('reason',p_reason)); return jsonb_build_object('id',p_report_id,'action',p_action);
end $$;
create or replace function public.admin_operations_audit(p_query text default '',p_from timestamptz default null,p_to timestamptz default null,p_offset integer default 0) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare result jsonb;
begin
 perform private.require_operations_admin();
 select coalesce(jsonb_agg(x),'[]') into result from (select id,action,entity_type,entity_id,created_at,jsonb_strip_nulls(jsonb_build_object('reason',details->>'reason')) as access_context from public.audit_logs where (p_from is null or created_at>=p_from) and (p_to is null or created_at<p_to) and (p_query='' or action ilike '%'||left(p_query,100)||'%' or entity_id::text= p_query or id::text=p_query) order by created_at desc,id limit 100 offset greatest(0,least(p_offset,100000))) x;
 perform private.write_audit(auth.uid(),'operations.audit_searched','audit',null,null,null,jsonb_build_object('query',left(p_query,100)));
 return result;
end $$;
create or replace function public.admin_operations_export(p_from timestamptz,p_to timestamptz,p_reason text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare rows jsonb; manifest jsonb; checksum text; export_id uuid;
begin
 perform private.require_operations_admin(); perform private.require_aal2('audit_export');
 if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '31 days' or p_reason is null or length(btrim(p_reason)) not between 10 and 2000 then raise exception 'bounded_export_and_reason_required'; end if;
 if (select count(*) from public.audit_logs where created_at>=p_from and created_at<p_to)>10000 then raise exception 'export_too_large_narrow_range'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]') into rows from (select id,action,entity_type,entity_id,organization_id,created_at from public.audit_logs where created_at>=p_from and created_at<p_to) x;
 checksum:=encode(extensions.digest(convert_to(rows::text,'UTF8'),'sha256'),'hex');
 manifest:=jsonb_build_object('format','jaegun-audit-v1','from',p_from,'to',p_to,'count',jsonb_array_length(rows),'sha256',checksum,'canonicalization','PostgreSQL jsonb::text UTF-8','scope','redacted audit archive, not full database backup','restore_contract','Upload unchanged records for checksum verification; verification does not restore deleted database data or authorize retention deletion');
 insert into private.operations_exports(actor_id,checksum,manifest) values(auth.uid(),checksum,manifest) returning id into export_id;
 perform private.write_audit(auth.uid(),'operations.audit_exported','operations_export',export_id,null,null,jsonb_build_object('reason',p_reason,'manifest',manifest));
 return jsonb_build_object('id',export_id,'manifest',manifest,'records',rows);
end $$;
create or replace function public.admin_operations_verify_export(p_export_id uuid,p_records jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare expected text; actual text;
begin
 perform private.require_operations_admin(); perform private.require_aal2('audit_restore_verification');
 if p_records is null or jsonb_typeof(p_records)<>'array' or jsonb_array_length(p_records)>10000 or octet_length(p_records::text)>10000000 then raise exception 'invalid_archive'; end if;
 select checksum into strict expected from private.operations_exports where id=p_export_id;
 actual:=encode(extensions.digest(convert_to(p_records::text,'UTF8'),'sha256'),'hex');
 if actual<>expected then raise exception 'archive_checksum_mismatch'; end if;
 update private.operations_exports set verified_at=now() where id=p_export_id;
 perform private.write_audit(auth.uid(),'operations.archive_verified','operations_export',p_export_id,null,null,jsonb_build_object('sha256',actual));
 return jsonb_build_object('verified',true,'sha256',actual,'retention_deletion_authorized',false);
end $$;
-- Holds protect the exact submitted evidence, not entire conversations.
create or replace function private.protect_operations_evidence() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if exists(select 1 from private.operations_holds where report_id=old.id and released_at is null)
 and (tg_op='DELETE' or new.evidence_snapshot is distinct from old.evidence_snapshot) then
 raise exception 'incident_evidence_under_legal_hold' using errcode='42501';
 end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger protect_operations_evidence before update or delete on public.content_reports for each row execute function private.protect_operations_evidence();
revoke all on function private.protect_operations_evidence() from public,anon,authenticated;
create or replace function public.operations_my_reports(p_offset integer default 0) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
begin
 if not coalesce(private.operations_session_is_live(),false) then raise exception 'authentication_required' using errcode='42501'; end if;
 -- Rights/appeal self-service deliberately remains available after consent expiry.
 return (select coalesce(jsonb_agg(x),'[]') from (
 select r.id,r.target_type,r.reason_code,r.status,r.created_at,r.resolution_code,r.resolution_note,
 case when r.reporter_id=auth.uid() then 'reporter' else 'subject' end as relationship,
 (select jsonb_build_object('id',a.id,'status',a.status,'decision',a.decision,'created_at',a.created_at) from private.operations_appeals a where a.report_id=r.id and a.appellant_id=auth.uid() order by a.created_at desc limit 1) as appeal
 from public.content_reports r where r.reporter_id=auth.uid() or r.reported_user_id=auth.uid()
 order by r.created_at desc,r.id limit 100 offset greatest(0,least(p_offset,10000))) x);
end $$;
revoke all on function public.operations_my_reports(integer) from public,anon;
grant execute on function public.operations_my_reports(integer) to authenticated;
revoke all on function private.require_operations_admin() from public,anon,authenticated;
revoke all on function public.admin_operations_snapshot(),public.admin_operations_cases(text,text,integer),public.admin_operations_case(uuid,text),public.operations_submit_appeal(uuid,text),public.admin_operations_action(uuid,text,text,uuid),public.admin_operations_audit(text,timestamptz,timestamptz,integer),public.admin_operations_export(timestamptz,timestamptz,text),public.admin_operations_verify_export(uuid,jsonb) from public,anon;
grant execute on function public.admin_operations_snapshot(),public.admin_operations_cases(text,text,integer),public.admin_operations_case(uuid,text),public.operations_submit_appeal(uuid,text),public.admin_operations_action(uuid,text,text,uuid),public.admin_operations_audit(text,timestamptz,timestamptz,integer),public.admin_operations_export(timestamptz,timestamptz,text),public.admin_operations_verify_export(uuid,jsonb) to authenticated;
commit;
