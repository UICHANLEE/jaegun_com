begin;
create table private.audit_gateway_keys (
 key_id text primary key check(key_id ~ '^[a-zA-Z0-9_-]{1,64}$'), secret text not null check(octet_length(secret)>=32),
 source text not null check(length(source) between 1 and 120), legal_approval_reference text not null check(length(legal_approval_reference) between 10 and 500), enabled boolean not null default false
);
create table private.audit_gateway_nonces (request_id uuid primary key, received_at timestamptz not null default clock_timestamp(), transaction_id bigint not null default txid_current());
create table private.audit_provenance (
 audit_id uuid primary key references public.audit_logs(id) on delete restrict,
 status text not null check(status in ('verified','unavailable')), source text not null,
 client_ip inet, request_id uuid, captured_at timestamptz not null default clock_timestamp(),
 check((status='verified' and client_ip is not null and request_id is not null) or (status='unavailable' and client_ip is null))
);
alter table private.audit_gateway_keys enable row level security;
alter table private.audit_gateway_nonces enable row level security;
alter table private.audit_provenance enable row level security;
revoke all on private.audit_gateway_keys,private.audit_gateway_nonces,private.audit_provenance from public,anon,authenticated;
create or replace function public.configure_audit_gateway(p_key_id text,p_secret text,p_source text,p_legal_approval_reference text,p_enabled boolean default false) returns void language plpgsql security definer set search_path=pg_catalog as $$
begin
 perform private.require_service_role('configure_audit_gateway');
 insert into private.audit_gateway_keys values(p_key_id,p_secret,p_source,p_legal_approval_reference,p_enabled)
 on conflict(key_id) do update set secret=excluded.secret,source=excluded.source,legal_approval_reference=excluded.legal_approval_reference,enabled=excluded.enabled;
end $$;
revoke all on function public.configure_audit_gateway(text,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.configure_audit_gateway(text,text,text,text,boolean) to service_role;
create or replace function public.audit_gateway_session_context() returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 if auth.uid() is null or auth.jwt()->>'role' is distinct from 'authenticated'
 or not exists(select 1 from auth.sessions s where s.id=(auth.jwt()->>'session_id')::uuid and s.user_id=auth.uid() and (s.not_after is null or s.not_after>statement_timestamp())) then
 raise exception 'live_session_required' using errcode='42501'; end if;
 return jsonb_build_object('actor_id',auth.uid(),'session_id',auth.jwt()->>'session_id');
exception when invalid_text_representation then raise exception 'live_session_required' using errcode='42501';
end $$;
revoke all on function public.audit_gateway_session_context() from public,anon;
grant execute on function public.audit_gateway_session_context() to authenticated;
create or replace function private.capture_audit_provenance(p_audit_id uuid) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare h jsonb; k private.audit_gateway_keys%rowtype; ip inet; stamp bigint; request_id uuid; payload text; signature text; status_reason text:='gateway_envelope_missing';
begin
 begin
 h:=nullif(current_setting('request.headers',true),'')::jsonb;
 if h->>'x-jaegun-audit-key' is not null then
 status_reason:='gateway_envelope_invalid';
 select * into k from private.audit_gateway_keys where key_id=h->>'x-jaegun-audit-key' and enabled;
 if found and auth.uid() is not null and coalesce(auth.jwt()->>'session_id','')<>''
 and exists(select 1 from auth.sessions s where s.id=(auth.jwt()->>'session_id')::uuid and s.user_id=auth.uid() and (s.not_after is null or s.not_after>clock_timestamp()))
 and h->>'x-jaegun-audit-time' ~ '^[0-9]{10,12}$' and h->>'x-jaegun-audit-signature' ~ '^[0-9a-f]{64}$'
 and length(h->>'x-jaegun-audit-ip')<=64 and h->>'x-jaegun-audit-ip' not like '%/%' then
 stamp:=(h->>'x-jaegun-audit-time')::bigint; ip:=(h->>'x-jaegun-audit-ip')::inet; request_id:=(h->>'x-jaegun-audit-request')::uuid;
 if abs(extract(epoch from clock_timestamp())-stamp)<=60 and current_setting('request.method',true)='POST' and current_setting('request.path',true) like '/rpc/%' then
 payload:='jaegun-audit-v1'||chr(10)||auth.uid()::text||chr(10)||(auth.jwt()->>'session_id')||chr(10)||current_setting('request.method',true)||chr(10)||current_setting('request.path',true)||chr(10)||(h->>'x-jaegun-audit-ip')||chr(10)||stamp::text||chr(10)||request_id::text;
 signature:=encode(extensions.hmac(convert_to(payload,'UTF8'),convert_to(k.secret,'UTF8'),'sha256'),'hex');
 if signature=h->>'x-jaegun-audit-signature' then
 insert into private.audit_gateway_nonces(request_id) values(request_id) on conflict do nothing;
 -- Multiple audit writes inside one PostgREST transaction share the verified envelope;
 -- reuse from another HTTP transaction is rejected.
 if found or exists(select 1 from private.audit_gateway_nonces n where n.request_id=(h->>'x-jaegun-audit-request')::uuid and n.transaction_id=txid_current()) then
 insert into private.audit_provenance(audit_id,status,source,client_ip,request_id) values(p_audit_id,'verified',k.source,ip,request_id); return;
 else status_reason:='gateway_envelope_replayed'; end if;
 end if;
 end if;
 end if;
 end if;
 exception when invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then status_reason:='gateway_envelope_invalid';
 end;
 insert into private.audit_provenance(audit_id,status,source) values(p_audit_id,'unavailable',status_reason);
end $$;
revoke all on function private.capture_audit_provenance(uuid) from public,anon,authenticated;
create or replace function private.write_audit(p_actor_id uuid,p_action text,p_entity_type text,p_entity_id uuid,p_organization_id uuid,p_target_user_id uuid,p_details jsonb default '{}'::jsonb) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare audit_id uuid;
begin
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,organization_id,target_user_id,details)
 values(p_actor_id,p_action,p_entity_type,p_entity_id,p_organization_id,p_target_user_id,coalesce(p_details,'{}')) returning id into audit_id;
 perform private.capture_audit_provenance(audit_id);
end $$;
revoke all on function private.write_audit(uuid,text,text,uuid,uuid,uuid,jsonb) from public,anon,authenticated;
create or replace function public.admin_operations_audit_provenance(p_audit_id uuid,p_reason text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare result jsonb;
begin
 perform private.require_operations_admin(); perform private.require_aal2('audit_provenance_investigation');
 if p_reason is null or length(btrim(p_reason)) not between 10 and 2000 then raise exception 'investigation_reason_required'; end if;
 perform 1 from public.audit_logs where id=p_audit_id; if not found then raise exception 'audit_not_found' using errcode='P0002'; end if;
 -- Content provenance requires the exact reported item, never arbitrary DM or anonymous tracking.
 if exists(select 1 from public.audit_logs a where a.id=p_audit_id and
 (a.entity_type in ('post','comment','message','channel_message','conversation') or a.action like 'community.post_%')
 and not exists(select 1 from public.content_reports r where r.target_type=a.entity_type and r.target_id=a.entity_id)) then
 raise exception 'reported_incident_required_for_content_provenance' using errcode='42501';
 end if;
 if exists(select 1 from public.audit_logs a where a.id=p_audit_id and (a.entity_type like 'faith%' or a.action like 'faith.%')) then
 raise exception 'private_faith_provenance_not_available_to_admin' using errcode='42501';
 end if;
 select jsonb_build_object('status',status,'source',source,'client_ip',host(client_ip),'request_id',request_id,'captured_at',captured_at) into result from private.audit_provenance where audit_id=p_audit_id;
 perform private.write_audit(auth.uid(),'operations.audit_provenance_accessed','audit',p_audit_id,null,null,jsonb_build_object('reason',p_reason));
 return coalesce(result,jsonb_build_object('status','unavailable','source','historical_record_without_verified_provenance'));
end $$;
revoke all on function public.admin_operations_audit_provenance(uuid,text) from public,anon;
grant execute on function public.admin_operations_audit_provenance(uuid,text) to authenticated;
commit;
