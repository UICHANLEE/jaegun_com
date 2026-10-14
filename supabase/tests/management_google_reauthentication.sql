-- All synthetic Auth rows and claims disappear at rollback; no real account is changed.
begin;
do $$
declare
  v_user uuid := gen_random_uuid();
  v_session uuid := gen_random_uuid();
  v_now bigint := floor(extract(epoch from statement_timestamp()))::bigint;
  v_claims jsonb;
  v_case jsonb;
  v_case_number integer := 0;
begin
  insert into auth.users(id, email, raw_user_meta_data)
  values(v_user, v_user::text || '@reauth-regression.invalid', '{"display_name":"재인증 회귀 테스트"}');
  insert into auth.identities(provider_id,user_id,identity_data,provider)
  values(v_user::text,v_user,jsonb_build_object('sub',v_user::text),'google');
  insert into auth.sessions(id,user_id,created_at,updated_at,aal)
  values(v_session,v_user,to_timestamp(v_now),to_timestamp(v_now),'aal1');
  insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
  values(gen_random_uuid(),v_session,to_timestamp(v_now),to_timestamp(v_now),'oauth');
  v_claims := jsonb_build_object('sub',v_user,'session_id',v_session,'role','authenticated',
    'is_anonymous',false,'aud','authenticated','iat',v_now,'exp',v_now+3600,'aal','aal1',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',v_now)));
  perform set_config('request.jwt.claims',v_claims::text,true);
  if private.sensitive_action_auth_expiry() is null then raise exception 'fresh_google_rejected'; end if;
  perform private.require_aal2('regression_sensitive_operation');
  if private.sensitive_action_auth_expiry() > to_timestamp(v_now+300) then raise exception 'proof_lifetime_exceeded'; end if;

  foreach v_case in array array[
    jsonb_set(v_claims,'{amr}',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',v_now-301))),
    jsonb_set(v_claims,'{amr}',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',v_now+1))),
    jsonb_set(v_claims,'{amr}',jsonb_build_array(jsonb_build_object('method','password','timestamp',v_now))),
    jsonb_set(v_claims,'{amr}',jsonb_build_array(jsonb_build_object('timestamp',v_now))),
    v_claims - 'amr',
    jsonb_set(jsonb_set(v_claims,'{aal}','"aal2"'),'{amr}','[]'::jsonb),
    jsonb_set(v_claims,'{session_id}','"invalid-session"'),
    jsonb_set(v_claims,'{sub}',to_jsonb(gen_random_uuid())),
    jsonb_set(v_claims,'{role}','"anon"'),
    v_claims - 'role',
    v_claims - 'aud',
    jsonb_set(v_claims,'{is_anonymous}','true'),
    jsonb_set(v_claims,'{exp}',to_jsonb(v_now-1)),
    jsonb_set(v_claims,'{iat}',to_jsonb(v_now+1)),
    jsonb_set(v_claims,'{amr}',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',v_now-1)))
  ] loop
    v_case_number := v_case_number + 1;
    perform set_config('request.jwt.claims',v_case::text,true);
    if private.sensitive_action_auth_expiry() is not null then raise exception 'invalid_proof_accepted: case %', v_case_number; end if;
    begin
      perform private.require_aal2('regression_sensitive_operation');
      raise exception 'sensitive_operation_bypassed';
    exception when insufficient_privilege then null;
    end;
  end loop;
  -- Neither token refresh nor editable metadata supplies a new OAuth timestamp.
  v_case := jsonb_set(v_claims,'{amr}',jsonb_build_array(jsonb_build_object('method','token_refresh','timestamp',v_now)));
  v_case := v_case || '{"user_metadata":{"reauthenticated":true,"provider":"google"}}';
  perform set_config('request.jwt.claims',v_case::text,true);
  if private.sensitive_action_auth_expiry() is not null then raise exception 'metadata_or_refresh_bypassed'; end if;
  perform set_config('request.jwt.claims',v_claims::text,true);
  update auth.sessions set not_after=to_timestamp(v_now-1) where id=v_session;
  if private.sensitive_action_auth_expiry() is not null then raise exception 'expired_session_accepted'; end if;
  update auth.sessions set not_after=null,aal='aal2' where id=v_session;
  perform set_config('request.jwt.claims',jsonb_set(v_claims,'{aal}','"aal2"')::text,true);
  if private.sensitive_action_auth_expiry() is null then raise exception 'legacy_aal2_rejected'; end if;
  perform set_config('request.jwt.claims',v_claims::text,true);
  begin
    perform public.get_sensitive_action_auth_status();
    raise exception 'missing_consent_bypassed';
  exception when insufficient_privilege then null;
  end;
  if has_function_privilege('anon','public.get_sensitive_action_auth_status()','EXECUTE')
    or has_function_privilege('authenticated','private.sensitive_action_auth_expiry()','EXECUTE') then
    raise exception 'private_proof_or_anonymous_status_exposed';
  end if;
  update auth.identities set provider='github' where user_id=v_user and provider='google';
  if private.sensitive_action_auth_expiry() is not null then raise exception 'non_google_identity_accepted'; end if;
  update auth.identities set provider='google' where user_id=v_user and provider='github';
  insert into auth.identities(provider_id,user_id,identity_data,provider)
  values(v_user::text,v_user,jsonb_build_object('sub',v_user::text),'github');
  if private.sensitive_action_auth_expiry() is not null then raise exception 'ambiguous_oauth_provider_accepted'; end if;
end;
$$;
rollback;
select 'management_google_reauthentication: regression checks passed; fixtures rolled back' as result;
