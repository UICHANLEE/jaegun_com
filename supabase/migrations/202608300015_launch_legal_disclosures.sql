-- Five independent launch consents, immutable historical versions, and a
-- database-enforced current-consent boundary for every protected capability.

alter table public.consent_documents
  drop constraint consent_documents_document_key_check;

alter table public.consent_documents
  add constraint consent_documents_document_key_check check (
    document_key in (
      'privacy_policy',
      'sensitive_information',
      'overseas_transfer',
      'terms_of_service',
      'community_guidelines'
    )
  );

do $$
declare
  v_transition_at timestamptz := pg_catalog.clock_timestamp();
  v_affected integer;
begin
  if (
    select pg_catalog.count(*)
    from public.consent_documents as document
    where document.locale = 'ko-KR'
      and document.required
      and document.retired_at is null
  ) <> 2 then
    raise exception 'unexpected_legacy_active_consent_count';
  end if;

  if (
    select pg_catalog.count(*)
    from public.consent_documents as document
    join (
      values
        (
          'privacy_policy'::text,
          '2026-08-27'::text,
          '개인정보 처리방침'::text,
          '/legal/privacy/2026-08-27'::text,
          '2eeac1f3dbaa45d8b2742aa9239aedf2507d67c02b397a6ac362ef20d9a2f829'::text
        ),
        (
          'community_guidelines'::text,
          '2026-08-27'::text,
          '공동체 이용규칙'::text,
          '/legal/community/2026-08-27'::text,
          'c587eae93255d82391ddd287a1737679f9a2823e598dd091fa4cb819eed3c59f'::text
        )
    ) as expected(document_key, version, title, document_url, content_sha256)
      on expected.document_key = document.document_key
     and expected.version = document.version
     and expected.title = document.title
     and expected.document_url = document.document_url
     and expected.content_sha256 = document.content_sha256
    where document.locale = 'ko-KR'
      and document.required
      and document.published_at = '2026-08-27 00:00:00+09'::timestamptz
      and document.effective_at = '2026-08-27 00:00:00+09'::timestamptz
      and document.retired_at is null
  ) <> 2 then
    raise exception 'legacy_consent_document_mismatch';
  end if;

  update public.consent_documents
  set retired_at = v_transition_at
  where locale = 'ko-KR'
    and required
    and retired_at is null
    and (document_key, version) in (
      ('privacy_policy', '2026-08-27'),
      ('community_guidelines', '2026-08-27')
    );
  get diagnostics v_affected = row_count;
  if v_affected <> 2 then
    raise exception 'legacy_consent_retirement_count_mismatch:%', v_affected;
  end if;

  insert into public.consent_documents (
    document_key,
    version,
    locale,
    title,
    document_url,
    content_sha256,
    required,
    published_at,
    effective_at,
    retired_at
  )
  values
    (
      'privacy_policy',
      '2026-08-30',
      'ko-KR',
      '개인정보 수집·이용 동의',
      '/legal/privacy/2026-08-30',
      '5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d',
      true,
      v_transition_at,
      v_transition_at,
      null
    ),
    (
      'sensitive_information',
      '2026-08-30',
      'ko-KR',
      '종교 관련 민감정보 처리 동의',
      '/legal/sensitive/2026-08-30',
      'a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b',
      true,
      v_transition_at,
      v_transition_at,
      null
    ),
    (
      'overseas_transfer',
      '2026-08-30',
      'ko-KR',
      '개인정보 국외 이전 동의',
      '/legal/overseas/2026-08-30',
      '8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684',
      true,
      v_transition_at,
      v_transition_at,
      null
    ),
    (
      'terms_of_service',
      '2026-08-30',
      'ko-KR',
      '이용약관 및 만 14세 이상 확인',
      '/legal/terms/2026-08-30',
      'ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9',
      true,
      v_transition_at,
      v_transition_at,
      null
    ),
    (
      'community_guidelines',
      '2026-08-30',
      'ko-KR',
      '공동체 운영정책',
      '/legal/community/2026-08-30',
      'e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d',
      true,
      v_transition_at,
      v_transition_at,
      null
    );

  if (
    select pg_catalog.count(*)
    from public.consent_documents as document
    join (
      values
        ('privacy_policy'::text, '5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d'::text),
        ('sensitive_information'::text, 'a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b'::text),
        ('overseas_transfer'::text, '8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684'::text),
        ('terms_of_service'::text, 'ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9'::text),
        ('community_guidelines'::text, 'e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d'::text)
    ) as expected(document_key, content_sha256)
      on expected.document_key = document.document_key
     and expected.content_sha256 = document.content_sha256
    where document.version = '2026-08-30'
      and document.locale = 'ko-KR'
      and document.required
      and document.published_at = v_transition_at
      and document.effective_at = v_transition_at
      and document.retired_at is null
  ) <> 5 then
    raise exception 'current_consent_document_mismatch';
  end if;

  if (
    select pg_catalog.count(*)
    from public.consent_documents as document
    where document.locale = 'ko-KR'
      and document.required
      and document.retired_at is null
  ) <> 5 then
    raise exception 'unexpected_current_active_consent_count';
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1
    from pg_catalog.pg_publication as publication
    where publication.pubname = 'supabase_realtime'
      and not publication.puballtables
  ) and not exists (
    select 1
    from pg_catalog.pg_publication_tables as published_table
    where published_table.pubname = 'supabase_realtime'
      and published_table.schemaname = 'public'
      and published_table.tablename = 'consent_documents'
  ) then
    execute 'alter publication supabase_realtime add table public.consent_documents';
  end if;
end;
$$;

-- The newest event for every currently published/effective required document
-- must be an unwithdrawn acceptance. An empty document set is never consent.
create or replace function private.has_current_required_consents(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  with required_documents as (
    select document.document_key, document.version
    from public.consent_documents as document
    where document.required
      and document.retired_at is null
      and document.published_at <= pg_catalog.statement_timestamp()
      and document.effective_at <= pg_catalog.statement_timestamp()
  )
  select p_user_id is not null
    and (
      select pg_catalog.array_agg(document_key order by document_key)
      from required_documents
    ) = array[
      'community_guidelines',
      'overseas_transfer',
      'privacy_policy',
      'sensitive_information',
      'terms_of_service'
    ]::text[]
    and not exists (
      select 1
      from required_documents as document
      where not coalesce(
        (
          select consent.accepted and consent.withdrawn_at is null
          from public.user_consents as consent
          where consent.user_id = p_user_id
            and consent.document_key = document.document_key
            and consent.document_version = document.version
          order by consent.recorded_at desc, consent.id desc
          limit 1
        ),
        false
      )
    );
$$;

revoke all on function private.has_current_required_consents(uuid)
  from public, anon, authenticated;
grant execute on function private.has_current_required_consents(uuid)
  to authenticated, service_role;

-- Central authority primitives fail closed before consulting membership or
-- administrator records. The account-deactivation check from migration 013 is
-- preserved in the platform-administrator primitive.
create or replace function private.is_platform_admin(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and exists (
      select 1
      from public.platform_admins as administrator
      join public.profiles as profile
        on profile.id = administrator.user_id
       and profile.deactivated_at is null
      where administrator.user_id = p_user_id
    );
$$;

create or replace function private.is_active_member(
  p_organization_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      where membership.organization_id = p_organization_id
        and membership.user_id = p_user_id
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
    );
$$;

create or replace function private.active_role(
  p_organization_id uuid,
  p_user_id uuid
)
returns public.app_role
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select membership.role
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
  join public.profiles as profile
    on profile.id = membership.user_id
   and profile.deactivated_at is null
  where private.has_current_required_consents(p_user_id)
    and membership.organization_id = p_organization_id
    and membership.user_id = p_user_id
    and membership.status = 'active'::public.membership_status
    and organization.status = 'active'::public.organization_status
  limit 1;
$$;

create or replace function private.can_manage_members(
  p_organization_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and (
      private.is_platform_admin(p_user_id)
      or exists (
        select 1
        from public.organization_memberships as membership
        join public.organizations as organization
          on organization.id = membership.organization_id
        join public.profiles as profile
          on profile.id = membership.user_id
         and profile.deactivated_at is null
        where membership.organization_id = p_organization_id
          and membership.user_id = p_user_id
          and membership.status = 'active'::public.membership_status
          and organization.status = 'active'::public.organization_status
          and membership.role in (
            'minister'::public.app_role,
            'executive'::public.app_role
          )
      )
    );
$$;

create or replace function private.shares_active_organization(
  p_left_user_id uuid,
  p_right_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_left_user_id)
    and private.has_current_required_consents(p_right_user_id)
    and exists (
      select 1
      from public.organization_memberships as left_membership
      join public.organization_memberships as right_membership
        on right_membership.organization_id = left_membership.organization_id
       and right_membership.status = 'active'::public.membership_status
      join public.organizations as organization
        on organization.id = left_membership.organization_id
       and organization.status = 'active'::public.organization_status
      join public.profiles as left_profile
        on left_profile.id = left_membership.user_id
       and left_profile.deactivated_at is null
      join public.profiles as right_profile
        on right_profile.id = right_membership.user_id
       and right_profile.deactivated_at is null
      where left_membership.user_id = p_left_user_id
        and left_membership.status = 'active'::public.membership_status
        and right_membership.user_id = p_right_user_id
    );
$$;

create or replace function private.can_view_profile(
  p_target_user_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and (
      p_target_user_id = p_actor_id
      or (
        private.has_current_required_consents(p_target_user_id)
        and (
          private.is_platform_admin(p_actor_id)
          or private.shares_active_organization(p_target_user_id, p_actor_id)
          or exists (
            select 1
            from public.membership_applications as application
            where application.user_id = p_target_user_id
              and application.status = 'pending'::public.application_status
              and private.can_review_application(application.id, p_actor_id)
          )
        )
      )
    );
$$;

create or replace function private.can_read_post(p_post_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and exists (
      select 1
      from public.posts as post
      where post.id = p_post_id
        and (
          post.author_id is null
          or private.has_current_required_consents(post.author_id)
        )
        and (
          (
            post.status = 'published'::public.post_status
            and (
              post.organization_id is null
              or private.is_active_member(post.organization_id, p_actor_id)
            )
          )
          or (
            post.organization_id is not null
            and (
              post.author_id = p_actor_id
              or private.can_manage_members(post.organization_id, p_actor_id)
            )
          )
          or private.is_platform_admin(p_actor_id)
        )
    );
$$;

create or replace function private.can_access_conversation(
  p_conversation_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and exists (
      select 1
      from public.conversations as conversation
      where conversation.id = p_conversation_id
        and p_actor_id in (
          conversation.participant_low,
          conversation.participant_high
        )
        and (
          private.has_current_required_consents(
            case
              when conversation.participant_low = p_actor_id
                then conversation.participant_high
              else conversation.participant_low
            end
          )
          or not exists (
            select 1
            from public.profiles as other_profile
            where other_profile.id = case
              when conversation.participant_low = p_actor_id
                then conversation.participant_high
              else conversation.participant_low
            end
          )
        )
        and private.is_active_member(conversation.organization_id, p_actor_id)
    );
$$;

create or replace function private.can_moderate_organization(
  p_organization_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and (
      private.is_platform_admin(p_actor_id)
      or (
        p_organization_id is not null
        and exists (
          select 1
          from public.organization_memberships as membership
          join public.organizations as organization
            on organization.id = membership.organization_id
          join public.profiles as profile
            on profile.id = membership.user_id
           and profile.deactivated_at is null
          where membership.organization_id = p_organization_id
            and membership.user_id = p_actor_id
            and membership.status = 'active'::public.membership_status
            and membership.role in (
              'minister'::public.app_role,
              'executive'::public.app_role
            )
            and organization.status = 'active'::public.organization_status
        )
      )
    );
$$;

create or replace function private.can_review_application(
  p_application_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.membership_applications as application
      where application.id = p_application_id
        and (
          application.user_id = p_actor_id
          or (
            private.has_current_required_consents(p_actor_id)
            and private.has_current_required_consents(application.user_id)
            and (
              private.is_platform_admin(p_actor_id)
              or (
                application.requested_role = 'member'::public.app_role
                and private.can_manage_members(
                  application.organization_id,
                  p_actor_id
                )
                and not exists (
                  select 1
                  from public.organization_memberships as current_target
                  where current_target.user_id = application.user_id
                    and current_target.status = 'active'::public.membership_status
                    and current_target.role in (
                      'minister'::public.app_role,
                      'executive'::public.app_role
                    )
                )
              )
            )
          )
        )
    );
$$;

create or replace function private.is_user_active_in_governance_scope(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      where membership.user_id = p_user_id
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and private.scope_contains_organization(
          p_scope_id,
          membership.organization_id
        )
    );
$$;

create or replace function private.governance_membership_role(
  p_scope_id uuid,
  p_user_id uuid
)
returns public.app_role
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select membership.role
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
  join public.profiles as profile
    on profile.id = membership.user_id
   and profile.deactivated_at is null
  where private.has_current_required_consents(p_user_id)
    and membership.user_id = p_user_id
    and membership.status = 'active'::public.membership_status
    and organization.status = 'active'::public.organization_status
    and private.scope_contains_organization(
      p_scope_id,
      membership.organization_id
    )
  limit 1;
$$;

create or replace function private.has_current_governance_office(
  p_scope_id uuid,
  p_user_id uuid,
  p_office_codes text[]
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and private.is_user_active_in_governance_scope(p_scope_id, p_user_id)
    and exists (
      select 1
      from public.governance_office_assignments as assignment
      where assignment.scope_id = p_scope_id
        and assignment.user_id = p_user_id
        and assignment.service_year = private.current_service_year()
        and assignment.ended_at is null
        and assignment.office_code = any(coalesce(p_office_codes, '{}'::text[]))
    );
$$;

create or replace function private.is_current_church_pastor(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and exists (
      select 1
      from public.governance_scopes as scope
      where scope.id = p_scope_id
        and scope.scope_type = 'church'::public.governance_scope_type
        and scope.is_active
        and private.has_current_governance_office(
          p_scope_id,
          p_user_id,
          array['pastor']::text[]
        )
    );
$$;

create or replace function private.has_native_governance_authority(
  p_scope_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and exists (
      select 1
      from public.governance_scopes as scope
      where scope.id = p_scope_id
        and scope.is_active
        and (
          private.is_platform_admin(p_user_id)
          or private.has_current_governance_office(
            p_scope_id,
            p_user_id,
            array['president', 'pastor']::text[]
          )
        )
    );
$$;

create or replace function private.has_active_governance_delegation(
  p_scope_id uuid,
  p_user_id uuid,
  p_capability text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and p_capability in (
      'manage_officers',
      'view_roster',
      'manage_events'
    )
    and private.is_user_active_in_governance_scope(p_scope_id, p_user_id)
    and exists (
      select 1
      from public.governance_authority_delegations as delegation
      where delegation.scope_id = p_scope_id
        and delegation.delegate_user_id = p_user_id
        and delegation.revoked_at is null
        and delegation.starts_at <= pg_catalog.statement_timestamp()
        and delegation.expires_at > pg_catalog.statement_timestamp()
        and p_capability = any(delegation.capabilities)
        and private.has_current_required_consents(delegation.grantor_user_id)
        and private.has_native_governance_authority(
          p_scope_id,
          delegation.grantor_user_id
        )
    );
$$;

create or replace function private.can_read_executive_operations(
  p_organization_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      where membership.organization_id = p_organization_id
        and membership.user_id = p_actor_id
        and membership.role = 'executive'::public.app_role
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
    );
$$;

create or replace function private.can_read_executive_assignment(
  p_membership_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and exists (
      select 1
      from public.organization_memberships as target
      where target.id = p_membership_id
        and private.has_current_required_consents(target.user_id)
        and (
          private.is_platform_admin(p_actor_id)
          or target.user_id = p_actor_id
          or private.can_read_executive_operations(
            target.organization_id,
            p_actor_id
          )
        )
    );
$$;

create or replace function private.has_current_executive_office(
  p_organization_id uuid,
  p_actor_id uuid,
  p_office_codes text[]
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and exists (
      select 1
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      join public.governance_scopes as church_scope
        on church_scope.scope_type = 'church'::public.governance_scope_type
       and church_scope.organization_id = membership.organization_id
       and church_scope.is_active
      join public.governance_office_assignments as assignment
        on assignment.scope_id = church_scope.id
       and assignment.user_id = membership.user_id
      where membership.organization_id = p_organization_id
        and membership.user_id = p_actor_id
        and membership.role = 'executive'::public.app_role
        and membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and assignment.service_year = private.current_service_year()
        and assignment.ended_at is null
        and assignment.office_code = any(coalesce(p_office_codes, '{}'::text[]))
    );
$$;

create or replace function private.can_read_event_scope(
  p_scope_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and exists (
      select 1
      from public.governance_scopes as scope
      where scope.id = p_scope_id
        and scope.is_active
        and (
          scope.scope_type <> 'church'::public.governance_scope_type
          or exists (
            select 1
            from public.organizations as organization
            where organization.id = scope.organization_id
              and organization.status = 'active'::public.organization_status
          )
        )
        and (
          private.is_platform_admin(p_actor_id)
          or private.is_user_active_in_governance_scope(
            p_scope_id,
            p_actor_id
          )
        )
    );
$$;

create or replace function private.can_manage_events(
  p_scope_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and (
      private.has_native_governance_authority(p_scope_id, p_actor_id)
      or private.has_active_governance_delegation(
        p_scope_id,
        p_actor_id,
        'manage_events'
      )
    );
$$;

create or replace function private.can_manage_department_offices(
  p_department_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and p_department_id is not null
    and exists (
      select 1
      from public.church_departments as department
      join public.governance_scopes as scope
        on scope.id = department.church_scope_id
      join public.organizations as organization
        on organization.id = scope.organization_id
      where department.id = p_department_id
        and department.is_active
        and scope.scope_type = 'church'::public.governance_scope_type
        and scope.is_active
        and organization.status = 'active'::public.organization_status
        and (
          private.is_platform_admin(p_user_id)
          or private.is_current_church_pastor(scope.id, p_user_id)
        )
    );
$$;

create or replace function private.can_view_church_departments(
  p_organization_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and p_organization_id is not null
    and (
      private.is_platform_admin(p_user_id)
      or exists (
        select 1
        from public.governance_scopes as scope
        join public.organizations as organization
          on organization.id = scope.organization_id
        where scope.scope_type = 'church'::public.governance_scope_type
          and scope.organization_id = p_organization_id
          and scope.is_active
          and organization.status = 'active'::public.organization_status
          and private.is_current_church_pastor(scope.id, p_user_id)
      )
    );
$$;

create or replace function private.can_read_community_media(
  p_name text,
  p_actor_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_organization_id uuid := private.try_uuid(pg_catalog.split_part(p_name, '/', 1));
  v_category text := pg_catalog.split_part(p_name, '/', 2);
  v_entity_id uuid := private.try_uuid(pg_catalog.split_part(p_name, '/', 3));
begin
  if not private.has_current_required_consents(p_actor_id)
    or v_organization_id is null then
    return false;
  end if;

  case v_category
    when 'posts' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.posts as post
          where post.id = v_entity_id
            and post.organization_id = v_organization_id
            and private.can_read_post(post.id, p_actor_id)
            and (
              exists (
                select 1
                from public.post_media as media
                where media.post_id = post.id
                  and media.storage_path = p_name
                  and (
                    media.uploader_id is null
                    or private.has_current_required_consents(media.uploader_id)
                  )
              )
              or (
                not exists (
                  select 1
                  from public.post_media as media
                  where media.post_id = post.id
                    and media.storage_path = p_name
                )
                and exists (
                  select 1
                  from storage.objects as object
                  where object.bucket_id = 'community-media'
                    and object.name = p_name
                    and (
                      (
                        object.owner_id = p_actor_id::text
                        and (object.owner is null or object.owner = p_actor_id)
                      )
                      or (object.owner_id is null and object.owner = p_actor_id)
                    )
                )
              )
            )
        );
    when 'applications' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.membership_applications as application
          where application.id = v_entity_id
            and application.organization_id = v_organization_id
            and private.has_current_required_consents(application.user_id)
            and private.can_review_application(application.id, p_actor_id)
        );
    when 'messages' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.conversations as conversation
          where conversation.id = v_entity_id
            and conversation.organization_id = v_organization_id
            and private.can_access_conversation(
              conversation.id,
              p_actor_id
            )
        );
    when 'organization' then
      return exists (
        select 1
        from public.organizations as organization
        where organization.id = v_organization_id
          and organization.status in (
            'seeded_unclaimed'::public.organization_status,
            'active'::public.organization_status
          )
      );
    else
      return false;
  end case;
end;
$$;

-- Direct table and Storage access receives the same outer gate. Only legal
-- documents, consent/state saving, account deletion, push-device removal, and
-- logout/session cleanup remain available while the gate is closed.
drop policy if exists organizations_select_directory_authenticated
  on public.organizations;
create policy organizations_select_directory_authenticated
on public.organizations for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and status in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  )
);

drop policy if exists organization_memberships_select_authorized
  on public.organization_memberships;
create policy organization_memberships_select_authorized
on public.organization_memberships for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and private.has_current_required_consents(user_id)
  and (
    user_id = auth.uid()
    or private.is_platform_admin(auth.uid())
    or (
      status = 'active'::public.membership_status
      and private.is_active_member(organization_id, auth.uid())
    )
    or private.can_manage_members(organization_id, auth.uid())
  )
);

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self
on public.profiles for update to authenticated
using (
  id = auth.uid()
  and private.has_current_required_consents(auth.uid())
)
with check (
  id = auth.uid()
  and private.has_current_required_consents(auth.uid())
);

drop policy if exists post_media_select_authorized on public.post_media;
create policy post_media_select_authorized
on public.post_media for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and private.can_read_post(post_id, auth.uid())
  and (
    uploader_id is null
    or private.has_current_required_consents(uploader_id)
  )
);

drop policy if exists membership_applications_select_authorized
  on public.membership_applications;
create policy membership_applications_select_authorized
on public.membership_applications for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and private.has_current_required_consents(user_id)
  and private.can_review_application(id, auth.uid())
);

drop policy if exists boards_select_authorized on public.boards;
create policy boards_select_authorized
on public.boards for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and (
    is_global
    or private.is_active_member(organization_id, auth.uid())
    or private.is_platform_admin(auth.uid())
  )
);

drop policy if exists posts_select_authorized on public.posts;
create policy posts_select_authorized
on public.posts for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and (
    (
      status = 'published'::public.post_status
      and (
        organization_id is null
        or private.is_active_member(organization_id, auth.uid())
      )
    )
    or (
      organization_id is not null
      and (
        author_id = auth.uid()
        or private.can_manage_members(organization_id, auth.uid())
      )
    )
    or private.is_platform_admin(auth.uid())
  )
  and (
    author_id is null
    or author_id = auth.uid()
    or (
      private.has_current_required_consents(author_id)
      and (
        not private.user_has_blocked(auth.uid(), author_id)
        or private.can_moderate_organization(organization_id, auth.uid())
      )
    )
  )
);

create or replace function private.can_receive_notification(
  p_notification_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_user_id)
    and exists (
      select 1
      from public.notifications as notification
      where notification.id = p_notification_id
        and notification.user_id = p_user_id
        and case
          when notification.kind = 'new_message'::public.notification_kind then
            exists (
              select 1
              from public.messages as source_message
              where source_message.id = private.try_uuid(
                  notification.metadata ->> 'message_id'
                )
                and source_message.sender_id is not null
                and private.has_current_required_consents(source_message.sender_id)
                and private.can_access_conversation(
                  source_message.conversation_id,
                  p_user_id
                )
            )
          when notification.kind = 'post_comment'::public.notification_kind then
            exists (
              select 1
              from public.comments as source_comment
              where source_comment.id = private.try_uuid(
                  notification.metadata ->> 'comment_id'
                )
                and source_comment.author_id is not null
                and private.has_current_required_consents(source_comment.author_id)
                and private.can_read_post(source_comment.post_id, p_user_id)
            )
          when notification.kind = 'application_submitted'::public.notification_kind then
            exists (
              select 1
              from public.membership_applications as source_application
              where source_application.id = notification.entity_id
                and private.has_current_required_consents(
                  source_application.user_id
                )
                and private.can_review_application(
                  source_application.id,
                  p_user_id
                )
            )
          when notification.metadata ? 'replacement_user_id' then
            private.has_current_required_consents(
              private.try_uuid(
                notification.metadata ->> 'replacement_user_id'
              )
            )
          else true
        end
    );
$$;

revoke all on function private.can_receive_notification(uuid, uuid)
  from public, anon, authenticated;

-- RLS callers receive only an auth-bound predicate.  The two-argument helper
-- remains owner-only because notification IDs and recipient IDs must not form
-- a cross-user boolean probing surface.
create or replace function private.can_receive_my_notification(
  p_notification_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.can_receive_notification(p_notification_id, auth.uid());
$$;

revoke all on function private.can_receive_my_notification(uuid)
  from public, anon, authenticated;
grant execute on function private.can_receive_my_notification(uuid)
  to authenticated;

drop policy if exists notifications_select_self on public.notifications;
create policy notifications_select_self
on public.notifications for select to authenticated
using (private.can_receive_my_notification(id));

drop policy if exists governance_scopes_select_directory
  on public.governance_scopes;
create policy governance_scopes_select_directory
on public.governance_scopes for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and (is_active or private.is_platform_admin(auth.uid()))
);

drop policy if exists event_rsvps_select_self_or_manager
  on public.event_rsvps;
create policy event_rsvps_select_self_or_manager
on public.event_rsvps for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and private.has_current_required_consents(user_id)
  and (
    user_id = auth.uid()
    or exists (
      select 1
      from public.event_occurrences as occurrence
      join public.events as event on event.id = occurrence.event_id
      where occurrence.id = event_rsvps.occurrence_id
        and private.can_manage_events(event.scope_id, auth.uid())
    )
  )
);

drop policy if exists jaegun_quarantine_media_insert on storage.objects;
create policy jaegun_quarantine_media_insert
on storage.objects for insert to authenticated
with check (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'community-media-quarantine'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.can_write_quarantine_media(name, auth.uid(), metadata)
);

drop policy if exists jaegun_quarantine_media_update on storage.objects;
create policy jaegun_quarantine_media_update
on storage.objects for update to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'community-media-quarantine'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.can_write_quarantine_media(name, auth.uid(), metadata)
)
with check (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'community-media-quarantine'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.can_write_quarantine_media(name, auth.uid(), metadata)
);

drop policy if exists jaegun_community_media_insert on storage.objects;
create policy jaegun_community_media_insert
on storage.objects for insert to authenticated
with check (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'community-media'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.authorize_direct_media_upload(
    bucket_id,
    name,
    auth.uid(),
    metadata
  )
);

drop policy if exists jaegun_avatars_insert on storage.objects;
create policy jaegun_avatars_insert
on storage.objects for insert to authenticated
with check (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'avatars'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.authorize_direct_media_upload(
    bucket_id,
    name,
    auth.uid(),
    metadata
  )
);

drop policy if exists jaegun_avatars_select on storage.objects;
create policy jaegun_avatars_select
on storage.objects for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'avatars'
  and private.can_read_avatar_object(name, auth.uid())
);

-- Signup metadata is accepted only as an exact five-key nested map whose
-- independent {accepted:true, version} entries match rows that are already
-- published and effective. Client clocks and acceptance times are not trusted.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_name text;
  v_required_consents jsonb := new.raw_user_meta_data -> 'accepted_required_consents';
  v_expected_keys text[];
begin
  v_name := nullif(pg_catalog.btrim(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    pg_catalog.split_part(coalesce(new.email, ''), '@', 1)
  )), '');

  insert into public.profiles (id, display_name)
  values (new.id, pg_catalog.left(coalesce(v_name, '사용자'), 80))
  on conflict (id) do nothing;

  select pg_catalog.array_agg(document.document_key order by document.document_key)
  into v_expected_keys
  from public.consent_documents as document
  where document.required
    and document.retired_at is null
    and document.published_at <= pg_catalog.statement_timestamp()
    and document.effective_at <= pg_catalog.statement_timestamp();

  if new.raw_user_meta_data ->> 'consent_contract' = 'required-consents-v2'
    and pg_catalog.jsonb_typeof(v_required_consents) = 'object'
    and v_expected_keys = array[
      'community_guidelines',
      'overseas_transfer',
      'privacy_policy',
      'sensitive_information',
      'terms_of_service'
    ]::text[]
    and (
      select pg_catalog.array_agg(key order by key)
      from pg_catalog.jsonb_object_keys(v_required_consents) as key
    ) = v_expected_keys
    and not exists (
      select 1
      from public.consent_documents as document
      where document.required
        and document.retired_at is null
        and document.published_at <= pg_catalog.statement_timestamp()
        and document.effective_at <= pg_catalog.statement_timestamp()
        and (
          pg_catalog.jsonb_typeof(
            v_required_consents -> document.document_key
          ) <> 'object'
          or v_required_consents #> array[document.document_key, 'accepted']
            is distinct from 'true'::jsonb
          or v_required_consents #>> array[document.document_key, 'version']
            is distinct from document.version
        )
    ) then
    insert into public.user_consents (
      user_id,
      document_key,
      document_version,
      accepted,
      source
    )
    select
      new.id,
      document.document_key,
      document.version,
      true,
      'signup_metadata'
    from public.consent_documents as document
    where document.required
      and document.retired_at is null
      and document.published_at <= pg_catalog.statement_timestamp()
      and document.effective_at <= pg_catalog.statement_timestamp()
    order by document.document_key;
  end if;

  return new;
end;
$$;

revoke all on function public.handle_new_auth_user()
  from public, anon, authenticated;

create or replace function public.get_my_safety_privacy_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_documents jsonb;
  v_required_consents jsonb;
  v_legacy_consents jsonb;
  v_privacy jsonb;
  v_notifications jsonb;
  v_deletion jsonb;
  v_blocks jsonb;
  v_devices jsonb;
  v_muted_conversations jsonb;
  v_gate_open boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select coalesce(
    pg_catalog.jsonb_object_agg(
      document.document_key,
      pg_catalog.jsonb_build_object(
        'version', document.version,
        'title', document.title,
        'url', document.document_url,
        'effective_at', document.effective_at,
        'required', document.required
      )
    ),
    '{}'::jsonb
  ) into v_documents
  from public.consent_documents as document
  where document.required
    and document.retired_at is null
    and document.published_at <= pg_catalog.statement_timestamp()
    and document.effective_at <= pg_catalog.statement_timestamp();

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'document_key', current_document.document_key,
        'document_version', current_document.version,
        'accepted', coalesce(latest.accepted and latest.withdrawn_at is null, false),
        'recorded_at', latest.recorded_at
      ) order by current_document.document_key
    ),
    '[]'::jsonb
  ) into v_required_consents
  from public.consent_documents as current_document
  left join lateral (
    select consent.accepted, consent.withdrawn_at, consent.recorded_at
    from public.user_consents as consent
    where consent.user_id = v_actor_id
      and consent.document_key = current_document.document_key
      and consent.document_version = current_document.version
    order by consent.recorded_at desc, consent.id desc
    limit 1
  ) as latest on true
  where current_document.required
    and current_document.retired_at is null
    and current_document.published_at <= pg_catalog.statement_timestamp()
    and current_document.effective_at <= pg_catalog.statement_timestamp();

  select pg_catalog.jsonb_build_object(
    'sensitive_affiliation', pg_catalog.jsonb_build_object(
      'version', v_documents #>> '{privacy_policy,version}',
      'accepted_at', (
        select item -> 'recorded_at'
        from pg_catalog.jsonb_array_elements(v_required_consents) as item
        where item ->> 'document_key' = 'privacy_policy'
          and (item ->> 'accepted')::boolean
        limit 1
      )
    ),
    'community_policy', pg_catalog.jsonb_build_object(
      'version', v_documents #>> '{community_guidelines,version}',
      'accepted_at', (
        select item -> 'recorded_at'
        from pg_catalog.jsonb_array_elements(v_required_consents) as item
        where item ->> 'document_key' = 'community_guidelines'
          and (item ->> 'accepted')::boolean
        limit 1
      )
    )
  ) into v_legacy_consents;

  select pg_catalog.to_jsonb(preference) into v_privacy
  from public.privacy_preferences as preference
  where preference.user_id = v_actor_id;

  select pg_catalog.to_jsonb(preference) into v_notifications
  from public.notification_preferences as preference
  where preference.user_id = v_actor_id;

  select pg_catalog.to_jsonb(request) into v_deletion
  from public.account_deletion_requests as request
  where request.user_id = v_actor_id
  order by request.requested_at desc
  limit 1;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'user_id', block.blocked_user_id,
        'display_name', case
          when private.has_current_required_consents(block.blocked_user_id)
            then profile.display_name
          else '이용할 수 없는 사용자'
        end,
        'avatar_url', null,
        'blocked_at', block.created_at
      ) order by block.created_at desc
    ),
    '[]'::jsonb
  ) into v_blocks
  from public.user_blocks as block
  left join public.profiles as profile on profile.id = block.blocked_user_id
  where block.blocker_id = v_actor_id;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', device.id,
        'installation_id', device.installation_id,
        'platform', device.platform,
        'app_version', device.app_version,
        'last_seen_at', device.last_seen_at,
        'disabled_at', device.disabled_at
      ) order by device.last_seen_at desc
    ),
    '[]'::jsonb
  ) into v_devices
  from public.push_devices as device
  where device.user_id = v_actor_id;

  select coalesce(pg_catalog.jsonb_agg(preference.conversation_id), '[]'::jsonb)
  into v_muted_conversations
  from public.conversation_preferences as preference
  where preference.user_id = v_actor_id
    and (
      not preference.notifications_enabled
      or preference.muted_until > pg_catalog.statement_timestamp()
    );

  v_gate_open := private.has_current_required_consents(v_actor_id);

  return pg_catalog.jsonb_build_object(
    'current_documents', v_documents,
    'required_consents', v_required_consents,
    'consents', v_legacy_consents,
    'consent_gate_open', v_gate_open,
    'directory_visibility', pg_catalog.jsonb_build_object(
      'avatar', coalesce((v_privacy ->> 'avatar_visible')::boolean, false),
      'church_title', coalesce((v_privacy ->> 'church_title_visible')::boolean, true),
      'email', coalesce((v_privacy ->> 'email_visible')::boolean, false),
      'bio', coalesce((v_privacy ->> 'bio_visible')::boolean, false)
    ),
    'notifications', pg_catalog.jsonb_build_object(
      'push_enabled', coalesce((v_notifications ->> 'push_enabled')::boolean, true),
      'categories', pg_catalog.jsonb_build_object(
        'approvals', coalesce((v_notifications ->> 'approvals_enabled')::boolean, true),
        'posts', coalesce((v_notifications ->> 'posts_enabled')::boolean, true),
        'comments', coalesce((v_notifications ->> 'comments_enabled')::boolean, true),
        'chats', coalesce((v_notifications ->> 'messages_enabled')::boolean, true),
        'governance', coalesce((v_notifications ->> 'governance_enabled')::boolean, true),
        'events', coalesce((v_notifications ->> 'events_enabled')::boolean, true)
      ),
      'quiet_hours_enabled', (v_notifications ->> 'quiet_hours_start') is not null,
      'quiet_hours_start', coalesce(pg_catalog.left(v_notifications ->> 'quiet_hours_start', 5), '21:00'),
      'quiet_hours_end', coalesce(pg_catalog.left(v_notifications ->> 'quiet_hours_end', 5), '08:00'),
      'time_zone', coalesce(v_notifications ->> 'timezone', 'Asia/Seoul'),
      'lock_screen_preview', coalesce(v_notifications ->> 'lock_screen_preview', 'generic')
    ),
    'blocked_profiles', case when v_gate_open then v_blocks else '[]'::jsonb end,
    'muted_conversation_ids', case when v_gate_open then v_muted_conversations else '[]'::jsonb end,
    'account_deletion', case
      when v_deletion ->> 'status' in (
        'requested',
        'processing',
        'awaiting_identity_deletion'
      ) then pg_catalog.jsonb_build_object(
        'status', 'pending',
        'requested_at', v_deletion -> 'requested_at',
        'scheduled_for', v_deletion -> 'scheduled_for'
      )
      else pg_catalog.jsonb_build_object(
        'status', 'none',
        'requested_at', null,
        'scheduled_for', null
      )
    end,
    'privacy_preferences', coalesce(v_privacy, pg_catalog.jsonb_build_object(
      'user_id', v_actor_id,
      'directory_visibility', 'private',
      'analytics_opt_in', false
    )),
    'notification_preferences', case when v_gate_open then coalesce(v_notifications, pg_catalog.jsonb_build_object(
      'user_id', v_actor_id,
      'push_enabled', true,
      'messages_enabled', true,
      'comments_enabled', true,
      'approvals_enabled', true,
      'community_enabled', true,
      'timezone', 'Asia/Seoul'
    )) else null end,
    'deletion_request', v_deletion,
    'blocked_users', case when v_gate_open then v_blocks else '[]'::jsonb end,
    'push_devices', case when v_gate_open then v_devices else '[]'::jsonb end
  );
end;
$$;

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

  select pg_catalog.jsonb_object_agg(document.document_key, document.version)
  into v_expected
  from public.consent_documents as document
  where document.required
    and document.retired_at is null
    and document.published_at <= pg_catalog.statement_timestamp()
    and document.effective_at <= pg_catalog.statement_timestamp();

  if pg_catalog.jsonb_typeof(p_required_consents) <> 'object'
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
    or p_required_consents <> v_expected then
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

-- SECURITY DEFINER read RPCs from earlier migrations are wrapped so they
-- cannot bypass the new RLS boundary. Roster-like results also suppress users
-- who have not accepted the current required set.
alter function public.get_my_context() set schema private;
alter function private.get_my_context()
  rename to get_my_context_before_current_consent_gate;
revoke all on function private.get_my_context_before_current_consent_gate()
  from public, anon, authenticated;

create function public.get_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.get_my_context_before_current_consent_gate();
end;
$$;

revoke all on function public.get_my_context()
  from public, anon, authenticated;
grant execute on function public.get_my_context() to authenticated;

alter function public.get_governance_tree() set schema private;
alter function private.get_governance_tree()
  rename to get_governance_tree_before_current_consent_gate;
revoke all on function private.get_governance_tree_before_current_consent_gate()
  from public, anon, authenticated;

create function public.get_governance_tree()
returns table (
  scope_id uuid,
  scope_type public.governance_scope_type,
  slug text,
  display_name text,
  parent_scope_id uuid,
  organization_id uuid,
  is_active boolean,
  church_count bigint,
  active_member_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select
    tree.scope_id,
    tree.scope_type,
    tree.slug,
    tree.display_name,
    tree.parent_scope_id,
    tree.organization_id,
    tree.is_active,
    tree.church_count,
    (
      select pg_catalog.count(*)
      from public.organization_memberships as membership
      join public.organizations as organization
        on organization.id = membership.organization_id
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      where membership.status = 'active'::public.membership_status
        and organization.status = 'active'::public.organization_status
        and private.has_current_required_consents(membership.user_id)
        and private.scope_contains_organization(
          tree.scope_id,
          membership.organization_id
        )
    )::bigint
  from private.get_governance_tree_before_current_consent_gate() as tree;
end;
$$;

revoke all on function public.get_governance_tree()
  from public, anon, authenticated;
grant execute on function public.get_governance_tree() to authenticated;

alter function public.list_scope_organizations(uuid) set schema private;
alter function private.list_scope_organizations(uuid)
  rename to list_scope_organizations_before_current_consent_gate;
revoke all on function private.list_scope_organizations_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.list_scope_organizations(p_scope_id uuid)
returns table (
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  active_member_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select
    scoped.organization_id,
    scoped.organization_name,
    scoped.presbytery_name,
    (
      select pg_catalog.count(*)
      from public.organization_memberships as membership
      join public.profiles as profile
        on profile.id = membership.user_id
       and profile.deactivated_at is null
      where membership.organization_id = scoped.organization_id
        and membership.status = 'active'::public.membership_status
        and private.has_current_required_consents(membership.user_id)
    )::bigint
  from private.list_scope_organizations_before_current_consent_gate(
    p_scope_id
  ) as scoped;
end;
$$;

revoke all on function public.list_scope_organizations(uuid)
  from public, anon, authenticated;
grant execute on function public.list_scope_organizations(uuid)
  to authenticated;

alter function public.list_governance_roster(uuid, integer, text, integer, integer)
  set schema private;
alter function private.list_governance_roster(uuid, integer, text, integer, integer)
  rename to list_governance_roster_before_current_consent_gate;
revoke all on function private.list_governance_roster_before_current_consent_gate(
  uuid, integer, text, integer, integer
) from public, anon, authenticated;

create function public.list_governance_roster(
  p_scope_id uuid,
  p_service_year integer default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  display_name text,
  church_title_code text,
  church_title_name text,
  membership_role public.app_role,
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  office_codes text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 200
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_governance_roster_page' using errcode = '22023';
  end if;

  return query
  with page_meta as (
    select roster.total_count
    from private.list_governance_roster_before_current_consent_gate(
      p_scope_id, p_service_year, p_search, 1, 0
    ) as roster
    limit 1
  ), all_rows as (
    select roster.*
    from page_meta
    cross join lateral pg_catalog.generate_series(
      0,
      least(
        pg_catalog.ceil(page_meta.total_count / 200.0)::integer - 1,
        50
      )
    ) as batch(batch_number)
    cross join lateral private.list_governance_roster_before_current_consent_gate(
      p_scope_id,
      p_service_year,
      p_search,
      200,
      batch.batch_number * 200
    ) as roster
  ), visible as (
    select all_rows.*
    from all_rows
    where private.has_current_required_consents(all_rows.user_id)
  )
  select
    visible.user_id,
    visible.display_name,
    visible.church_title_code,
    visible.church_title_name,
    visible.membership_role,
    visible.organization_id,
    visible.organization_name,
    visible.presbytery_name,
    visible.office_codes,
    pg_catalog.count(*) over ()::bigint
  from visible
  order by
    (pg_catalog.cardinality(visible.office_codes) > 0) desc,
    visible.organization_name,
    visible.display_name,
    visible.user_id
  limit p_limit
  offset p_offset;
end;
$$;

revoke all on function public.list_governance_roster(
  uuid, integer, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.list_governance_roster(
  uuid, integer, text, integer, integer
) to authenticated;

alter function public.list_department_office_candidates(
  uuid, integer, text, integer, integer
) set schema private;
alter function private.list_department_office_candidates(
  uuid, integer, text, integer, integer
) rename to list_department_candidates_before_current_consent_gate;
revoke all on function private.list_department_candidates_before_current_consent_gate(
  uuid, integer, text, integer, integer
) from public, anon, authenticated;

create function public.list_department_office_candidates(
  p_department_id uuid,
  p_service_year integer,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  membership_id uuid,
  display_name text,
  church_title_code text,
  membership_role public.app_role,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_department_candidate_page' using errcode = '22023';
  end if;

  return query
  with page_meta as (
    select candidate.total_count
    from private.list_department_candidates_before_current_consent_gate(
      p_department_id, p_service_year, p_search, 1, 0
    ) as candidate
    limit 1
  ), all_rows as (
    select candidate.*
    from page_meta
    cross join lateral pg_catalog.generate_series(
      0,
      least(
        pg_catalog.ceil(page_meta.total_count / 100.0)::integer - 1,
        100
      )
    ) as batch(batch_number)
    cross join lateral private.list_department_candidates_before_current_consent_gate(
      p_department_id,
      p_service_year,
      p_search,
      100,
      batch.batch_number * 100
    ) as candidate
  ), visible as (
    select all_rows.*
    from all_rows
    where private.has_current_required_consents(all_rows.user_id)
  )
  select
    visible.user_id,
    visible.membership_id,
    visible.display_name,
    visible.church_title_code,
    visible.membership_role,
    pg_catalog.count(*) over ()::bigint
  from visible
  order by visible.display_name, visible.user_id
  limit p_limit
  offset p_offset;
end;
$$;

revoke all on function public.list_department_office_candidates(
  uuid, integer, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.list_department_office_candidates(
  uuid, integer, text, integer, integer
) to authenticated;

alter function public.list_governance_office_candidates(
  uuid, integer, text, text, integer, integer
) set schema private;
alter function private.list_governance_office_candidates(
  uuid, integer, text, text, integer, integer
) rename to list_governance_candidates_before_current_consent_gate;
revoke all on function private.list_governance_candidates_before_current_consent_gate(
  uuid, integer, text, text, integer, integer
) from public, anon, authenticated;

create function public.list_governance_office_candidates(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  display_name text,
  church_title_code text,
  church_title_name text,
  membership_role public.app_role,
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  office_codes text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_governance_candidate_page' using errcode = '22023';
  end if;

  return query
  with page_meta as (
    select candidate.total_count
    from private.list_governance_candidates_before_current_consent_gate(
      p_scope_id, p_service_year, p_office_code, p_search, 1, 0
    ) as candidate
    limit 1
  ), all_rows as (
    select candidate.*
    from page_meta
    cross join lateral pg_catalog.generate_series(
      0,
      least(
        pg_catalog.ceil(page_meta.total_count / 100.0)::integer - 1,
        100
      )
    ) as batch(batch_number)
    cross join lateral private.list_governance_candidates_before_current_consent_gate(
      p_scope_id,
      p_service_year,
      p_office_code,
      p_search,
      100,
      batch.batch_number * 100
    ) as candidate
  ), visible as (
    select all_rows.*
    from all_rows
    where private.has_current_required_consents(all_rows.user_id)
  )
  select
    visible.user_id,
    visible.display_name,
    visible.church_title_code,
    visible.church_title_name,
    visible.membership_role,
    visible.organization_id,
    visible.organization_name,
    visible.presbytery_name,
    visible.office_codes,
    pg_catalog.count(*) over ()::bigint
  from visible
  order by visible.organization_name, visible.display_name, visible.user_id
  limit p_limit
  offset p_offset;
end;
$$;

revoke all on function public.list_governance_office_candidates(
  uuid, integer, text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.list_governance_office_candidates(
  uuid, integer, text, text, integer, integer
) to authenticated;

alter function public.list_church_departments(uuid, integer) set schema private;
alter function private.list_church_departments(uuid, integer)
  rename to list_church_departments_before_current_consent_gate;
revoke all on function private.list_church_departments_before_current_consent_gate(
  uuid, integer
) from public, anon, authenticated;

create function public.list_church_departments(
  p_organization_id uuid,
  p_service_year integer default null
)
returns table (
  department_id uuid,
  department_code text,
  display_name text,
  sort_order smallint,
  office_code text,
  user_id uuid,
  member_display_name text,
  church_title_code text,
  membership_role public.app_role
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select
    department.department_id,
    department.department_code,
    department.display_name,
    department.sort_order,
    department.office_code,
    case when private.has_current_required_consents(department.user_id)
      then department.user_id else null end,
    case when private.has_current_required_consents(department.user_id)
      then department.member_display_name else null end,
    case when private.has_current_required_consents(department.user_id)
      then department.church_title_code else null end,
    case when private.has_current_required_consents(department.user_id)
      then department.membership_role else null end
  from private.list_church_departments_before_current_consent_gate(
    p_organization_id,
    p_service_year
  ) as department;
end;
$$;

revoke all on function public.list_church_departments(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.list_church_departments(uuid, integer)
  to authenticated;

alter function public.list_governance_delegations(uuid) set schema private;
alter function private.list_governance_delegations(uuid)
  rename to list_governance_delegations_before_current_consent_gate;
revoke all on function private.list_governance_delegations_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.list_governance_delegations(p_scope_id uuid)
returns table (
  delegation_id uuid,
  scope_id uuid,
  grantor_user_id uuid,
  grantor_name text,
  delegate_user_id uuid,
  delegate_name text,
  capabilities text[],
  starts_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  status text,
  reason text
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select delegation.*
  from private.list_governance_delegations_before_current_consent_gate(
    p_scope_id
  ) as delegation
  where private.has_current_required_consents(delegation.grantor_user_id)
    and private.has_current_required_consents(delegation.delegate_user_id);
end;
$$;

revoke all on function public.list_governance_delegations(uuid)
  from public, anon, authenticated;
grant execute on function public.list_governance_delegations(uuid)
  to authenticated;

alter function public.get_conversation_summaries() set schema private;
alter function private.get_conversation_summaries()
  rename to get_conversation_summaries_before_current_consent_gate;
revoke all on function private.get_conversation_summaries_before_current_consent_gate()
  from public, anon, authenticated;

create function public.get_conversation_summaries()
returns table (
  id uuid,
  organization_id uuid,
  participants jsonb,
  last_message jsonb,
  unread_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select summary.*
  from private.get_conversation_summaries_before_current_consent_gate() as summary
  where (
      private.has_current_required_consents(
        (summary.participants -> 0 ->> 'id')::uuid
      )
      or not exists (
        select 1
        from public.profiles as profile
        where profile.id = (summary.participants -> 0 ->> 'id')::uuid
      )
    )
    and (
      private.has_current_required_consents(
        (summary.participants -> 1 ->> 'id')::uuid
      )
      or not exists (
        select 1
        from public.profiles as profile
        where profile.id = (summary.participants -> 1 ->> 'id')::uuid
      )
    );
end;
$$;

revoke all on function public.get_conversation_summaries()
  from public, anon, authenticated;
grant execute on function public.get_conversation_summaries()
  to authenticated;

drop policy if exists consent_documents_select_published
  on public.consent_documents;
create policy consent_documents_select_published
on public.consent_documents for select to anon, authenticated
using (
  published_at <= pg_catalog.statement_timestamp()
  and effective_at <= pg_catalog.statement_timestamp()
);

drop policy if exists user_blocks_select_self on public.user_blocks;
create policy user_blocks_select_self
on public.user_blocks for select to authenticated
using (
  blocker_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
);

drop policy if exists user_blocks_insert_self on public.user_blocks;
create policy user_blocks_insert_self
on public.user_blocks for insert to authenticated
with check (
  blocker_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
  and private.has_current_required_consents(blocked_user_id)
);

drop policy if exists user_blocks_delete_self on public.user_blocks;
create policy user_blocks_delete_self
on public.user_blocks for delete to authenticated
using (
  blocker_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
);

drop policy if exists notification_preferences_select_self
  on public.notification_preferences;
create policy notification_preferences_select_self
on public.notification_preferences for select to authenticated
using (
  user_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
);

drop policy if exists conversation_preferences_select_self
  on public.conversation_preferences;
create policy conversation_preferences_select_self
on public.conversation_preferences for select to authenticated
using (
  user_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
  and private.can_access_conversation(conversation_id, auth.uid())
);

drop policy if exists push_devices_select_self on public.push_devices;
create policy push_devices_select_self
on public.push_devices for select to authenticated
using (
  user_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
);

drop policy if exists media_upload_intents_select_self
  on public.media_upload_intents;
create policy media_upload_intents_select_self
on public.media_upload_intents for select to authenticated
using (
  uploader_id = auth.uid()
  and private.has_current_required_consents(auth.uid())
);

drop policy if exists media_scan_records_select_owner
  on public.media_scan_records;
create policy media_scan_records_select_owner
on public.media_scan_records for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and exists (
    select 1
    from public.media_upload_intents as intent
    where intent.id = media_scan_records.intent_id
      and intent.uploader_id = auth.uid()
  )
);

drop policy if exists content_reports_select_authorized
  on public.content_reports;
create policy content_reports_select_authorized
on public.content_reports for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and (
    reporter_id = auth.uid()
    or private.can_moderate_organization(organization_id, auth.uid())
  )
);

drop policy if exists moderation_actions_select_authorized
  on public.moderation_actions;
create policy moderation_actions_select_authorized
on public.moderation_actions for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and (
    private.can_moderate_organization(organization_id, auth.uid())
    or exists (
      select 1
      from public.content_reports as report
      where report.id = moderation_actions.report_id
        and report.reporter_id = auth.uid()
    )
  )
);

-- Authority-bearing or sensitive rows may be deactivated without consent, but
-- cannot be newly created or returned to an active state for a non-consenting
-- user. This closes SECURITY DEFINER approval/assignment bypasses.
create or replace function private.enforce_current_consent_on_membership()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.status = 'active'::public.membership_status
    and not private.has_current_required_consents(new.user_id) then
    raise exception 'target_current_required_consents_required'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists organization_memberships_require_current_consent
  on public.organization_memberships;
create trigger organization_memberships_require_current_consent
before insert or update on public.organization_memberships
for each row execute function private.enforce_current_consent_on_membership();

create or replace function private.enforce_current_consent_on_application()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.status = 'pending'::public.application_status
    and not private.has_current_required_consents(new.user_id) then
    raise exception 'applicant_current_required_consents_required'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists membership_applications_require_current_consent
  on public.membership_applications;
create trigger membership_applications_require_current_consent
before insert or update on public.membership_applications
for each row execute function private.enforce_current_consent_on_application();

create or replace function private.enforce_current_consent_on_governance_assignment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.ended_at is null
    and not private.has_current_required_consents(new.user_id) then
    raise exception 'officer_current_required_consents_required'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists governance_assignments_require_current_consent
  on public.governance_office_assignments;
create trigger governance_assignments_require_current_consent
before insert or update
on public.governance_office_assignments
for each row execute function private.enforce_current_consent_on_governance_assignment();

drop trigger if exists department_assignments_require_current_consent
  on public.department_office_assignments;
create trigger department_assignments_require_current_consent
before insert or update
on public.department_office_assignments
for each row execute function private.enforce_current_consent_on_governance_assignment();

create or replace function private.enforce_current_consent_on_delegation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.revoked_at is null
    and (
      not private.has_current_required_consents(new.grantor_user_id)
      or not private.has_current_required_consents(new.delegate_user_id)
    ) then
    raise exception 'delegation_parties_current_required_consents_required'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists governance_delegations_require_current_consent
  on public.governance_authority_delegations;
create trigger governance_delegations_require_current_consent
before insert or update
on public.governance_authority_delegations
for each row execute function private.enforce_current_consent_on_delegation();

create or replace function private.enforce_current_consent_on_content_report()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if not private.has_current_required_consents(new.reporter_id) then
    raise exception 'reporter_current_required_consents_required'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists content_reports_require_current_consent
  on public.content_reports;
create trigger content_reports_require_current_consent
before insert on public.content_reports
for each row execute function private.enforce_current_consent_on_content_report();

revoke all on function private.enforce_current_consent_on_membership()
  from public, anon, authenticated;
revoke all on function private.enforce_current_consent_on_application()
  from public, anon, authenticated;
revoke all on function private.enforce_current_consent_on_governance_assignment()
  from public, anon, authenticated;
revoke all on function private.enforce_current_consent_on_delegation()
  from public, anon, authenticated;
revoke all on function private.enforce_current_consent_on_content_report()
  from public, anon, authenticated;

-- Notification rows may remain as an in-app audit trail, but no new push job is
-- created for a recipient whose current consent gate is closed.
create or replace function private.enqueue_generic_push_notification()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_preferences public.notification_preferences%rowtype;
  v_allowed boolean := true;
  v_has_preferences boolean := false;
  v_event_code text;
  v_title text;
begin
  if not private.has_current_required_consents(new.user_id) then
    return new;
  end if;
  if not private.can_receive_notification(new.id, new.user_id) then
    return new;
  end if;

  select * into v_preferences
  from public.notification_preferences
  where user_id = new.user_id;
  v_has_preferences := found;

  if v_has_preferences and not v_preferences.push_enabled then
    return new;
  end if;

  if new.entity_type in ('event', 'event_occurrence') then
    v_allowed := not v_has_preferences or v_preferences.events_enabled;
    v_event_code := 'community_notice';
    v_title := '새 알림이 있습니다';
  else
    case new.kind
      when 'new_message'::public.notification_kind then
        v_allowed := not v_has_preferences or v_preferences.messages_enabled;
        v_event_code := 'new_message';
        v_title := '새 메시지가 있습니다';
        if exists (
          select 1
          from public.conversation_preferences as preference
          where preference.user_id = new.user_id
            and preference.conversation_id = new.entity_id
            and (
              not preference.notifications_enabled
              or preference.muted_until > pg_catalog.statement_timestamp()
            )
        ) then
          v_allowed := false;
        end if;
      when 'post_comment'::public.notification_kind then
        v_allowed := not v_has_preferences or v_preferences.comments_enabled;
        v_event_code := 'post_comment';
        v_title := '새 알림이 있습니다';
      when 'application_submitted'::public.notification_kind,
           'application_approved'::public.notification_kind,
           'application_rejected'::public.notification_kind,
           'application_withdrawn'::public.notification_kind,
           'membership_changed'::public.notification_kind then
        v_allowed := not v_has_preferences or v_preferences.approvals_enabled;
        v_event_code := 'application_update';
        v_title := '새 알림이 있습니다';
      when 'admin_action'::public.notification_kind then
        v_event_code := 'security_notice';
        v_title := '보안 알림이 있습니다';
      else
        v_allowed := not v_has_preferences or v_preferences.community_enabled;
        v_event_code := 'community_notice';
        v_title := '새 알림이 있습니다';
    end case;
  end if;

  if not v_allowed then
    return new;
  end if;

  insert into private.push_outbox (
    user_id,
    event_code,
    entity_type,
    entity_id,
    title,
    body,
    collapse_key,
    idempotency_key,
    is_silent,
    next_attempt_at
  ) values (
    new.user_id,
    v_event_code,
    coalesce(new.entity_type, 'notification'),
    new.entity_id,
    v_title,
    '앱에서 내용을 확인해 주세요.',
    case when new.entity_id is null then null
      else coalesce(new.entity_type, 'notification') || ':' || new.entity_id::text
    end,
    'notification:' || new.id::text,
    v_has_preferences and v_preferences.lock_screen_preview = 'hidden',
    private.next_push_attempt_at(new.user_id, pg_catalog.clock_timestamp())
  )
  on conflict (idempotency_key) do nothing;

  return new;
end;
$$;

revoke all on function private.enqueue_generic_push_notification()
  from public, anon, authenticated;

-- Once migration 015 is active, the six-argument legacy saver cannot represent
-- the five required decisions. Keep the signature for schema compatibility but
-- fail closed instead of returning a misleading two-document success state.
create or replace function public.save_my_privacy_preferences(
  p_sensitive_affiliation_consent_version text,
  p_community_policy_version text,
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
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  raise exception 'required_consents_v2_required' using errcode = '23514';
end;
$$;

revoke all on function public.save_my_privacy_preferences(
  text, text, boolean, boolean, boolean, boolean
) from public, anon, authenticated;
grant execute on function public.save_my_privacy_preferences(
  text, text, boolean, boolean, boolean, boolean
) to authenticated;

create or replace function public.upsert_my_privacy_preferences(
  p_directory_visibility text,
  p_analytics_opt_in boolean,
  p_push_enabled boolean,
  p_privacy_document_version text,
  p_community_document_version text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  raise exception 'required_consents_v2_required' using errcode = '23514';
end;
$$;

revoke all on function public.upsert_my_privacy_preferences(
  text, boolean, boolean, text, text
) from public, anon, authenticated;
grant execute on function public.upsert_my_privacy_preferences(
  text, boolean, boolean, text, text
) to authenticated;

-- Push registration is a collection operation, so the service-role Edge
-- function may register a target only while that target has current consent.
alter function public.service_register_push_device(
  uuid, uuid, text, text, text, integer, text
) set schema private;
alter function private.service_register_push_device(
  uuid, uuid, text, text, text, integer, text
) rename to register_push_device_before_current_consent_gate;
revoke all on function private.register_push_device_before_current_consent_gate(
  uuid, uuid, text, text, text, integer, text
) from public, anon, authenticated, service_role;

create function public.service_register_push_device(
  p_user_id uuid,
  p_installation_id uuid,
  p_platform text,
  p_token_ciphertext text,
  p_token_fingerprint text,
  p_encryption_key_version integer,
  p_app_version text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_service_role('register_push_device');
  if not private.has_current_required_consents(p_user_id) then
    raise exception 'target_current_required_consents_required'
      using errcode = '42501';
  end if;
  return private.register_push_device_before_current_consent_gate(
    p_user_id,
    p_installation_id,
    p_platform,
    p_token_ciphertext,
    p_token_fingerprint,
    p_encryption_key_version,
    p_app_version
  );
end;
$$;

revoke all on function public.service_register_push_device(
  uuid, uuid, text, text, text, integer, text
) from public, anon, authenticated;
grant execute on function public.service_register_push_device(
  uuid, uuid, text, text, text, integer, text
) to service_role;

-- Existing queued work is also suppressed at claim time. This covers jobs
-- created before a document transition or before a later withdrawal event.
alter function public.service_claim_push_jobs(integer) set schema private;
alter function private.service_claim_push_jobs(integer)
  rename to claim_push_jobs_before_current_consent_gate;
revoke all on function private.claim_push_jobs_before_current_consent_gate(integer)
  from public, anon, authenticated, service_role;

create function public.service_claim_push_jobs(p_limit integer default 50)
returns table (
  delivery_id uuid,
  job_id uuid,
  device_id uuid,
  platform text,
  token_ciphertext text,
  encryption_key_version smallint,
  event_code text,
  entity_type text,
  entity_id uuid,
  title text,
  body text,
  is_silent boolean,
  collapse_key text,
  delivery_attempts integer
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_service_role('claim_push_jobs');

  update private.push_deliveries as delivery
  set status = 'dead',
      claimed_at = null,
      last_error_code = 'current_required_consents_missing',
      updated_at = pg_catalog.clock_timestamp()
  from private.push_outbox as job
  where job.id = delivery.job_id
    and delivery.status in ('pending', 'failed', 'processing')
    and (
      not private.has_current_required_consents(job.user_id)
      or (
        job.idempotency_key like 'notification:%'
        and not private.can_receive_notification(
          private.try_uuid(
            pg_catalog.split_part(job.idempotency_key, ':', 2)
          ),
          job.user_id
        )
      )
    );

  update private.push_outbox as job
  set status = 'dead',
      claimed_at = null,
      last_error_code = 'current_required_consents_missing',
      updated_at = pg_catalog.clock_timestamp()
  where job.status in ('pending', 'failed', 'processing')
    and (
      not private.has_current_required_consents(job.user_id)
      or (
        job.idempotency_key like 'notification:%'
        and not private.can_receive_notification(
          private.try_uuid(
            pg_catalog.split_part(job.idempotency_key, ':', 2)
          ),
          job.user_id
        )
      )
    );

  return query
  select *
  from private.claim_push_jobs_before_current_consent_gate(p_limit);
end;
$$;

revoke all on function public.service_claim_push_jobs(integer)
  from public, anon, authenticated;
grant execute on function public.service_claim_push_jobs(integer)
  to service_role;

-- SECURITY DEFINER entry points that can return an idempotent result or an
-- owner's previously persisted payload must check the actor before touching
-- those rows.  Their pre-015 implementations remain private so the wrappers
-- preserve the already-audited mutation semantics while enforcing the new
-- launch consent boundary first.
alter function public.get_or_create_conversation(uuid) set schema private;
alter function private.get_or_create_conversation(uuid)
  rename to get_or_create_conversation_before_current_consent_gate;
revoke all on function private.get_or_create_conversation_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.get_or_create_conversation(p_other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_actor_organization_id uuid;
  v_error_message text;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_other_user_id is null or p_other_user_id = v_actor_id then
    raise exception 'conversation_requires_another_user' using errcode = '23514';
  end if;

  select membership.organization_id into v_actor_organization_id
  from public.organization_memberships as membership
  join public.organizations as organization
    on organization.id = membership.organization_id
   and organization.status = 'active'::public.organization_status
  join public.profiles as profile
    on profile.id = membership.user_id
   and profile.deactivated_at is null
  where membership.user_id = v_actor_id
    and membership.status = 'active'::public.membership_status;
  if not found then
    raise exception 'active_membership_required' using errcode = '42501';
  end if;

  if not (
    private.is_active_member(v_actor_organization_id, p_other_user_id)
    and not private.users_are_blocked(v_actor_id, p_other_user_id)
  ) then
    raise exception 'conversation_target_unavailable' using errcode = '42501';
  end if;

  begin
    return private.get_or_create_conversation_before_current_consent_gate(
      p_other_user_id
    );
  exception
    when sqlstate '42501' then
      get stacked diagnostics v_error_message = message_text;
      if v_error_message in (
        'user_block_boundary',
        'other_user_must_be_active_in_same_organization'
      ) then
        raise exception 'conversation_target_unavailable' using errcode = '42501';
      end if;
      raise;
  end;
end;
$$;

revoke all on function public.get_or_create_conversation(uuid)
  from public, anon, authenticated;
grant execute on function public.get_or_create_conversation(uuid)
  to authenticated;

alter function public.reconcile_message_batch(uuid, uuid, uuid[]) set schema private;
alter function private.reconcile_message_batch(uuid, uuid, uuid[])
  rename to reconcile_message_batch_before_current_consent_gate;
revoke all on function private.reconcile_message_batch_before_current_consent_gate(
  uuid, uuid, uuid[]
) from public, anon, authenticated;

create function public.reconcile_message_batch(
  p_conversation_id uuid,
  p_expected_sender_id uuid,
  p_client_nonces uuid[]
)
returns table(client_nonce uuid)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if not private.can_access_conversation(p_conversation_id, auth.uid()) then
    raise exception 'conversation_access_forbidden' using errcode = '42501';
  end if;
  return query
  select reconciliation.client_nonce
  from private.reconcile_message_batch_before_current_consent_gate(
    p_conversation_id,
    p_expected_sender_id,
    p_client_nonces
  ) as reconciliation;
end;
$$;

revoke all on function public.reconcile_message_batch(uuid, uuid, uuid[])
  from public, anon, authenticated;
grant execute on function public.reconcile_message_batch(uuid, uuid, uuid[])
  to authenticated;

alter function public.reconcile_post_operation(uuid, uuid) set schema private;
alter function private.reconcile_post_operation(uuid, uuid)
  rename to reconcile_post_operation_before_current_consent_gate;
revoke all on function private.reconcile_post_operation_before_current_consent_gate(uuid, uuid)
  from public, anon, authenticated;

create function public.reconcile_post_operation(
  p_post_id uuid,
  p_expected_author_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.reconcile_post_operation_before_current_consent_gate(
    p_post_id,
    p_expected_author_id
  );
end;
$$;

revoke all on function public.reconcile_post_operation(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.reconcile_post_operation(uuid, uuid)
  to authenticated;

alter function public.save_owned_post_draft(uuid, uuid, uuid, uuid, text, text)
  set schema private;
alter function private.save_owned_post_draft(uuid, uuid, uuid, uuid, text, text)
  rename to save_owned_post_draft_before_current_consent_gate;
revoke all on function private.save_owned_post_draft_before_current_consent_gate(
  uuid, uuid, uuid, uuid, text, text
) from public, anon, authenticated;

create function public.save_owned_post_draft(
  p_post_id uuid,
  p_expected_author_id uuid,
  p_organization_id uuid,
  p_board_id uuid,
  p_title text,
  p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.save_owned_post_draft_before_current_consent_gate(
    p_post_id,
    p_expected_author_id,
    p_organization_id,
    p_board_id,
    p_title,
    p_body
  );
end;
$$;

revoke all on function public.save_owned_post_draft(
  uuid, uuid, uuid, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.save_owned_post_draft(
  uuid, uuid, uuid, uuid, text, text
) to authenticated;

alter function public.cancel_event(uuid, uuid, text) set schema private;
alter function private.cancel_event(uuid, uuid, text)
  rename to cancel_event_before_current_consent_gate;
revoke all on function private.cancel_event_before_current_consent_gate(uuid, uuid, text)
  from public, anon, authenticated;

create function public.cancel_event(
  p_event_id uuid,
  p_client_operation_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.cancel_event_before_current_consent_gate(
    p_event_id,
    p_client_operation_id,
    p_reason
  );
end;
$$;

revoke all on function public.cancel_event(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.cancel_event(uuid, uuid, text)
  to authenticated;

-- Privacy-field visibility -------------------------------------------------
-- Base row authorization and one-way block behavior stay identical to the
-- profiles RLS contract.  Field-specific helpers then apply fail-closed
-- defaults for optional profile fields while keeping self access complete.
create or replace function private.can_view_profile_with_block_semantics(
  p_target_user_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.can_view_profile(p_target_user_id, p_actor_id)
    and (
      p_target_user_id = p_actor_id
      or not private.user_has_blocked(p_actor_id, p_target_user_id)
      or private.is_platform_admin(p_actor_id)
      or exists (
        select 1
        from public.organization_memberships as target_membership
        where target_membership.user_id = p_target_user_id
          and private.can_moderate_organization(
            target_membership.organization_id,
            p_actor_id
          )
      )
    );
$$;

create or replace function private.can_view_profile_avatar(
  p_target_user_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.can_view_profile_with_block_semantics(
      p_target_user_id,
      p_actor_id
    )
    and (
      p_target_user_id = p_actor_id
      or coalesce(
        (
          select preference.avatar_visible
          from public.privacy_preferences as preference
          where preference.user_id = p_target_user_id
        ),
        false
      )
    );
$$;

create or replace function private.can_view_profile_bio(
  p_target_user_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.can_view_profile_with_block_semantics(
      p_target_user_id,
      p_actor_id
    )
    and (
      p_target_user_id = p_actor_id
      or coalesce(
        (
          select preference.bio_visible
          from public.privacy_preferences as preference
          where preference.user_id = p_target_user_id
        ),
        false
      )
    );
$$;

create or replace function private.can_view_church_title(
  p_target_user_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.can_view_profile_with_block_semantics(
      p_target_user_id,
      p_actor_id
    )
    and (
      p_target_user_id = p_actor_id
      or coalesce(
        (
          select preference.church_title_visible
          from public.privacy_preferences as preference
          where preference.user_id = p_target_user_id
        ),
        true
      )
    );
$$;

-- Scoped roster RPCs already enforce their own exact governance/department
-- authority.  Their title projection therefore applies only the target's
-- current-consent state and title preference; requiring same-church profile
-- visibility here would incorrectly blank authorized presbytery/assembly
-- rosters.  Membership-directory projections use can_view_church_title above
-- because that path also needs profile/block semantics.
create or replace function private.church_title_preference_allows(
  p_target_user_id uuid,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.has_current_required_consents(p_actor_id)
    and private.has_current_required_consents(p_target_user_id)
    and (
      p_target_user_id = p_actor_id
      or coalesce(
        (
          select preference.church_title_visible
          from public.privacy_preferences as preference
          where preference.user_id = p_target_user_id
        ),
        true
      )
    );
$$;

revoke all on function private.can_view_profile_with_block_semantics(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_view_profile_avatar(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_view_profile_bio(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.can_view_church_title(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.church_title_preference_allows(uuid, uuid)
  from public, anon, authenticated;

-- Keep the policy expression privilege-independent now that the membership
-- table exposes only its opaque id.  The SECURITY DEFINER helper reproduces
-- the prior one-way block and moderator/platform-admin exceptions.
drop policy if exists profiles_select_authorized on public.profiles;
create policy profiles_select_authorized
on public.profiles for select to authenticated
using (
  private.can_view_profile_with_block_semantics(id, auth.uid())
);
grant execute on function private.can_view_profile_with_block_semantics(uuid, uuid)
  to authenticated;

create or replace function private.can_read_avatar_object(
  p_name text,
  p_actor_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_owner_id uuid := private.try_uuid(pg_catalog.split_part(p_name, '/', 1));
begin
  return v_owner_id is not null
    and private.can_view_profile_avatar(v_owner_id, p_actor_id);
end;
$$;

create or replace function public.list_visible_profiles(
  p_profile_ids uuid[]
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  bio text
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_profile_ids is null
    or pg_catalog.cardinality(p_profile_ids) not between 1 and 200
    or pg_catalog.array_position(p_profile_ids, null::uuid) is not null then
    raise exception 'invalid_profile_directory_request' using errcode = '22023';
  end if;

  return query
  with requested as (
    select requested_id, min(ordinality) as ordinality
    from pg_catalog.unnest(p_profile_ids) with ordinality
      as input(requested_id, ordinality)
    group by requested_id
  )
  select
    profile.id,
    profile.display_name,
    case
      when private.can_view_profile_avatar(profile.id, v_actor_id)
        then profile.avatar_path
      else null
    end,
    case
      when private.can_view_profile_bio(profile.id, v_actor_id)
        then profile.bio
      else null
    end
  from requested
  join public.profiles as profile on profile.id = requested.requested_id
  where private.can_view_profile_with_block_semantics(profile.id, v_actor_id)
  order by requested.ordinality;
end;
$$;

revoke all on function public.list_visible_profiles(uuid[])
  from public, anon, authenticated;
grant execute on function public.list_visible_profiles(uuid[])
  to authenticated;

create or replace function public.list_visible_organization_memberships(
  p_organization_id uuid,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  organization_id uuid,
  user_id uuid,
  role public.app_role,
  church_title_code text,
  status public.membership_status,
  joined_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_organization_id is null and not private.is_platform_admin(v_actor_id) then
    raise exception 'membership_directory_forbidden' using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 500
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_membership_directory_page' using errcode = '22023';
  end if;

  return query
  select
    membership.id,
    membership.organization_id,
    membership.user_id,
    membership.role,
    case
      when private.can_view_church_title(membership.user_id, v_actor_id)
        then membership.church_title_code
      else null
    end,
    membership.status,
    membership.joined_at
  from public.organization_memberships as membership
  where (
      p_organization_id is null
      or membership.organization_id = p_organization_id
    )
    and private.has_current_required_consents(membership.user_id)
    and (
      membership.user_id = v_actor_id
      or private.is_platform_admin(v_actor_id)
      or (
        membership.status = 'active'::public.membership_status
        and private.is_active_member(membership.organization_id, v_actor_id)
      )
      or private.can_manage_members(membership.organization_id, v_actor_id)
    )
  order by membership.joined_at, membership.id
  limit p_limit
  offset p_offset;
end;
$$;

revoke all on function public.list_visible_organization_memberships(
  uuid, integer, integer
) from public, anon, authenticated;
grant execute on function public.list_visible_organization_memberships(
  uuid, integer, integer
) to authenticated;

-- Profiles are RPC-only. Membership Realtime invalidation keeps only the
-- opaque row id; profile id remains the minimum predicate column required by
-- PostgreSQL for the existing self UPDATE path. Every semantic field stays
-- RPC-only.
revoke select on table public.profiles from authenticated;
grant select (id) on public.profiles to authenticated;
revoke select on table public.organization_memberships from authenticated;
revoke select (
  id,
  user_id,
  organization_id,
  role,
  status,
  church_title_code,
  joined_at,
  ended_at,
  updated_at
) on public.organization_memberships from authenticated;
grant select (id) on public.organization_memberships to authenticated;

-- Apply avatar preference masking to both conversation participants while
-- preserving the prior deleted-account history and current-consent filters.
create or replace function public.get_conversation_summaries()
returns table (
  id uuid,
  organization_id uuid,
  participants jsonb,
  last_message jsonb,
  unread_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select
    summary.id,
    summary.organization_id,
    (
      select pg_catalog.jsonb_agg(
        case
          when private.can_view_profile_avatar(
            private.try_uuid(participant.value ->> 'id'),
            v_actor_id
          ) then participant.value
          else pg_catalog.jsonb_set(
            participant.value,
            '{avatar_path}',
            'null'::jsonb,
            true
          )
        end
        order by participant.ordinality
      )
      from pg_catalog.jsonb_array_elements(summary.participants)
        with ordinality as participant(value, ordinality)
    ),
    summary.last_message,
    summary.unread_count
  from private.get_conversation_summaries_before_current_consent_gate() as summary
  where (
      private.has_current_required_consents(
        private.try_uuid(summary.participants -> 0 ->> 'id')
      )
      or not exists (
        select 1
        from public.profiles as profile
        where profile.id = private.try_uuid(summary.participants -> 0 ->> 'id')
      )
    )
    and (
      private.has_current_required_consents(
        private.try_uuid(summary.participants -> 1 ->> 'id')
      )
      or not exists (
        select 1
        from public.profiles as profile
        where profile.id = private.try_uuid(summary.participants -> 1 ->> 'id')
      )
    );
end;
$$;

-- Governance roster search is applied only after title masking so a hidden
-- church title cannot be used as an existence oracle.  The private legacy
-- function still performs all scope, authority, service-year, and AAL checks.
create or replace function public.list_governance_roster(
  p_scope_id uuid,
  p_service_year integer default null,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  display_name text,
  church_title_code text,
  church_title_name text,
  membership_role public.app_role,
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  office_codes text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if v_search is not null and pg_catalog.char_length(v_search) > 80 then
    raise exception 'governance_roster_search_too_long' using errcode = '22001';
  end if;
  if p_limit is null or p_limit not between 1 and 200
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_governance_roster_page' using errcode = '22023';
  end if;

  return query
  with page_meta as (
    select roster.total_count
    from private.list_governance_roster_before_current_consent_gate(
      p_scope_id, p_service_year, null, 1, 0
    ) as roster
    limit 1
  ), all_rows as (
    select roster.*
    from page_meta
    cross join lateral pg_catalog.generate_series(
      0,
      least(
        pg_catalog.ceil(page_meta.total_count / 200.0)::integer - 1,
        50
      )
    ) as batch(batch_number)
    cross join lateral private.list_governance_roster_before_current_consent_gate(
      p_scope_id,
      p_service_year,
      null,
      200,
      batch.batch_number * 200
    ) as roster
  ), masked as (
    select
      all_rows.user_id,
      all_rows.display_name,
      case when title_access.visible then all_rows.church_title_code else null end
        as church_title_code,
      case when title_access.visible then all_rows.church_title_name else null end
        as church_title_name,
      all_rows.membership_role,
      all_rows.organization_id,
      all_rows.organization_name,
      all_rows.presbytery_name,
      all_rows.office_codes
    from all_rows
    cross join lateral (
      select private.church_title_preference_allows(
        all_rows.user_id,
        v_actor_id
      ) as visible
    ) as title_access
    where private.has_current_required_consents(all_rows.user_id)
  ), visible as (
    select masked.*
    from masked
    where v_search is null
      or masked.display_name ilike '%' || v_search || '%'
      or masked.organization_name ilike '%' || v_search || '%'
      or masked.presbytery_name ilike '%' || v_search || '%'
      or coalesce(masked.church_title_name, '') ilike '%' || v_search || '%'
  )
  select
    visible.user_id,
    visible.display_name,
    visible.church_title_code,
    visible.church_title_name,
    visible.membership_role,
    visible.organization_id,
    visible.organization_name,
    visible.presbytery_name,
    visible.office_codes,
    pg_catalog.count(*) over ()::bigint
  from visible
  order by
    (pg_catalog.cardinality(visible.office_codes) > 0) desc,
    visible.organization_name,
    visible.display_name,
    visible.user_id
  limit p_limit
  offset p_offset;
end;
$$;

create or replace function public.list_governance_office_candidates(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  display_name text,
  church_title_code text,
  church_title_name text,
  membership_role public.app_role,
  organization_id uuid,
  organization_name text,
  presbytery_name text,
  office_codes text[],
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if v_search is not null and pg_catalog.char_length(v_search) > 80 then
    raise exception 'governance_candidate_search_too_long' using errcode = '22001';
  end if;
  if p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_governance_candidate_page' using errcode = '22023';
  end if;

  return query
  with page_meta as (
    select candidate.total_count
    from private.list_governance_candidates_before_current_consent_gate(
      p_scope_id, p_service_year, p_office_code, null, 1, 0
    ) as candidate
    limit 1
  ), all_rows as (
    select candidate.*
    from page_meta
    cross join lateral pg_catalog.generate_series(
      0,
      least(
        pg_catalog.ceil(page_meta.total_count / 100.0)::integer - 1,
        100
      )
    ) as batch(batch_number)
    cross join lateral private.list_governance_candidates_before_current_consent_gate(
      p_scope_id,
      p_service_year,
      p_office_code,
      null,
      100,
      batch.batch_number * 100
    ) as candidate
  ), masked as (
    select
      all_rows.user_id,
      all_rows.display_name,
      case when title_access.visible then all_rows.church_title_code else null end
        as church_title_code,
      case when title_access.visible then all_rows.church_title_name else null end
        as church_title_name,
      all_rows.membership_role,
      all_rows.organization_id,
      all_rows.organization_name,
      all_rows.presbytery_name,
      all_rows.office_codes
    from all_rows
    cross join lateral (
      select private.church_title_preference_allows(
        all_rows.user_id,
        v_actor_id
      ) as visible
    ) as title_access
    where private.has_current_required_consents(all_rows.user_id)
  ), visible as (
    select masked.*
    from masked
    where v_search is null
      or masked.display_name ilike '%' || v_search || '%'
      or masked.organization_name ilike '%' || v_search || '%'
      or masked.presbytery_name ilike '%' || v_search || '%'
      or coalesce(masked.church_title_name, '') ilike '%' || v_search || '%'
  )
  select
    visible.user_id,
    visible.display_name,
    visible.church_title_code,
    visible.church_title_name,
    visible.membership_role,
    visible.organization_id,
    visible.organization_name,
    visible.presbytery_name,
    visible.office_codes,
    pg_catalog.count(*) over ()::bigint
  from visible
  order by visible.organization_name, visible.display_name, visible.user_id
  limit p_limit
  offset p_offset;
end;
$$;

create or replace function public.list_department_office_candidates(
  p_department_id uuid,
  p_service_year integer,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  membership_id uuid,
  display_name text,
  church_title_code text,
  membership_role public.app_role,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_search text := nullif(pg_catalog.btrim(p_search), '');
begin
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if v_search is not null and pg_catalog.char_length(v_search) > 80 then
    raise exception 'department_candidate_search_too_long' using errcode = '22001';
  end if;
  if p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000 then
    raise exception 'invalid_department_candidate_page' using errcode = '22023';
  end if;

  return query
  with page_meta as (
    select candidate.total_count
    from private.list_department_candidates_before_current_consent_gate(
      p_department_id, p_service_year, null, 1, 0
    ) as candidate
    limit 1
  ), all_rows as (
    select candidate.*
    from page_meta
    cross join lateral pg_catalog.generate_series(
      0,
      least(
        pg_catalog.ceil(page_meta.total_count / 100.0)::integer - 1,
        100
      )
    ) as batch(batch_number)
    cross join lateral private.list_department_candidates_before_current_consent_gate(
      p_department_id,
      p_service_year,
      null,
      100,
      batch.batch_number * 100
    ) as candidate
  ), masked as (
    select
      all_rows.user_id,
      all_rows.membership_id,
      all_rows.display_name,
      case when title_access.visible then all_rows.church_title_code else null end
        as church_title_code,
      case when title_access.visible then title.display_name else null end
        as church_title_name,
      all_rows.membership_role
    from all_rows
    left join public.church_title_catalog as title
      on title.code = all_rows.church_title_code
    cross join lateral (
      select private.church_title_preference_allows(
        all_rows.user_id,
        v_actor_id
      ) as visible
    ) as title_access
    where private.has_current_required_consents(all_rows.user_id)
  ), visible as (
    select masked.*
    from masked
    where v_search is null
      or masked.display_name ilike '%' || v_search || '%'
      or coalesce(masked.church_title_name, '') ilike '%' || v_search || '%'
  )
  select
    visible.user_id,
    visible.membership_id,
    visible.display_name,
    visible.church_title_code,
    visible.membership_role,
    pg_catalog.count(*) over ()::bigint
  from visible
  order by visible.display_name, visible.user_id
  limit p_limit
  offset p_offset;
end;
$$;

create or replace function public.list_church_departments(
  p_organization_id uuid,
  p_service_year integer default null
)
returns table (
  department_id uuid,
  department_code text,
  display_name text,
  sort_order smallint,
  office_code text,
  user_id uuid,
  member_display_name text,
  church_title_code text,
  membership_role public.app_role
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  return query
  select
    department.department_id,
    department.department_code,
    department.display_name,
    department.sort_order,
    department.office_code,
    case when private.has_current_required_consents(department.user_id)
      then department.user_id else null end,
    case when private.has_current_required_consents(department.user_id)
      then department.member_display_name else null end,
    case when private.church_title_preference_allows(
        department.user_id,
        v_actor_id
      )
      then department.church_title_code else null end,
    case when private.has_current_required_consents(department.user_id)
      then department.membership_role else null end
  from private.list_church_departments_before_current_consent_gate(
    p_organization_id,
    p_service_year
  ) as department;
end;
$$;

-- Protected SECURITY DEFINER entry points must reject a stale/open-tab actor
-- before validating caller-controlled fields or looking up protected UUIDs.
-- Centralize that first-statement contract so every wrapper returns the same
-- fail-closed error and performs no legacy read, lock, or idempotency probe.
create or replace function private.require_current_consent_actor()
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return v_actor_id;
end;
$$;

revoke all on function private.require_current_consent_actor()
  from public, anon, authenticated;

create or replace function private.require_current_consent_target(
  p_target_user_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if p_target_user_id is null
    or not private.has_current_required_consents(p_target_user_id) then
    raise exception 'target_current_required_consents_required'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function private.require_current_consent_target(uuid)
  from public, anon, authenticated;

alter function public.submit_membership_application(
  uuid, public.app_role, text, text, text[], integer
) set schema private;
alter function private.submit_membership_application(
  uuid, public.app_role, text, text, text[], integer
) rename to submit_membership_application_before_current_consent_gate;
revoke all on function private.submit_membership_application_before_current_consent_gate(
  uuid, public.app_role, text, text, text[], integer
) from public, anon, authenticated;

create function public.submit_membership_application(
  p_organization_id uuid,
  p_requested_role public.app_role,
  p_applicant_note text default null,
  p_requested_church_title_code text default null,
  p_requested_executive_office_codes text[] default '{}'::text[],
  p_requested_service_year integer default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_current_consent_actor();
  return private.submit_membership_application_before_current_consent_gate(
    p_organization_id,
    p_requested_role,
    p_applicant_note,
    p_requested_church_title_code,
    p_requested_executive_office_codes,
    p_requested_service_year
  );
end;
$$;

revoke all on function public.submit_membership_application(
  uuid, public.app_role, text, text, text[], integer
) from public, anon, authenticated;
grant execute on function public.submit_membership_application(
  uuid, public.app_role, text, text, text[], integer
) to authenticated;

alter function public.set_membership_application_evidence(uuid, text)
  set schema private;
alter function private.set_membership_application_evidence(uuid, text)
  rename to set_membership_application_evidence_before_current_consent_gate;
revoke all on function private.set_membership_application_evidence_before_current_consent_gate(
  uuid, text
) from public, anon, authenticated;

create function public.set_membership_application_evidence(
  p_application_id uuid,
  p_evidence_path text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.membership_applications as application
    where application.id = p_application_id
      and application.user_id = v_actor_id
  ) then
    raise exception 'application_owner_forbidden' using errcode = '42501';
  end if;
  perform private.set_membership_application_evidence_before_current_consent_gate(
    p_application_id,
    p_evidence_path
  );
end;
$$;

revoke all on function public.set_membership_application_evidence(uuid, text)
  from public, anon, authenticated;
grant execute on function public.set_membership_application_evidence(uuid, text)
  to authenticated;

alter function public.withdraw_membership_application(uuid)
  set schema private;
alter function private.withdraw_membership_application(uuid)
  rename to withdraw_membership_application_before_current_consent_gate;
revoke all on function private.withdraw_membership_application_before_current_consent_gate(
  uuid
) from public, anon, authenticated;

create function public.withdraw_membership_application(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.membership_applications as application
    where application.id = p_application_id
      and application.user_id = v_actor_id
  ) then
    raise exception 'application_owner_forbidden' using errcode = '42501';
  end if;
  perform private.withdraw_membership_application_before_current_consent_gate(
    p_application_id
  );
end;
$$;

revoke all on function public.withdraw_membership_application(uuid)
  from public, anon, authenticated;
grant execute on function public.withdraw_membership_application(uuid)
  to authenticated;

alter function public.review_membership_application(
  uuid, public.review_decision, text
) set schema private;
alter function private.review_membership_application(
  uuid, public.review_decision, text
) rename to review_membership_application_before_current_consent_gate;
revoke all on function private.review_membership_application_before_current_consent_gate(
  uuid, public.review_decision, text
) from public, anon, authenticated;

create function public.review_membership_application(
  p_application_id uuid,
  p_decision public.review_decision,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_actor_is_platform_admin boolean;
  v_actor_is_scoped_reviewer boolean := false;
  v_target_user_id uuid;
  v_requested_role public.app_role;
  v_application_status public.application_status;
begin
  v_actor_id := private.require_current_consent_actor();
  v_actor_is_platform_admin := private.is_platform_admin(v_actor_id);

  -- A non-admin must prove exact-organization member-review authority before
  -- the legacy function is allowed to reveal whether the UUID exists, its
  -- review state, or whether the request/current membership is leadership.
  -- Keep those predicates in one server-side boolean so every unauthorized
  -- target shape produces the same response.
  select
    application.user_id,
    application.requested_role,
    application.status,
    application.user_id <> v_actor_id
      and application.requested_role = 'member'::public.app_role
      and private.can_manage_members(
        application.organization_id,
        v_actor_id
      )
      and not exists (
        select 1
        from public.organization_memberships as current_target
        where current_target.user_id = application.user_id
          and current_target.status = 'active'::public.membership_status
          and current_target.role in (
            'minister'::public.app_role,
            'executive'::public.app_role
          )
      )
  into
    v_target_user_id,
    v_requested_role,
    v_application_status,
    v_actor_is_scoped_reviewer
  from public.membership_applications as application
  where application.id = p_application_id;

  if not v_actor_is_platform_admin
    and not coalesce(v_actor_is_scoped_reviewer, false) then
    raise exception 'membership_application_review_forbidden'
      using errcode = '42501';
  end if;

  -- Preserve the established AAL2 rule for a still-pending leadership
  -- decision, but enforce it before entering the legacy row-locking path.
  if v_application_status = 'pending'::public.application_status
    and v_requested_role in (
      'minister'::public.app_role,
      'executive'::public.app_role
    ) then
    perform private.require_aal2('leadership_membership_review');
  end if;

  -- Rejection remains a safety-reducing operation for a non-current target.
  -- Approval is the only branch that can activate protected membership data.
  if v_application_status = 'pending'::public.application_status
    and p_decision = 'approve'::public.review_decision then
    perform private.require_current_consent_target(v_target_user_id);
  end if;

  return private.review_membership_application_before_current_consent_gate(
    p_application_id,
    p_decision,
    p_reason
  );
end;
$$;

revoke all on function public.review_membership_application(
  uuid, public.review_decision, text
) from public, anon, authenticated;
grant execute on function public.review_membership_application(
  uuid, public.review_decision, text
) to authenticated;

alter function public.set_membership_status(
  uuid, public.membership_status, text
) set schema private;
alter function private.set_membership_status(
  uuid, public.membership_status, text
) rename to set_membership_status_before_current_consent_gate;
revoke all on function private.set_membership_status_before_current_consent_gate(
  uuid, public.membership_status, text
) from public, anon, authenticated;

create function public.set_membership_status(
  p_membership_id uuid,
  p_status public.membership_status,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_actor_is_platform_admin boolean;
  v_actor_is_scoped_manager boolean := false;
  v_target_user_id uuid;
  v_current_status public.membership_status;
begin
  v_actor_id := private.require_current_consent_actor();
  v_actor_is_platform_admin := private.is_platform_admin(v_actor_id);

  -- Resolve authority and protected target attributes in one non-observable
  -- predicate. A non-admin receives one error for missing, self, foreign,
  -- leadership, suspended, or revoked membership UUIDs outside their scope.
  select
    membership.user_id,
    membership.status,
    membership.user_id <> v_actor_id
      and membership.role not in (
        'minister'::public.app_role,
        'executive'::public.app_role
      )
      and private.can_manage_members(
        membership.organization_id,
        v_actor_id
      )
  into
    v_target_user_id,
    v_current_status,
    v_actor_is_scoped_manager
  from public.organization_memberships as membership
  where membership.id = p_membership_id;

  if not v_actor_is_platform_admin
    and not coalesce(v_actor_is_scoped_manager, false) then
    raise exception 'membership_status_change_forbidden'
      using errcode = '42501';
  end if;

  -- Suspension/revocation must remain available for safety cleanup. Only a
  -- transition back to active requires current evidence from the target.
  if v_target_user_id is not null
    and v_current_status is distinct from 'active'::public.membership_status
    and p_status = 'active'::public.membership_status then
    perform private.require_current_consent_target(v_target_user_id);
  end if;

  perform private.set_membership_status_before_current_consent_gate(
    p_membership_id,
    p_status,
    p_reason
  );
end;
$$;

revoke all on function public.set_membership_status(
  uuid, public.membership_status, text
) from public, anon, authenticated;
grant execute on function public.set_membership_status(
  uuid, public.membership_status, text
) to authenticated;

alter function public.update_organization_profile(uuid, jsonb)
  set schema private;
alter function private.update_organization_profile(uuid, jsonb)
  rename to update_organization_profile_before_current_consent_gate;
revoke all on function private.update_organization_profile_before_current_consent_gate(
  uuid, jsonb
) from public, anon, authenticated;

create function public.update_organization_profile(
  p_organization_id uuid,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_current_consent_actor();
  return private.update_organization_profile_before_current_consent_gate(
    p_organization_id,
    p_patch
  );
end;
$$;

revoke all on function public.update_organization_profile(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.update_organization_profile(uuid, jsonb)
  to authenticated;

alter function public.publish_owned_post(uuid, uuid, text[])
  set schema private;
alter function private.publish_owned_post(uuid, uuid, text[])
  rename to publish_owned_post_before_current_consent_gate;
revoke all on function private.publish_owned_post_before_current_consent_gate(
  uuid, uuid, text[]
) from public, anon, authenticated;

create function public.publish_owned_post(
  p_post_id uuid,
  p_expected_author_id uuid,
  p_expected_media_paths text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_current_consent_actor();
  return private.publish_owned_post_before_current_consent_gate(
    p_post_id,
    p_expected_author_id,
    p_expected_media_paths
  );
end;
$$;

revoke all on function public.publish_owned_post(uuid, uuid, text[])
  from public, anon, authenticated;
grant execute on function public.publish_owned_post(uuid, uuid, text[])
  to authenticated;

alter function public.send_message(
  uuid, public.message_kind, text, text, jsonb, uuid
) set schema private;
alter function private.send_message(
  uuid, public.message_kind, text, text, jsonb, uuid
) rename to send_message_before_current_consent_gate;
revoke all on function private.send_message_before_current_consent_gate(
  uuid, public.message_kind, text, text, jsonb, uuid
) from public, anon, authenticated;

create function public.send_message(
  p_conversation_id uuid,
  p_kind public.message_kind,
  p_body text default null,
  p_media_path text default null,
  p_media_metadata jsonb default '{}'::jsonb,
  p_client_nonce uuid default gen_random_uuid()
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.conversations as conversation
    where conversation.id = p_conversation_id
      and private.can_access_conversation(conversation.id, v_actor_id)
  ) then
    raise exception 'conversation_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  return private.send_message_before_current_consent_gate(
    p_conversation_id,
    p_kind,
    p_body,
    p_media_path,
    p_media_metadata,
    p_client_nonce
  );
end;
$$;

revoke all on function public.send_message(
  uuid, public.message_kind, text, text, jsonb, uuid
) from public, anon, authenticated;
grant execute on function public.send_message(
  uuid, public.message_kind, text, text, jsonb, uuid
) to authenticated;

alter function public.send_message_batch(uuid, uuid, jsonb)
  set schema private;
alter function private.send_message_batch(uuid, uuid, jsonb)
  rename to send_message_batch_before_current_consent_gate;
revoke all on function private.send_message_batch_before_current_consent_gate(
  uuid, uuid, jsonb
) from public, anon, authenticated;

create function public.send_message_batch(
  p_conversation_id uuid,
  p_expected_sender_id uuid,
  p_messages jsonb
)
returns uuid[]
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.conversations as conversation
    where conversation.id = p_conversation_id
      and private.can_access_conversation(conversation.id, v_actor_id)
  ) then
    raise exception 'conversation_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  return private.send_message_batch_before_current_consent_gate(
    p_conversation_id,
    p_expected_sender_id,
    p_messages
  );
end;
$$;

revoke all on function public.send_message_batch(uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.send_message_batch(uuid, uuid, jsonb)
  to authenticated;

alter function public.mark_conversation_read(uuid, uuid)
  set schema private;
alter function private.mark_conversation_read(uuid, uuid)
  rename to mark_conversation_read_before_current_consent_gate;
revoke all on function private.mark_conversation_read_before_current_consent_gate(
  uuid, uuid
) from public, anon, authenticated;

create function public.mark_conversation_read(
  p_conversation_id uuid,
  p_message_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform private.require_current_consent_actor();
  perform private.mark_conversation_read_before_current_consent_gate(
    p_conversation_id,
    p_message_id
  );
end;
$$;

revoke all on function public.mark_conversation_read(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.mark_conversation_read(uuid, uuid)
  to authenticated;

alter function public.resolve_content_report(uuid, text, text)
  set schema private;
alter function private.resolve_content_report(uuid, text, text)
  rename to resolve_content_report_before_current_consent_gate;
revoke all on function private.resolve_content_report_before_current_consent_gate(
  uuid, text, text
) from public, anon, authenticated;

create function public.resolve_content_report(
  p_report_id uuid,
  p_action text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.content_reports as report
    where report.id = p_report_id
      and private.can_moderate_organization(
        report.organization_id,
        v_actor_id
      )
  ) then
    raise exception 'content_report_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  return private.resolve_content_report_before_current_consent_gate(
    p_report_id,
    p_action,
    p_reason
  );
end;
$$;

revoke all on function public.resolve_content_report(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.resolve_content_report(uuid, text, text)
  to authenticated;

alter function public.revoke_governance_delegation(uuid, text)
  set schema private;
alter function private.revoke_governance_delegation(uuid, text)
  rename to revoke_governance_delegation_before_current_consent_gate;
revoke all on function private.revoke_governance_delegation_before_current_consent_gate(
  uuid, text
) from public, anon, authenticated;

create function public.revoke_governance_delegation(
  p_delegation_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_delegation_id is null then
    raise exception 'delegation_id_required' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.governance_authority_delegations as delegation
    where delegation.id = p_delegation_id
      and (
        v_actor_id in (
          delegation.grantor_user_id,
          delegation.delegate_user_id
        )
        or private.has_native_governance_authority(
          delegation.scope_id,
          v_actor_id
        )
      )
  ) then
    raise exception 'governance_delegation_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  perform private.revoke_governance_delegation_before_current_consent_gate(
    p_delegation_id,
    p_reason
  );
end;
$$;

revoke all on function public.revoke_governance_delegation(uuid, text)
  from public, anon, authenticated;
grant execute on function public.revoke_governance_delegation(uuid, text)
  to authenticated;

-- Executive record UUIDs are client generated and may be cached. Resolve live
-- rows and durable tombstones only within the supplied authorized church so a
-- retry cannot distinguish a foreign live/deleted record from an unavailable
-- operation ID.
alter function public.save_meeting_minute(
  uuid, boolean, uuid, integer, date, text, text, text
) set schema private;
alter function private.save_meeting_minute(
  uuid, boolean, uuid, integer, date, text, text, text
) rename to save_meeting_minute_before_resource_gate;
revoke all on function private.save_meeting_minute_before_resource_gate(
  uuid, boolean, uuid, integer, date, text, text, text
) from public, anon, authenticated;

create function public.save_meeting_minute(
  p_id uuid,
  p_create boolean,
  p_organization_id uuid,
  p_meeting_year integer,
  p_meeting_date date,
  p_title text,
  p_body text,
  p_status text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_row_organization_id uuid;
  v_tombstone_organization_id uuid;
  v_row_found boolean;
  v_tombstone_found boolean;
  v_error_message text;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_create is null or p_id is null then
    raise exception 'meeting_minute_operation_id_required'
      using errcode = '22023';
  end if;
  if not private.can_manage_meeting_minutes(
    p_organization_id,
    v_actor_id
  ) then
    raise exception 'meeting_minute_write_forbidden' using errcode = '42501';
  end if;

  select minute.organization_id into v_row_organization_id
  from public.meeting_minutes as minute
  where minute.id = p_id;
  v_row_found := found;
  select tombstone.organization_id into v_tombstone_organization_id
  from private.executive_operation_tombstones as tombstone
  where tombstone.entity_type = 'meeting_minute'
    and tombstone.entity_id = p_id;
  v_tombstone_found := found;

  if (v_row_found and v_row_organization_id is distinct from p_organization_id)
    or (
      v_tombstone_found
      and v_tombstone_organization_id is distinct from p_organization_id
    )
    or (
      not p_create
      and not v_row_found
      and not v_tombstone_found
    ) then
    raise exception 'meeting_minute_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;

  begin
    return private.save_meeting_minute_before_resource_gate(
      p_id,
      p_create,
      p_organization_id,
      p_meeting_year,
      p_meeting_date,
      p_title,
      p_body,
      p_status
    );
  exception
    when sqlstate '42501' or sqlstate 'P0002' then
      get stacked diagnostics v_error_message = message_text;
      if v_error_message in (
        'meeting_minute_organization_mismatch',
        'meeting_minute_not_found'
      ) then
        raise exception 'meeting_minute_not_found_or_forbidden'
          using errcode = 'P0002';
      end if;
      raise;
  end;
end;
$$;

revoke all on function public.save_meeting_minute(
  uuid, boolean, uuid, integer, date, text, text, text
) from public, anon, authenticated;
grant execute on function public.save_meeting_minute(
  uuid, boolean, uuid, integer, date, text, text, text
) to authenticated;

alter function public.save_ledger_entry(
  uuid, boolean, uuid, integer, date, text, text, text, numeric, text
) set schema private;
alter function private.save_ledger_entry(
  uuid, boolean, uuid, integer, date, text, text, text, numeric, text
) rename to save_ledger_entry_before_resource_gate;
revoke all on function private.save_ledger_entry_before_resource_gate(
  uuid, boolean, uuid, integer, date, text, text, text, numeric, text
) from public, anon, authenticated;

create function public.save_ledger_entry(
  p_id uuid,
  p_create boolean,
  p_organization_id uuid,
  p_fiscal_year integer,
  p_entry_date date,
  p_entry_type text,
  p_category text,
  p_description text,
  p_amount numeric,
  p_memo text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_row_organization_id uuid;
  v_tombstone_organization_id uuid;
  v_row_found boolean;
  v_tombstone_found boolean;
  v_error_message text;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_create is null or p_id is null then
    raise exception 'ledger_operation_id_required' using errcode = '22023';
  end if;
  if not private.can_manage_ledger(p_organization_id, v_actor_id) then
    raise exception 'ledger_write_forbidden' using errcode = '42501';
  end if;

  select entry.organization_id into v_row_organization_id
  from public.ledger_entries as entry
  where entry.id = p_id;
  v_row_found := found;
  select tombstone.organization_id into v_tombstone_organization_id
  from private.executive_operation_tombstones as tombstone
  where tombstone.entity_type = 'ledger_entry'
    and tombstone.entity_id = p_id;
  v_tombstone_found := found;

  if (v_row_found and v_row_organization_id is distinct from p_organization_id)
    or (
      v_tombstone_found
      and v_tombstone_organization_id is distinct from p_organization_id
    )
    or (
      not p_create
      and not v_row_found
      and not v_tombstone_found
    ) then
    raise exception 'ledger_entry_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;

  begin
    return private.save_ledger_entry_before_resource_gate(
      p_id,
      p_create,
      p_organization_id,
      p_fiscal_year,
      p_entry_date,
      p_entry_type,
      p_category,
      p_description,
      p_amount,
      p_memo
    );
  exception
    when sqlstate '42501' or sqlstate 'P0002' then
      get stacked diagnostics v_error_message = message_text;
      if v_error_message in (
        'ledger_entry_organization_mismatch',
        'ledger_entry_not_found'
      ) then
        raise exception 'ledger_entry_not_found_or_forbidden'
          using errcode = 'P0002';
      end if;
      raise;
  end;
end;
$$;

revoke all on function public.save_ledger_entry(
  uuid, boolean, uuid, integer, date, text, text, text, numeric, text
) from public, anon, authenticated;
grant execute on function public.save_ledger_entry(
  uuid, boolean, uuid, integer, date, text, text, text, numeric, text
) to authenticated;

alter function public.delete_meeting_minute(uuid)
  set schema private;
alter function private.delete_meeting_minute(uuid)
  rename to delete_meeting_minute_before_current_consent_gate;
revoke all on function private.delete_meeting_minute_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.delete_meeting_minute(p_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.meeting_minutes as minute
    where minute.id = p_id
      and private.can_manage_meeting_minutes(
        minute.organization_id,
        v_actor_id
      )
  ) then
    raise exception 'meeting_minute_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  perform private.delete_meeting_minute_before_current_consent_gate(p_id);
end;
$$;

revoke all on function public.delete_meeting_minute(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_meeting_minute(uuid)
  to authenticated;

alter function public.delete_ledger_entry(uuid)
  set schema private;
alter function private.delete_ledger_entry(uuid)
  rename to delete_ledger_entry_before_current_consent_gate;
revoke all on function private.delete_ledger_entry_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.delete_ledger_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.ledger_entries as entry
    where entry.id = p_id
      and private.can_manage_ledger(entry.organization_id, v_actor_id)
  ) then
    raise exception 'ledger_entry_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  perform private.delete_ledger_entry_before_current_consent_gate(p_id);
end;
$$;

revoke all on function public.delete_ledger_entry(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_ledger_entry(uuid)
  to authenticated;

-- Target-bearing assignment and delegation RPCs first establish the actor's
-- exact-scope/AAL2 authority, then reject a withdrawn target before target
-- eligibility reads can become a state oracle.
alter function public.set_governance_offices(uuid, integer, uuid, text[])
  set schema private;
alter function private.set_governance_offices(uuid, integer, uuid, text[])
  rename to set_governance_offices_before_current_consent_gate;
revoke all on function private.set_governance_offices_before_current_consent_gate(
  uuid, integer, uuid, text[]
) from public, anon, authenticated;

create function public.set_governance_offices(
  p_scope_id uuid,
  p_service_year integer,
  p_user_id uuid,
  p_office_codes text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not private.can_manage_governance_offices(p_scope_id, v_actor_id) then
    raise exception 'governance_office_management_forbidden'
      using errcode = '42501';
  end if;
  perform private.require_aal2('governance_office_assignments.insert');
  if pg_catalog.cardinality(coalesce(p_office_codes, '{}'::text[])) > 0 then
    perform private.require_current_consent_target(p_user_id);
  end if;
  return private.set_governance_offices_before_current_consent_gate(
    p_scope_id,
    p_service_year,
    p_user_id,
    p_office_codes
  );
end;
$$;

revoke all on function public.set_governance_offices(uuid, integer, uuid, text[])
  from public, anon, authenticated;
grant execute on function public.set_governance_offices(uuid, integer, uuid, text[])
  to authenticated;

alter function public.assign_governance_office(uuid, integer, text, uuid)
  set schema private;
alter function private.assign_governance_office(uuid, integer, text, uuid)
  rename to assign_governance_office_before_current_consent_gate;
revoke all on function private.assign_governance_office_before_current_consent_gate(
  uuid, integer, text, uuid
) from public, anon, authenticated;

create function public.assign_governance_office(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not private.can_manage_governance_offices(p_scope_id, v_actor_id) then
    raise exception 'governance_office_management_forbidden'
      using errcode = '42501';
  end if;
  perform private.require_aal2('governance_office_assignments.insert');
  perform private.require_current_consent_target(p_user_id);
  return private.assign_governance_office_before_current_consent_gate(
    p_scope_id,
    p_service_year,
    p_office_code,
    p_user_id
  );
end;
$$;

revoke all on function public.assign_governance_office(uuid, integer, text, uuid)
  from public, anon, authenticated;
grant execute on function public.assign_governance_office(uuid, integer, text, uuid)
  to authenticated;

alter function public.set_executive_offices(uuid, integer, text[])
  set schema private;
alter function private.set_executive_offices(uuid, integer, text[])
  rename to set_executive_offices_before_current_consent_gate;
revoke all on function private.set_executive_offices_before_current_consent_gate(
  uuid, integer, text[]
) from public, anon, authenticated;

create function public.set_executive_offices(
  p_membership_id uuid,
  p_service_year integer,
  p_office_codes text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_target_user_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  select membership.user_id into v_target_user_id
  from public.organization_memberships as membership
  join public.governance_scopes as scope
    on scope.scope_type = 'church'::public.governance_scope_type
   and scope.organization_id = membership.organization_id
   and scope.is_active
  where membership.id = p_membership_id
    and membership.role = 'executive'::public.app_role
    and membership.status = 'active'::public.membership_status
    and private.can_manage_governance_offices(scope.id, v_actor_id);
  if not found then
    raise exception 'governance_office_management_forbidden'
      using errcode = '42501';
  end if;
  perform private.require_aal2('governance_office_assignments.insert');
  perform private.require_current_consent_target(v_target_user_id);
  return private.set_executive_offices_before_current_consent_gate(
    p_membership_id,
    p_service_year,
    p_office_codes
  );
end;
$$;

revoke all on function public.set_executive_offices(uuid, integer, text[])
  from public, anon, authenticated;
grant execute on function public.set_executive_offices(uuid, integer, text[])
  to authenticated;

alter function public.grant_governance_delegation(
  uuid, uuid, text[], timestamptz, text
) set schema private;
alter function private.grant_governance_delegation(
  uuid, uuid, text[], timestamptz, text
) rename to grant_governance_delegation_before_current_consent_gate;
revoke all on function private.grant_governance_delegation_before_current_consent_gate(
  uuid, uuid, text[], timestamptz, text
) from public, anon, authenticated;

create function public.grant_governance_delegation(
  p_scope_id uuid,
  p_delegate_user_id uuid,
  p_capabilities text[],
  p_expires_at timestamptz,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not private.has_native_governance_authority(p_scope_id, v_actor_id) then
    raise exception 'native_scope_authority_required_for_delegation'
      using errcode = '42501';
  end if;
  perform private.require_aal2('governance_authority_delegations.insert');
  perform private.require_current_consent_target(p_delegate_user_id);
  return private.grant_governance_delegation_before_current_consent_gate(
    p_scope_id,
    p_delegate_user_id,
    p_capabilities,
    p_expires_at,
    p_reason
  );
end;
$$;

revoke all on function public.grant_governance_delegation(
  uuid, uuid, text[], timestamptz, text
) from public, anon, authenticated;
grant execute on function public.grant_governance_delegation(
  uuid, uuid, text[], timestamptz, text
) to authenticated;

alter function public.grant_event_management_delegation(
  uuid, uuid, timestamptz, text
) set schema private;
alter function private.grant_event_management_delegation(
  uuid, uuid, timestamptz, text
) rename to grant_event_management_delegation_before_current_consent_gate;
revoke all on function private.grant_event_management_delegation_before_current_consent_gate(
  uuid, uuid, timestamptz, text
) from public, anon, authenticated;

create function public.grant_event_management_delegation(
  p_scope_id uuid,
  p_delegate_user_id uuid,
  p_expires_at timestamptz,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not private.has_native_governance_authority(p_scope_id, v_actor_id) then
    raise exception 'native_scope_authority_required_for_delegation'
      using errcode = '42501';
  end if;
  perform private.require_aal2('event_management_delegation');
  perform private.require_current_consent_target(p_delegate_user_id);
  return private.grant_event_management_delegation_before_current_consent_gate(
    p_scope_id,
    p_delegate_user_id,
    p_expires_at,
    p_reason
  );
end;
$$;

revoke all on function public.grant_event_management_delegation(
  uuid, uuid, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.grant_event_management_delegation(
  uuid, uuid, timestamptz, text
) to authenticated;

-- Safety evidence stays immutable in Postgres and remains available through
-- the redacting moderator RPC only; raw table grants would bypass its target
-- pseudonymization and field minimization.
revoke select on table public.content_reports from authenticated;
revoke select on table public.moderation_actions from authenticated;

alter function public.respond_to_event(uuid, text, uuid) set schema private;
alter function private.respond_to_event(uuid, text, uuid)
  rename to respond_to_event_before_current_consent_gate;
revoke all on function private.respond_to_event_before_current_consent_gate(uuid, text, uuid)
  from public, anon, authenticated;

create function public.respond_to_event(
  p_occurrence_id uuid,
  p_response text,
  p_client_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_occurrence_id is not null
    and not exists (
      select 1
      from public.event_occurrences as occurrence
      join public.events as event on event.id = occurrence.event_id
      where occurrence.id = p_occurrence_id
        and private.can_read_event_scope(event.scope_id, v_actor_id)
    ) then
    raise exception 'event_occurrence_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;
  return private.respond_to_event_before_current_consent_gate(
    p_occurrence_id,
    p_response,
    p_client_operation_id
  );
end;
$$;

revoke all on function public.respond_to_event(uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.respond_to_event(uuid, text, uuid)
  to authenticated;

-- Event revision snapshots remain part of the authorized audit trail after a
-- target withdraws.  Only the mutable live profile label is redacted.
alter function public.list_event_revisions(uuid) set schema private;
alter function private.list_event_revisions(uuid)
  rename to list_event_revisions_before_current_consent_gate;
revoke all on function private.list_event_revisions_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.list_event_revisions(p_event_id uuid)
returns table (
  revision integer,
  action text,
  snapshot jsonb,
  changed_by uuid,
  changed_by_name text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if not exists (
    select 1
    from public.events as event
    where event.id = p_event_id
      and private.can_manage_events(event.scope_id, v_actor_id)
  ) then
    raise exception 'event_revision_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;

  return query
  select
    history.revision,
    history.action,
    history.snapshot - 'created_by' - 'updated_by',
    case
      when history.changed_by is null
        or not private.has_current_required_consents(history.changed_by)
        then null::uuid
      else history.changed_by
    end,
    case
      when history.changed_by is null then history.changed_by_name
      when private.has_current_required_consents(history.changed_by) then history.changed_by_name
      when not exists (
        select 1 from public.profiles as profile where profile.id = history.changed_by
      ) then '탈퇴한 회원'::text
      else '동의 갱신 필요 회원'::text
    end,
    history.created_at
  from private.list_event_revisions_before_current_consent_gate(p_event_id) as history;
end;
$$;

revoke all on function public.list_event_revisions(uuid)
  from public, anon, authenticated;
grant execute on function public.list_event_revisions(uuid)
  to authenticated;

-- Moderation evidence is an immutable safety record and cannot disappear just
-- because the reported account later withdraws consent.  Preserve the report
-- and snapshot while redacting mutable live profile labels for non-current
-- users.  The moderator actor is still subject to the central consent gate.
create or replace function public.list_moderation_reports(
  p_status text default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  organization_name text,
  target_type text,
  target_id uuid,
  reported_user_id uuid,
  target_author_name text,
  reporter_display_name text,
  reason_code text,
  details text,
  evidence_summary text,
  status text,
  created_at timestamptz,
  resolved_at timestamptz,
  resolution_reason text
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'invalid_report_limit' using errcode = '22023';
  end if;
  if p_status is not null
    and p_status not in ('open', 'reviewing', 'resolved', 'dismissed', 'escalated') then
    raise exception 'invalid_report_status' using errcode = '22023';
  end if;

  return query
  select
    report.id,
    report.organization_id,
    organization.display_name,
    report.target_type,
    report.target_id,
    report.reported_user_id,
    case
      when report.reported_user_id is null then target_profile.display_name
      when private.has_current_required_consents(report.reported_user_id) then target_profile.display_name
      when target_profile.id is null then '탈퇴한 회원'::text
      else '동의 갱신 필요 회원'::text
    end,
    case
      when private.has_current_required_consents(report.reporter_id) then reporter_profile.display_name
      when reporter_profile.id is null then '탈퇴한 회원'::text
      else '동의 갱신 필요 회원'::text
    end,
    report.reason_code,
    report.details,
    case report.target_type
      when 'post' then coalesce(report.evidence_snapshot ->> 'title', '게시글')
        || ' · ' || pg_catalog.left(coalesce(report.evidence_snapshot ->> 'body_excerpt', ''), 240)
      when 'comment' then pg_catalog.left(coalesce(report.evidence_snapshot ->> 'body_excerpt', '댓글'), 280)
      when 'message' then pg_catalog.left(coalesce(report.evidence_snapshot ->> 'body_excerpt', '메시지 또는 미디어'), 280)
      else case
        when report.reported_user_id is null
          or private.has_current_required_consents(report.reported_user_id)
          then coalesce(report.evidence_snapshot ->> 'display_name', '사용자 프로필')
        when target_profile.id is null then '탈퇴한 회원'::text
        else '동의 갱신 필요 회원'::text
      end
    end,
    report.status,
    report.created_at,
    report.resolved_at,
    report.resolution_note
  from public.content_reports as report
  left join public.organizations as organization on organization.id = report.organization_id
  left join public.profiles as target_profile on target_profile.id = report.reported_user_id
  left join public.profiles as reporter_profile on reporter_profile.id = report.reporter_id
  where private.can_moderate_organization(report.organization_id, v_actor_id)
    and (p_status is null or report.status = p_status)
  order by
    case report.status when 'open' then 0 when 'reviewing' then 1 when 'escalated' then 2 else 3 end,
    report.created_at,
    report.id
  limit p_limit;
end;
$$;

revoke all on function public.list_moderation_reports(text, integer)
  from public, anon, authenticated;
grant execute on function public.list_moderation_reports(text, integer)
  to authenticated;

-- Ordinary post/comment reads follow the author's current consent.  Historical
-- moderation snapshots remain available through the scoped moderation RPC.
drop policy if exists comments_select_authorized on public.comments;
create policy comments_select_authorized
on public.comments for select to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and private.can_read_post(post_id, auth.uid())
  and (
    status = 'active'::public.comment_status
    or author_id = auth.uid()
    or private.can_manage_post(post_id, auth.uid())
  )
  and (
    author_id is null
    or (
      private.has_current_required_consents(author_id)
      and (
        author_id = auth.uid()
        or not private.user_has_blocked(auth.uid(), author_id)
        or private.can_manage_post(post_id, auth.uid())
      )
    )
  )
);

drop policy if exists comments_update_author_or_staff on public.comments;
create policy comments_update_author_or_staff
on public.comments for update to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and (
    author_id = auth.uid()
    or private.can_manage_post(post_id, auth.uid())
  )
)
with check (
  private.has_current_required_consents(auth.uid())
  and (
    author_id = auth.uid()
    or private.can_manage_post(post_id, auth.uid())
  )
);

-- RSVP rows are retained as the user's historical preference, but only users
-- with the current exact consent set participate in capacity, wait-list, and
-- aggregate calculations. Re-consent makes the preserved RSVP effective
-- again without rewriting the audit history.
create or replace function private.respond_to_event_before_current_consent_gate(
  p_occurrence_id uuid,
  p_response text,
  p_client_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_requested_response text := pg_catalog.lower(pg_catalog.btrim(p_response));
  v_occurrence public.event_occurrences%rowtype;
  v_event public.events%rowtype;
  v_existing public.event_rsvps%rowtype;
  v_operation private.event_rsvp_operations%rowtype;
  v_effective_response text;
  v_yes_count integer;
  v_waitlist_count integer;
  v_waitlist_position integer;
  v_promote_user_id uuid;
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_occurrence_id is null or p_client_operation_id is null then
    raise exception 'occurrence_and_operation_id_required' using errcode = '22023';
  end if;
  if v_requested_response not in ('yes', 'no', 'maybe') then
    raise exception 'invalid_event_response' using errcode = '23514';
  end if;

  select * into v_operation
  from private.event_rsvp_operations as operation
  where operation.actor_id = v_actor_id
    and operation.operation_id = p_client_operation_id;
  if found then
    if v_operation.occurrence_id <> p_occurrence_id
      or v_operation.requested_response <> v_requested_response then
      raise exception 'event_rsvp_operation_id_conflict' using errcode = '42501';
    end if;
    select event.* into v_event
    from public.event_occurrences as occurrence
    join public.events as event on event.id = occurrence.event_id
    where occurrence.id = p_occurrence_id;
    if not found then
      raise exception 'event_occurrence_not_found' using errcode = 'P0002';
    end if;
    if not private.can_read_event_scope(v_event.scope_id, v_actor_id) then
      raise exception 'event_read_forbidden' using errcode = '42501';
    end if;
    select
      pg_catalog.count(*) filter (where rsvp.response = 'yes')::integer,
      pg_catalog.count(*) filter (where rsvp.response = 'waitlist')::integer
    into v_yes_count, v_waitlist_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = p_occurrence_id
      and private.has_current_required_consents(rsvp.user_id);

    v_waitlist_position := null;
    if v_operation.result ->> 'response' = 'waitlist' then
      select position into v_waitlist_position
      from (
        select
          rsvp.user_id,
          row_number() over (
            order by rsvp.responded_at, rsvp.user_id
          )::integer as position
        from public.event_rsvps as rsvp
        where rsvp.occurrence_id = p_occurrence_id
          and rsvp.response = 'waitlist'
          and private.has_current_required_consents(rsvp.user_id)
      ) as positions
      where positions.user_id = v_actor_id;
    end if;

    return v_operation.result || pg_catalog.jsonb_build_object(
      'yes_count', v_yes_count,
      'waitlist_count', v_waitlist_count,
      'waitlist_position', v_waitlist_position
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('event-rsvp:' || p_occurrence_id::text, 0)
  );
  select * into v_occurrence
  from public.event_occurrences as occurrence
  where occurrence.id = p_occurrence_id
  for update;
  if not found then
    raise exception 'event_occurrence_not_found' using errcode = 'P0002';
  end if;

  select * into v_event
  from public.events as event
  where event.id = v_occurrence.event_id;
  if not private.can_read_event_scope(v_event.scope_id, v_actor_id) then
    raise exception 'event_read_forbidden' using errcode = '42501';
  end if;
  if v_event.status <> 'scheduled'
    or v_occurrence.status <> 'scheduled'
    or v_occurrence.starts_at <= pg_catalog.statement_timestamp() then
    raise exception 'event_rsvp_closed' using errcode = '55000';
  end if;

  select * into v_existing
  from public.event_rsvps as rsvp
  where rsvp.occurrence_id = p_occurrence_id
    and rsvp.user_id = v_actor_id
  for update;

  if v_requested_response = 'yes' and v_event.capacity is not null then
    select pg_catalog.count(*)::integer into v_yes_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = p_occurrence_id
      and rsvp.response = 'yes'
      and rsvp.user_id <> v_actor_id
      and private.has_current_required_consents(rsvp.user_id);
    v_effective_response := case
      when v_yes_count >= v_event.capacity then 'waitlist'
      else 'yes'
    end;
  else
    v_effective_response := v_requested_response;
  end if;

  perform private.consume_rate_limit(v_actor_id, 'event_rsvps', 30, 60, 1);
  insert into public.event_rsvps (
    occurrence_id,
    user_id,
    response,
    responded_at
  ) values (
    p_occurrence_id,
    v_actor_id,
    v_effective_response,
    pg_catalog.clock_timestamp()
  )
  on conflict (occurrence_id, user_id)
  do update set
    response = excluded.response,
    responded_at = case
      when event_rsvps.response is distinct from excluded.response
        then excluded.responded_at
      else event_rsvps.responded_at
    end;

  if found
    and v_existing.response = 'yes'
    and v_effective_response <> 'yes' then
    select rsvp.user_id into v_promote_user_id
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = p_occurrence_id
      and rsvp.response = 'waitlist'
      and private.has_current_required_consents(rsvp.user_id)
    order by rsvp.responded_at, rsvp.user_id
    limit 1
    for update;

    if v_promote_user_id is not null then
      update public.event_rsvps
      set response = 'yes'
      where occurrence_id = p_occurrence_id
        and user_id = v_promote_user_id;

      insert into public.notifications (
        user_id,
        kind,
        title,
        body,
        entity_type,
        entity_id,
        metadata
      ) values (
        v_promote_user_id,
        'admin_action'::public.notification_kind,
        '일정 참석이 확정되었습니다',
        '대기 중이던 일정에 자리가 생겨 참석으로 변경되었습니다. 앱에서 일정을 확인해 주세요.',
        'event_occurrence',
        p_occurrence_id,
        pg_catalog.jsonb_build_object('event_id', v_event.id)
      );
    end if;
  end if;

  select
    pg_catalog.count(*) filter (where rsvp.response = 'yes')::integer,
    pg_catalog.count(*) filter (where rsvp.response = 'waitlist')::integer
  into v_yes_count, v_waitlist_count
  from public.event_rsvps as rsvp
  where rsvp.occurrence_id = p_occurrence_id
    and private.has_current_required_consents(rsvp.user_id);

  if v_effective_response = 'waitlist' then
    select position into v_waitlist_position
    from (
      select
        rsvp.user_id,
        row_number() over (order by rsvp.responded_at, rsvp.user_id)::integer as position
      from public.event_rsvps as rsvp
      where rsvp.occurrence_id = p_occurrence_id
        and rsvp.response = 'waitlist'
        and private.has_current_required_consents(rsvp.user_id)
    ) as positions
    where positions.user_id = v_actor_id;
  end if;

  v_result := pg_catalog.jsonb_build_object(
    'occurrence_id', p_occurrence_id,
    'requested_response', v_requested_response,
    'response', v_effective_response,
    'yes_count', v_yes_count,
    'waitlist_count', v_waitlist_count,
    'waitlist_position', v_waitlist_position
  );
  insert into private.event_rsvp_operations (
    actor_id,
    operation_id,
    occurrence_id,
    requested_response,
    result
  ) values (
    v_actor_id,
    p_client_operation_id,
    p_occurrence_id,
    v_requested_response,
    v_result
  );

  perform private.write_audit(
    v_actor_id,
    'event.rsvp',
    'event_occurrence',
    p_occurrence_id,
    null,
    v_actor_id,
    pg_catalog.jsonb_build_object('response', v_effective_response)
  );
  return v_result;
end;
$$;

revoke all on function private.respond_to_event_before_current_consent_gate(
  uuid, text, uuid
) from public, anon, authenticated;

create or replace function public.list_event_occurrences(
  p_from timestamptz,
  p_to timestamptz,
  p_scope_id uuid default null,
  p_limit integer default 100
)
returns table (
  occurrence_id uuid,
  event_id uuid,
  scope_id uuid,
  scope_type public.governance_scope_type,
  scope_name text,
  title text,
  description text,
  location_text text,
  starts_at timestamptz,
  ends_at timestamptz,
  capacity integer,
  event_status text,
  occurrence_status text,
  recurrence_frequency text,
  recurrence_interval smallint,
  recurrence_weekdays smallint[],
  recurrence_month_day smallint,
  recurrence_until timestamptz,
  recurrence_count smallint,
  reminder_offsets_minutes integer[],
  revision integer,
  own_response text,
  yes_count bigint,
  maybe_count bigint,
  waitlist_count bigint,
  waitlist_position bigint,
  can_manage boolean
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null
    or p_to <= p_from
    or p_to > p_from + interval '366 days' then
    raise exception 'invalid_event_occurrence_range' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'invalid_event_occurrence_limit' using errcode = '22023';
  end if;
  if p_scope_id is not null
    and not private.can_read_event_scope(p_scope_id, v_actor_id) then
    raise exception 'event_read_forbidden' using errcode = '42501';
  end if;

  return query
  select
    occurrence.id,
    event.id,
    event.scope_id,
    scope.scope_type,
    scope.display_name,
    event.title,
    event.description,
    event.location_text,
    occurrence.starts_at,
    occurrence.ends_at,
    event.capacity,
    event.status,
    occurrence.status,
    event.recurrence_frequency,
    event.recurrence_interval,
    event.recurrence_weekdays,
    event.recurrence_month_day,
    event.recurrence_until,
    event.recurrence_count,
    event.reminder_offsets_minutes,
    event.revision,
    own_rsvp.response,
    coalesce(totals.yes_count, 0),
    coalesce(totals.maybe_count, 0),
    coalesce(totals.waitlist_count, 0),
    own_rsvp.waitlist_position,
    private.can_manage_events(event.scope_id, v_actor_id)
  from public.event_occurrences as occurrence
  join public.events as event on event.id = occurrence.event_id
  join public.governance_scopes as scope on scope.id = event.scope_id
  left join lateral (
    select
      pg_catalog.count(*) filter (where rsvp.response = 'yes') as yes_count,
      pg_catalog.count(*) filter (where rsvp.response = 'maybe') as maybe_count,
      pg_catalog.count(*) filter (where rsvp.response = 'waitlist') as waitlist_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = occurrence.id
      and private.has_current_required_consents(rsvp.user_id)
  ) as totals on true
  left join lateral (
    select
      mine.response,
      case
        when mine.response = 'waitlist' then (
          select pg_catalog.count(*)
          from public.event_rsvps as ahead
          where ahead.occurrence_id = occurrence.id
            and ahead.response = 'waitlist'
            and private.has_current_required_consents(ahead.user_id)
            and row(ahead.responded_at, ahead.user_id)
              <= row(mine.responded_at, mine.user_id)
        )
        else null
      end as waitlist_position
    from public.event_rsvps as mine
    where mine.occurrence_id = occurrence.id
      and mine.user_id = v_actor_id
      and private.has_current_required_consents(mine.user_id)
  ) as own_rsvp on true
  where occurrence.starts_at >= p_from
    and occurrence.starts_at < p_to
    and (p_scope_id is null or event.scope_id = p_scope_id)
    and private.can_read_event_scope(event.scope_id, v_actor_id)
  order by occurrence.starts_at, event.title, occurrence.id
  limit p_limit;
end;
$$;

revoke all on function public.list_event_occurrences(
  timestamptz, timestamptz, uuid, integer
) from public, anon, authenticated;
grant execute on function public.list_event_occurrences(
  timestamptz, timestamptz, uuid, integer
) to authenticated;

create or replace function public.get_event_occurrence(p_occurrence_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(v_actor_id) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'occurrence_id', occurrence.id,
    'event_id', event.id,
    'scope_id', event.scope_id,
    'scope_type', scope.scope_type,
    'scope_name', scope.display_name,
    'title', event.title,
    'description', event.description,
    'location_text', event.location_text,
    'starts_at', occurrence.starts_at,
    'ends_at', occurrence.ends_at,
    'capacity', event.capacity,
    'event_status', event.status,
    'occurrence_status', occurrence.status,
    'recurrence_frequency', event.recurrence_frequency,
    'recurrence_interval', event.recurrence_interval,
    'recurrence_weekdays', event.recurrence_weekdays,
    'recurrence_month_day', event.recurrence_month_day,
    'recurrence_until', event.recurrence_until,
    'recurrence_count', event.recurrence_count,
    'reminder_offsets_minutes', event.reminder_offsets_minutes,
    'revision', event.revision,
    'own_response', mine.response,
    'yes_count', coalesce(totals.yes_count, 0),
    'maybe_count', coalesce(totals.maybe_count, 0),
    'waitlist_count', coalesce(totals.waitlist_count, 0),
    'waitlist_position', case
      when mine.response = 'waitlist' then (
        select pg_catalog.count(*)
        from public.event_rsvps as ahead
        where ahead.occurrence_id = occurrence.id
          and ahead.response = 'waitlist'
          and private.has_current_required_consents(ahead.user_id)
          and row(ahead.responded_at, ahead.user_id)
            <= row(mine.responded_at, mine.user_id)
      )
      else null
    end,
    'can_manage', private.can_manage_events(event.scope_id, v_actor_id)
  ) into v_result
  from public.event_occurrences as occurrence
  join public.events as event on event.id = occurrence.event_id
  join public.governance_scopes as scope on scope.id = event.scope_id
  left join public.event_rsvps as mine
    on mine.occurrence_id = occurrence.id
   and mine.user_id = v_actor_id
   and private.has_current_required_consents(mine.user_id)
  left join lateral (
    select
      pg_catalog.count(*) filter (where rsvp.response = 'yes') as yes_count,
      pg_catalog.count(*) filter (where rsvp.response = 'maybe') as maybe_count,
      pg_catalog.count(*) filter (where rsvp.response = 'waitlist') as waitlist_count
    from public.event_rsvps as rsvp
    where rsvp.occurrence_id = occurrence.id
      and private.has_current_required_consents(rsvp.user_id)
  ) as totals on true
  where occurrence.id = p_occurrence_id
    and private.can_read_event_scope(event.scope_id, v_actor_id);

  if v_result is null then
    raise exception 'event_occurrence_not_found_or_forbidden' using errcode = 'P0002';
  end if;
  return v_result;
end;
$$;

revoke all on function public.get_event_occurrence(uuid)
  from public, anon, authenticated;
grant execute on function public.get_event_occurrence(uuid)
  to authenticated;

-- Other authenticated SECURITY DEFINER paths are protected at their first
-- statement as well.  Device removal and account-deletion functions are
-- intentionally not wrapped because they are the explicit cleanup escape
-- hatches available while the consent gate is closed.
alter function public.prepare_post_media_cleanup(uuid, uuid, text[]) set schema private;
alter function private.prepare_post_media_cleanup(uuid, uuid, text[])
  rename to prepare_post_media_cleanup_before_current_consent_gate;
revoke all on function private.prepare_post_media_cleanup_before_current_consent_gate(
  uuid, uuid, text[]
) from public, anon, authenticated;

create function public.prepare_post_media_cleanup(
  p_post_id uuid,
  p_expected_author_id uuid,
  p_storage_paths text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.prepare_post_media_cleanup_before_current_consent_gate(
    p_post_id,
    p_expected_author_id,
    p_storage_paths
  );
end;
$$;

revoke all on function public.prepare_post_media_cleanup(uuid, uuid, text[])
  from public, anon, authenticated;
grant execute on function public.prepare_post_media_cleanup(uuid, uuid, text[])
  to authenticated;

alter function public.mark_notifications_read(uuid[]) set schema private;
alter function private.mark_notifications_read(uuid[])
  rename to mark_notifications_read_before_current_consent_gate;
revoke all on function private.mark_notifications_read_before_current_consent_gate(uuid[])
  from public, anon, authenticated;

create function public.mark_notifications_read(
  p_notification_ids uuid[] default null
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.mark_notifications_read_before_current_consent_gate(
    p_notification_ids
  );
end;
$$;

revoke all on function public.mark_notifications_read(uuid[])
  from public, anon, authenticated;
grant execute on function public.mark_notifications_read(uuid[])
  to authenticated;

alter function public.block_user(uuid, text) set schema private;
alter function private.block_user(uuid, text)
  rename to block_user_before_current_consent_gate;
revoke all on function private.block_user_before_current_consent_gate(uuid, text)
  from public, anon, authenticated;

create function public.block_user(
  p_user_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();

  if p_user_id is null or p_user_id = v_actor_id then
    raise exception 'invalid_block_target' using errcode = '23514';
  end if;
  if p_reason is not null and pg_catalog.char_length(p_reason) > 500 then
    raise exception 'block_reason_too_long' using errcode = '22001';
  end if;

  -- A new block requires the same actor-bound profile eligibility used by the
  -- directory.  An existing block remains idempotently repeatable after the
  -- target withdraws consent, because safety boundaries must not disappear or
  -- become unmanageable when the blocked account closes its consent gate.
  if not (
    private.can_view_profile(p_user_id, v_actor_id)
    or exists (
      select 1
      from public.user_blocks as existing_block
      where existing_block.blocker_id = v_actor_id
        and existing_block.blocked_user_id = p_user_id
    )
  ) then
    raise exception 'block_target_unavailable'
      using errcode = '42501';
  end if;

  return private.block_user_before_current_consent_gate(p_user_id, p_reason);
end;
$$;

revoke all on function public.block_user(uuid, text)
  from public, anon, authenticated;
grant execute on function public.block_user(uuid, text)
  to authenticated;

alter function public.unblock_user(uuid) set schema private;
alter function private.unblock_user(uuid)
  rename to unblock_user_before_current_consent_gate;
revoke all on function private.unblock_user_before_current_consent_gate(uuid)
  from public, anon, authenticated;

create function public.unblock_user(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.unblock_user_before_current_consent_gate(p_user_id);
end;
$$;

revoke all on function public.unblock_user(uuid)
  from public, anon, authenticated;
grant execute on function public.unblock_user(uuid)
  to authenticated;

alter function public.save_my_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean,
  text, text, text, text
) set schema private;
alter function private.save_my_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean,
  text, text, text, text
) rename to save_my_notification_preferences_before_current_consent_gate;
revoke all on function private.save_my_notification_preferences_before_current_consent_gate(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean,
  text, text, text, text
) from public, anon, authenticated;

create function public.save_my_notification_preferences(
  p_push_enabled boolean,
  p_approvals boolean,
  p_posts boolean,
  p_comments boolean,
  p_chats boolean,
  p_governance boolean,
  p_events boolean,
  p_quiet_hours_enabled boolean,
  p_quiet_hours_start text,
  p_quiet_hours_end text,
  p_time_zone text,
  p_lock_screen_preview text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.save_my_notification_preferences_before_current_consent_gate(
    p_push_enabled,
    p_approvals,
    p_posts,
    p_comments,
    p_chats,
    p_governance,
    p_events,
    p_quiet_hours_enabled,
    p_quiet_hours_start,
    p_quiet_hours_end,
    p_time_zone,
    p_lock_screen_preview
  );
end;
$$;

revoke all on function public.save_my_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean,
  text, text, text, text
) from public, anon, authenticated;
grant execute on function public.save_my_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean,
  text, text, text, text
) to authenticated;

alter function public.list_my_security_activity(integer) set schema private;
alter function private.list_my_security_activity(integer)
  rename to list_my_security_activity_before_current_consent_gate;
revoke all on function private.list_my_security_activity_before_current_consent_gate(integer)
  from public, anon, authenticated;

create function public.list_my_security_activity(p_limit integer default 50)
returns table (
  id uuid,
  action text,
  action_label text,
  occurred_at timestamptz,
  device_label text,
  ip_hint text
)
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return query
  select activity.id,
         activity.action,
         activity.action_label,
         activity.occurred_at,
         activity.device_label,
         activity.ip_hint
  from private.list_my_security_activity_before_current_consent_gate(
    p_limit
  ) as activity;
end;
$$;

revoke all on function public.list_my_security_activity(integer)
  from public, anon, authenticated;
grant execute on function public.list_my_security_activity(integer)
  to authenticated;

alter function public.touch_my_push_device(uuid, text) set schema private;
alter function private.touch_my_push_device(uuid, text)
  rename to touch_my_push_device_before_current_consent_gate;
revoke all on function private.touch_my_push_device_before_current_consent_gate(uuid, text)
  from public, anon, authenticated;

create function public.touch_my_push_device(
  p_device_id uuid,
  p_app_version text default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.touch_my_push_device_before_current_consent_gate(
    p_device_id,
    p_app_version
  );
end;
$$;

revoke all on function public.touch_my_push_device(uuid, text)
  from public, anon, authenticated;
grant execute on function public.touch_my_push_device(uuid, text)
  to authenticated;

alter function public.assign_department_office(uuid, integer, text, uuid)
  set schema private;
alter function private.assign_department_office(uuid, integer, text, uuid)
  rename to assign_department_office_before_current_consent_gate;
revoke all on function private.assign_department_office_before_current_consent_gate(
  uuid, integer, text, uuid
) from public, anon, authenticated;

create function public.assign_department_office(
  p_department_id uuid,
  p_service_year integer,
  p_office_code text,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();

  -- Authority and AAL are checked before any target-dependent predicate so an
  -- outsider receives one uniform error for real, withdrawn, and unknown UUIDs.
  if not private.can_manage_department_offices(
    p_department_id,
    v_actor_id
  ) then
    raise exception 'department_office_management_forbidden'
      using errcode = '42501';
  end if;

  perform private.require_aal2('department_office_assignment');
  perform private.require_current_consent_target(p_user_id);

  return private.assign_department_office_before_current_consent_gate(
    p_department_id,
    p_service_year,
    p_office_code,
    p_user_id
  );
end;
$$;

revoke all on function public.assign_department_office(uuid, integer, text, uuid)
  from public, anon, authenticated;
grant execute on function public.assign_department_office(uuid, integer, text, uuid)
  to authenticated;

alter function public.create_content_report(text, uuid, text, text)
  set schema private;
alter function private.create_content_report(text, uuid, text, text)
  rename to create_content_report_before_current_consent_gate;
revoke all on function private.create_content_report_before_current_consent_gate(
  text, uuid, text, text
) from public, anon, authenticated;

create function public.create_content_report(
  p_target_type text,
  p_target_id uuid,
  p_reason_code text,
  p_details text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_target_accessible boolean := true;
  v_organization_id uuid;
  v_snapshot jsonb;
  v_report_id uuid;
  v_existing_reason text;
begin
  v_actor_id := private.require_current_consent_actor();

  -- Caller-controlled validation remains target-independent, while every
  -- valid but inaccessible UUID shares one response before the legacy replay
  -- or snapshot path can disclose protected state.
  if p_target_type not in ('post', 'comment', 'message', 'profile')
    or p_target_id is null then
    raise exception 'invalid_report_target' using errcode = '22023';
  end if;
  if p_reason_code not in (
    'harassment', 'spam', 'hate', 'sexual_content', 'violence',
    'privacy', 'impersonation', 'self_harm', 'other'
  ) then
    raise exception 'invalid_report_reason' using errcode = '22023';
  end if;
  if p_details is not null and char_length(p_details) > 2000 then
    raise exception 'report_details_too_long' using errcode = '22001';
  end if;

  if p_target_type = 'profile' then
    if p_target_id = v_actor_id then
      raise exception 'cannot_report_self' using errcode = '23514';
    end if;

    -- Profile reporting remains available when the target hides their bio.
    -- Capture only the fields the reporter can currently view, and require an
    -- exact active shared church plus the normal consent/block boundary.
    select
      actor_membership.organization_id,
      pg_catalog.jsonb_build_object(
        'target_type', 'profile',
        'id', profile.id,
        'display_name', profile.display_name,
        'bio_excerpt', case
          when private.can_view_profile_bio(profile.id, v_actor_id)
            then pg_catalog.left(coalesce(profile.bio, ''), 1000)
          else null
        end,
        'captured_at', pg_catalog.clock_timestamp()
      )
    into v_organization_id, v_snapshot
    from public.organization_memberships as actor_membership
    join public.organization_memberships as target_membership
      on target_membership.organization_id = actor_membership.organization_id
     and target_membership.status = 'active'::public.membership_status
    join public.organizations as organization
      on organization.id = actor_membership.organization_id
     and organization.status = 'active'::public.organization_status
    join public.profiles as profile
      on profile.id = target_membership.user_id
     and profile.deactivated_at is null
    where actor_membership.user_id = v_actor_id
      and actor_membership.status = 'active'::public.membership_status
      and target_membership.user_id = p_target_id
      and private.can_view_profile_with_block_semantics(
        profile.id,
        v_actor_id
      )
    limit 1;

    if v_snapshot is null then
      raise exception 'report_target_not_accessible' using errcode = '42501';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'report:' || v_actor_id::text || ':profile:' || p_target_id::text,
        0
      )
    );
    select report.id, report.reason_code
    into v_report_id, v_existing_reason
    from public.content_reports as report
    where report.reporter_id = v_actor_id
      and report.target_type = 'profile'
      and report.target_id = p_target_id
      and report.status in ('open', 'reviewing', 'escalated')
    order by report.created_at desc
    limit 1;

    if v_report_id is not null then
      if v_existing_reason = p_reason_code then
        return v_report_id;
      end if;
      raise exception 'active_report_already_exists' using errcode = '23505';
    end if;

    perform private.consume_rate_limit(v_actor_id, 'reports', 5, 3600, 1);
    insert into public.content_reports (
      reporter_id,
      organization_id,
      target_type,
      target_id,
      reported_user_id,
      reason_code,
      details,
      evidence_snapshot
    ) values (
      v_actor_id,
      v_organization_id,
      'profile',
      p_target_id,
      p_target_id,
      p_reason_code,
      nullif(pg_catalog.btrim(p_details), ''),
      v_snapshot
    )
    returning id into v_report_id;

    perform private.write_audit(
      v_actor_id,
      'moderation.report_created',
      'content_report',
      v_report_id,
      v_organization_id,
      p_target_id,
      pg_catalog.jsonb_build_object(
        'target_type', 'profile',
        'target_id', p_target_id,
        'reason_code', p_reason_code
      )
    );
    return v_report_id;
  elsif p_target_type = 'comment' then
    select exists (
      select 1
      from public.comments as comment
      join public.posts as post on post.id = comment.post_id
      where comment.id = p_target_id
        and private.can_read_post(post.id, v_actor_id)
        and (
          comment.status = 'active'::public.comment_status
          or comment.author_id = v_actor_id
          or private.can_manage_post(post.id, v_actor_id)
        )
        and (
          comment.author_id is null
          or (
            private.has_current_required_consents(comment.author_id)
            and (
              comment.author_id = v_actor_id
              or not private.user_has_blocked(v_actor_id, comment.author_id)
              or private.can_manage_post(post.id, v_actor_id)
            )
          )
        )
    ) into v_target_accessible;
  end if;

  if not coalesce(v_target_accessible, false) then
    raise exception 'report_target_not_accessible' using errcode = '42501';
  end if;
  return private.create_content_report_before_current_consent_gate(
    p_target_type,
    p_target_id,
    p_reason_code,
    p_details
  );
end;
$$;

revoke all on function public.create_content_report(text, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.create_content_report(text, uuid, text, text)
  to authenticated;

-- Executive records remain available to authorized executives, but immutable
-- author identifiers are never exposed through direct table SELECT.  The
-- application already requests only this explicit non-identifying column set.
revoke select on table public.meeting_minutes from authenticated;
revoke select on table public.ledger_entries from authenticated;
grant select (
  id,
  organization_id,
  meeting_year,
  meeting_date,
  title,
  body,
  status,
  created_at,
  updated_at
) on public.meeting_minutes to authenticated;
grant select (
  id,
  organization_id,
  fiscal_year,
  entry_date,
  entry_type,
  category,
  description,
  amount,
  memo,
  created_at,
  updated_at
) on public.ledger_entries to authenticated;

revoke select on table public.executive_office_assignments from authenticated;
grant select (
  id,
  membership_id,
  service_year,
  office_code,
  created_at,
  ended_at
) on public.executive_office_assignments to authenticated;

-- Remove secondary actor UUIDs from direct REST surfaces.  RLS still decides
-- which rows are visible; column privileges constrain every visible row to the
-- fields the production client actually requests.
revoke select on table public.organizations from authenticated;
grant select (
  id,
  source_name,
  display_name,
  slug,
  presbytery,
  description,
  location_text,
  contact_phone,
  website_url,
  worship_schedule,
  hero_path,
  status,
  claimed_at
) on public.organizations to authenticated;

revoke select on table public.boards from authenticated;
grant select (
  id,
  organization_id,
  slug,
  name,
  description,
  sort_order,
  is_global,
  is_read_only,
  staff_only_posting,
  created_at,
  updated_at
) on public.boards to authenticated;

revoke select on table public.organization_memberships from authenticated;
grant select (
  id,
  user_id,
  organization_id,
  role,
  status,
  church_title_code,
  joined_at,
  ended_at,
  updated_at
) on public.organization_memberships to authenticated;

revoke select on table public.membership_applications from authenticated;
grant select (
  id,
  user_id,
  organization_id,
  requested_role,
  requested_church_title_code,
  requested_executive_office_codes,
  requested_service_year,
  status,
  applicant_note,
  review_reason,
  reviewed_at,
  created_at,
  updated_at
) on public.membership_applications to authenticated;

revoke select on table public.platform_admins from authenticated;

-- These audit/governance/event tables are RPC-only.  Repeat the revokes in
-- this transition so future grant drift cannot expose snapshots or actor IDs.
revoke select on table public.event_revisions from authenticated;
revoke select on table public.events from authenticated;
revoke select on table public.event_occurrences from authenticated;
revoke select on table public.event_rsvps from authenticated;
revoke select on table public.governance_office_assignments from authenticated;
revoke select on table public.governance_authority_delegations from authenticated;
revoke select on table public.department_office_assignments from authenticated;
revoke select on table public.audit_logs from authenticated;

-- Clearing an office is a deactivation path and remains permitted when the
-- prior holder has not re-consented.  The mutation result must not reveal that
-- hidden holder's UUID.
alter function public.clear_governance_office(uuid, integer, text)
  set schema private;
alter function private.clear_governance_office(uuid, integer, text)
  rename to clear_governance_office_before_target_consent_redaction;
revoke all on function private.clear_governance_office_before_target_consent_redaction(
  uuid, integer, text
) from public, anon, authenticated;

create function public.clear_governance_office(
  p_scope_id uuid,
  p_service_year integer,
  p_office_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_result jsonb;
  v_target_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  v_result := private.clear_governance_office_before_target_consent_redaction(
    p_scope_id,
    p_service_year,
    p_office_code
  );
  v_target_id := private.try_uuid(v_result ->> 'user_id');
  if v_target_id is not null
    and not private.has_current_required_consents(v_target_id) then
    v_result := (v_result - 'user_id')
      || pg_catalog.jsonb_build_object('user_id', null);
  end if;
  return v_result;
end;
$$;

revoke all on function public.clear_governance_office(uuid, integer, text)
  from public, anon, authenticated;
grant execute on function public.clear_governance_office(uuid, integer, text)
  to authenticated;

alter function public.clear_department_office(uuid, integer, text)
  set schema private;
alter function private.clear_department_office(uuid, integer, text)
  rename to clear_department_office_before_target_consent_redaction;
revoke all on function private.clear_department_office_before_target_consent_redaction(
  uuid, integer, text
) from public, anon, authenticated;

create function public.clear_department_office(
  p_department_id uuid,
  p_service_year integer,
  p_office_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_result jsonb;
  v_target_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  v_result := private.clear_department_office_before_target_consent_redaction(
    p_department_id,
    p_service_year,
    p_office_code
  );
  v_target_id := private.try_uuid(v_result ->> 'user_id');
  if v_target_id is not null
    and not private.has_current_required_consents(v_target_id) then
    v_result := (v_result - 'user_id')
      || pg_catalog.jsonb_build_object('user_id', null);
  end if;
  return v_result;
end;
$$;

revoke all on function public.clear_department_office(uuid, integer, text)
  from public, anon, authenticated;
grant execute on function public.clear_department_office(uuid, integer, text)
  to authenticated;

-- Media abandonment is a protected cleanup workflow, not a consent escape
-- hatch. Keep the legacy signatures for open clients, but perform the exact
-- current-consent check before the original SECURITY DEFINER functions can
-- inspect intents, Storage ownership, cleanup rows, or idempotency state.
alter function public.abandon_media_upload_intents(text[])
  set schema private;
alter function private.abandon_media_upload_intents(text[])
  rename to abandon_media_upload_intents_before_current_consent_gate;
revoke all on function private.abandon_media_upload_intents_before_current_consent_gate(
  text[]
) from public, anon, authenticated;

create function public.abandon_media_upload_intents(
  p_approved_paths text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.abandon_media_upload_intents_before_current_consent_gate(
    p_approved_paths
  );
end;
$$;

revoke all on function public.abandon_media_upload_intents(text[])
  from public, anon, authenticated;
grant execute on function public.abandon_media_upload_intents(text[])
  to authenticated;

alter function public.abandon_direct_media_objects(text, text[])
  set schema private;
alter function private.abandon_direct_media_objects(text, text[])
  rename to abandon_direct_media_objects_before_current_consent_gate;
revoke all on function private.abandon_direct_media_objects_before_current_consent_gate(
  text, text[]
) from public, anon, authenticated;

create function public.abandon_direct_media_objects(
  p_bucket_id text,
  p_storage_paths text[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.has_current_required_consents(auth.uid()) then
    raise exception 'current_required_consents_required' using errcode = '42501';
  end if;
  return private.abandon_direct_media_objects_before_current_consent_gate(
    p_bucket_id,
    p_storage_paths
  );
end;
$$;

revoke all on function public.abandon_direct_media_objects(text, text[])
  from public, anon, authenticated;
grant execute on function public.abandon_direct_media_objects(text, text[])
  to authenticated;

drop policy if exists jaegun_quarantine_media_delete on storage.objects;
create policy jaegun_quarantine_media_delete
on storage.objects for delete to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'community-media-quarantine'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.can_write_quarantine_media(name, auth.uid(), metadata)
);

drop policy if exists jaegun_community_media_delete on storage.objects;
create policy jaegun_community_media_delete
on storage.objects for delete to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'community-media'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.can_mutate_direct_media_object(bucket_id, name, auth.uid())
);

drop policy if exists jaegun_avatars_delete on storage.objects;
create policy jaegun_avatars_delete
on storage.objects for delete to authenticated
using (
  private.has_current_required_consents(auth.uid())
  and bucket_id = 'avatars'
  and (
    (owner_id = auth.uid()::text and (owner is null or owner = auth.uid()))
    or (owner_id is null and owner = auth.uid())
  )
  and private.can_mutate_direct_media_object(bucket_id, name, auth.uid())
);

-- Replays are authorization checks, not bearer receipts. Validate the
-- caller's current exact-scope authority and AAL2 before the legacy function
-- can return a cached cancellation result.
create or replace function public.cancel_event(
  p_event_id uuid,
  p_client_operation_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_scope_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();

  if p_event_id is not null then
    select event.scope_id into v_scope_id
    from public.events as event
    where event.id = p_event_id
      and private.can_manage_events(event.scope_id, v_actor_id);
    if not found then
      raise exception 'event_not_found_or_forbidden'
        using errcode = 'P0002';
    end if;
    perform private.require_aal2('event_cancel');
  end if;

  return private.cancel_event_before_current_consent_gate(
    p_event_id,
    p_client_operation_id,
    p_reason
  );
end;
$$;

revoke all on function public.cancel_event(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.cancel_event(uuid, uuid, text)
  to authenticated;

-- Event save/update has a single resource-and-authority resolution boundary.
-- A caller cannot distinguish a foreign existing event from a missing ID by
-- changing the supplied scope, create flag, or otherwise-invalid payload.
alter function public.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) set schema private;
alter function private.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) rename to save_event_before_authority_gate;
revoke all on function private.save_event_before_authority_gate(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) from public, anon, authenticated;

create function public.save_event(
  p_id uuid,
  p_create boolean,
  p_scope_id uuid,
  p_title text,
  p_description text,
  p_location_text text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_capacity integer,
  p_recurrence_frequency text,
  p_recurrence_interval integer,
  p_recurrence_weekdays smallint[],
  p_recurrence_month_day integer,
  p_recurrence_until timestamptz,
  p_recurrence_count integer,
  p_reminder_offsets_minutes integer[]
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid;
  v_existing_scope_id uuid;
begin
  v_actor_id := private.require_current_consent_actor();
  if p_id is null or p_create is null or p_scope_id is null then
    raise exception 'event_id_create_flag_and_scope_required'
      using errcode = '22023';
  end if;

  if not private.can_manage_events(p_scope_id, v_actor_id) then
    raise exception 'event_save_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;

  select event.scope_id into v_existing_scope_id
  from public.events as event
  where event.id = p_id;

  if found then
    if v_existing_scope_id is distinct from p_scope_id
      or not private.can_manage_events(v_existing_scope_id, v_actor_id) then
      raise exception 'event_save_not_found_or_forbidden'
        using errcode = 'P0002';
    end if;
  elsif not p_create then
    raise exception 'event_save_not_found_or_forbidden'
      using errcode = 'P0002';
  end if;

  perform private.require_aal2('event_save');
  return private.save_event_before_authority_gate(
    p_id,
    p_create,
    p_scope_id,
    p_title,
    p_description,
    p_location_text,
    p_starts_at,
    p_ends_at,
    p_capacity,
    p_recurrence_frequency,
    p_recurrence_interval,
    p_recurrence_weekdays,
    p_recurrence_month_day,
    p_recurrence_until,
    p_recurrence_count,
    p_reminder_offsets_minutes
  );
end;
$$;

revoke all on function public.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) from public, anon, authenticated;
grant execute on function public.save_event(
  uuid, boolean, uuid, text, text, text, timestamptz, timestamptz, integer,
  text, integer, smallint[], integer, timestamptz, integer, integer[]
) to authenticated;

-- Final direct-read privilege boundary.  Keep this after every historical
-- compatibility grant in the migration so later sections cannot accidentally
-- reopen privacy-controlled columns.  The two opaque ids are retained only for
-- profile self-UPDATE predicates and membership Realtime invalidation.
revoke select on table public.profiles from authenticated;
grant select (id) on public.profiles to authenticated;
revoke select on table public.organization_memberships from authenticated;
revoke select (
  id,
  user_id,
  organization_id,
  role,
  status,
  church_title_code,
  joined_at,
  ended_at,
  updated_at
) on public.organization_memberships from authenticated;
grant select (id) on public.organization_memberships to authenticated;
