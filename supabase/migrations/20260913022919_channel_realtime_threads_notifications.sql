-- Channel collaboration phase 2: private invalidation events for Realtime,
-- one-level reply threads, owner-authored edits/deletes, and per-channel
-- notification preferences. Protected message content remains RPC-only.

alter table public.channel_messages
  add column parent_message_id uuid references public.channel_messages(id) on delete set null,
  add column edited_at timestamptz,
  add column deleted_at timestamptz;
create index channel_messages_thread_idx
  on public.channel_messages(channel_id,parent_message_id,seq)
  where hidden_at is null;

create table public.channel_notification_preferences (
  channel_id uuid not null references public.community_channels(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  mode text not null default 'mentions' check(mode in ('all','mentions','none')),
  updated_at timestamptz not null default clock_timestamp(),
  primary key(channel_id,user_id)
);
alter table public.channel_notification_preferences enable row level security;
revoke all on public.channel_notification_preferences from public,anon,authenticated;

-- Only opaque invalidation signals are exposed to Postgres Changes. Message
-- bodies, attachment paths, member names and reactions remain behind snapshot
-- RPCs so block, consent and membership checks cannot be bypassed.
create table public.channel_change_events (
  id bigint generated always as identity primary key,
  channel_id uuid not null references public.community_channels(id) on delete cascade,
  change_kind text not null check(change_kind in ('channel','membership','message','reaction','mention','attachment','preference')),
  created_at timestamptz not null default clock_timestamp()
);
create index channel_change_events_channel_idx on public.channel_change_events(channel_id,id desc);
alter table public.channel_change_events enable row level security;
revoke all on public.channel_change_events from public,anon,authenticated;
grant select on public.channel_change_events to authenticated;

create function private.can_receive_channel_event(p_channel_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select private.has_current_required_consents((select auth.uid())) and exists (
    select 1 from public.community_channels c
    where c.id=p_channel_id
      and private.is_active_member(c.organization_id,(select auth.uid()))
      and (c.visibility='public' or exists (
        select 1 from public.channel_members m
        where m.channel_id=c.id and m.user_id=(select auth.uid())
      ))
  );
$$;
revoke all on function private.can_receive_channel_event(uuid) from public,anon,authenticated;
grant execute on function private.can_receive_channel_event(uuid) to authenticated;

create policy channel_change_events_select_participant
on public.channel_change_events for select to authenticated
using (private.can_receive_channel_event(channel_id));

create function private.emit_channel_change()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_channel_id uuid; v_kind text; v_event_id bigint;
begin
  if tg_table_name='community_channels' and tg_op='DELETE' then return null; end if;
  v_kind:=case tg_table_name
    when 'community_channels' then 'channel'
    when 'channel_members' then 'membership'
    when 'channel_messages' then 'message'
    when 'channel_message_reactions' then 'reaction'
    when 'channel_message_mentions' then 'mention'
    when 'channel_message_attachments' then 'attachment'
    when 'channel_notification_preferences' then 'preference'
    else null end;
  if tg_table_name='community_channels' then v_channel_id:=coalesce(new.id,old.id);
  elsif tg_table_name in ('channel_members','channel_notification_preferences') then v_channel_id:=coalesce(new.channel_id,old.channel_id);
  elsif tg_table_name='channel_messages' then v_channel_id:=coalesce(new.channel_id,old.channel_id);
  else
    select m.channel_id into v_channel_id from public.channel_messages m
    where m.id=coalesce(new.message_id,old.message_id);
  end if;
  if v_channel_id is not null and v_kind is not null then
    insert into public.channel_change_events(channel_id,change_kind) values(v_channel_id,v_kind) returning id into v_event_id;
    -- Realtime only needs the new row long enough to broadcast it. Amortized
    -- pruning prevents an unbounded event ledger without adding a worker.
    if v_event_id%100=0 then
      delete from public.channel_change_events where created_at<clock_timestamp()-interval '7 days';
    end if;
  end if;
  return null;
end; $$;
revoke all on function private.emit_channel_change() from public,anon,authenticated;
create trigger channel_change_event_channel after insert or update or delete on public.community_channels for each row execute function private.emit_channel_change();
create trigger channel_change_event_member after insert or update or delete on public.channel_members for each row execute function private.emit_channel_change();
create trigger channel_change_event_message after insert or update or delete on public.channel_messages for each row execute function private.emit_channel_change();
create trigger channel_change_event_reaction after insert or update or delete on public.channel_message_reactions for each row execute function private.emit_channel_change();
create trigger channel_change_event_mention after insert or update or delete on public.channel_message_mentions for each row execute function private.emit_channel_change();
create trigger channel_change_event_attachment after insert or update or delete on public.channel_message_attachments for each row execute function private.emit_channel_change();
create trigger channel_change_event_preference after insert or update or delete on public.channel_notification_preferences for each row execute function private.emit_channel_change();

do $$ begin
  if exists(select 1 from pg_catalog.pg_publication where pubname='supabase_realtime')
    and not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='channel_change_events') then
    alter publication supabase_realtime add table public.channel_change_events;
  end if;
end; $$;

create function private.channel_notification_mode(p_channel_id uuid,p_user_id uuid)
returns text language sql stable security definer set search_path=pg_catalog as $$
  select coalesce((select p.mode from public.channel_notification_preferences p where p.channel_id=p_channel_id and p.user_id=p_user_id),'mentions');
$$;
revoke all on function private.channel_notification_mode(uuid,uuid) from public,anon,authenticated;

create or replace function private.channel_snapshot(p_organization_id uuid,p_channel_id uuid default null,p_before_seq bigint default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb; selected public.community_channels%rowtype;
begin
  if not private.is_active_member(p_organization_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  select jsonb_build_object('channels',coalesce(jsonb_agg(row_data order by created_at desc),'[]'::jsonb)) into result from (
    select c.created_at,jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'visibility',c.visibility,'archived',c.archived,'ownerId',c.owner_id,'status',m.status,'role',m.role,
      'lastReadSeq',coalesce(m.last_read_seq,0),'notificationMode',private.channel_notification_mode(c.id,actor),
      'unreadCount',case when m.status='active' then (select count(*) from public.channel_messages msg where msg.channel_id=c.id and msg.seq>m.last_read_seq and msg.sender_id<>actor and msg.hidden_at is null and msg.deleted_at is null and private.is_active_member(c.organization_id,msg.sender_id) and not private.users_are_blocked(actor,msg.sender_id)) else 0 end) row_data
    from public.community_channels c left join public.channel_members m on m.channel_id=c.id and m.user_id=actor
    where c.organization_id=p_organization_id and (c.visibility='public' or m.user_id is not null)
    order by c.created_at desc limit 200
  ) visible;
  result:=result||jsonb_build_object('actorId',actor); if p_channel_id is null then return result; end if;
  select * into selected from public.community_channels where id=p_channel_id and organization_id=p_organization_id;
  if not found or not private.channel_is_participant(p_channel_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  return result||jsonb_build_object(
    'messages',(select coalesce(jsonb_agg(to_jsonb(msg) order by msg.seq),'[]'::jsonb) from (
      select m.id,m.seq,case when m.deleted_at is null then m.body else '' end body,m.sender_id as "senderId",p.display_name as "senderName",m.created_at as "createdAt",m.edited_at as "editedAt",(m.deleted_at is not null) as deleted,
        m.forwarded_from_id as "forwardedFromId",m.forwarded_sender_name as "forwardedSenderName",
        (select count(*)::int from public.channel_messages reply join public.profiles rp on rp.id=reply.sender_id where reply.parent_message_id=m.id and reply.hidden_at is null and reply.deleted_at is null and private.is_active_member(p_organization_id,reply.sender_id) and not private.users_are_blocked(actor,reply.sender_id)) as "replyCount",
        (select coalesce(jsonb_agg(jsonb_build_object('emoji',r.emoji,'count',r.total,'reacted',r.mine) order by r.emoji),'[]'::jsonb) from (select reaction.emoji,count(*)::int total,bool_or(reaction.user_id=actor) mine from public.channel_message_reactions reaction where reaction.message_id=m.id group by reaction.emoji) r) reactions,
        (select coalesce(jsonb_agg(mention.user_id),'[]'::jsonb) from public.channel_message_mentions mention where mention.message_id=m.id) as "mentionUserIds",
        (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'path',a.storage_path,'kind',a.kind,'mimeType',a.mime_type,'byteSize',a.byte_size,'fileName',a.file_name) order by a.created_at),'[]'::jsonb) from public.channel_message_attachments a where a.message_id=m.id) attachments
      from public.channel_messages m join public.profiles p on p.id=m.sender_id
      where m.channel_id=p_channel_id and m.parent_message_id is null and m.hidden_at is null and (m.deleted_at is null or exists(select 1 from public.channel_messages reply where reply.parent_message_id=m.id and reply.hidden_at is null and reply.deleted_at is null)) and (p_before_seq is null or m.seq<p_before_seq) and private.is_active_member(p_organization_id,m.sender_id) and not private.users_are_blocked(actor,m.sender_id)
      order by m.seq desc limit 50
    ) msg),
    'members',(select coalesce(jsonb_agg(jsonb_build_object('userId',m.user_id,'name',p.display_name,'role',m.role,'status',m.status)),'[]'::jsonb) from public.channel_members m join public.profiles p on p.id=m.user_id where m.channel_id=p_channel_id and private.is_active_member(p_organization_id,m.user_id) and not private.users_are_blocked(actor,m.user_id) and (m.status='active' or selected.owner_id=actor or exists(select 1 from public.channel_members me where me.channel_id=p_channel_id and me.user_id=actor and me.role='manager' and me.status='active'))));
end; $$;

create function private.channel_thread_snapshot(p_channel_id uuid,p_root_message_id uuid,p_before_seq bigint default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); org uuid;
begin
  select c.organization_id into org from public.community_channels c where c.id=p_channel_id;
  if org is null or not private.channel_is_participant(p_channel_id,actor) or not exists(select 1 from public.channel_messages m where m.id=p_root_message_id and m.channel_id=p_channel_id and m.parent_message_id is null and m.hidden_at is null) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  return jsonb_build_object('actorId',actor,'rootId',p_root_message_id,'messages',(
    select coalesce(jsonb_agg(to_jsonb(msg) order by msg.seq),'[]'::jsonb) from (
      select m.id,m.seq,case when m.deleted_at is null then m.body else '' end body,m.sender_id as "senderId",p.display_name as "senderName",m.created_at as "createdAt",m.edited_at as "editedAt",(m.deleted_at is not null) as deleted,m.parent_message_id as "parentMessageId",
        (select coalesce(jsonb_agg(jsonb_build_object('emoji',r.emoji,'count',r.total,'reacted',r.mine) order by r.emoji),'[]'::jsonb) from (select reaction.emoji,count(*)::int total,bool_or(reaction.user_id=actor) mine from public.channel_message_reactions reaction where reaction.message_id=m.id group by reaction.emoji) r) reactions,
        (select coalesce(jsonb_agg(mention.user_id),'[]'::jsonb) from public.channel_message_mentions mention where mention.message_id=m.id) as "mentionUserIds",
        (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'path',a.storage_path,'kind',a.kind,'mimeType',a.mime_type,'byteSize',a.byte_size,'fileName',a.file_name) order by a.created_at),'[]'::jsonb) from public.channel_message_attachments a where a.message_id=m.id) attachments
      from public.channel_messages m join public.profiles p on p.id=m.sender_id
      where m.channel_id=p_channel_id and m.parent_message_id=p_root_message_id and m.hidden_at is null and m.deleted_at is null and (p_before_seq is null or m.seq<p_before_seq) and private.is_active_member(org,m.sender_id) and not private.users_are_blocked(actor,m.sender_id)
      order by m.seq desc limit 100
    ) msg
  ));
end; $$;
revoke all on function private.channel_thread_snapshot(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function private.channel_thread_snapshot(uuid,uuid,bigint) to authenticated;
create function public.channel_thread_snapshot(p_channel_id uuid,p_root_message_id uuid,p_before_seq bigint default null)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.channel_thread_snapshot(p_channel_id,p_root_message_id,p_before_seq);$$;
revoke all on function public.channel_thread_snapshot(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.channel_thread_snapshot(uuid,uuid,bigint) to authenticated;

create or replace function private.channel_rich_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); source public.channel_messages%rowtype; destination public.community_channels%rowtype; existing public.channel_messages%rowtype; root_message public.channel_messages%rowtype; v_message_id uuid; target uuid; emoji_value text; attachment jsonb; mention_value jsonb; notified uuid[]:=array[]::uuid[]; deleted_paths jsonb:='[]'::jsonb; preference_mode text;
begin
  if p_channel_id is null or jsonb_typeof(p_payload) is distinct from 'object' or (p_payload->>'expectedActorId')::uuid is distinct from actor then raise exception 'channel_access_denied' using errcode='42501'; end if;
  if not private.channel_is_participant(p_channel_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('channel:'||p_channel_id::text,0));
  if p_action='preference' then
    preference_mode:=p_payload->>'mode';
    if preference_mode not in ('all','mentions','none') then raise exception 'invalid_channel_preference' using errcode='22023'; end if;
    insert into public.channel_notification_preferences(channel_id,user_id,mode) values(p_channel_id,actor,preference_mode)
    on conflict(channel_id,user_id) do update set mode=excluded.mode,updated_at=clock_timestamp();
    return jsonb_build_object('id',p_channel_id,'mode',preference_mode);
  elsif p_action='react' then
    v_message_id:=(p_payload->>'messageId')::uuid; emoji_value:=p_payload->>'emoji';
    if emoji_value not in ('👍','❤️','🙏','😂','😮','😢') or not exists(select 1 from public.channel_messages m where m.id=v_message_id and m.channel_id=p_channel_id and m.hidden_at is null and m.deleted_at is null) then raise exception 'invalid_channel_reaction' using errcode='22023'; end if;
    perform private.consume_rate_limit(actor,'channel:react',120,60);
    if exists(select 1 from public.channel_message_reactions r where r.message_id=v_message_id and r.user_id=actor and r.emoji=emoji_value) then delete from public.channel_message_reactions r where r.message_id=v_message_id and r.user_id=actor and r.emoji=emoji_value; else insert into public.channel_message_reactions values(v_message_id,actor,emoji_value,clock_timestamp()); end if;
    return jsonb_build_object('id',v_message_id);
  elsif p_action='edit' then
    v_message_id:=(p_payload->>'messageId')::uuid;
    select * into source from public.channel_messages where id=v_message_id and channel_id=p_channel_id for update;
    if not found or source.sender_id<>actor or source.hidden_at is not null or source.deleted_at is not null or source.forwarded_from_id is not null or char_length(btrim(coalesce(p_payload->>'body',''))) not between 1 and 4000 or not private.ugc_text_is_allowed(p_payload->>'body') then raise exception 'invalid_channel_edit' using errcode='22023'; end if;
    update public.channel_messages set body=btrim(p_payload->>'body'),edited_at=clock_timestamp() where id=v_message_id;
    perform private.write_audit(actor,'channel.message_edited','channel_message',v_message_id,(select organization_id from public.community_channels where id=p_channel_id),null,'{}'::jsonb);
    return jsonb_build_object('id',v_message_id);
  elsif p_action='delete' then
    v_message_id:=(p_payload->>'messageId')::uuid;
    select * into source from public.channel_messages where id=v_message_id and channel_id=p_channel_id for update;
    if not found or source.sender_id<>actor or source.hidden_at is not null or source.deleted_at is not null then raise exception 'invalid_channel_delete' using errcode='22023'; end if;
    select coalesce(jsonb_agg(a.storage_path),'[]'::jsonb) into deleted_paths from public.channel_message_attachments a where a.message_id=v_message_id and a.uploader_id=actor;
    delete from public.channel_message_attachments where message_id=v_message_id;
    delete from public.channel_message_mentions where message_id=v_message_id;
    delete from public.channel_message_reactions where message_id=v_message_id;
    update public.channel_messages set body='',deleted_at=clock_timestamp(),edited_at=null where id=v_message_id;
    perform private.write_audit(actor,'channel.message_deleted','channel_message',v_message_id,(select organization_id from public.community_channels where id=p_channel_id),null,jsonb_build_object('attachment_paths',deleted_paths));
    return jsonb_build_object('id',v_message_id,'deletedPaths',deleted_paths);
  elsif p_action='forward' then
    select * into source from public.channel_messages where id=(p_payload->>'messageId')::uuid and channel_id=p_channel_id and hidden_at is null and deleted_at is null;
    target:=(p_payload->>'targetChannelId')::uuid; select * into destination from public.community_channels where id=target and not archived;
    if not found or source.id is null or nullif(btrim(source.body),'') is null or destination.organization_id is distinct from (select organization_id from public.community_channels where id=p_channel_id) or not private.channel_is_participant(target,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
    perform private.consume_rate_limit(actor,'channel:send',30,60); v_message_id:=(p_payload->>'operationId')::uuid;
    if v_message_id is null then raise exception 'invalid_channel_message' using errcode='22023'; end if;
    select * into existing from public.channel_messages where id=v_message_id;
    if found then if existing.channel_id=target and existing.sender_id=actor and existing.forwarded_from_id=coalesce(source.forwarded_from_id,source.id) then return jsonb_build_object('id',v_message_id); end if; raise exception 'channel_operation_conflict' using errcode='23505'; end if;
    insert into public.channel_messages(id,channel_id,sender_id,body,forwarded_from_id,forwarded_sender_name) select v_message_id,target,actor,source.body,coalesce(source.forwarded_from_id,source.id),coalesce(source.forwarded_sender_name,p.display_name) from public.profiles p where p.id=source.sender_id;
    return jsonb_build_object('id',v_message_id);
  elsif p_action='send' then
    select * into destination from public.community_channels where id=p_channel_id and not archived; if not found then raise exception 'channel_archived' using errcode='23514'; end if;
    v_message_id:=(p_payload->>'messageId')::uuid;
    if v_message_id is null or char_length(coalesce(p_payload->>'body',''))>4000 or (nullif(btrim(coalesce(p_payload->>'body','')),'') is null and coalesce(jsonb_array_length(p_payload->'attachments'),0)=0) then raise exception 'invalid_channel_message' using errcode='22023'; end if;
    if coalesce(jsonb_array_length(p_payload->'attachments'),0)>4 or coalesce(jsonb_array_length(p_payload->'mentionUserIds'),0)>10 then raise exception 'invalid_channel_message' using errcode='22023'; end if;
    if nullif(btrim(coalesce(p_payload->>'body','')),'') is not null and not private.ugc_text_is_allowed(p_payload->>'body') then raise exception 'unsafe_content_rejected' using errcode='22023'; end if;
    if p_payload->>'parentMessageId' is not null then
      select * into root_message from public.channel_messages where id=(p_payload->>'parentMessageId')::uuid and channel_id=p_channel_id and parent_message_id is null and hidden_at is null and deleted_at is null;
      if not found then raise exception 'invalid_channel_thread' using errcode='22023'; end if;
    end if;
    select * into existing from public.channel_messages where id=v_message_id;
    if found then if existing.channel_id=p_channel_id and existing.sender_id=actor and existing.body=btrim(coalesce(p_payload->>'body','')) and existing.parent_message_id is not distinct from root_message.id then return jsonb_build_object('id',v_message_id); end if; raise exception 'channel_operation_conflict' using errcode='23505'; end if;
    perform private.consume_rate_limit(actor,'channel:send',30,60);
    insert into public.channel_messages(id,channel_id,sender_id,body,parent_message_id) values(v_message_id,p_channel_id,actor,btrim(coalesce(p_payload->>'body','')),root_message.id);
    for mention_value in select value from jsonb_array_elements(coalesce(p_payload->'mentionUserIds','[]'::jsonb)) loop
      target:=(mention_value#>>'{}')::uuid;
      if not exists(select 1 from public.channel_members cm where cm.channel_id=p_channel_id and cm.user_id=target and cm.status='active') or not private.is_active_member(destination.organization_id,target) or private.users_are_blocked(actor,target) then raise exception 'invalid_channel_mention' using errcode='22023'; end if;
      insert into public.channel_message_mentions values(v_message_id,target) on conflict do nothing;
      if found and target<>actor and private.channel_notification_mode(p_channel_id,target)<>'none' then
        insert into public.notifications(user_id,kind,title,body,entity_type,entity_id,metadata) values(target,'new_message','채널에서 회원님을 태그했습니다','# '||destination.name||' 채널에서 새 태그를 확인해 주세요.','channel',p_channel_id,jsonb_build_object('message_id',v_message_id,'channel_notice_type','mention'));
        notified:=array_append(notified,target);
      end if;
    end loop;
    if root_message.id is not null and root_message.sender_id<>actor and not (root_message.sender_id=any(notified)) and not private.users_are_blocked(actor,root_message.sender_id) and private.channel_notification_mode(p_channel_id,root_message.sender_id)<>'none' then
      insert into public.notifications(user_id,kind,title,body,entity_type,entity_id,metadata) values(root_message.sender_id,'new_message','채널 답글이 도착했습니다','# '||destination.name||' 채널에서 답글을 확인해 주세요.','channel',p_channel_id,jsonb_build_object('message_id',v_message_id,'root_message_id',root_message.id,'channel_notice_type','reply'));
      notified:=array_append(notified,root_message.sender_id);
    end if;
    for target in select cm.user_id from public.channel_members cm where cm.channel_id=p_channel_id and cm.status='active' and cm.user_id<>actor and not (cm.user_id=any(notified)) and private.channel_notification_mode(p_channel_id,cm.user_id)='all' and private.is_active_member(destination.organization_id,cm.user_id) and not private.users_are_blocked(actor,cm.user_id) loop
      insert into public.notifications(user_id,kind,title,body,entity_type,entity_id,metadata) values(target,'new_message','채널에 새 메시지가 있습니다','# '||destination.name||' 채널의 새 메시지를 확인해 주세요.','channel',p_channel_id,jsonb_build_object('message_id',v_message_id,'channel_notice_type','all'));
    end loop;
    for attachment in select value from jsonb_array_elements(coalesce(p_payload->'attachments','[]'::jsonb)) loop
      if attachment->>'kind' not in ('image','video') or (attachment->>'byteSize')::bigint<1 or (attachment->>'byteSize')::bigint>524288000 or (attachment->>'kind'='image' and ((attachment->>'byteSize')::bigint>15728640 or attachment->>'mimeType' not like 'image/%')) or (attachment->>'kind'='video' and attachment->>'mimeType' not like 'video/%') or char_length(attachment->>'fileName') not between 1 and 180 or split_part(attachment->>'path','/',1)<>destination.organization_id::text or split_part(attachment->>'path','/',2)<>'channels' or private.try_uuid(split_part(attachment->>'path','/',3)) is distinct from p_channel_id or not exists(select 1 from storage.objects o where o.bucket_id='community-media' and o.name=attachment->>'path' and coalesce(o.owner,private.try_uuid(o.owner_id))=actor and lower(o.metadata->>'mimetype')=lower(attachment->>'mimeType') and (o.metadata->>'size')::bigint=(attachment->>'byteSize')::bigint) then raise exception 'invalid_channel_attachment' using errcode='22023'; end if;
      insert into public.channel_message_attachments(id,message_id,uploader_id,storage_path,kind,mime_type,byte_size,file_name) values((attachment->>'id')::uuid,v_message_id,actor,attachment->>'path',attachment->>'kind',attachment->>'mimeType',(attachment->>'byteSize')::bigint,attachment->>'fileName');
    end loop;
    return jsonb_build_object('id',v_message_id);
  else raise exception 'invalid_channel_action' using errcode='22023'; end if;
end; $$;
revoke all on function private.channel_rich_command(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.channel_rich_command(text,uuid,jsonb) to authenticated;

-- Channel new-message notifications must be validated against the channel
-- source row rather than the direct-message table before inbox or push access.
create or replace function private.can_receive_notification(p_notification_id uuid,p_user_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select private.has_current_required_consents(p_user_id) and exists(
    select 1 from public.notifications notification where notification.id=p_notification_id and notification.user_id=p_user_id and case
      when notification.kind='new_message'::public.notification_kind and notification.entity_type='channel' then exists(
        select 1 from public.channel_messages source_message where source_message.id=private.try_uuid(notification.metadata->>'message_id') and source_message.channel_id=notification.entity_id and source_message.hidden_at is null and source_message.deleted_at is null and private.has_current_required_consents(source_message.sender_id) and private.channel_is_participant(source_message.channel_id,p_user_id) and not private.users_are_blocked(source_message.sender_id,p_user_id))
      when notification.kind='new_message'::public.notification_kind then exists(
        select 1 from public.messages source_message where source_message.id=private.try_uuid(notification.metadata->>'message_id') and source_message.sender_id is not null and private.has_current_required_consents(source_message.sender_id) and private.can_access_conversation(source_message.conversation_id,p_user_id))
      when notification.kind='post_comment'::public.notification_kind then exists(
        select 1 from public.comments source_comment where source_comment.id=private.try_uuid(notification.metadata->>'comment_id') and source_comment.author_id is not null and private.has_current_required_consents(source_comment.author_id) and private.can_read_post(source_comment.post_id,p_user_id))
      when notification.kind='application_submitted'::public.notification_kind then exists(
        select 1 from public.membership_applications source_application where source_application.id=notification.entity_id and private.has_current_required_consents(source_application.user_id) and private.can_review_application(source_application.id,p_user_id))
      when notification.metadata?'replacement_user_id' then private.has_current_required_consents(private.try_uuid(notification.metadata->>'replacement_user_id'))
      else true end
  );
$$;
revoke all on function private.can_receive_notification(uuid,uuid) from public,anon,authenticated;

create or replace function private.suppress_blocked_user_notification()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_source_user_id uuid;
begin
  if new.kind='new_message'::public.notification_kind and new.entity_type='channel' then select message.sender_id into v_source_user_id from public.channel_messages message where message.id=private.try_uuid(new.metadata->>'message_id');
  elsif new.kind='new_message'::public.notification_kind then select message.sender_id into v_source_user_id from public.messages message where message.id=private.try_uuid(new.metadata->>'message_id');
  elsif new.kind='post_comment'::public.notification_kind then select comment.author_id into v_source_user_id from public.comments comment where comment.id=private.try_uuid(new.metadata->>'comment_id'); end if;
  if private.user_has_blocked(new.user_id,v_source_user_id) then return null; end if;
  return new;
end; $$;
revoke all on function private.suppress_blocked_user_notification() from public,anon,authenticated;
