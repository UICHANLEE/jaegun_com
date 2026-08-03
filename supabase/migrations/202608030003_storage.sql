-- Jaegun community: private Supabase Storage buckets and path-aware RLS.

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values
  (
    'avatars',
    'avatars',
    false,
    5242880,
    array[
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/avif',
      'image/heic',
      'image/heif'
    ]::text[]
  ),
  (
    'community-media',
    'community-media',
    false,
    524288000,
    array[
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/avif',
      'image/heic',
      'image/heif',
      'video/mp4',
      'video/quicktime',
      'video/webm'
    ]::text[]
  )
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql
immutable
security definer
set search_path = pg_catalog
as $$
begin
  if p_value is null then
    return null;
  end if;
  return p_value::uuid;
exception
  when invalid_text_representation then
    return null;
end;
$$;

create or replace function private.community_object_size_allowed(p_metadata jsonb)
returns boolean
language plpgsql
immutable
security definer
set search_path = pg_catalog
as $$
declare
  v_size_text text := p_metadata ->> 'size';
  v_mime text := pg_catalog.lower(coalesce(p_metadata ->> 'mimetype', ''));
  v_size bigint;
begin
  if v_size_text is null or v_size_text !~ '^[0-9]+$' then
    return false;
  end if;
  v_size := v_size_text::bigint;

  if v_mime like 'image/%' then
    return v_size > 0 and v_size <= 15728640;
  end if;
  if v_mime like 'video/%' then
    return v_size > 0 and v_size <= 524288000;
  end if;
  return false;
exception
  when numeric_value_out_of_range then
    return false;
end;
$$;

create or replace function private.can_read_avatar_object(p_name text, p_actor_id uuid)
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
    and private.can_view_profile(v_owner_id, p_actor_id);
end;
$$;

create or replace function private.can_write_avatar_object(p_name text, p_actor_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select p_actor_id is not null
    and private.try_uuid(pg_catalog.split_part(p_name, '/', 1)) = p_actor_id
    and pg_catalog.split_part(p_name, '/', 2) <> '';
$$;

create or replace function private.can_read_community_media(p_name text, p_actor_id uuid)
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
  if p_actor_id is null or v_organization_id is null then
    return false;
  end if;

  case v_category
    when 'posts' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.posts as p
          where p.id = v_entity_id
            and p.organization_id = v_organization_id
            and private.can_read_post(p.id, p_actor_id)
        );
    when 'applications' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.membership_applications as a
          where a.id = v_entity_id
            and a.organization_id = v_organization_id
            and (
              a.user_id = p_actor_id
              or private.can_review_application(a.id, p_actor_id)
            )
        );
    when 'messages' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.conversations as c
          where c.id = v_entity_id
            and c.organization_id = v_organization_id
            and private.can_access_conversation(c.id, p_actor_id)
        );
    when 'organization' then
      return exists (
        select 1
        from public.organizations as o
        where o.id = v_organization_id
          and o.status in (
            'seeded_unclaimed'::public.organization_status,
            'active'::public.organization_status
          )
      );
    else
      return false;
  end case;
end;
$$;

create or replace function private.can_write_community_media(p_name text, p_actor_id uuid)
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
  if p_actor_id is null or v_organization_id is null then
    return false;
  end if;

  if v_category = 'organization' then
    if pg_catalog.split_part(p_name, '/', 3) = '' then
      return false;
    end if;
  elsif v_entity_id is null or pg_catalog.split_part(p_name, '/', 4) = '' then
    return false;
  end if;

  case v_category
    when 'posts' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.posts as p
          where p.id = v_entity_id
            and p.organization_id = v_organization_id
            and private.can_manage_post(p.id, p_actor_id)
        );
    when 'applications' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.membership_applications as a
          where a.id = v_entity_id
            and a.organization_id = v_organization_id
            and a.user_id = p_actor_id
            and a.status = 'pending'::public.application_status
        );
    when 'messages' then
      return v_entity_id is not null
        and exists (
          select 1
          from public.conversations as c
          where c.id = v_entity_id
            and c.organization_id = v_organization_id
            and private.can_access_conversation(c.id, p_actor_id)
        );
    when 'organization' then
      return private.can_manage_members(v_organization_id, p_actor_id);
    else
      return false;
  end case;
end;
$$;

revoke all on function private.try_uuid(text) from public, anon, authenticated;
revoke all on function private.community_object_size_allowed(jsonb) from public, anon, authenticated;
revoke all on function private.can_read_avatar_object(text, uuid) from public, anon, authenticated;
revoke all on function private.can_write_avatar_object(text, uuid) from public, anon, authenticated;
revoke all on function private.can_read_community_media(text, uuid) from public, anon, authenticated;
revoke all on function private.can_write_community_media(text, uuid) from public, anon, authenticated;

grant execute on function private.try_uuid(text) to authenticated;
grant execute on function private.community_object_size_allowed(jsonb) to authenticated;
grant execute on function private.can_read_avatar_object(text, uuid) to authenticated;
grant execute on function private.can_write_avatar_object(text, uuid) to authenticated;
grant execute on function private.can_read_community_media(text, uuid) to authenticated;
grant execute on function private.can_write_community_media(text, uuid) to authenticated;

drop policy if exists jaegun_avatars_select on storage.objects;
create policy jaegun_avatars_select
on storage.objects for select to authenticated
using (
  bucket_id = 'avatars'
  and private.can_read_avatar_object(name, auth.uid())
);

drop policy if exists jaegun_avatars_insert on storage.objects;
create policy jaegun_avatars_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'avatars'
  and private.can_write_avatar_object(name, auth.uid())
);

drop policy if exists jaegun_avatars_update on storage.objects;
create policy jaegun_avatars_update
on storage.objects for update to authenticated
using (
  bucket_id = 'avatars'
  and private.can_write_avatar_object(name, auth.uid())
)
with check (
  bucket_id = 'avatars'
  and private.can_write_avatar_object(name, auth.uid())
);

drop policy if exists jaegun_avatars_delete on storage.objects;
create policy jaegun_avatars_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'avatars'
  and private.can_write_avatar_object(name, auth.uid())
);

drop policy if exists jaegun_community_media_select on storage.objects;
create policy jaegun_community_media_select
on storage.objects for select to authenticated
using (
  bucket_id = 'community-media'
  and private.can_read_community_media(name, auth.uid())
);

drop policy if exists jaegun_community_media_insert on storage.objects;
create policy jaegun_community_media_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'community-media'
  and private.can_write_community_media(name, auth.uid())
  and private.community_object_size_allowed(metadata)
);

drop policy if exists jaegun_community_media_update on storage.objects;
create policy jaegun_community_media_update
on storage.objects for update to authenticated
using (
  bucket_id = 'community-media'
  and private.can_write_community_media(name, auth.uid())
)
with check (
  bucket_id = 'community-media'
  and private.can_write_community_media(name, auth.uid())
  and private.community_object_size_allowed(metadata)
);

drop policy if exists jaegun_community_media_delete on storage.objects;
create policy jaegun_community_media_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'community-media'
  and private.can_write_community_media(name, auth.uid())
);
