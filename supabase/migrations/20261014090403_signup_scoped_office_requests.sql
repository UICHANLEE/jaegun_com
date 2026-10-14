-- Signup selections are requests, not assignments or app roles. All assignment
-- writes remain in the established, audited exact-scope assignment RPCs.
create table public.membership_office_requests (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.membership_applications(id) on delete cascade,
  scope_id uuid not null references public.governance_scopes(id) on delete cascade,
  department_id uuid references public.church_departments(id) on delete cascade,
  service_year integer not null check (service_year between 2000 and 2100),
  office_code text not null check (office_code in
    ('president','vice_president','general_secretary','secretary','treasurer','pastor')),
  status text not null default 'pending' check (status in ('pending','approved','rejected','withdrawn')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  review_reason text check (char_length(review_reason) <= 2000),
  created_at timestamptz not null default now(),
  check (department_id is null or office_code <> 'pastor'),
  check ((status = 'pending' and reviewed_at is null and reviewed_by is null)
    or (status <> 'pending' and reviewed_at is not null)),
  check (status <> 'rejected' or nullif(btrim(review_reason), '') is not null)
);
create unique index membership_office_request_unique_idx on public.membership_office_requests
  (application_id, scope_id, coalesce(department_id, '00000000-0000-0000-0000-000000000000'::uuid), service_year, office_code);
create index membership_office_request_scope_idx on public.membership_office_requests (scope_id, status, created_at, id);
create index membership_office_request_department_idx on public.membership_office_requests (department_id) where department_id is not null;
create index membership_office_request_reviewer_idx on public.membership_office_requests (reviewed_by) where reviewed_by is not null;
alter table public.membership_office_requests enable row level security;
revoke all on public.membership_office_requests from public, anon, authenticated;

-- Actor-bound idempotency is private and never inferred from a client profile.
create table private.membership_office_submissions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  client_request_id uuid not null,
  application_id uuid not null references public.membership_applications(id) on delete cascade,
  payload jsonb not null,
  primary key (user_id, client_request_id)
);
create index membership_office_submission_application_idx on private.membership_office_submissions (application_id);
alter table private.membership_office_submissions enable row level security;
revoke all on private.membership_office_submissions from public, anon, authenticated;

create function public.list_signup_office_options(p_organization_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare v_church public.governance_scopes%rowtype; v_result jsonb;
begin
  perform private.require_current_consent_actor();
  select scope.* into v_church from public.governance_scopes scope
  join public.organizations organization on organization.id = scope.organization_id
  where scope.organization_id = p_organization_id and scope.scope_type = 'church'
    and scope.is_active and organization.status in ('active','seeded_unclaimed');
  if not found then raise exception 'organization_not_available' using errcode = 'P0002'; end if;
  with recursive ancestors as (
    select scope.id, scope.parent_scope_id, scope.scope_type, scope.display_name, 0 as depth
    from public.governance_scopes scope where scope.id = v_church.id and scope.is_active
    union all
    select scope.id, scope.parent_scope_id, scope.scope_type, scope.display_name, child.depth + 1
    from public.governance_scopes scope join ancestors child on child.parent_scope_id = scope.id
    where scope.is_active and child.depth < 2
  ) select jsonb_build_object(
    'service_year', private.current_service_year(),
    'next_service_year', private.current_service_year() + 1,
    'scopes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'scope_type', scope_type,
      'display_name', display_name) order by depth desc), '[]'::jsonb) from ancestors),
    'departments', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'scope_id', church_scope_id,
      'department_code', department_code, 'display_name', display_name) order by sort_order), '[]'::jsonb)
      from public.church_departments where church_scope_id = v_church.id and is_active),
    'office_codes', jsonb_build_array('president','vice_president','general_secretary','secretary','treasurer','pastor'),
    'department_office_codes', jsonb_build_array('president','vice_president','general_secretary','secretary','treasurer')
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.list_signup_office_options(uuid) from public, anon, authenticated;
grant execute on function public.list_signup_office_options(uuid) to authenticated;

create function public.submit_membership_with_office_requests(
  p_organization_id uuid, p_requested_role public.app_role,
  p_client_request_id uuid,
  p_applicant_note text default null, p_requested_church_title_code text default null,
  p_requested_executive_office_codes text[] default '{}'::text[],
  p_requested_service_year integer default null,
  p_office_requests jsonb default '[]'::jsonb
) returns uuid language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_actor uuid; v_application uuid; v_options jsonb; v_item jsonb; v_scope uuid; v_department uuid;
  v_year integer; v_office text; v_payload jsonb; v_existing private.membership_office_submissions%rowtype;
begin
  v_actor := private.require_current_consent_actor();
  if p_client_request_id is null then raise exception 'client_request_id_required' using errcode = '22023'; end if;
  if p_office_requests is null or jsonb_typeof(p_office_requests) <> 'array'
    or jsonb_array_length(p_office_requests) > 36 then
    raise exception 'invalid_office_requests' using errcode = '23514';
  end if;
  v_payload := jsonb_build_object('organization_id',p_organization_id,'role',p_requested_role,
    'note',p_applicant_note,'title',p_requested_church_title_code,'legacy_offices',p_requested_executive_office_codes,
    'legacy_year',p_requested_service_year,'requests',p_office_requests);
  perform pg_advisory_xact_lock(hashtextextended('office-signup:' || v_actor::text, 0));
  select * into v_existing from private.membership_office_submissions
    where user_id = v_actor and client_request_id = p_client_request_id;
  if found then
    if v_existing.payload is distinct from v_payload then
      raise exception 'client_request_payload_mismatch' using errcode = '23514';
    end if;
    return v_existing.application_id;
  end if;
  v_options := public.list_signup_office_options(p_organization_id);
  -- Both membership and the selected requests commit together or roll back.
  v_application := public.submit_membership_application(p_organization_id, p_requested_role,
    p_applicant_note, p_requested_church_title_code, p_requested_executive_office_codes, p_requested_service_year);
  for v_item in select value from jsonb_array_elements(p_office_requests) loop
    if jsonb_typeof(v_item) <> 'object' or not (v_item ?& array['scope_id','service_year','office_code'])
      or exists (select 1 from jsonb_object_keys(v_item) key
        where key not in ('scope_id','department_id','service_year','office_code'))
      or jsonb_typeof(v_item->'scope_id') <> 'string'
      or jsonb_typeof(v_item->'service_year') <> 'number'
      or jsonb_typeof(v_item->'office_code') <> 'string' then
      raise exception 'invalid_office_request_shape' using errcode = '23514';
    end if;
    v_scope := (v_item->>'scope_id')::uuid;
    v_department := (v_item->>'department_id')::uuid;
    v_year := (v_item->>'service_year')::integer;
    v_office := v_item->>'office_code';
    if v_year not between private.current_service_year() and private.current_service_year() + 1
      or v_office not in ('president','vice_president','general_secretary','secretary','treasurer','pastor')
      or not exists (select 1 from jsonb_array_elements(v_options->'scopes') scope
        where scope->>'id' = v_scope::text) then
      raise exception 'invalid_office_request_scope_year_or_code' using errcode = '23514';
    end if;
    if v_department is not null and (v_office = 'pastor' or not exists (
      select 1 from jsonb_array_elements(v_options->'departments') department
      where department->>'id' = v_department::text and department->>'scope_id' = v_scope::text
    )) then raise exception 'invalid_office_request_department' using errcode = '23514'; end if;
    insert into public.membership_office_requests(application_id,scope_id,department_id,service_year,office_code)
      values(v_application,v_scope,v_department,v_year,v_office);
  end loop;
  insert into private.membership_office_submissions(user_id,client_request_id,application_id,payload)
    values(v_actor,p_client_request_id,v_application,v_payload);
  return v_application;
end;
$$;
revoke all on function public.submit_membership_with_office_requests(uuid,public.app_role,uuid,text,text,text[],integer,jsonb)
  from public, anon, authenticated;
grant execute on function public.submit_membership_with_office_requests(uuid,public.app_role,uuid,text,text,text[],integer,jsonb) to authenticated;

create function public.list_membership_office_requests(p_application_id uuid default null,
  p_limit integer default 100, p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare v_actor uuid; v_result jsonb;
begin
  v_actor := private.require_current_consent_actor();
  if p_limit not between 1 and 100 or p_offset not between 0 and 10000
    or p_limit is null or p_offset is null then raise exception 'invalid_pagination' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(row_data order by created_at,id), '[]'::jsonb) into v_result from (
    select request.id, request.created_at, jsonb_build_object(
      'id', request.id, 'application_id', request.application_id, 'user_id', application.user_id,
      'scope_id',request.scope_id,'scope_type',scope.scope_type,'scope_name',scope.display_name,
      'department_id',request.department_id,'department_name',department.display_name,
      'service_year',request.service_year,'office_code',request.office_code,'status',request.status,
      'membership_status',application.status,'review_reason',request.review_reason,
      'can_review', case when request.department_id is null then
        private.can_manage_governance_offices(request.scope_id,v_actor)
        else private.can_manage_department_offices(request.department_id,v_actor) end
    ) as row_data
    from public.membership_office_requests request
    join public.membership_applications application on application.id = request.application_id
    join public.governance_scopes scope on scope.id = request.scope_id
    left join public.church_departments department on department.id = request.department_id
    where (p_application_id is null or request.application_id = p_application_id)
      and (application.user_id = v_actor or (private.has_current_required_consents(application.user_id) and case when request.department_id is null then
        private.can_manage_governance_offices(request.scope_id,v_actor)
        else private.can_manage_department_offices(request.department_id,v_actor) end))
    order by request.created_at,request.id limit p_limit offset p_offset
  ) authorized;
  return v_result;
end;
$$;
revoke all on function public.list_membership_office_requests(uuid,integer,integer) from public, anon, authenticated;
grant execute on function public.list_membership_office_requests(uuid,integer,integer) to authenticated;

create function public.review_membership_office_request(p_request_id uuid,
  p_decision public.review_decision, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare v_actor uuid; v_request public.membership_office_requests%rowtype;
  v_application public.membership_applications%rowtype; v_result jsonb; v_status text; v_application_id uuid;
begin
  v_actor := private.require_current_consent_actor();
  -- Uniform failure for missing and unauthorized request identifiers.
  select application_id into v_application_id from public.membership_office_requests request
    where id = p_request_id and case when request.department_id is null then
      private.can_manage_governance_offices(request.scope_id,v_actor)
      else private.can_manage_department_offices(request.department_id,v_actor) end;
  if not found then raise exception 'office_request_review_forbidden' using errcode = '42501'; end if;
  perform private.require_aal2('membership_office_request_review');
  -- Same lock order as membership review + close trigger, avoiding deadlocks.
  select * into v_application from public.membership_applications where id = v_application_id for update;
  select * into v_request from public.membership_office_requests request where id=p_request_id
    and case when request.department_id is null then private.can_manage_governance_offices(request.scope_id,v_actor)
      else private.can_manage_department_offices(request.department_id,v_actor) end for update;
  if not found then raise exception 'office_request_review_forbidden' using errcode = '42501'; end if;
  if p_decision is null or char_length(p_reason) > 2000 then
    raise exception 'invalid_office_request_decision' using errcode = '22023'; end if;
  v_status := case p_decision when 'approve' then 'approved' else 'rejected' end;
  if v_status = 'rejected' and nullif(btrim(p_reason),'') is null then
    raise exception 'rejection_reason_required' using errcode = '23514'; end if;
  if v_request.status = v_status then return jsonb_build_object('id',v_request.id,'status',v_status,'changed',false); end if;
  if v_request.status <> 'pending' then raise exception 'office_request_already_reviewed' using errcode = '23514'; end if;
  if v_status = 'approved' then
    if v_application.status <> 'approved' or not exists (
      select 1 from public.organization_memberships membership
      join public.organizations organization on organization.id = membership.organization_id
      join public.profiles profile on profile.id = membership.user_id
      where membership.user_id = v_application.user_id and membership.organization_id = v_application.organization_id
        and membership.status = 'active' and organization.status = 'active' and profile.deactivated_at is null
    ) then raise exception 'office_request_requires_active_approved_membership' using errcode = '23514'; end if;
    perform private.require_current_consent_target(v_application.user_id);
    -- Revalidate hierarchy at review time (a church may have moved).
    if not private.scope_contains_organization(v_request.scope_id,v_application.organization_id) then
      raise exception 'office_request_scope_changed' using errcode = '23514'; end if;
    if v_request.department_id is null then
      v_result := public.assign_governance_office(v_request.scope_id,v_request.service_year,v_request.office_code,v_application.user_id);
    else
      v_result := public.assign_department_office(v_request.department_id,v_request.service_year,v_request.office_code,v_application.user_id);
    end if;
  end if;
  update public.membership_office_requests set status=v_status,reviewed_by=v_actor,
    reviewed_at=now(),review_reason=nullif(btrim(p_reason),'') where id=v_request.id;
  perform private.write_audit(v_actor,'membership_office_request.reviewed','membership_office_request',
    v_request.id,v_application.organization_id,v_application.user_id,
    jsonb_build_object('decision',p_decision,'scope_id',v_request.scope_id,'department_id',v_request.department_id,
      'service_year',v_request.service_year,'office_code',v_request.office_code));
  return jsonb_build_object('id',v_request.id,'status',v_status,'changed',true,'assignment',v_result);
end;
$$;
revoke all on function public.review_membership_office_request(uuid,public.review_decision,text) from public, anon, authenticated;
grant execute on function public.review_membership_office_request(uuid,public.review_decision,text) to authenticated;

create function private.close_office_requests_with_application()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  if new.status in ('rejected','withdrawn') and new.status is distinct from old.status then
    update public.membership_office_requests set status='withdrawn',reviewed_at=now(),reviewed_by=new.reviewed_by
      where application_id=new.id and status='pending';
  end if;
  return new;
end;
$$;
revoke all on function private.close_office_requests_with_application() from public, anon, authenticated;
create trigger membership_application_closes_office_requests after update of status
  on public.membership_applications for each row execute function private.close_office_requests_with_application();
