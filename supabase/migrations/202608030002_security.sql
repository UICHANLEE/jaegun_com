-- Jaegun community: row-level security, authorization helpers, and transactional RPCs.
-- SECURITY DEFINER functions use a fixed, empty-trust search_path and fully qualified objects.

grant usage on schema private to authenticated, service_role;

alter table public.profiles
  add constraint profiles_avatar_path_check check (
    avatar_path is null or avatar_path like id::text || '/%'
  );

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
      from public.platform_admins as pa
      where pa.user_id = p_user_id
    );
$$;

create or replace function private.is_active_member(p_organization_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_user_id is not null
    and exists (
      select 1
      from public.organization_memberships as m
      join public.organizations as o on o.id = m.organization_id
      where m.organization_id = p_organization_id
        and m.user_id = p_user_id
        and m.status = 'active'::public.membership_status
        and o.status = 'active'::public.organization_status
    );
$$;

create or replace function private.active_role(p_organization_id uuid, p_user_id uuid)
returns public.app_role
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select m.role
  from public.organization_memberships as m
  join public.organizations as o on o.id = m.organization_id
  where m.organization_id = p_organization_id
    and m.user_id = p_user_id
    and m.status = 'active'::public.membership_status
    and o.status = 'active'::public.organization_status
  limit 1;
$$;

create or replace function private.can_manage_members(p_organization_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select private.is_platform_admin(p_user_id)
    or exists (
      select 1
      from public.organization_memberships as m
      join public.organizations as o on o.id = m.organization_id
      where m.organization_id = p_organization_id
        and m.user_id = p_user_id
        and m.status = 'active'::public.membership_status
        and o.status = 'active'::public.organization_status
        and m.role in ('minister'::public.app_role, 'executive'::public.app_role)
    );
$$;

create or replace function private.shares_active_organization(p_left_user_id uuid, p_right_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_left_user_id is not null
    and p_right_user_id is not null
    and exists (
      select 1
      from public.organization_memberships as left_membership
      join public.organization_memberships as right_membership
        on right_membership.organization_id = left_membership.organization_id
       and right_membership.status = 'active'::public.membership_status
      join public.organizations as o
        on o.id = left_membership.organization_id
       and o.status = 'active'::public.organization_status
      where left_membership.user_id = p_left_user_id
        and left_membership.status = 'active'::public.membership_status
        and right_membership.user_id = p_right_user_id
    );
$$;

create or replace function private.can_review_application(p_application_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.membership_applications as a
      where a.id = p_application_id
        and (
          a.user_id = p_actor_id
          or private.is_platform_admin(p_actor_id)
          or (
            a.requested_role = 'member'::public.app_role
            and private.can_manage_members(a.organization_id, p_actor_id)
            and not exists (
              select 1
              from public.organization_memberships as current_target
              where current_target.user_id = a.user_id
                and current_target.status = 'active'::public.membership_status
                and current_target.role in (
                  'minister'::public.app_role,
                  'executive'::public.app_role
                )
            )
          )
        )
    );
$$;

create or replace function private.can_view_profile(p_target_user_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and (
      p_target_user_id = p_actor_id
      or private.is_platform_admin(p_actor_id)
      or private.shares_active_organization(p_target_user_id, p_actor_id)
      or exists (
        select 1
        from public.membership_applications as a
        where a.user_id = p_target_user_id
          and a.status = 'pending'::public.application_status
          and private.can_review_application(a.id, p_actor_id)
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
  select p_actor_id is not null
    and exists (
      select 1
      from public.posts as p
      where p.id = p_post_id
        and (
          (
            p.status = 'published'::public.post_status
            and (
              p.organization_id is null
              or private.is_active_member(p.organization_id, p_actor_id)
            )
          )
          or (
            p.organization_id is not null
            and (
              p.author_id = p_actor_id
              or private.can_manage_members(p.organization_id, p_actor_id)
            )
          )
          or private.is_platform_admin(p_actor_id)
        )
    );
$$;

create or replace function private.can_manage_post(p_post_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.posts as p
      where p.id = p_post_id
        and (
          private.is_platform_admin(p_actor_id)
          or (
            p.organization_id is not null
            and (
              (
                p.author_id = p_actor_id
                and private.is_active_member(p.organization_id, p_actor_id)
              )
              or private.can_manage_members(p.organization_id, p_actor_id)
            )
          )
        )
    );
$$;

create or replace function private.can_create_post(
  p_organization_id uuid,
  p_board_id uuid,
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
      from public.boards as b
      where b.id = p_board_id
        and b.organization_id = p_organization_id
        and not b.is_global
        and not b.is_read_only
        and private.is_active_member(p_organization_id, p_actor_id)
        and (
          not b.staff_only_posting
          or private.can_manage_members(p_organization_id, p_actor_id)
        )
    );
$$;

create or replace function private.can_comment(p_post_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.posts as p
      where p.id = p_post_id
        and p.organization_id is not null
        and p.status = 'published'::public.post_status
        and p.allow_comments
        and private.is_active_member(p.organization_id, p_actor_id)
    );
$$;

create or replace function private.can_access_conversation(p_conversation_id uuid, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and exists (
      select 1
      from public.conversations as c
      where c.id = p_conversation_id
        and p_actor_id in (c.participant_low, c.participant_high)
        and private.is_active_member(c.organization_id, p_actor_id)
    );
$$;

create or replace function private.post_media_path_matches(p_post_id uuid, p_storage_path text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.posts as p
    where p.id = p_post_id
      and p.organization_id is not null
      and pg_catalog.strpos(
        p_storage_path,
        p.organization_id::text || '/posts/' || p.id::text || '/'
      ) = 1
  );
$$;

create or replace function private.application_evidence_path_matches(
  p_application_id uuid,
  p_storage_path text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.membership_applications as a
    where a.id = p_application_id
      and pg_catalog.strpos(
        p_storage_path,
        a.organization_id::text || '/applications/' || a.id::text || '/'
      ) = 1
  );
$$;

create or replace function private.message_media_path_matches(
  p_conversation_id uuid,
  p_storage_path text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from public.conversations as c
    where c.id = p_conversation_id
      and pg_catalog.strpos(
        p_storage_path,
        c.organization_id::text || '/messages/' || c.id::text || '/'
      ) = 1
  );
$$;

create or replace function private.write_audit(
  p_actor_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_organization_id uuid,
  p_target_user_id uuid,
  p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  insert into public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    organization_id,
    target_user_id,
    details
  )
  values (
    p_actor_id,
    p_action,
    p_entity_type,
    p_entity_id,
    p_organization_id,
    p_target_user_id,
    coalesce(p_details, '{}'::jsonb)
  );
end;
$$;

-- Keep post/board scope and ownership consistent. A FK-driven author -> NULL transition
-- is allowed so account deletion can anonymize retained community content.
create or replace function private.validate_post_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_board public.boards%rowtype;
begin
  select * into v_board
  from public.boards
  where id = new.board_id;

  if not found then
    raise exception 'board_not_found' using errcode = 'P0002';
  end if;

  if new.is_system then
    if not v_board.is_global or new.organization_id is not null then
      raise exception 'system_post_requires_global_board' using errcode = '23514';
    end if;
  elsif v_board.is_global or v_board.organization_id is distinct from new.organization_id then
    raise exception 'post_board_organization_mismatch' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    if (
      old.author_id is distinct from new.author_id
      and new.author_id is not null
    )
      or old.organization_id is distinct from new.organization_id
      or old.board_id is distinct from new.board_id
      or old.is_system is distinct from new.is_system then
      raise exception 'post_ownership_and_scope_are_immutable' using errcode = '42501';
    end if;
  end if;

  if new.status = 'published'::public.post_status and new.published_at is null then
    new.published_at := pg_catalog.now();
  end if;
  if new.status = 'deleted'::public.post_status and new.deleted_at is null then
    new.deleted_at := pg_catalog.now();
  elsif new.status <> 'deleted'::public.post_status then
    new.deleted_at := null;
  end if;
  if tg_op = 'UPDATE' and row(new.title, new.body) is distinct from row(old.title, old.body) then
    new.edited_at := pg_catalog.now();
  end if;

  return new;
end;
$$;

create trigger posts_validate_write
before insert or update on public.posts
for each row execute function private.validate_post_write();

create or replace function private.validate_comment_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_parent_post_id uuid;
begin
  if tg_op = 'UPDATE' and (
    old.post_id is distinct from new.post_id
    or (
      old.author_id is distinct from new.author_id
      and new.author_id is not null
    )
    or old.parent_id is distinct from new.parent_id
  ) then
    raise exception 'comment_ownership_and_thread_are_immutable' using errcode = '42501';
  end if;

  if new.parent_id is not null then
    select c.post_id into v_parent_post_id
    from public.comments as c
    where c.id = new.parent_id;
    if v_parent_post_id is distinct from new.post_id then
      raise exception 'comment_parent_post_mismatch' using errcode = '23514';
    end if;
  end if;

  if new.status = 'deleted'::public.comment_status and new.deleted_at is null then
    new.deleted_at := pg_catalog.now();
  elsif new.status <> 'deleted'::public.comment_status then
    new.deleted_at := null;
  end if;
  if tg_op = 'UPDATE' and new.body is distinct from old.body then
    new.edited_at := pg_catalog.now();
  end if;
  return new;
end;
$$;

create trigger comments_validate_write
before insert or update on public.comments
for each row execute function private.validate_comment_write();

create or replace function private.notify_post_comment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_post public.posts%rowtype;
  v_commenter_name text;
begin
  select * into v_post from public.posts where id = new.post_id;
  if v_post.author_id is null or v_post.author_id = new.author_id then
    return new;
  end if;

  select display_name into v_commenter_name
  from public.profiles
  where id = new.author_id;

  insert into public.notifications (
    user_id, kind, title, body, entity_type, entity_id, metadata
  )
  values (
    v_post.author_id,
    'post_comment'::public.notification_kind,
    '새 댓글이 달렸습니다',
    coalesce(v_commenter_name, '회원') || '님이 게시물에 댓글을 남겼습니다.',
    'post',
    v_post.id,
    pg_catalog.jsonb_build_object('comment_id', new.id)
  );
  return new;
end;
$$;

create trigger comments_notify_author
after insert on public.comments
for each row
when (new.status = 'active'::public.comment_status)
execute function private.notify_post_comment();

-- Helper/trigger functions are deliberately non-callable by clients unless explicitly granted below.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_platform_admin(uuid) to authenticated;
grant execute on function private.is_active_member(uuid, uuid) to authenticated;
grant execute on function private.active_role(uuid, uuid) to authenticated;
grant execute on function private.can_manage_members(uuid, uuid) to authenticated;
grant execute on function private.shares_active_organization(uuid, uuid) to authenticated;
grant execute on function private.can_review_application(uuid, uuid) to authenticated;
grant execute on function private.can_view_profile(uuid, uuid) to authenticated;
grant execute on function private.can_read_post(uuid, uuid) to authenticated;
grant execute on function private.can_manage_post(uuid, uuid) to authenticated;
grant execute on function private.can_create_post(uuid, uuid, uuid) to authenticated;
grant execute on function private.can_comment(uuid, uuid) to authenticated;
grant execute on function private.can_access_conversation(uuid, uuid) to authenticated;
grant execute on function private.post_media_path_matches(uuid, text) to authenticated;

-- RLS is enabled on every application table, including append-only audit data.
alter table public.profiles enable row level security;
alter table public.platform_admins enable row level security;
alter table public.organizations enable row level security;
alter table public.membership_applications enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.boards enable row level security;
alter table public.posts enable row level security;
alter table public.post_media enable row level security;
alter table public.comments enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.conversation_reads enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_logs enable row level security;

create policy profiles_select_authorized
on public.profiles for select to authenticated
using (private.can_view_profile(id, auth.uid()));

create policy profiles_update_self
on public.profiles for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create policy platform_admins_select_admin
on public.platform_admins for select to authenticated
using (private.is_platform_admin(auth.uid()));

create policy organizations_select_directory
on public.organizations for select to anon, authenticated
using (
  status in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  )
);

create policy organizations_select_platform_admin
on public.organizations for select to authenticated
using (private.is_platform_admin(auth.uid()));

create policy membership_applications_select_authorized
on public.membership_applications for select to authenticated
using (private.can_review_application(id, auth.uid()));

create policy organization_memberships_select_authorized
on public.organization_memberships for select to authenticated
using (
  user_id = auth.uid()
  or private.is_platform_admin(auth.uid())
  or (
    status = 'active'::public.membership_status
    and private.is_active_member(organization_id, auth.uid())
  )
  or private.can_manage_members(organization_id, auth.uid())
);

create policy boards_select_authorized
on public.boards for select to authenticated
using (
  is_global
  or private.is_active_member(organization_id, auth.uid())
  or private.is_platform_admin(auth.uid())
);

create policy posts_select_authorized
on public.posts for select to authenticated
using (
  auth.uid() is not null
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
);

create policy posts_insert_member
on public.posts for insert to authenticated
with check (
  author_id = auth.uid()
  and not is_system
  and status in ('draft'::public.post_status, 'published'::public.post_status)
  and private.can_create_post(organization_id, board_id, auth.uid())
);

create policy posts_update_author_or_staff
on public.posts for update to authenticated
using (private.can_manage_post(id, auth.uid()))
with check (
  private.is_platform_admin(auth.uid())
  or (
    organization_id is not null
    and private.is_active_member(organization_id, auth.uid())
    and (author_id = auth.uid() or private.can_manage_members(organization_id, auth.uid()))
  )
);

create policy post_media_select_authorized
on public.post_media for select to authenticated
using (private.can_read_post(post_id, auth.uid()));

create policy post_media_insert_authorized
on public.post_media for insert to authenticated
with check (
  uploader_id = auth.uid()
  and private.can_manage_post(post_id, auth.uid())
  and private.post_media_path_matches(post_id, storage_path)
);

create policy post_media_update_authorized
on public.post_media for update to authenticated
using (private.can_manage_post(post_id, auth.uid()))
with check (
  uploader_id = auth.uid()
  and private.can_manage_post(post_id, auth.uid())
  and private.post_media_path_matches(post_id, storage_path)
);

create policy post_media_delete_authorized
on public.post_media for delete to authenticated
using (private.can_manage_post(post_id, auth.uid()));

create policy comments_select_authorized
on public.comments for select to authenticated
using (
  private.can_read_post(post_id, auth.uid())
  and (
    status = 'active'::public.comment_status
    or author_id = auth.uid()
    or private.can_manage_post(post_id, auth.uid())
  )
);

create policy comments_insert_member
on public.comments for insert to authenticated
with check (
  author_id = auth.uid()
  and status = 'active'::public.comment_status
  and private.can_comment(post_id, auth.uid())
);

create policy comments_update_author_or_staff
on public.comments for update to authenticated
using (
  author_id = auth.uid()
  or private.can_manage_post(post_id, auth.uid())
)
with check (
  author_id = auth.uid()
  or private.can_manage_post(post_id, auth.uid())
);

create policy conversations_select_participant
on public.conversations for select to authenticated
using (private.can_access_conversation(id, auth.uid()));

create policy messages_select_participant
on public.messages for select to authenticated
using (private.can_access_conversation(conversation_id, auth.uid()));

create policy conversation_reads_select_participant
on public.conversation_reads for select to authenticated
using (private.can_access_conversation(conversation_id, auth.uid()));

create policy notifications_select_self
on public.notifications for select to authenticated
using (user_id = auth.uid());

create policy audit_logs_select_platform_admin
on public.audit_logs for select to authenticated
using (private.is_platform_admin(auth.uid()));

-- Remove broad defaults and expose only the operations backed by the policies above.
revoke all on table public.profiles from public, anon, authenticated;
revoke all on table public.platform_admins from public, anon, authenticated;
revoke all on table public.organizations from public, anon, authenticated;
revoke all on table public.membership_applications from public, anon, authenticated;
revoke all on table public.organization_memberships from public, anon, authenticated;
revoke all on table public.boards from public, anon, authenticated;
revoke all on table public.posts from public, anon, authenticated;
revoke all on table public.post_media from public, anon, authenticated;
revoke all on table public.comments from public, anon, authenticated;
revoke all on table public.conversations from public, anon, authenticated;
revoke all on table public.messages from public, anon, authenticated;
revoke all on table public.conversation_reads from public, anon, authenticated;
revoke all on table public.notifications from public, anon, authenticated;
revoke all on table public.audit_logs from public, anon, authenticated;

grant select on table public.organizations to anon, authenticated;
grant select, update on table public.profiles to authenticated;
grant select on table public.platform_admins to authenticated;
grant select on table public.membership_applications to authenticated;
grant select on table public.organization_memberships to authenticated;
grant select on table public.boards to authenticated;
grant select, insert, update on table public.posts to authenticated;
grant select, insert, update, delete on table public.post_media to authenticated;
grant select, insert, update on table public.comments to authenticated;
grant select on table public.conversations to authenticated;
grant select on table public.messages to authenticated;
grant select on table public.conversation_reads to authenticated;
grant select on table public.notifications to authenticated;
grant select on table public.audit_logs to authenticated;

-- Submit one initial-membership or role-change application at a time.
create or replace function public.submit_membership_application(
  p_organization_id uuid,
  p_requested_role public.app_role,
  p_applicant_note text default null
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
    applicant_note
  )
  values (
    v_actor_id,
    p_organization_id,
    p_requested_role,
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
      'requested_role', p_requested_role
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
    pg_catalog.jsonb_build_object('requested_role', p_requested_role)
  );

  return v_application_id;
end;
$$;

create or replace function public.set_membership_application_evidence(
  p_application_id uuid,
  p_evidence_path text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_application public.membership_applications%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_application
  from public.membership_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'application_not_found' using errcode = 'P0002';
  end if;
  if v_application.user_id <> v_actor_id
    or v_application.status <> 'pending'::public.application_status then
    raise exception 'application_not_editable' using errcode = '42501';
  end if;
  if p_evidence_path is null
    or not private.application_evidence_path_matches(p_application_id, p_evidence_path) then
    raise exception 'invalid_evidence_path' using errcode = '23514';
  end if;

  update public.membership_applications
  set evidence_path = p_evidence_path
  where id = p_application_id;
end;
$$;

create or replace function public.withdraw_membership_application(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_application public.membership_applications%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_application
  from public.membership_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'application_not_found' using errcode = 'P0002';
  end if;
  if v_application.user_id <> v_actor_id
    or v_application.status <> 'pending'::public.application_status then
    raise exception 'application_not_withdrawable' using errcode = '42501';
  end if;

  update public.membership_applications
  set
    status = 'withdrawn'::public.application_status,
    reviewed_at = pg_catalog.now(),
    review_reason = '신청자 취소'
  where id = p_application_id;

  perform private.write_audit(
    v_actor_id,
    'membership_application.withdrawn',
    'membership_application',
    p_application_id,
    v_application.organization_id,
    v_actor_id,
    '{}'::jsonb
  );
end;
$$;

-- The only approval path. The row lock makes concurrent reviews deterministic.
create or replace function public.review_membership_application(
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
  v_actor_id uuid := auth.uid();
  v_application public.membership_applications%rowtype;
  v_existing public.organization_memberships%rowtype;
  v_membership_id uuid;
  v_actor_is_platform_admin boolean;
  v_requires_platform_admin boolean;
  v_old_role public.app_role;
  v_organization_status public.organization_status;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_application
  from public.membership_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'application_not_found' using errcode = 'P0002';
  end if;
  if v_application.status <> 'pending'::public.application_status then
    raise exception 'application_already_reviewed' using errcode = '40001';
  end if;
  if v_application.user_id = v_actor_id then
    raise exception 'self_approval_is_forbidden' using errcode = '42501';
  end if;
  if p_decision = 'reject'::public.review_decision
    and nullif(pg_catalog.btrim(p_reason), '') is null then
    raise exception 'rejection_reason_required' using errcode = '23514';
  end if;
  if p_reason is not null and char_length(p_reason) > 2000 then
    raise exception 'review_reason_too_long' using errcode = '22001';
  end if;

  select * into v_existing
  from public.organization_memberships
  where user_id = v_application.user_id
    and status = 'active'::public.membership_status
  for update;

  if found and v_existing.organization_id <> v_application.organization_id then
    raise exception 'applicant_is_active_in_another_organization' using errcode = '23505';
  end if;

  v_old_role := case when found then v_existing.role else null end;
  v_actor_is_platform_admin := private.is_platform_admin(v_actor_id);
  v_requires_platform_admin :=
    v_application.requested_role in (
      'minister'::public.app_role,
      'executive'::public.app_role
    )
    or v_old_role in (
      'minister'::public.app_role,
      'executive'::public.app_role
    );

  if v_requires_platform_admin then
    if not v_actor_is_platform_admin then
      raise exception 'platform_admin_required_for_leadership_review' using errcode = '42501';
    end if;
  elsif not coalesce(
    private.active_role(v_application.organization_id, v_actor_id) in (
      'minister'::public.app_role,
      'executive'::public.app_role
    ),
    false
  ) then
    raise exception 'same_organization_leader_required' using errcode = '42501';
  end if;

  if p_decision = 'reject'::public.review_decision then
    update public.membership_applications
    set
      status = 'rejected'::public.application_status,
      review_reason = pg_catalog.btrim(p_reason),
      reviewed_by = v_actor_id,
      reviewed_at = v_now
    where id = p_application_id;

    insert into public.notifications (
      user_id, kind, title, body, entity_type, entity_id, metadata
    )
    values (
      v_application.user_id,
      'application_rejected'::public.notification_kind,
      '가입 신청 결과 안내',
      '가입 신청이 승인되지 않았습니다. 사유를 확인해 주세요.',
      'membership_application',
      p_application_id,
      pg_catalog.jsonb_build_object('reason', pg_catalog.btrim(p_reason))
    );

    perform private.write_audit(
      v_actor_id,
      'membership_application.rejected',
      'membership_application',
      p_application_id,
      v_application.organization_id,
      v_application.user_id,
      pg_catalog.jsonb_build_object(
        'requested_role', v_application.requested_role,
        'reason', pg_catalog.btrim(p_reason)
      )
    );

    return pg_catalog.jsonb_build_object(
      'application_id', p_application_id,
      'status', 'rejected'
    );
  end if;

  select status into v_organization_status
  from public.organizations
  where id = v_application.organization_id
  for update;

  if v_organization_status not in (
    'seeded_unclaimed'::public.organization_status,
    'active'::public.organization_status
  ) then
    raise exception 'organization_not_available_for_approval' using errcode = '42501';
  end if;

  if v_old_role = v_application.requested_role then
    raise exception 'requested_role_is_already_active' using errcode = '23505';
  end if;

  if v_existing.id is null then
    insert into public.organization_memberships (
      user_id,
      organization_id,
      role,
      status,
      approved_from_application_id,
      approved_by,
      joined_at
    )
    values (
      v_application.user_id,
      v_application.organization_id,
      v_application.requested_role,
      'active'::public.membership_status,
      p_application_id,
      v_actor_id,
      v_now
    )
    returning id into v_membership_id;
  else
    update public.organization_memberships
    set
      role = v_application.requested_role,
      approved_from_application_id = p_application_id,
      approved_by = v_actor_id,
      updated_at = v_now
    where id = v_existing.id
    returning id into v_membership_id;
  end if;

  update public.membership_applications
  set
    status = 'approved'::public.application_status,
    review_reason = nullif(pg_catalog.btrim(p_reason), ''),
    reviewed_by = v_actor_id,
    reviewed_at = v_now
  where id = p_application_id;

  if v_application.requested_role in (
    'minister'::public.app_role,
    'executive'::public.app_role
  ) then
    update public.organizations
    set
      status = case
        when status = 'seeded_unclaimed'::public.organization_status
          then 'active'::public.organization_status
        else status
      end,
      claimed_at = coalesce(claimed_at, v_now),
      claimed_by = coalesce(claimed_by, v_application.user_id)
    where id = v_application.organization_id
      and status <> 'archived'::public.organization_status;
  end if;

  insert into public.notifications (
    user_id, kind, title, body, entity_type, entity_id, metadata
  )
  values (
    v_application.user_id,
    'application_approved'::public.notification_kind,
    '가입이 승인되었습니다',
    '이제 교회 공동체의 게시판과 채팅을 이용할 수 있습니다.',
    'membership',
    v_membership_id,
    pg_catalog.jsonb_build_object(
      'organization_id', v_application.organization_id,
      'role', v_application.requested_role
    )
  );

  perform private.write_audit(
    v_actor_id,
    'membership_application.approved',
    'membership_application',
    p_application_id,
    v_application.organization_id,
    v_application.user_id,
    pg_catalog.jsonb_build_object(
      'membership_id', v_membership_id,
      'old_role', v_old_role,
      'new_role', v_application.requested_role
    )
  );

  return pg_catalog.jsonb_build_object(
    'application_id', p_application_id,
    'membership_id', v_membership_id,
    'status', 'approved',
    'role', v_application.requested_role
  );
end;
$$;

-- Membership suspension/reactivation/revocation has the same hierarchy as approval.
create or replace function public.set_membership_status(
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
  v_actor_id uuid := auth.uid();
  v_membership public.organization_memberships%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if nullif(pg_catalog.btrim(p_reason), '') is null then
    raise exception 'status_change_reason_required' using errcode = '23514';
  end if;
  if char_length(p_reason) > 2000 then
    raise exception 'status_change_reason_too_long' using errcode = '22001';
  end if;

  select * into v_membership
  from public.organization_memberships
  where id = p_membership_id
  for update;

  if not found then
    raise exception 'membership_not_found' using errcode = 'P0002';
  end if;
  if v_membership.user_id = v_actor_id then
    raise exception 'self_membership_change_is_forbidden' using errcode = '42501';
  end if;

  if v_membership.role in (
    'minister'::public.app_role,
    'executive'::public.app_role
  ) then
    if not private.is_platform_admin(v_actor_id) then
      raise exception 'platform_admin_required_for_leadership_change' using errcode = '42501';
    end if;
  elsif not coalesce(
    private.active_role(v_membership.organization_id, v_actor_id) in (
      'minister'::public.app_role,
      'executive'::public.app_role
    ),
    false
  ) then
    raise exception 'same_organization_leader_required' using errcode = '42501';
  end if;

  if v_membership.status = p_status then
    return;
  end if;

  update public.organization_memberships
  set
    status = p_status,
    ended_at = case
      when p_status = 'active'::public.membership_status then null
      else v_now
    end,
    updated_at = v_now
  where id = p_membership_id;

  insert into public.notifications (
    user_id, kind, title, body, entity_type, entity_id, metadata
  )
  values (
    v_membership.user_id,
    'membership_changed'::public.notification_kind,
    '회원 상태가 변경되었습니다',
    '회원 상태와 변경 사유를 확인해 주세요.',
    'membership',
    p_membership_id,
    pg_catalog.jsonb_build_object(
      'old_status', v_membership.status,
      'new_status', p_status,
      'reason', pg_catalog.btrim(p_reason)
    )
  );

  perform private.write_audit(
    v_actor_id,
    'membership.status_changed',
    'membership',
    p_membership_id,
    v_membership.organization_id,
    v_membership.user_id,
    pg_catalog.jsonb_build_object(
      'old_status', v_membership.status,
      'new_status', p_status,
      'reason', pg_catalog.btrim(p_reason)
    )
  );
end;
$$;

create or replace function public.update_organization_profile(
  p_organization_id uuid,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_result public.organizations%rowtype;
  v_hero_path text;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.can_manage_members(p_organization_id, v_actor_id) then
    raise exception 'organization_manager_required' using errcode = '42501';
  end if;
  if p_patch is null or pg_catalog.jsonb_typeof(p_patch) <> 'object' then
    raise exception 'patch_must_be_an_object' using errcode = '22023';
  end if;
  if p_patch - array[
    'description',
    'location_text',
    'contact_phone',
    'website_url',
    'worship_schedule',
    'hero_path'
  ] <> '{}'::jsonb then
    raise exception 'patch_contains_forbidden_fields' using errcode = '42501';
  end if;
  if p_patch ? 'worship_schedule'
    and pg_catalog.jsonb_typeof(p_patch -> 'worship_schedule') <> 'array' then
    raise exception 'worship_schedule_must_be_an_array' using errcode = '22023';
  end if;

  v_hero_path := case
    when p_patch ? 'hero_path' then nullif(p_patch ->> 'hero_path', '')
    else null
  end;
  if v_hero_path is not null
    and pg_catalog.strpos(
      v_hero_path,
      p_organization_id::text || '/organization/'
    ) <> 1 then
    raise exception 'invalid_organization_hero_path' using errcode = '23514';
  end if;

  update public.organizations
  set
    description = case
      when p_patch ? 'description' then nullif(pg_catalog.btrim(p_patch ->> 'description'), '')
      else description
    end,
    location_text = case
      when p_patch ? 'location_text' then nullif(pg_catalog.btrim(p_patch ->> 'location_text'), '')
      else location_text
    end,
    contact_phone = case
      when p_patch ? 'contact_phone' then nullif(pg_catalog.btrim(p_patch ->> 'contact_phone'), '')
      else contact_phone
    end,
    website_url = case
      when p_patch ? 'website_url' then nullif(pg_catalog.btrim(p_patch ->> 'website_url'), '')
      else website_url
    end,
    worship_schedule = case
      when p_patch ? 'worship_schedule' then p_patch -> 'worship_schedule'
      else worship_schedule
    end,
    hero_path = case
      when p_patch ? 'hero_path' then v_hero_path
      else hero_path
    end
  where id = p_organization_id
  returning * into v_result;

  if not found then
    raise exception 'organization_not_found' using errcode = 'P0002';
  end if;

  perform private.write_audit(
    v_actor_id,
    'organization.profile_updated',
    'organization',
    p_organization_id,
    p_organization_id,
    null,
    pg_catalog.jsonb_build_object('changed_fields', p_patch)
  );

  return pg_catalog.to_jsonb(v_result);
end;
$$;

create or replace function public.get_my_context()
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

  select pg_catalog.to_jsonb(p) into v_profile
  from public.profiles as p
  where p.id = v_actor_id;

  select pg_catalog.to_jsonb(m), pg_catalog.to_jsonb(o)
  into v_membership, v_organization
  from public.organization_memberships as m
  join public.organizations as o on o.id = m.organization_id
  where m.user_id = v_actor_id
    and m.status = 'active'::public.membership_status
  limit 1;

  select pg_catalog.to_jsonb(a) into v_application
  from public.membership_applications as a
  where a.user_id = v_actor_id
    and a.status in (
      'pending'::public.application_status,
      'rejected'::public.application_status
    )
  order by a.created_at desc
  limit 1;

  return pg_catalog.jsonb_build_object(
    'profile', v_profile,
    'is_platform_admin', private.is_platform_admin(v_actor_id),
    'membership', v_membership,
    'organization', v_organization,
    'pending_application', case
      when v_application ->> 'status' = 'pending' then v_application
      else null
    end,
    'latest_application', v_application
  );
end;
$$;

-- Conversations can only be created between two active members of the same church.
create or replace function public.get_or_create_conversation(p_other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_membership public.organization_memberships%rowtype;
  v_low uuid;
  v_high uuid;
  v_conversation_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_other_user_id is null or p_other_user_id = v_actor_id then
    raise exception 'conversation_requires_another_user' using errcode = '23514';
  end if;

  select * into v_actor_membership
  from public.organization_memberships
  where user_id = v_actor_id
    and status = 'active'::public.membership_status;

  if not found then
    raise exception 'active_membership_required' using errcode = '42501';
  end if;
  if not private.is_active_member(v_actor_membership.organization_id, p_other_user_id) then
    raise exception 'other_user_must_be_active_in_same_organization' using errcode = '42501';
  end if;

  if v_actor_id::text < p_other_user_id::text then
    v_low := v_actor_id;
    v_high := p_other_user_id;
  else
    v_low := p_other_user_id;
    v_high := v_actor_id;
  end if;

  insert into public.conversations (
    organization_id,
    participant_low,
    participant_high,
    created_by
  )
  values (
    v_actor_membership.organization_id,
    v_low,
    v_high,
    v_actor_id
  )
  on conflict (organization_id, participant_low, participant_high)
  do update set updated_at = excluded.updated_at
  returning id into v_conversation_id;

  insert into public.conversation_reads (conversation_id, user_id)
  values
    (v_conversation_id, v_low),
    (v_conversation_id, v_high)
  on conflict (conversation_id, user_id) do nothing;

  return v_conversation_id;
end;
$$;

create or replace function public.send_message(
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
  v_actor_id uuid := auth.uid();
  v_conversation public.conversations%rowtype;
  v_recipient_id uuid;
  v_message_id uuid;
  v_sender_name text;
  v_inserted boolean := false;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_conversation
  from public.conversations
  where id = p_conversation_id
  for update;

  if not found then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;
  if not private.can_access_conversation(p_conversation_id, v_actor_id) then
    raise exception 'conversation_access_denied' using errcode = '42501';
  end if;
  if p_client_nonce is null then
    raise exception 'client_nonce_required' using errcode = '23502';
  end if;
  if p_kind = 'text'::public.message_kind then
    if nullif(pg_catalog.btrim(p_body), '') is null or p_media_path is not null then
      raise exception 'invalid_text_message' using errcode = '23514';
    end if;
  else
    if p_media_path is null
      or not private.message_media_path_matches(p_conversation_id, p_media_path) then
      raise exception 'invalid_message_media_path' using errcode = '23514';
    end if;
  end if;
  if p_body is not null and char_length(p_body) > 10000 then
    raise exception 'message_body_too_long' using errcode = '22001';
  end if;

  insert into public.messages (
    conversation_id,
    sender_id,
    kind,
    body,
    media_path,
    media_metadata,
    client_nonce,
    created_at
  )
  values (
    p_conversation_id,
    v_actor_id,
    p_kind,
    nullif(pg_catalog.btrim(p_body), ''),
    p_media_path,
    coalesce(p_media_metadata, '{}'::jsonb),
    p_client_nonce,
    v_now
  )
  on conflict (conversation_id, sender_id, client_nonce) do nothing
  returning id into v_message_id;

  v_inserted := found;
  if not v_inserted then
    select id into v_message_id
    from public.messages
    where conversation_id = p_conversation_id
      and sender_id = v_actor_id
      and client_nonce = p_client_nonce;
    return v_message_id;
  end if;

  update public.conversations
  set last_message_at = v_now
  where id = p_conversation_id;

  insert into public.conversation_reads (
    conversation_id,
    user_id,
    last_read_message_id,
    last_read_at
  )
  values (p_conversation_id, v_actor_id, v_message_id, v_now)
  on conflict (conversation_id, user_id)
  do update set
    last_read_message_id = excluded.last_read_message_id,
    last_read_at = excluded.last_read_at;

  v_recipient_id := case
    when v_conversation.participant_low = v_actor_id
      then v_conversation.participant_high
    else v_conversation.participant_low
  end;

  select display_name into v_sender_name
  from public.profiles
  where id = v_actor_id;

  insert into public.notifications (
    user_id, kind, title, body, entity_type, entity_id, metadata
  )
  values (
    v_recipient_id,
    'new_message'::public.notification_kind,
    coalesce(v_sender_name, '회원') || '님의 새 메시지',
    case
      when p_kind = 'text'::public.message_kind
        then left(pg_catalog.btrim(p_body), 120)
      when p_kind = 'image'::public.message_kind then '사진을 보냈습니다.'
      else '영상을 보냈습니다.'
    end,
    'conversation',
    p_conversation_id,
    pg_catalog.jsonb_build_object('message_id', v_message_id)
  );

  return v_message_id;
end;
$$;

create or replace function public.mark_conversation_read(
  p_conversation_id uuid,
  p_message_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_message_id uuid := p_message_id;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not private.can_access_conversation(p_conversation_id, v_actor_id) then
    raise exception 'conversation_access_denied' using errcode = '42501';
  end if;

  if v_message_id is null then
    select id into v_message_id
    from public.messages
    where conversation_id = p_conversation_id
    order by created_at desc
    limit 1;
  elsif not exists (
    select 1
    from public.messages
    where id = v_message_id
      and conversation_id = p_conversation_id
  ) then
    raise exception 'message_not_in_conversation' using errcode = '23514';
  end if;

  insert into public.conversation_reads (
    conversation_id,
    user_id,
    last_read_message_id,
    last_read_at
  )
  values (
    p_conversation_id,
    v_actor_id,
    v_message_id,
    pg_catalog.clock_timestamp()
  )
  on conflict (conversation_id, user_id)
  do update set
    last_read_message_id = excluded.last_read_message_id,
    last_read_at = excluded.last_read_at;
end;
$$;

create or replace function public.mark_notifications_read(
  p_notification_ids uuid[] default null
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_id uuid := auth.uid();
  v_count integer;
begin
  if v_actor_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  update public.notifications
  set read_at = coalesce(read_at, pg_catalog.clock_timestamp())
  where user_id = v_actor_id
    and read_at is null
    and (
      p_notification_ids is null
      or id = any(p_notification_ids)
    );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- PostgreSQL grants EXECUTE to PUBLIC by default; close that door, then grant only to signed-in users.
revoke all on function public.submit_membership_application(uuid, public.app_role, text)
  from public, anon, authenticated;
revoke all on function public.set_membership_application_evidence(uuid, text)
  from public, anon, authenticated;
revoke all on function public.withdraw_membership_application(uuid)
  from public, anon, authenticated;
revoke all on function public.review_membership_application(uuid, public.review_decision, text)
  from public, anon, authenticated;
revoke all on function public.set_membership_status(uuid, public.membership_status, text)
  from public, anon, authenticated;
revoke all on function public.update_organization_profile(uuid, jsonb)
  from public, anon, authenticated;
revoke all on function public.get_my_context()
  from public, anon, authenticated;
revoke all on function public.get_or_create_conversation(uuid)
  from public, anon, authenticated;
revoke all on function public.send_message(uuid, public.message_kind, text, text, jsonb, uuid)
  from public, anon, authenticated;
revoke all on function public.mark_conversation_read(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.mark_notifications_read(uuid[])
  from public, anon, authenticated;

grant execute on function public.submit_membership_application(uuid, public.app_role, text)
  to authenticated;
grant execute on function public.set_membership_application_evidence(uuid, text)
  to authenticated;
grant execute on function public.withdraw_membership_application(uuid)
  to authenticated;
grant execute on function public.review_membership_application(uuid, public.review_decision, text)
  to authenticated;
grant execute on function public.set_membership_status(uuid, public.membership_status, text)
  to authenticated;
grant execute on function public.update_organization_profile(uuid, jsonb)
  to authenticated;
grant execute on function public.get_my_context()
  to authenticated;
grant execute on function public.get_or_create_conversation(uuid)
  to authenticated;
grant execute on function public.send_message(uuid, public.message_kind, text, text, jsonb, uuid)
  to authenticated;
grant execute on function public.mark_conversation_read(uuid, uuid)
  to authenticated;
grant execute on function public.mark_notifications_read(uuid[])
  to authenticated;
