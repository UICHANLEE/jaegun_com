-- Account-deletion defense in depth.
-- A due deletion can spend time retrying Storage cleanup before Auth hard
-- deletion. Deactivation must therefore be an immediate, durable authority
-- boundary even while a previously issued JWT has not expired yet.

create or replace function private.is_platform_admin(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_user_id is not null
    and exists (
      select 1
      from public.platform_admins as administrator
      join public.profiles as profile
        on profile.id = administrator.user_id
       and profile.deactivated_at is null
      where administrator.user_id = p_user_id
    );
$$;

create or replace function private.enforce_active_membership_profile()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.status = 'active'::public.membership_status
    and not exists (
      select 1
      from public.profiles as profile
      where profile.id = new.user_id
        and profile.deactivated_at is null
    ) then
    raise exception 'active_profile_required_for_membership'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists organization_memberships_require_active_profile
  on public.organization_memberships;
create trigger organization_memberships_require_active_profile
before insert or update of user_id, status on public.organization_memberships
for each row execute function private.enforce_active_membership_profile();

create or replace function private.enforce_active_application_profile()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.status = 'pending'::public.application_status
    and not exists (
      select 1
      from public.profiles as profile
      where profile.id = new.user_id
        and profile.deactivated_at is null
    ) then
    raise exception 'active_profile_required_for_application'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists membership_applications_require_active_profile
  on public.membership_applications;
create trigger membership_applications_require_active_profile
before insert or update of user_id, status on public.membership_applications
for each row execute function private.enforce_active_application_profile();

create or replace function private.freeze_deactivated_profile_authority()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if old.deactivated_at is not null or new.deactivated_at is null then
    return new;
  end if;

  -- Platform administrator status is intentionally not restorable by merely
  -- clearing deactivated_at later. It requires a fresh audited grant.
  delete from public.platform_admins as administrator
  where administrator.user_id = new.id;

  update public.organization_memberships as membership
  set status = 'revoked'::public.membership_status,
      ended_at = coalesce(membership.ended_at, v_now),
      updated_at = v_now
  where membership.user_id = new.id
    and membership.status = 'active'::public.membership_status;

  update public.membership_applications as application
  set status = 'withdrawn'::public.application_status,
      reviewed_at = coalesce(application.reviewed_at, v_now),
      review_reason = coalesce(application.review_reason, '비활성 계정 권한 동결')
  where application.user_id = new.id
    and application.status = 'pending'::public.application_status;

  update public.governance_office_assignments as assignment
  set ended_at = coalesce(assignment.ended_at, v_now)
  where assignment.user_id = new.id
    and assignment.ended_at is null;

  update public.governance_authority_delegations as delegation
  set revoked_at = coalesce(delegation.revoked_at, v_now),
      revoked_by = coalesce(delegation.revoked_by, new.id),
      revocation_reason = coalesce(
        delegation.revocation_reason,
        '비활성 계정 권한 동결'
      )
  where (
      delegation.grantor_user_id = new.id
      or delegation.delegate_user_id = new.id
    )
    and delegation.revoked_at is null;

  delete from public.push_devices as device
  where device.user_id = new.id;

  return new;
end;
$$;

drop trigger if exists profiles_freeze_authority_on_deactivation
  on public.profiles;
create trigger profiles_freeze_authority_on_deactivation
after update of deactivated_at on public.profiles
for each row
when (old.deactivated_at is null and new.deactivated_at is not null)
execute function private.freeze_deactivated_profile_authority();

revoke all on function private.enforce_active_membership_profile()
  from public, anon, authenticated;
revoke all on function private.enforce_active_application_profile()
  from public, anon, authenticated;
revoke all on function private.freeze_deactivated_profile_authority()
  from public, anon, authenticated;

comment on function private.freeze_deactivated_profile_authority() is
  'Irreversibly removes product authority when a profile is deactivated so stale JWTs cannot regain access during deletion cleanup.';
