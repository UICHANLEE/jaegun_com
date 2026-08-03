-- Efficient inbox summaries: never require clients to fetch every message in every conversation.

create index if not exists messages_conversation_live_timeline_idx
  on public.messages (conversation_id, created_at desc, id desc)
  include (sender_id, kind)
  where deleted_at is null;

create or replace function public.get_conversation_summaries()
returns table (
  id uuid,
  organization_id uuid,
  participants jsonb,
  last_message jsonb,
  unread_count bigint
)
language sql
stable
security definer
set search_path = pg_catalog
as $$
  with actor as (
    select auth.uid() as user_id
  ),
  accessible_conversations as (
    select c.*
    from public.conversations as c
    cross join actor
    where actor.user_id is not null
      and (
        c.participant_low = actor.user_id
        or c.participant_high = actor.user_id
      )
      and private.is_active_member(c.organization_id, actor.user_id)
  )
  select
    c.id,
    c.organization_id,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', low_profile.id,
        'display_name', low_profile.display_name,
        'avatar_path', low_profile.avatar_path
      ),
      pg_catalog.jsonb_build_object(
        'id', high_profile.id,
        'display_name', high_profile.display_name,
        'avatar_path', high_profile.avatar_path
      )
    ) as participants,
    case
      when latest.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', latest.id,
        'sender_id', latest.sender_id,
        'kind', latest.kind,
        'body', latest.body,
        'created_at', latest.created_at
      )
    end as last_message,
    coalesce(unread.unread_count, 0)::bigint as unread_count
  from accessible_conversations as c
  cross join actor
  join public.profiles as low_profile
    on low_profile.id = c.participant_low
  join public.profiles as high_profile
    on high_profile.id = c.participant_high
  left join public.conversation_reads as reads
    on reads.conversation_id = c.id
   and reads.user_id = actor.user_id
  left join lateral (
    select
      m.id,
      m.sender_id,
      m.kind,
      m.body,
      m.created_at
    from public.messages as m
    where m.conversation_id = c.id
      and m.deleted_at is null
    order by m.created_at desc, m.id desc
    limit 1
  ) as latest on true
  left join lateral (
    select count(*)::bigint as unread_count
    from public.messages as unread_message
    where unread_message.conversation_id = c.id
      and unread_message.deleted_at is null
      and unread_message.sender_id is distinct from actor.user_id
      and unread_message.created_at > coalesce(
        reads.last_read_at,
        '-infinity'::timestamptz
      )
  ) as unread on true
  order by coalesce(latest.created_at, c.created_at) desc, c.id;
$$;

revoke all on function public.get_conversation_summaries()
  from public, anon, authenticated;
grant execute on function public.get_conversation_summaries()
  to authenticated;
