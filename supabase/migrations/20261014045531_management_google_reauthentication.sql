-- Keep existing authorization, scope, consent and audit checks intact. Only the
-- step-up evidence changes: fresh Google OAuth or an existing verified AAL2 session.
-- Timestamp matches the verified remote migration history.
create or replace function private.sensitive_action_auth_expiry()
returns timestamptz
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_claims jsonb := auth.jwt();
  v_actor uuid := auth.uid();
  v_session auth.sessions%rowtype;
  v_now timestamptz := pg_catalog.statement_timestamp();
  v_issued bigint;
  v_expiry timestamptz;
  v_amr jsonb;
  v_oauth_time bigint;
begin
  if v_actor is null or v_claims ->> 'role' is distinct from 'authenticated'
    or v_claims -> 'is_anonymous' is distinct from 'false'::jsonb
    or not coalesce((v_claims -> 'aud' = '"authenticated"'::jsonb
      or (pg_catalog.jsonb_typeof(v_claims -> 'aud') = 'array'
        and v_claims -> 'aud' @> '["authenticated"]'::jsonb)), false)
    or pg_catalog.jsonb_typeof(v_claims -> 'iat') is distinct from 'number'
    or pg_catalog.jsonb_typeof(v_claims -> 'exp') is distinct from 'number'
    or coalesce(v_claims ->> 'iat', '') !~ '^[0-9]{1,12}$'
    or coalesce(v_claims ->> 'exp', '') !~ '^[0-9]{1,12}$' then
    return null;
  end if;
  v_issued := (v_claims ->> 'iat')::bigint;
  v_expiry := pg_catalog.to_timestamp((v_claims ->> 'exp')::bigint);
  if pg_catalog.to_timestamp(v_issued) > v_now or v_expiry <= v_now then return null; end if;
  select * into v_session from auth.sessions
  where id = (v_claims ->> 'session_id')::uuid and user_id = v_actor;
  if not found or (v_session.not_after is not null and v_session.not_after <= v_now) then return null; end if;
  v_expiry := least(v_expiry, coalesce(v_session.not_after, v_expiry));
  if v_claims ->> 'aal' = 'aal2' and v_session.aal::text = 'aal2' then return v_expiry; end if;
  -- Auth-owned identities, not editable user_metadata or browser timestamps.
  -- Fail closed if another OAuth provider is linked: AMR alone does not name the provider.
  if not exists (select 1 from auth.identities where user_id = v_actor and provider = 'google')
    or exists (select 1 from auth.identities where user_id = v_actor and provider not in ('google', 'email'))
    or pg_catalog.jsonb_typeof(v_claims -> 'amr') is distinct from 'array' then return null; end if;
  for v_amr in select value from pg_catalog.jsonb_array_elements(v_claims -> 'amr') loop
    if v_amr ->> 'method' is distinct from 'oauth'
      or pg_catalog.jsonb_typeof(v_amr -> 'timestamp') is distinct from 'number'
      or coalesce(v_amr ->> 'timestamp', '') !~ '^[0-9]{1,12}$' then continue; end if;
    v_oauth_time := (v_amr ->> 'timestamp')::bigint;
    if v_oauth_time <= v_issued
      and pg_catalog.to_timestamp(v_oauth_time) <= v_now
      and pg_catalog.to_timestamp(v_oauth_time) + interval '5 minutes' > v_now
      and exists (select 1 from auth.mfa_amr_claims
        where session_id = v_session.id and authentication_method = 'oauth'
          and pg_catalog.floor(extract(epoch from updated_at))::bigint = v_oauth_time) then
      return least(v_expiry, pg_catalog.to_timestamp(v_oauth_time) + interval '5 minutes');
    end if;
  end loop;
  return null;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;
revoke all on function private.sensitive_action_auth_expiry() from public, anon, authenticated;

-- Compatibility name: all existing sensitive-operation callers automatically
-- receive the new evidence boundary without changing any role checks.
create or replace function private.require_aal2(p_operation text)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_claims_text text := pg_catalog.current_setting('request.jwt.claims', true);
  v_claims jsonb;
  v_role_setting text := pg_catalog.current_setting('role', true);
begin
  if v_claims_text is null or v_claims_text = '' then
    if v_role_setting in ('authenticated', 'anon', 'service_role') then
      if session_user in ('postgres', 'supabase_admin')
        and pg_catalog.current_setting('test.governance_service_year', true) is not null then return; end if;
      raise exception 'signed_authentication_context_required:%', p_operation using errcode = '42501';
    end if;
    if session_user not in ('postgres', 'supabase_admin') then
      raise exception 'signed_authentication_context_required:%', p_operation using errcode = '42501';
    end if;
    return;
  end if;
  begin v_claims := v_claims_text::jsonb;
  exception when invalid_text_representation then
    raise exception 'invalid_authentication_context' using errcode = '42501';
  end;
  if v_claims ->> 'role' = 'service_role' then return; end if;
  if private.sensitive_action_auth_expiry() is null then
    raise exception 'recent_google_authentication_required:%', p_operation using errcode = '42501';
  end if;
end;
$$;
revoke all on function private.require_aal2(text) from public, anon, authenticated;

create or replace function public.get_sensitive_action_auth_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare v_expiry timestamptz;
begin
  perform private.require_current_consent_actor();
  v_expiry := private.sensitive_action_auth_expiry();
  return pg_catalog.jsonb_build_object('verified', v_expiry is not null,
    'expires_at', v_expiry, 'server_now', pg_catalog.statement_timestamp());
end;
$$;
revoke all on function public.get_sensitive_action_auth_status() from public, anon, authenticated;
grant execute on function public.get_sensitive_action_auth_status() to authenticated;
