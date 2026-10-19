-- Union departments deliberately do not extend governance_scope_type: their
-- membership and offices never participate in base-role or hierarchy authority.
create table private.union_departments (
 id uuid primary key, boundary_scope_id uuid not null references public.governance_scopes(id),
 display_name text not null check (char_length(btrim(display_name)) between 1 and 120),
 revision bigint not null default 1, is_active boolean not null default true,
 created_at timestamptz not null default now()
);
create table private.union_department_members (
 department_id uuid not null references private.union_departments(id),
 user_id uuid not null references public.profiles(id) on delete cascade,
 joined_at timestamptz not null default now(), ended_at timestamptz,
 primary key(department_id,user_id)
);
create table private.union_department_offices (
 id uuid primary key default gen_random_uuid(), department_id uuid not null references private.union_departments(id),
 user_id uuid not null references public.profiles(id) on delete cascade, service_year integer not null check(service_year between 2000 and 2100),
 office_code text not null check(office_code in ('president','vice_president','general_secretary','secretary','treasurer')),
 assigned_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(), ended_at timestamptz
);
create unique index union_department_office_holder on private.union_department_offices(department_id,service_year,office_code) where ended_at is null;
create table private.union_department_delegations (
 id uuid primary key, department_id uuid not null references private.union_departments(id),
 grantor_user_id uuid not null references public.profiles(id) on delete cascade, delegate_user_id uuid not null references public.profiles(id) on delete cascade,
 starts_at timestamptz not null default now(), expires_at timestamptz not null,
 reason text not null check(char_length(btrim(reason)) between 1 and 500), revoked_at timestamptz,
 check(grantor_user_id<>delegate_user_id), check(expires_at>starts_at and expires_at<=starts_at+interval '90 days')
);
create table private.governance_mutation_receipts (
 actor_id uuid not null references public.profiles(id) on delete cascade, request_id uuid not null, payload jsonb not null,
 result jsonb not null, primary key(actor_id,request_id)
);
alter table private.union_departments enable row level security;
alter table private.union_department_members enable row level security;
alter table private.union_department_offices enable row level security;
alter table private.union_department_delegations enable row level security;
alter table private.governance_mutation_receipts enable row level security;
revoke all on private.union_departments,private.union_department_members,private.union_department_offices,private.union_department_delegations,private.governance_mutation_receipts from public,anon,authenticated;

create function private.union_member(p_department_id uuid,p_user_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.has_current_required_consents(p_user_id) and exists(
 select 1 from private.union_department_members m join private.union_departments d on d.id=m.department_id
 where d.id=p_department_id and d.is_active and m.user_id=p_user_id and m.ended_at is null
 and private.is_user_active_in_governance_scope(d.boundary_scope_id,p_user_id));
$$;
create function private.union_native_manager(p_department_id uuid,p_user_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.is_platform_admin(p_user_id) or (private.union_member(p_department_id,p_user_id) and exists(
 select 1 from private.union_department_offices o where o.department_id=p_department_id and o.user_id=p_user_id
 and o.service_year=private.current_service_year() and o.office_code='president' and o.ended_at is null));
$$;
create function private.union_manager(p_department_id uuid,p_user_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select private.union_native_manager(p_department_id,p_user_id) or (private.union_member(p_department_id,p_user_id) and exists(
 select 1 from private.union_department_delegations d where d.department_id=p_department_id and d.delegate_user_id=p_user_id
 and d.revoked_at is null and d.starts_at<=statement_timestamp() and d.expires_at>statement_timestamp()
 and extract(year from d.starts_at at time zone 'Asia/Seoul')=private.current_service_year()
 and private.union_native_manager(p_department_id,d.grantor_user_id)));
$$;
revoke all on function private.union_member(uuid,uuid),private.union_native_manager(uuid,uuid),private.union_manager(uuid,uuid) from public,anon,authenticated;

create function public.get_union_departments() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb;
begin
 select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('boundary_name',s.display_name,
 'can_manage',private.union_manager(d.id,actor),'can_delegate',private.union_native_manager(d.id,actor)) order by d.display_name),'[]') into result
 from private.union_departments d join public.governance_scopes s on s.id=d.boundary_scope_id
 where private.is_platform_admin(actor) or private.union_member(d.id,actor);
 return result;
end; $$;

create function public.get_union_department_detail(p_department_id uuid,p_service_year integer default null) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb; year integer:=coalesce(p_service_year,private.current_service_year());
begin
 if not (private.is_platform_admin(actor) or private.union_member(p_department_id,actor)) then raise exception 'union_membership_required' using errcode='42501'; end if;
 select jsonb_build_object('members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'display_name',p.display_name,'ended_at',m.ended_at) order by p.display_name)
 from private.union_department_members m join public.profiles p on p.id=m.user_id
 where m.department_id=p_department_id and m.ended_at is null and private.union_member(p_department_id,m.user_id)),'[]'),
 'offices',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('display_name',p.display_name) order by o.created_at desc)
 from private.union_department_offices o join public.profiles p on p.id=o.user_id where o.department_id=p_department_id and o.service_year=year),'[]'),
 'delegations',case when private.union_native_manager(p_department_id,actor) then coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object('display_name',p.display_name) order by d.starts_at desc)
 from private.union_department_delegations d join public.profiles p on p.id=d.delegate_user_id where d.department_id=p_department_id),'[]') else '[]'::jsonb end) into result;
 return result;
end; $$;

-- Revision + actor-bound request receipts make retries safe, including creates.
create function public.mutate_union_department(p_request_id uuid,p_department_id uuid,p_expected_revision bigint,p_action text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); d private.union_departments%rowtype; receipt private.governance_mutation_receipts%rowtype;
 payload jsonb:=jsonb_build_object('department',p_department_id,'revision',p_expected_revision,'action',p_action,'payload',p_payload);
 target uuid; yr integer; code text; expires timestamptz; result jsonb; native boolean;
begin
 perform private.require_aal2('union_department_management');
 if p_request_id is null or p_department_id is null or p_payload is null then raise exception 'invalid_union_request' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text||p_request_id::text,0));
 select * into receipt from private.governance_mutation_receipts where actor_id=actor and request_id=p_request_id;
 if found then if receipt.payload<>payload then raise exception 'request_payload_conflict' using errcode='23505'; end if; return receipt.result; end if;
 select * into d from private.union_departments where id=p_department_id for update;
 if p_action='create' then
  if not private.is_platform_admin(actor) then raise exception 'platform_admin_required' using errcode='42501'; end if;
  if found or p_expected_revision is not null then raise exception 'union_revision_conflict' using errcode='40001'; end if;
  if not exists(select 1 from public.governance_scopes where id=(p_payload->>'boundary_scope_id')::uuid and scope_type in ('general_assembly','presbytery') and is_active) then raise exception 'invalid_union_boundary' using errcode='23514'; end if;
  insert into private.union_departments(id,boundary_scope_id,display_name) values(p_department_id,(p_payload->>'boundary_scope_id')::uuid,btrim(p_payload->>'display_name')) returning * into d;
 else
  if not found or d.revision is distinct from p_expected_revision then raise exception 'union_revision_conflict' using errcode='40001'; end if;
  if not private.union_manager(d.id,actor) then raise exception 'union_management_forbidden' using errcode='42501'; end if;
  native:=private.union_native_manager(d.id,actor);
  if p_action='rename' then
   if not private.is_platform_admin(actor) then raise exception 'platform_admin_required' using errcode='42501'; end if;
   update private.union_departments set display_name=btrim(p_payload->>'display_name') where id=d.id;
  elsif p_action in ('add_member','remove_member') then
   if not native then raise exception 'union_native_authority_required' using errcode='42501'; end if;
   target:=(p_payload->>'user_id')::uuid;
   if target is null then raise exception 'union_target_required' using errcode='22023'; end if;
   if p_action='add_member' then
    perform private.require_current_consent_target(target);
    if not private.is_user_active_in_governance_scope(d.boundary_scope_id,target) then raise exception 'union_target_outside_boundary' using errcode='23514'; end if;
    insert into private.union_department_members(department_id,user_id) values(d.id,target) on conflict(department_id,user_id) do update set ended_at=null,joined_at=now();
   else
    update private.union_department_members set ended_at=now() where department_id=d.id and user_id=target and ended_at is null;
    update private.union_department_offices set ended_at=now() where department_id=d.id and user_id=target and ended_at is null;
    update private.union_department_delegations set revoked_at=now() where department_id=d.id and (delegate_user_id=target or grantor_user_id=target) and revoked_at is null;
   end if;
  elsif p_action in ('assign_office','clear_office') then
   yr:=(p_payload->>'service_year')::integer; code:=p_payload->>'office_code';
   if yr is null or code is null or yr not in (private.current_service_year(),private.current_service_year()+1) or code not in ('president','vice_president','general_secretary','secretary','treasurer') then raise exception 'invalid_union_office_year' using errcode='23514'; end if;
   if not native and (code='president' or exists(select 1 from private.union_department_offices where department_id=d.id and user_id=(p_payload->>'user_id')::uuid and service_year=yr and ended_at is null and office_code='president')) then raise exception 'delegated_authority_change_forbidden' using errcode='42501'; end if;
   if p_action='assign_office' then
    target:=(p_payload->>'user_id')::uuid;
    if not private.union_member(d.id,target) or (not native and target=actor) then raise exception 'union_active_member_required' using errcode='42501'; end if;
   end if;
   update private.union_department_offices set ended_at=now() where department_id=d.id and service_year=yr and office_code=code and ended_at is null;
   if p_action='assign_office' then insert into private.union_department_offices(department_id,user_id,service_year,office_code,assigned_by) values(d.id,target,yr,code,actor); end if;
  elsif p_action='delegate' then
   if not native then raise exception 'union_native_authority_required' using errcode='42501'; end if;
   target:=(p_payload->>'user_id')::uuid; expires:=(p_payload->>'expires_at')::timestamptz;
   if target=actor or not private.union_member(d.id,target) then raise exception 'union_delegation_target_forbidden' using errcode='42501'; end if;
   if expires is null or expires<=now() or expires>now()+interval '90 days' or expires>make_timestamptz(private.current_service_year()+1,1,1,0,0,0,'Asia/Seoul') then raise exception 'invalid_union_delegation_expiry' using errcode='23514'; end if;
   insert into private.union_department_delegations(id,department_id,grantor_user_id,delegate_user_id,expires_at,reason) values(p_request_id,d.id,actor,target,expires,btrim(p_payload->>'reason'));
  elsif p_action='revoke_delegation' then
   if not native or nullif(btrim(p_payload->>'reason'),'') is null then raise exception 'union_revocation_forbidden' using errcode='42501'; end if;
   update private.union_department_delegations set revoked_at=coalesce(revoked_at,now()) where id=(p_payload->>'delegation_id')::uuid and department_id=d.id;
  else raise exception 'invalid_union_action' using errcode='22023'; end if;
  update private.union_departments set revision=revision+1 where id=d.id returning * into d;
 end if;
 result:=to_jsonb(d);
 perform private.write_audit(actor,'union_department.'||p_action,'union_department',d.id,null,target,p_payload||jsonb_build_object('revision',d.revision));
 insert into private.governance_mutation_receipts values(actor,p_request_id,payload,result);
 return result;
end; $$;

create function public.list_governance_office_history(p_scope_id uuid,p_service_year integer,p_department_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb;
begin
 if not private.can_view_governance_roster(p_scope_id,actor) then raise exception 'scope_roster_forbidden' using errcode='42501'; end if;
 if p_department_id is null then
 select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('display_name',p.display_name) order by a.created_at desc),'[]') into result
 from public.governance_office_assignments a join public.profiles p on p.id=a.user_id where a.scope_id=p_scope_id and a.service_year=p_service_year;
 else
 if not exists(select 1 from public.church_departments where id=p_department_id and church_scope_id=p_scope_id) then raise exception 'department_scope_mismatch' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('display_name',p.display_name) order by a.created_at desc),'[]') into result
 from public.department_office_assignments a join public.profiles p on p.id=a.user_id where a.department_id=p_department_id and a.service_year=p_service_year;
 end if;
 return result;
end; $$;

create function public.save_governance_organization(p_request_id uuid,p_scope_id uuid,p_expected_updated_at timestamptz,p_scope_type text,p_parent_scope_id uuid,p_slug text,p_display_name text,p_is_active boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); s public.governance_scopes%rowtype; parent public.governance_scopes%rowtype;
 payload jsonb:=jsonb_build_array(p_scope_id,p_expected_updated_at,p_scope_type,p_parent_scope_id,p_slug,p_display_name,p_is_active); r private.governance_mutation_receipts%rowtype; org uuid; result jsonb;
begin
 if not private.is_platform_admin(actor) then raise exception 'platform_admin_required' using errcode='42501'; end if;
 perform private.require_aal2('organization_management');
 if p_request_id is null or p_scope_id is null or nullif(btrim(p_display_name),'') is null or char_length(p_display_name)>120 or p_is_active is null then raise exception 'invalid_organization_request' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text||p_request_id::text,0));
 select * into r from private.governance_mutation_receipts where actor_id=actor and request_id=p_request_id;
 if found then if r.payload<>payload then raise exception 'request_payload_conflict' using errcode='23505'; end if; return r.result; end if;
 select * into s from public.governance_scopes where id=p_scope_id for update;
 if found then
  if s.updated_at is distinct from p_expected_updated_at then raise exception 'organization_revision_conflict' using errcode='40001'; end if;
  if s.scope_type::text<>p_scope_type or s.parent_scope_id is distinct from p_parent_scope_id or s.slug<>p_slug then raise exception 'organization_reparent_forbidden' using errcode='22023'; end if;
  if s.scope_type='presbytery' and s.legacy_presbytery_name is distinct from btrim(p_display_name) then
   update public.governance_scopes set legacy_presbytery_name=btrim(p_display_name) where id=s.id;
   update public.organizations set presbytery=btrim(p_display_name)
   where id in(select organization_id from public.governance_scopes where parent_scope_id=s.id and scope_type='church');
  end if;
  if s.organization_id is not null then
   update public.organizations set display_name=btrim(p_display_name),status=case when p_is_active then 'active'::public.organization_status else 'suspended'::public.organization_status end where id=s.organization_id;
  end if;
  update public.governance_scopes set display_name=btrim(p_display_name),is_active=p_is_active,updated_at=clock_timestamp() where id=s.id returning * into s;
 else
  if p_expected_updated_at is not null or p_scope_type not in ('presbytery','church') or not p_is_active then raise exception 'invalid_organization_create' using errcode='22023'; end if;
  select * into parent from public.governance_scopes where id=p_parent_scope_id and is_active;
  if not found or (p_scope_type='presbytery' and parent.scope_type<>'general_assembly') or (p_scope_type='church' and parent.scope_type<>'presbytery') then raise exception 'invalid_organization_parent' using errcode='23514'; end if;
  if p_scope_type='church' then
   org:=p_scope_id;
   insert into public.organizations(id,slug,source_name,display_name,presbytery,status) values(org,p_slug,btrim(p_display_name),btrim(p_display_name),parent.legacy_presbytery_name,'active');
   select * into s from public.governance_scopes where organization_id=org;
  else
   insert into public.governance_scopes(id,scope_type,slug,display_name,parent_scope_id,legacy_presbytery_name) values(p_scope_id,'presbytery',p_slug,btrim(p_display_name),parent.id,btrim(p_display_name)) returning * into s;
  end if;
 end if;
 result:=to_jsonb(s);
 perform private.write_audit(actor,'organization.managed','governance_scope',s.id,s.organization_id,null,jsonb_build_object('display_name',s.display_name,'is_active',s.is_active));
 insert into private.governance_mutation_receipts values(actor,p_request_id,payload,result);
 return result;
end; $$;

create function public.get_governance_management_scopes() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb;
begin
 select coalesce(jsonb_agg(to_jsonb(s) order by s.scope_type,s.display_name),'[]') into result from public.governance_scopes s
 where private.is_platform_admin(actor) or private.can_view_governance_roster(s.id,actor);
 return result;
end; $$;
revoke all on function public.get_union_departments(),public.get_union_department_detail(uuid,integer),public.mutate_union_department(uuid,uuid,bigint,text,jsonb),public.list_governance_office_history(uuid,integer,uuid),public.save_governance_organization(uuid,uuid,timestamptz,text,uuid,text,text,boolean),public.get_governance_management_scopes() from public,anon;
grant execute on function public.get_union_departments(),public.get_union_department_detail(uuid,integer),public.mutate_union_department(uuid,uuid,bigint,text,jsonb),public.list_governance_office_history(uuid,integer,uuid),public.save_governance_organization(uuid,uuid,timestamptz,text,uuid,text,text,boolean),public.get_governance_management_scopes() to authenticated;
comment on function public.get_union_departments() is 'Explicit union membership only; no executive role, hierarchy authority or signup office changes.';

create function public.list_union_department_candidates(p_department_id uuid,p_search text default '',p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); boundary uuid; result jsonb;
begin
 if not private.union_native_manager(p_department_id,actor) then raise exception 'union_native_authority_required' using errcode='42501'; end if;
 select boundary_scope_id into boundary from private.union_departments where id=p_department_id;
 select coalesce(jsonb_agg(to_jsonb(candidate)),'[]') into result from (
 select p.id as user_id,p.display_name,o.display_name as organization_name from public.profiles p
 join public.organization_memberships m on m.user_id=p.id join public.organizations o on o.id=m.organization_id
 where m.status='active' and o.status='active' and p.deactivated_at is null
 and private.has_current_required_consents(p.id) and private.scope_contains_organization(boundary,o.id)
 and (coalesce(p_search,'')='' or p.display_name ilike '%'||left(p_search,80)||'%' or o.display_name ilike '%'||left(p_search,80)||'%')
 order by p.display_name,p.id limit 30 offset greatest(0,least(coalesce(p_offset,0),100000))) candidate;
 return result;
end; $$;
revoke all on function public.list_union_department_candidates(uuid,text,integer) from public,anon;
grant execute on function public.list_union_department_candidates(uuid,text,integer) to authenticated;

-- Compare the holder displayed by the client under the original RPC lock.
-- A lost response can be safely acknowledged with the same actor-bound request.
create function public.mutate_governance_office(p_request_id uuid,p_scope_id uuid,p_department_id uuid,p_service_year integer,p_office_code text,p_user_id uuid,p_expected_user_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); current_holder uuid; actual_scope uuid:=p_scope_id;
 payload jsonb:=jsonb_build_array(p_scope_id,p_department_id,p_service_year,p_office_code,p_user_id,p_expected_user_id);
 receipt private.governance_mutation_receipts%rowtype; result jsonb;
begin
 perform private.require_aal2('governance_office_management');
 if p_request_id is null or p_service_year is null or p_office_code is null then raise exception 'invalid_office_request' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text||p_request_id::text,0));
 select * into receipt from private.governance_mutation_receipts where actor_id=actor and request_id=p_request_id;
 if found then if receipt.payload<>payload then raise exception 'request_payload_conflict' using errcode='23505'; end if; return receipt.result; end if;
 if p_department_id is null then
  if not private.can_manage_governance_offices(actual_scope,actor) then raise exception 'governance_office_management_forbidden' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('governance-office:'||actual_scope::text||':'||p_service_year::text,0));
  select user_id into current_holder from public.governance_office_assignments where scope_id=actual_scope and service_year=p_service_year and office_code=p_office_code and ended_at is null;
 else
  select church_scope_id into actual_scope from public.church_departments where id=p_department_id;
  if actual_scope is null or (p_scope_id is not null and actual_scope<>p_scope_id) or not private.can_manage_department_offices(p_department_id,actor) then raise exception 'department_office_management_forbidden' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('department-office:'||p_department_id::text||':'||p_service_year::text||':'||p_office_code,0));
  select user_id into current_holder from public.department_office_assignments where department_id=p_department_id and service_year=p_service_year and office_code=p_office_code and ended_at is null;
 end if;
 if current_holder is distinct from p_expected_user_id then raise exception 'office_holder_changed_reload_required' using errcode='40001'; end if;
 if p_department_id is null then
  if p_user_id is null then result:=public.clear_governance_office(actual_scope,p_service_year,p_office_code);
  else result:=public.assign_governance_office(actual_scope,p_service_year,p_office_code,p_user_id); end if;
 else
  if p_user_id is null then result:=public.clear_department_office(p_department_id,p_service_year,p_office_code);
  else result:=public.assign_department_office(p_department_id,p_service_year,p_office_code,p_user_id); end if;
 end if;
 insert into private.governance_mutation_receipts values(actor,p_request_id,payload,result);
 return result;
end; $$;
revoke all on function public.mutate_governance_office(uuid,uuid,uuid,integer,text,uuid,uuid) from public,anon;
grant execute on function public.mutate_governance_office(uuid,uuid,uuid,integer,text,uuid,uuid) to authenticated;

-- Suspension or a membership move permanently ends union grants. Reactivation
-- requires explicit membership/office/delegation assignment, never resurrection.
create function private.freeze_ineligible_union_memberships() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
declare targets uuid[];
begin
 if tg_table_name='organization_memberships' then
  targets:=array[old.user_id];
 elsif tg_table_name='profiles' then
  targets:=array[new.id];
 elsif tg_table_name='organizations' then
  select array_agg(user_id) into targets from public.organization_memberships where organization_id=new.id;
 else
  select array_agg(distinct m.user_id) into targets from private.union_department_members m
  join private.union_departments d on d.id=m.department_id
  where m.ended_at is null and not private.is_user_active_in_governance_scope(d.boundary_scope_id,m.user_id);
 end if;
 update private.union_department_members m set ended_at=coalesce(m.ended_at,clock_timestamp())
 from private.union_departments d where d.id=m.department_id and m.user_id=any(targets)
 and m.ended_at is null and not private.is_user_active_in_governance_scope(d.boundary_scope_id,m.user_id);
 update private.union_department_offices o set ended_at=clock_timestamp()
 where o.user_id=any(targets) and o.ended_at is null and exists(
 select 1 from private.union_department_members m where m.department_id=o.department_id and m.user_id=o.user_id and m.ended_at is not null);
 update private.union_department_delegations g set revoked_at=clock_timestamp()
 where g.revoked_at is null and (g.grantor_user_id=any(targets) or g.delegate_user_id=any(targets)) and exists(
 select 1 from private.union_department_members m where m.department_id=g.department_id
 and m.user_id in (g.grantor_user_id,g.delegate_user_id) and m.ended_at is not null);
 return null;
end; $$;
revoke all on function private.freeze_ineligible_union_memberships() from public,anon,authenticated;
create trigger union_membership_freeze after update of status,organization_id or delete on public.organization_memberships
for each row execute function private.freeze_ineligible_union_memberships();
create trigger union_profile_freeze after update of deactivated_at on public.profiles
for each row when(old.deactivated_at is null and new.deactivated_at is not null) execute function private.freeze_ineligible_union_memberships();
create trigger union_organization_freeze after update of status on public.organizations
for each row when(old.status is distinct from new.status) execute function private.freeze_ineligible_union_memberships();
create trigger union_boundary_freeze after update of is_active on public.governance_scopes
for each row when(old.is_active and not new.is_active) execute function private.freeze_ineligible_union_memberships();
