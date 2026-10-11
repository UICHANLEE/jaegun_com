-- One server-side visibility predicate for messages, threads and their media.
-- Helpers are private; public entry points always derive the actor from Auth.
create function private.can_read_channel_message(p_message_id uuid,p_actor_id uuid,p_allow_tombstone boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select exists (
    select 1 from public.channel_messages m
    join public.community_channels c on c.id=m.channel_id
    where m.id=p_message_id and m.hidden_at is null
      and (m.deleted_at is null or p_allow_tombstone)
      and private.channel_is_participant(c.id,p_actor_id)
      and private.is_active_member(c.organization_id,m.sender_id)
      and not private.users_are_blocked(p_actor_id,m.sender_id)
      and (m.parent_message_id is null or exists (
        select 1 from public.channel_messages root
        where root.id=m.parent_message_id and root.channel_id=m.channel_id
          and root.parent_message_id is null and root.hidden_at is null
          and private.is_active_member(c.organization_id,root.sender_id)
          and not private.users_are_blocked(p_actor_id,root.sender_id)
      ))
  );
$$;
revoke all on function private.can_read_channel_message(uuid,uuid,boolean) from public,anon,authenticated;

create table private.channel_thread_reads (
  channel_id uuid not null,
  root_message_id uuid not null references public.channel_messages(id) on delete cascade,
  user_id uuid not null,
  last_read_seq bigint not null default 0 check(last_read_seq>=0),
  primary key(root_message_id,user_id),
  foreign key(channel_id,user_id) references public.channel_members(channel_id,user_id) on delete cascade
);
create index channel_thread_reads_member_idx on private.channel_thread_reads(channel_id,user_id);
alter table private.channel_thread_reads enable row level security;
revoke all on private.channel_thread_reads from public,anon,authenticated;

-- Retain the exact deletion result so a lost response can be safely retried.
create table private.channel_message_deletions (
  message_id uuid primary key references public.channel_messages(id) on delete cascade,
  deleted_paths jsonb not null check(jsonb_typeof(deleted_paths)='array')
);
alter table private.channel_message_deletions enable row level security;
revoke all on private.channel_message_deletions from public,anon,authenticated;

alter function private.channel_snapshot(uuid,uuid,bigint) rename to channel_snapshot_before_visibility_integrity;
revoke all on function private.channel_snapshot_before_visibility_integrity(uuid,uuid,bigint) from public,anon,authenticated;
create function private.channel_snapshot(p_organization_id uuid,p_channel_id uuid default null,p_before_seq bigint default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb;
begin
  result:=private.channel_snapshot_before_visibility_integrity(p_organization_id,p_channel_id,p_before_seq);
  result:=jsonb_set(result,'{channels}',coalesce((
    select jsonb_agg(item||jsonb_build_object('unreadCount',(
      select count(*) from public.channel_messages m
      left join private.channel_thread_reads tr on tr.root_message_id=m.parent_message_id and tr.user_id=actor
      where m.channel_id=(item->>'id')::uuid and m.sender_id<>actor
        and m.seq>case when m.parent_message_id is null then coalesce((item->>'lastReadSeq')::bigint,0) else coalesce(tr.last_read_seq,0) end
        and private.can_read_channel_message(m.id,actor)
    )) order by ord)
    from jsonb_array_elements(result->'channels') with ordinality as channel(item,ord)
  ),'[]'::jsonb));
  if p_channel_id is not null then
    result:=jsonb_set(result,'{messages}',coalesce((
      select jsonb_agg(item||jsonb_build_object(
        'replyCount',(select count(*) from public.channel_messages r where r.parent_message_id=(item->>'id')::uuid and private.can_read_channel_message(r.id,actor)),
        'unreadReplyCount',(select count(*) from public.channel_messages r
          left join private.channel_thread_reads tr on tr.root_message_id=r.parent_message_id and tr.user_id=actor
          where r.parent_message_id=(item->>'id')::uuid and r.sender_id<>actor and r.seq>coalesce(tr.last_read_seq,0) and private.can_read_channel_message(r.id,actor))
      ) order by ord)
      from jsonb_array_elements(result->'messages') with ordinality as message(item,ord)
      where private.can_read_channel_message((item->>'id')::uuid,actor,true)
        and (not (item->>'deleted')::boolean or exists(select 1 from public.channel_messages r where r.parent_message_id=(item->>'id')::uuid and private.can_read_channel_message(r.id,actor)))
    ),'[]'::jsonb));
  end if;
  return result;
end; $$;
revoke all on function private.channel_snapshot(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function private.channel_snapshot(uuid,uuid,bigint) to authenticated;

alter function private.channel_thread_snapshot(uuid,uuid,bigint) rename to channel_thread_snapshot_before_visibility_integrity;
revoke all on function private.channel_thread_snapshot_before_visibility_integrity(uuid,uuid,bigint) from public,anon,authenticated;
create function private.channel_thread_snapshot(p_channel_id uuid,p_root_message_id uuid,p_before_seq bigint default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); root public.channel_messages%rowtype; result jsonb;
begin
  select * into root from public.channel_messages where id=p_root_message_id and channel_id=p_channel_id and parent_message_id is null;
  if not found or not private.can_read_channel_message(root.id,actor,true) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  result:=private.channel_thread_snapshot_before_visibility_integrity(p_channel_id,p_root_message_id,p_before_seq);
  return result||jsonb_build_object('channelId',p_channel_id,'rootDeleted',root.deleted_at is not null,
    'lastReadSeq',coalesce((select last_read_seq from private.channel_thread_reads where root_message_id=root.id and user_id=actor),0));
end; $$;
revoke all on function private.channel_thread_snapshot(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function private.channel_thread_snapshot(uuid,uuid,bigint) to authenticated;

alter function private.channel_rich_command(text,uuid,jsonb) rename to channel_rich_command_before_visibility_integrity;
revoke all on function private.channel_rich_command_before_visibility_integrity(text,uuid,jsonb) from public,anon,authenticated;
create or replace function private.channel_rich_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); source public.channel_messages%rowtype;
  result jsonb; attachment jsonb; stored_attachments jsonb; requested_attachments jsonb;
  stored_mentions jsonb; requested_mentions jsonb; read_seq bigint;
begin
  if p_channel_id is null or jsonb_typeof(p_payload) is distinct from 'object' or (p_payload->>'expectedActorId')::uuid is distinct from actor then raise exception 'channel_access_denied' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('channel:'||p_channel_id::text,0));
  if not private.channel_is_participant(p_channel_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  if p_action='read_thread' then
    select * into source from public.channel_messages where id=(p_payload->>'messageId')::uuid and channel_id=p_channel_id and parent_message_id is null;
    if not found or not private.can_read_channel_message(source.id,actor,true) then raise exception 'channel_access_denied' using errcode='42501'; end if;
    select coalesce(max(seq),0) into read_seq from public.channel_messages
      where parent_message_id=source.id and seq<=coalesce((p_payload->>'seq')::bigint,0) and private.can_read_channel_message(id,actor);
    insert into private.channel_thread_reads(channel_id,root_message_id,user_id,last_read_seq) values(p_channel_id,source.id,actor,read_seq)
    on conflict(root_message_id,user_id) do update set last_read_seq=greatest(channel_thread_reads.last_read_seq,excluded.last_read_seq);
    return jsonb_build_object('id',source.id,'lastReadSeq',(select last_read_seq from private.channel_thread_reads where root_message_id=source.id and user_id=actor));
  end if;
  if p_action in ('react','forward') then
    if not exists(select 1 from public.channel_messages where id=(p_payload->>'messageId')::uuid and channel_id=p_channel_id and private.can_read_channel_message(id,actor)) then raise exception 'channel_access_denied' using errcode='42501'; end if;
    if p_action='react' then
      if p_payload->>'emoji' is null or p_payload->>'emoji' not in ('👍','❤️','🙏','😂','😮','😢')
        or (p_payload?'active' and jsonb_typeof(p_payload->'active') is distinct from 'boolean') then
        raise exception 'invalid_channel_reaction' using errcode='22023';
      end if;
      -- New clients request a desired state; lost-response retries are no-ops.
      -- Omitting active preserves the legacy toggle during a rolling deployment.
      if p_payload?'active' and (p_payload->>'active')::boolean=exists(
        select 1 from public.channel_message_reactions r where r.message_id=(p_payload->>'messageId')::uuid and r.user_id=actor and r.emoji=p_payload->>'emoji'
      ) then return jsonb_build_object('id',(p_payload->>'messageId')::uuid); end if;
    end if;
  elsif p_action='send' then
    select * into source from public.channel_messages where id=(p_payload->>'messageId')::uuid;
    if found then
      select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'path',a.storage_path,'kind',a.kind,'mimeType',a.mime_type,'byteSize',a.byte_size,'fileName',a.file_name) order by a.id),'[]'::jsonb)
        into stored_attachments from public.channel_message_attachments a where a.message_id=source.id;
      select coalesce(jsonb_agg(value order by value->>'id'),'[]'::jsonb) into requested_attachments from jsonb_array_elements(coalesce(p_payload->'attachments','[]'::jsonb));
      select coalesce(jsonb_agg(user_id order by user_id),'[]'::jsonb) into stored_mentions from public.channel_message_mentions where message_id=source.id;
      select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into requested_mentions from (select distinct (value#>>'{}')::uuid id from jsonb_array_elements(coalesce(p_payload->'mentionUserIds','[]'::jsonb))) ids;
      if source.channel_id<>p_channel_id or source.sender_id<>actor or source.deleted_at is not null or source.hidden_at is not null
        or source.body is distinct from btrim(coalesce(p_payload->>'body','')) or source.parent_message_id is distinct from (p_payload->>'parentMessageId')::uuid
        or stored_attachments is distinct from requested_attachments or stored_mentions is distinct from requested_mentions then
        raise exception 'channel_operation_conflict' using errcode='23505';
      end if;
      -- A successful retry must not attach newly uploaded objects or restore a deleted message.
      return jsonb_build_object('id',source.id);
    end if;
    if p_payload->>'parentMessageId' is not null and not exists(select 1 from public.channel_messages where id=(p_payload->>'parentMessageId')::uuid and channel_id=p_channel_id and parent_message_id is null and private.can_read_channel_message(id,actor)) then raise exception 'invalid_channel_thread' using errcode='22023'; end if;
    -- Use the same object lock/cleanup guard as all other hardened direct attachments.
    for attachment in select value from jsonb_array_elements(coalesce(p_payload->'attachments','[]'::jsonb)) order by value->>'path' loop
      perform private.require_owned_media_object('community-media',attachment->>'path',actor,(attachment->>'kind')::public.media_kind,attachment->>'mimeType',(attachment->>'byteSize')::bigint);
    end loop;
  elsif p_action='delete' then
    select * into source from public.channel_messages where id=(p_payload->>'messageId')::uuid and channel_id=p_channel_id and sender_id=actor;
    if found and source.deleted_at is not null then
      return jsonb_build_object('id',source.id,'deletedPaths',coalesce((select deleted_paths from private.channel_message_deletions where message_id=source.id),'[]'::jsonb));
    end if;
  end if;
  result:=private.channel_rich_command_before_visibility_integrity(p_action,p_channel_id,p_payload);
  if p_action='delete' then
    insert into private.channel_message_deletions(message_id,deleted_paths) values((result->>'id')::uuid,coalesce(result->'deletedPaths','[]'::jsonb)) on conflict do nothing;
  end if;
  return result;
end; $$;
revoke all on function private.channel_rich_command(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.channel_rich_command(text,uuid,jsonb) to authenticated;

alter function private.can_read_community_media(text,uuid) rename to can_read_community_media_before_channel_visibility;
revoke all on function private.can_read_community_media_before_channel_visibility(text,uuid) from public,anon,authenticated;
create or replace function private.can_read_community_media(p_name text,p_actor_id uuid)
returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_channel_id uuid:=private.try_uuid(split_part(p_name,'/',3));
begin
  if split_part(p_name,'/',2)<>'channels' then return private.can_read_community_media_before_channel_visibility(p_name,p_actor_id); end if;
  if p_actor_id is distinct from auth.uid() or not private.channel_is_participant(v_channel_id,p_actor_id) then return false; end if;
  return exists(select 1 from public.community_channels c where c.id=v_channel_id and c.organization_id=private.try_uuid(split_part(p_name,'/',1))) and (
    exists(select 1 from public.channel_message_attachments a join public.channel_messages m on m.id=a.message_id where a.storage_path=p_name and m.channel_id=v_channel_id and private.can_read_channel_message(m.id,p_actor_id))
    or (not exists(select 1 from public.channel_message_attachments a where a.storage_path=p_name)
      and exists(select 1 from storage.objects o where o.bucket_id='community-media' and o.name=p_name and ((o.owner_id=p_actor_id::text and (o.owner is null or o.owner=p_actor_id)) or (o.owner_id is null and o.owner=p_actor_id))))
  );
end; $$;
revoke all on function private.can_read_community_media(text,uuid) from public,anon,authenticated;
grant execute on function private.can_read_community_media(text,uuid) to authenticated;
-- Policies store function OIDs, so rebind instead of leaving the renamed old predicate reachable.
drop policy jaegun_community_media_select on storage.objects;
create policy jaegun_community_media_select on storage.objects for select to authenticated using(bucket_id='community-media' and private.can_read_community_media(name,auth.uid()));

alter function private.can_receive_notification(uuid,uuid) rename to can_receive_notification_before_channel_visibility;
revoke all on function private.can_receive_notification_before_channel_visibility(uuid,uuid) from public,anon,authenticated;
create function private.can_receive_notification(p_notification_id uuid,p_user_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select private.can_receive_notification_before_channel_visibility(p_notification_id,p_user_id)
    and not exists(select 1 from public.notifications n where n.id=p_notification_id and n.kind='new_message' and n.entity_type='channel' and not private.can_read_channel_message(private.try_uuid(n.metadata->>'message_id'),p_user_id));
$$;
revoke all on function private.can_receive_notification(uuid,uuid) from public,anon,authenticated;

-- Read receipts and private preference changes are not community activity.
-- In particular read -> event -> refetch -> read must never become a feedback loop.
create or replace function private.emit_channel_change()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_channel_id uuid; v_kind text; v_event_id bigint;
begin
  if tg_table_name='community_channels' and tg_op='DELETE' then return null; end if;
  if tg_table_name='channel_members' and tg_op='UPDATE' then
    if (to_jsonb(new)-'last_read_seq')=(to_jsonb(old)-'last_read_seq') then return null; end if;
  end if;
  if tg_table_name='channel_notification_preferences' then return null; end if;
  v_kind:=case tg_table_name when 'community_channels' then 'channel' when 'channel_members' then 'membership' when 'channel_messages' then 'message' when 'channel_message_reactions' then 'reaction' when 'channel_message_mentions' then 'mention' when 'channel_message_attachments' then 'attachment' else null end;
  if tg_table_name='community_channels' then v_channel_id:=coalesce(new.id,old.id);
  elsif tg_table_name in ('channel_members','channel_messages') then v_channel_id:=coalesce(new.channel_id,old.channel_id);
  else select m.channel_id into v_channel_id from public.channel_messages m where m.id=coalesce(new.message_id,old.message_id); end if;
  -- Cascades run after the channel has gone; do not recreate an event with a broken FK.
  if v_kind is not null and exists(select 1 from public.community_channels where id=v_channel_id) then
    insert into public.channel_change_events(channel_id,change_kind) values(v_channel_id,v_kind) returning id into v_event_id;
    if v_event_id%100=0 then delete from public.channel_change_events where created_at<clock_timestamp()-interval '7 days'; end if;
  end if;
  return null;
end; $$;
revoke all on function private.emit_channel_change() from public,anon,authenticated;
