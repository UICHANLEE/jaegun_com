-- Social authentication never supplies legal acceptance or organization authority.
-- This transaction retires, publishes and activates the five documents together;
-- historical rows and existing user IDs, memberships and approval records remain intact.
do $$
declare
  v_transition_at timestamptz;
  v_affected integer;
begin
  lock table public.consent_documents in exclusive mode;
  v_transition_at := pg_catalog.clock_timestamp();
  if (select pg_catalog.count(*) from public.consent_documents
      where required and retired_at is null) <> 5
    or (select pg_catalog.count(*) from public.consent_documents as document
        join (values
      ('privacy_policy'::text, '5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d'::text),
      ('sensitive_information'::text, 'a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b'::text),
      ('overseas_transfer'::text, '8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684'::text),
      ('terms_of_service'::text, 'ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9'::text),
      ('community_guidelines'::text, 'e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d'::text)
        ) as expected(document_key, content_sha256)
          on expected.document_key = document.document_key
         and expected.content_sha256 = document.content_sha256
        where document.version = '2026-08-30' and document.locale = 'ko-KR'
          and document.required and document.retired_at is null) <> 5 then
    raise exception 'unexpected_active_consent_contract';
  end if;
  update public.consent_documents set retired_at = v_transition_at
  where required and retired_at is null;
  get diagnostics v_affected = row_count;
  if v_affected <> 5 then
    raise exception 'consent_retirement_count_mismatch';
  end if;
  insert into public.consent_documents (
    document_key, version, locale, title, document_url, content_sha256,
    required, published_at, effective_at, retired_at
  ) values
    ('privacy_policy', '2026-10-14', 'ko-KR', '개인정보 수집·이용 동의', '/legal/privacy/2026-10-14', '67efb4d62726b98fc25ee47d35846cc22275089e3934e1a6928c1489ba4f28fb', true, v_transition_at, v_transition_at, null),
    ('sensitive_information', '2026-10-14', 'ko-KR', '종교 관련 민감정보 처리 동의', '/legal/sensitive/2026-10-14', '4435c25cb223996ce37f9b756a0477d445d157cebbb3d11e8afff945d2726664', true, v_transition_at, v_transition_at, null),
    ('overseas_transfer', '2026-10-14', 'ko-KR', '개인정보 국외 이전 동의', '/legal/overseas/2026-10-14', '0e562b7b0c18ed61684aabebb6307152f5508ca4647d01dbd27cb3d444a47d62', true, v_transition_at, v_transition_at, null),
    ('terms_of_service', '2026-10-14', 'ko-KR', '이용약관 및 만 14세 이상 확인', '/legal/terms/2026-10-14', '5e40c29280f72f98d497220030fba13333808cf90e1350411d0c905871cc7908', true, v_transition_at, v_transition_at, null),
    ('community_guidelines', '2026-10-14', 'ko-KR', '공동체 운영정책', '/legal/community/2026-10-14', '42399002842b5d3fb7d19c15ae4721deab99401d42790722f4825d9092bcd8a6', true, v_transition_at, v_transition_at, null);
end;
$$;

-- One canonical active contract shared by signup, RPC acceptance and access gates.
create function private.has_exact_current_consent_contract()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select (select pg_catalog.count(*) from public.consent_documents where required and retired_at is null) = 5
    and (select pg_catalog.count(*) from public.consent_documents as document
      join (values
        ('privacy_policy','/legal/privacy/2026-10-14','67efb4d62726b98fc25ee47d35846cc22275089e3934e1a6928c1489ba4f28fb'),
        ('sensitive_information','/legal/sensitive/2026-10-14','4435c25cb223996ce37f9b756a0477d445d157cebbb3d11e8afff945d2726664'),
        ('overseas_transfer','/legal/overseas/2026-10-14','0e562b7b0c18ed61684aabebb6307152f5508ca4647d01dbd27cb3d444a47d62'),
        ('terms_of_service','/legal/terms/2026-10-14','5e40c29280f72f98d497220030fba13333808cf90e1350411d0c905871cc7908'),
        ('community_guidelines','/legal/community/2026-10-14','42399002842b5d3fb7d19c15ae4721deab99401d42790722f4825d9092bcd8a6')
      ) as expected(document_key, document_url, content_sha256)
        on expected.document_key = document.document_key
        and expected.document_url = document.document_url
        and expected.content_sha256 = document.content_sha256
      where document.required and document.retired_at is null
        and document.version = '2026-10-14' and document.locale = 'ko-KR'
        and document.published_at <= pg_catalog.statement_timestamp()
        and document.effective_at <= pg_catalog.statement_timestamp()) = 5;
$$;
revoke all on function private.has_exact_current_consent_contract() from public, anon, authenticated;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_name text;
  v_required_consents jsonb := new.raw_user_meta_data -> 'accepted_required_consents';
  v_expected_keys text[] := array['community_guidelines','overseas_transfer','privacy_policy','sensitive_information','terms_of_service'];
begin
  v_name := coalesce(
    nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'name'), ''),
    '사용자'
  );
  insert into public.profiles (id, display_name)
  values (new.id, pg_catalog.left(v_name, 80))
  on conflict (id) do nothing;
  -- Only the email signup request can atomically record explicit nested consent.
  -- Provider comes from Auth-owned app metadata, never editable user claims.
  if new.raw_app_meta_data ->> 'provider' = 'email'
    and new.raw_user_meta_data ->> 'consent_contract' = 'required-consents-v2'
    and pg_catalog.jsonb_typeof(v_required_consents) = 'object' then
    lock table public.consent_documents in share mode;
    if private.has_exact_current_consent_contract()
      and (select pg_catalog.array_agg(key order by key)
        from pg_catalog.jsonb_object_keys(v_required_consents) as key) = v_expected_keys
      and (select pg_catalog.count(*) from public.consent_documents
           where required and retired_at is null) = 5
      and (select pg_catalog.jsonb_object_agg(document_key, version)
           from public.consent_documents where required and retired_at is null
             and locale = 'ko-KR'
             and published_at <= pg_catalog.statement_timestamp()
             and effective_at <= pg_catalog.statement_timestamp()) =
        '{"privacy_policy":"2026-10-14","sensitive_information":"2026-10-14","overseas_transfer":"2026-10-14","terms_of_service":"2026-10-14","community_guidelines":"2026-10-14"}'::jsonb
      and not exists (
        select 1 from public.consent_documents as document
        where document.required and document.retired_at is null
          and (pg_catalog.jsonb_typeof(v_required_consents -> document.document_key) is distinct from 'object'
            or v_required_consents #> array[document.document_key, 'accepted'] is distinct from 'true'::jsonb
            or v_required_consents #>> array[document.document_key, 'version'] is distinct from document.version
            or (select pg_catalog.array_agg(key order by key)
                from pg_catalog.jsonb_object_keys(case
                  when pg_catalog.jsonb_typeof(v_required_consents -> document.document_key) = 'object'
                  then v_required_consents -> document.document_key else '{}'::jsonb end) as key)
              is distinct from array['accepted','version']::text[])
      ) then
      insert into public.user_consents (user_id, document_key, document_version, accepted, source)
      select new.id, document_key, version, true, 'signup_metadata'
      from public.consent_documents where required and retired_at is null
      order by document_key;
    end if;
  end if;
  -- OAuth metadata never records consent or organization authority.
  return new;
end;
$$;
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

create or replace function private.has_current_required_consents(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  with required_documents as (
    select document.document_key, document.version, document.locale
    from public.consent_documents as document
    where document.required and document.retired_at is null
      and document.published_at <= pg_catalog.statement_timestamp()
      and document.effective_at <= pg_catalog.statement_timestamp()
  )
  select coalesce(p_user_id is not null
    and private.has_exact_current_consent_contract()
    and (select pg_catalog.count(*) from required_documents) = 5
    and (select pg_catalog.jsonb_object_agg(document_key, version)
         from required_documents) = '{"privacy_policy":"2026-10-14","sensitive_information":"2026-10-14","overseas_transfer":"2026-10-14","terms_of_service":"2026-10-14","community_guidelines":"2026-10-14"}'::jsonb
    and not exists (select 1 from required_documents where locale <> 'ko-KR')
    and not exists (
      select 1 from required_documents as document
      where not coalesce((
        select consent.accepted and consent.withdrawn_at is null
        from public.user_consents as consent
        where consent.user_id = p_user_id
          and consent.document_key = document.document_key
          and consent.document_version = document.version
        order by consent.recorded_at desc, consent.id desc limit 1
      ), false)
    ), false);
$$;
revoke all on function private.has_current_required_consents(uuid) from public, anon, authenticated;
grant execute on function private.has_current_required_consents(uuid) to authenticated, service_role;

create or replace function public.save_my_privacy_preferences_v2(
  p_required_consents jsonb,
  p_avatar_visible boolean,
  p_church_title_visible boolean,
  p_email_visible boolean,
  p_bio_visible boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_expected jsonb;
  v_document record;
  v_directory_visibility text;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  lock table public.consent_documents in share mode;

  select pg_catalog.jsonb_object_agg(document.document_key, document.version)
  into v_expected
  from public.consent_documents as document
  where document.required
    and document.retired_at is null
    and document.published_at <= pg_catalog.statement_timestamp()
    and document.effective_at <= pg_catalog.statement_timestamp();

  if pg_catalog.jsonb_typeof(p_required_consents) is distinct from 'object'
    or not private.has_exact_current_consent_contract()
    or v_expected is distinct from '{"privacy_policy":"2026-10-14","sensitive_information":"2026-10-14","overseas_transfer":"2026-10-14","terms_of_service":"2026-10-14","community_guidelines":"2026-10-14"}'::jsonb
    or (select pg_catalog.count(*) from public.consent_documents
        where required and retired_at is null) <> 5
    or (
      select pg_catalog.array_agg(key order by key)
      from pg_catalog.jsonb_object_keys(v_expected) as key
    ) <> array[
      'community_guidelines',
      'overseas_transfer',
      'privacy_policy',
      'sensitive_information',
      'terms_of_service'
    ]::text[]
    or p_required_consents is distinct from v_expected then
    raise exception 'current_required_consents_mismatch' using errcode = '23514';
  end if;

  for v_document in
    select document.document_key, document.version
    from public.consent_documents as document
    where document.required
      and document.retired_at is null
      and document.published_at <= pg_catalog.statement_timestamp()
      and document.effective_at <= pg_catalog.statement_timestamp()
    order by document.document_key
  loop
    if not coalesce(
      (
        select consent.accepted and consent.withdrawn_at is null
        from public.user_consents as consent
        where consent.user_id = v_actor_id
          and consent.document_key = v_document.document_key
          and consent.document_version = v_document.version
        order by consent.recorded_at desc, consent.id desc
        limit 1
      ),
      false
    ) then
      insert into public.user_consents (
        user_id,
        document_key,
        document_version,
        accepted,
        source
      )
      values (
        v_actor_id,
        v_document.document_key,
        v_document.version,
        true,
        'app'
      );
    end if;
  end loop;

  v_directory_visibility := case
    when coalesce(p_avatar_visible, false)
      or coalesce(p_email_visible, false)
      or coalesce(p_bio_visible, false) then 'church_profile'
    when coalesce(p_church_title_visible, false) then 'name_only'
    else 'private'
  end;

  insert into public.privacy_preferences (
    user_id,
    directory_visibility,
    analytics_opt_in,
    avatar_visible,
    church_title_visible,
    email_visible,
    bio_visible
  )
  values (
    v_actor_id,
    v_directory_visibility,
    false,
    coalesce(p_avatar_visible, false),
    coalesce(p_church_title_visible, false),
    coalesce(p_email_visible, false),
    coalesce(p_bio_visible, false)
  )
  on conflict (user_id)
  do update set
    directory_visibility = excluded.directory_visibility,
    avatar_visible = excluded.avatar_visible,
    church_title_visible = excluded.church_title_visible,
    email_visible = excluded.email_visible,
    bio_visible = excluded.bio_visible;

  insert into public.notification_preferences (user_id)
  values (v_actor_id)
  on conflict (user_id) do nothing;

  perform private.write_audit(
    v_actor_id,
    'privacy.preferences_updated',
    'profile',
    v_actor_id,
    null,
    v_actor_id,
    pg_catalog.jsonb_build_object(
      'required_document_keys', (
        select pg_catalog.jsonb_agg(key order by key)
        from pg_catalog.jsonb_object_keys(v_expected) as key
      ),
      'directory_visibility', v_directory_visibility
    )
  );

  return public.get_my_safety_privacy_state();
end;
$$;

revoke all on function public.save_my_privacy_preferences_v2(
  jsonb,
  boolean,
  boolean,
  boolean,
  boolean
) from public, anon, authenticated;
grant execute on function public.save_my_privacy_preferences_v2(
  jsonb,
  boolean,
  boolean,
  boolean,
  boolean
) to authenticated;


-- Pending applicants may set only their own user-entered name after consent.
create function public.update_my_display_name(p_display_name text)
returns text
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := private.require_current_consent_actor();
  v_name text := pg_catalog.btrim(p_display_name);
begin
  if v_name is null or pg_catalog.char_length(v_name) not between 1 and 80
    or v_name ~ '[[:cntrl:]]' then
    raise exception 'invalid_display_name' using errcode = '23514';
  end if;
  update public.profiles set display_name = v_name
  where id = v_actor_id and deactivated_at is null;
  if not found then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  return v_name;
end;
$$;
revoke all on function public.update_my_display_name(text) from public, anon, authenticated;
grant execute on function public.update_my_display_name(text) to authenticated;
