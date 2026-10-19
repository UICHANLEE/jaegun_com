-- Same actor/current-consent boundary as get_my_context(). Native entry never
-- consumes governance_access: that expensive exact-scope discovery remains in
-- the dedicated management RPC, not every entry/realtime heartbeat.
create function public.get_my_native_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_profile jsonb;
  v_membership jsonb;
  v_organization jsonb;
  v_application jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  select pg_catalog.to_jsonb(profile) into v_profile
  from public.profiles as profile where profile.id = v_actor_id;
  select pg_catalog.to_jsonb(membership), pg_catalog.to_jsonb(organization)
  into v_membership, v_organization
  from public.organization_memberships as membership
  join public.organizations as organization on organization.id = membership.organization_id
  where membership.user_id = v_actor_id
    and membership.status = 'active'::public.membership_status
  limit 1;
  select pg_catalog.to_jsonb(application) into v_application
  from public.membership_applications as application
  where application.user_id = v_actor_id
    and application.status in ('pending'::public.application_status, 'rejected'::public.application_status)
  order by application.created_at desc limit 1;
  return pg_catalog.jsonb_build_object(
    'profile', v_profile,
    'is_platform_admin', private.is_platform_admin(v_actor_id),
    'membership', v_membership,
    'organization', v_organization,
    'pending_application', case when v_application ->> 'status' = 'pending' then v_application else null end,
    'latest_application', v_application
  );
end;
$$;
revoke all on function public.get_my_native_context() from public, anon, authenticated, service_role;
grant execute on function public.get_my_native_context() to authenticated;
comment on function public.get_my_native_context() is
  'Own current-consent-gated native entry state only; governance discovery stays on its exact-scope RPC. No actor input, writes, or cached authority.';
notify pgrst, 'reload schema';
