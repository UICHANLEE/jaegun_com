-- Run in a rollback transaction. Synthetic accounts only; never records consent
-- for real people. The same test can be prefixed with the migration for preflight.
begin;
do $$
declare
  v_admin uuid := gen_random_uuid();
  v_new_user uuid := gen_random_uuid();
  v_org uuid;
  v_old jsonb;
  v_new jsonb;
  v_started timestamptz;
  v_full_ms numeric;
  v_light_ms numeric;
begin
  if has_function_privilege('anon','public.get_my_native_context()','EXECUTE') then raise exception 'anon_acl_failed'; end if;
  if not has_function_privilege('authenticated','public.get_my_native_context()','EXECUTE') then raise exception 'authenticated_acl_failed'; end if;
  if pg_get_function_identity_arguments('public.get_my_native_context()'::regprocedure) <> '' then raise exception 'actor_input_forbidden'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  begin
    perform public.get_my_native_context();
    raise exception 'anonymous_should_fail';
  exception when insufficient_privilege then null;
  end;
  insert into auth.users(id,email,raw_user_meta_data) values
    (v_admin,'native-perf-'||v_admin::text||'@example.invalid','{"display_name":"Synthetic performance fixture"}'),
    (v_new_user,'native-perf-'||v_new_user::text||'@example.invalid','{"display_name":"Synthetic no-consent fixture"}');
  insert into public.platform_admins(user_id,note) values (v_admin,'Rollback-only native performance test');
  select id into v_org from public.organizations where status='active' order by id limit 1;
  if v_org is null then raise exception 'active_organization_fixture_required'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  begin
    perform public.get_my_native_context();
    raise exception 'admin_without_consent_should_fail';
  exception when insufficient_privilege then null;
  end;
  insert into public.user_consents(user_id,document_key,document_version,accepted,source)
  select v_admin,document_key,version,true,'admin_migration'
  from public.consent_documents where required and retired_at is null
    and published_at<=statement_timestamp() and effective_at<=statement_timestamp();
  insert into public.organization_memberships(user_id,organization_id,role) values(v_admin,v_org,'member');
  v_old := public.get_my_context(); v_new := public.get_my_native_context();
  if v_new <> (v_old - 'governance_access') then raise exception 'context_equivalence_failed'; end if;
  if v_new->'profile'->>'id' <> v_admin::text or v_new->'membership'->>'organization_id' <> v_org::text
    or v_new ? 'governance_access' then raise exception 'actor_scope_projection_failed'; end if;
  v_started := clock_timestamp();
  for i in 1..3 loop perform public.get_my_context(); end loop;
  v_full_ms := extract(epoch from clock_timestamp()-v_started)*1000/3;
  v_started := clock_timestamp();
  for i in 1..3 loop perform public.get_my_native_context(); end loop;
  v_light_ms := extract(epoch from clock_timestamp()-v_started)*1000/3;
  update public.user_consents set accepted=false, withdrawn_at=clock_timestamp()
  where user_id=v_admin and document_key='privacy_policy';
  begin
    perform public.get_my_native_context();
    raise exception 'withdrawn_consent_should_fail';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub',v_new_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_new_user,'role','authenticated')::text,true);
  begin
    perform public.get_my_native_context();
    raise exception 'new_user_without_consent_should_fail';
  exception when insufficient_privilege then null;
  end;
  perform set_config('test.native_context_metrics',jsonb_build_object('checks_passed',9,
    'full_context_mean_ms',round(v_full_ms,3),'native_context_mean_ms',round(v_light_ms,3),
    'benchmark_kind','rollback_synthetic_admin_3_iterations_not_http_latency')::text,true);
end;
$$;
select current_setting('test.native_context_metrics')::jsonb as results;
rollback;
