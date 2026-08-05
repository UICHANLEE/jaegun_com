-- Church titles are display metadata only. Authorization continues to depend solely
-- on platform_admins and organization_memberships.role (public.app_role).

create table public.church_title_catalog (
  code text primary key check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  display_name text not null unique check (char_length(display_name) between 1 and 40),
  sort_order smallint not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.church_title_catalog is
  'Display-only church titles. These codes never grant application permissions.';

insert into public.church_title_catalog (code, display_name, sort_order)
values
  ('congregant', '성도', 10),
  ('deacon', '집사', 20),
  ('ordained_deacon', '안수집사', 30),
  ('kwonsa', '권사', 40),
  ('elder', '장로', 50),
  ('evangelist', '전도사', 60),
  ('pastor', '목사', 70)
on conflict (code) do update
set
  display_name = excluded.display_name,
  sort_order = excluded.sort_order;

alter table public.church_title_catalog enable row level security;

create policy church_title_catalog_select_active
on public.church_title_catalog for select to authenticated
using (is_active or private.is_platform_admin(auth.uid()));

revoke all on table public.church_title_catalog from public, anon, authenticated;
grant select on table public.church_title_catalog to authenticated;

alter table public.organization_memberships
  add column church_title_code text
  references public.church_title_catalog(code) on update cascade on delete restrict;

alter table public.membership_applications
  add column requested_church_title_code text
  references public.church_title_catalog(code) on update cascade on delete restrict;

comment on column public.organization_memberships.church_title_code is
  'Optional display title, independent from the authorization-bearing role column.';
comment on column public.membership_applications.requested_church_title_code is
  'Optional requested display title. Approval authority is determined only by requested_role.';

-- Preserve the existing review RPC and its proven approval hierarchy. When that RPC
-- links an approved application to a membership, this trigger copies only the title.
create or replace function private.copy_church_title_from_application()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_title_code text;
begin
  if new.approved_from_application_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.approved_from_application_id is not distinct from old.approved_from_application_id then
      return new;
    end if;
  end if;

  select a.requested_church_title_code into v_title_code
  from public.membership_applications as a
  where a.id = new.approved_from_application_id;

  if v_title_code is not null then
    new.church_title_code := v_title_code;
  end if;

  return new;
end;
$$;

revoke all on function private.copy_church_title_from_application()
  from public, anon, authenticated;

create trigger organization_memberships_copy_church_title
before insert or update of approved_from_application_id
on public.organization_memberships
for each row execute function private.copy_church_title_from_application();

-- Replace the original three-argument function with a four-argument version whose
-- final parameter defaults to NULL. Existing three-argument callers remain valid.
revoke all on function public.submit_membership_application(uuid, public.app_role, text)
  from public, anon, authenticated;
drop function public.submit_membership_application(uuid, public.app_role, text);

create function public.submit_membership_application(
  p_organization_id uuid,
  p_requested_role public.app_role,
  p_applicant_note text default null,
  p_requested_church_title_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_application_id uuid;
  v_existing public.organization_memberships%rowtype;
  v_organization public.organizations%rowtype;
  v_title_code text := nullif(pg_catalog.btrim(p_requested_church_title_code), '');
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_organization
  from public.organizations
  where id = p_organization_id;

  if not found or v_organization.status not in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  ) then
    raise exception 'organization_not_available' using errcode = 'P0002';
  end if;

  if p_applicant_note is not null and char_length(p_applicant_note) > 2000 then
    raise exception 'applicant_note_too_long' using errcode = '22001';
  end if;

  if v_title_code is not null and not exists (
    select 1
    from public.church_title_catalog as title
    where title.code = v_title_code
      and title.is_active
  ) then
    raise exception 'invalid_church_title_code' using errcode = '23514';
  end if;

  select * into v_existing
  from public.organization_memberships
  where user_id = v_actor_id
    and status = 'active'::public.membership_status
  for update;

  if found and v_existing.organization_id <> p_organization_id then
    raise exception 'active_membership_exists_in_another_organization' using errcode = '23505';
  end if;
  if found and v_existing.role = p_requested_role then
    raise exception 'requested_role_is_already_active' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.membership_applications as pending
    where pending.user_id = v_actor_id
      and pending.status = 'pending'::public.application_status
  ) then
    raise exception 'pending_application_already_exists' using errcode = '23505';
  end if;

  insert into public.membership_applications (
    user_id,
    organization_id,
    requested_role,
    requested_church_title_code,
    applicant_note
  )
  values (
    v_actor_id,
    p_organization_id,
    p_requested_role,
    v_title_code,
    nullif(pg_catalog.btrim(p_applicant_note), '')
  )
  returning id into v_application_id;

  insert into public.notifications (
    user_id,
    kind,
    title,
    body,
    entity_type,
    entity_id,
    metadata
  )
  select
    recipients.user_id,
    'application_submitted'::public.notification_kind,
    '새 가입 승인 요청',
    v_organization.display_name || ' 가입 승인 요청이 도착했습니다.',
    'membership_application',
    v_application_id,
    pg_catalog.jsonb_build_object(
      'organization_id', p_organization_id,
      'requested_role', p_requested_role,
      'church_title_code', v_title_code
    )
  from (
    select pa.user_id
    from public.platform_admins as pa
    where
      p_requested_role in (
        'minister'::public.app_role,
        'executive'::public.app_role
      )
      or coalesce(
        v_existing.role in (
          'minister'::public.app_role,
          'executive'::public.app_role
        ),
        false
      )
    union
    select m.user_id
    from public.organization_memberships as m
    where p_requested_role = 'member'::public.app_role
      and not coalesce(
        v_existing.role in (
          'minister'::public.app_role,
          'executive'::public.app_role
        ),
        false
      )
      and m.organization_id = p_organization_id
      and m.status = 'active'::public.membership_status
      and m.role in ('minister'::public.app_role, 'executive'::public.app_role)
  ) as recipients
  where recipients.user_id <> v_actor_id;

  perform private.write_audit(
    v_actor_id,
    'membership_application.submitted',
    'membership_application',
    v_application_id,
    p_organization_id,
    v_actor_id,
    pg_catalog.jsonb_build_object(
      'requested_role', p_requested_role,
      'church_title_code', v_title_code
    )
  );

  return v_application_id;
end;
$$;

revoke all on function public.submit_membership_application(
  uuid,
  public.app_role,
  text,
  text
) from public, anon, authenticated;
grant execute on function public.submit_membership_application(
  uuid,
  public.app_role,
  text,
  text
) to authenticated;
