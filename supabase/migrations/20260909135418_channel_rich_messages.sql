-- Rich channel messages: bounded reactions, mentions, forwarding and hardened
-- image/video attachments. Tables remain RPC-only and Storage rechecks channel
-- participation for every signed URL and object operation.
alter table public.channel_messages drop constraint channel_messages_body_check;
alter table public.channel_messages add constraint channel_messages_body_check
  check (char_length(body) <= 4000);
alter table public.channel_messages add column forwarded_from_id uuid references public.channel_messages(id) on delete set null;
alter table public.channel_messages add column forwarded_sender_name text check (forwarded_sender_name is null or char_length(forwarded_sender_name) between 1 and 120);

create table public.channel_message_reactions (
  message_id uuid not null references public.channel_messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('👍','❤️','🙏','😂','😮','😢')),
  created_at timestamptz not null default clock_timestamp(),
  primary key(message_id,user_id,emoji)
);
create table public.channel_message_mentions (
  message_id uuid not null references public.channel_messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key(message_id,user_id)
);
create table public.channel_message_attachments (
  id uuid primary key,
  message_id uuid not null references public.channel_messages(id) on delete cascade,
  uploader_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null unique,
  kind text not null check (kind in ('image','video')),
  mime_type text not null,
  byte_size bigint not null check (byte_size between 1 and 524288000),
  file_name text not null check (char_length(file_name) between 1 and 180),
  created_at timestamptz not null default clock_timestamp()
);
create index channel_reactions_user_idx on public.channel_message_reactions(user_id,message_id);
create index channel_mentions_user_idx on public.channel_message_mentions(user_id,message_id);
create index channel_attachments_message_idx on public.channel_message_attachments(message_id);
alter table public.channel_message_reactions enable row level security;
alter table public.channel_message_mentions enable row level security;
alter table public.channel_message_attachments enable row level security;
revoke all on public.channel_message_reactions,public.channel_message_mentions,public.channel_message_attachments from public,anon,authenticated;

create or replace function private.media_path_is_referenced(p_bucket_id text,p_name text)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select case p_bucket_id
    when 'avatars' then exists(select 1 from public.profiles p where p.avatar_path=p_name)
    when 'community-media' then
      exists(select 1 from public.post_media m where m.storage_path=p_name)
      or exists(select 1 from public.messages m where m.media_path=p_name)
      or exists(select 1 from public.membership_applications a where a.evidence_path=p_name)
      or exists(select 1 from public.organizations o where o.hero_path=p_name)
      or exists(select 1 from public.channel_message_attachments a where a.storage_path=p_name)
    else false end;
$$;

create or replace function private.direct_media_path_shape_allowed(p_bucket_id text,p_name text,p_actor_id uuid)
returns boolean language plpgsql immutable security definer set search_path=pg_catalog as $$
declare v_segments text[]; v_leaf text; v_leaf_stem text;
begin
  if p_actor_id is null or p_name is null or p_name='' or p_name like '/%' or p_name like '%/' or strpos(p_name,'\\')>0 then return false; end if;
  v_segments:=string_to_array(p_name,'/');
  if array_position(v_segments,'') is not null or array_position(v_segments,'.') is not null or array_position(v_segments,'..') is not null then return false; end if;
  if p_bucket_id='avatars' then
    if cardinality(v_segments)<>2 or private.try_uuid(v_segments[1]) is distinct from p_actor_id then return false; end if; v_leaf:=v_segments[2];
  elsif p_bucket_id='community-media' then
    if private.try_uuid(v_segments[1]) is null then return false; end if;
    if v_segments[2]='organization' then if cardinality(v_segments)<>3 then return false; end if; v_leaf:=v_segments[3];
    elsif v_segments[2] in ('posts','messages','applications','channels') then
      if cardinality(v_segments)<>4 or private.try_uuid(v_segments[3]) is null then return false; end if; v_leaf:=v_segments[4];
    else return false; end if;
  else return false; end if;
  if length(v_leaf)-length(replace(v_leaf,'.',''))<>1 then return false; end if;
  v_leaf_stem:=split_part(v_leaf,'.',1);
  return private.try_uuid(v_leaf_stem) is not null and split_part(v_leaf,'.',2)<>'';
end; $$;

create or replace function private.can_read_community_media(p_name text,p_actor_id uuid)
returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_org uuid:=private.try_uuid(split_part(p_name,'/',1)); v_category text:=split_part(p_name,'/',2); v_entity uuid:=private.try_uuid(split_part(p_name,'/',3));
begin
  if not private.has_current_required_consents(p_actor_id) or v_org is null then return false; end if;
  case v_category
    when 'posts' then return v_entity is not null and exists(select 1 from public.posts p where p.id=v_entity and p.organization_id=v_org and private.can_read_post(p.id,p_actor_id) and (exists(select 1 from public.post_media m where m.post_id=p.id and m.storage_path=p_name and (m.uploader_id is null or private.has_current_required_consents(m.uploader_id))) or (not exists(select 1 from public.post_media m where m.post_id=p.id and m.storage_path=p_name) and exists(select 1 from storage.objects o where o.bucket_id='community-media' and o.name=p_name and ((o.owner_id=p_actor_id::text and (o.owner is null or o.owner=p_actor_id)) or (o.owner_id is null and o.owner=p_actor_id))))));
    when 'applications' then return v_entity is not null and exists(select 1 from public.membership_applications a where a.id=v_entity and a.organization_id=v_org and private.has_current_required_consents(a.user_id) and private.can_review_application(a.id,p_actor_id));
    when 'messages' then return v_entity is not null and exists(select 1 from public.conversations c where c.id=v_entity and c.organization_id=v_org and private.can_access_conversation(c.id,p_actor_id));
    when 'channels' then return v_entity is not null and exists(select 1 from public.community_channels c where c.id=v_entity and c.organization_id=v_org and private.channel_is_participant(c.id,p_actor_id) and (exists(select 1 from public.channel_message_attachments a where a.storage_path=p_name) or exists(select 1 from storage.objects o where o.bucket_id='community-media' and o.name=p_name and ((o.owner_id=p_actor_id::text and (o.owner is null or o.owner=p_actor_id)) or (o.owner_id is null and o.owner=p_actor_id)))));
    when 'organization' then return exists(select 1 from public.organizations o where o.id=v_org and o.status in ('seeded_unclaimed'::public.organization_status,'active'::public.organization_status));
    else return false;
  end case;
end; $$;

create or replace function private.can_write_community_media(p_name text,p_actor_id uuid)
returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_org uuid:=private.try_uuid(split_part(p_name,'/',1)); v_category text:=split_part(p_name,'/',2); v_entity uuid:=private.try_uuid(split_part(p_name,'/',3));
begin
  if p_actor_id is null or v_org is null then return false; end if;
  if v_category='organization' then if split_part(p_name,'/',3)='' then return false; end if;
  elsif v_entity is null or split_part(p_name,'/',4)='' then return false; end if;
  case v_category
    when 'posts' then return exists(select 1 from public.posts p where p.id=v_entity and p.organization_id=v_org and private.can_manage_post(p.id,p_actor_id));
    when 'applications' then return exists(select 1 from public.membership_applications a where a.id=v_entity and a.organization_id=v_org and a.user_id=p_actor_id and a.status='pending'::public.application_status);
    when 'messages' then return exists(select 1 from public.conversations c where c.id=v_entity and c.organization_id=v_org and private.can_access_conversation(c.id,p_actor_id));
    when 'channels' then return exists(select 1 from public.community_channels c where c.id=v_entity and c.organization_id=v_org and not c.archived and private.channel_is_participant(c.id,p_actor_id));
    when 'organization' then return private.can_manage_members(v_org,p_actor_id);
    else return false;
  end case;
end; $$;

-- Replace the snapshot to add reactions, mentions and attachments without
-- granting direct table access. Signed URLs are minted by Storage after this
-- RPC has proven channel participation.
create or replace function private.channel_snapshot(p_organization_id uuid,p_channel_id uuid default null,p_before_seq bigint default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); result jsonb; selected public.community_channels%rowtype;
begin
  if not private.is_active_member(p_organization_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  select jsonb_build_object('channels',coalesce(jsonb_agg(row_data order by created_at desc),'[]'::jsonb)) into result from (select c.created_at,jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'visibility',c.visibility,'archived',c.archived,'ownerId',c.owner_id,'status',m.status,'role',m.role,'unreadCount',case when m.status='active' then (select count(*) from public.channel_messages msg where msg.channel_id=c.id and msg.seq>m.last_read_seq and msg.sender_id<>actor and msg.hidden_at is null and private.is_active_member(c.organization_id,msg.sender_id) and not private.users_are_blocked(actor,msg.sender_id)) else 0 end) row_data from public.community_channels c left join public.channel_members m on m.channel_id=c.id and m.user_id=actor where c.organization_id=p_organization_id and (c.visibility='public' or m.user_id is not null) order by c.created_at desc limit 200) visible;
  result:=result||jsonb_build_object('actorId',actor); if p_channel_id is null then return result; end if;
  select * into selected from public.community_channels where id=p_channel_id and organization_id=p_organization_id;
  if not found or not private.channel_is_participant(p_channel_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  return result||jsonb_build_object(
    'messages',(select coalesce(jsonb_agg(to_jsonb(msg) order by msg.seq),'[]'::jsonb) from (select m.id,m.seq,m.body,m.sender_id as "senderId",p.display_name as "senderName",m.created_at as "createdAt",m.forwarded_from_id as "forwardedFromId",m.forwarded_sender_name as "forwardedSenderName",
      (select coalesce(jsonb_agg(jsonb_build_object('emoji',r.emoji,'count',r.total,'reacted',r.mine) order by r.emoji),'[]'::jsonb) from (select reaction.emoji,count(*)::int total,bool_or(reaction.user_id=actor) mine from public.channel_message_reactions reaction where reaction.message_id=m.id group by reaction.emoji) r) reactions,
      (select coalesce(jsonb_agg(mention.user_id),'[]'::jsonb) from public.channel_message_mentions mention where mention.message_id=m.id) as "mentionUserIds",
      (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'path',a.storage_path,'kind',a.kind,'mimeType',a.mime_type,'byteSize',a.byte_size,'fileName',a.file_name) order by a.created_at),'[]'::jsonb) from public.channel_message_attachments a where a.message_id=m.id) attachments
      from public.channel_messages m join public.profiles p on p.id=m.sender_id where m.channel_id=p_channel_id and m.hidden_at is null and (p_before_seq is null or m.seq<p_before_seq) and private.is_active_member(p_organization_id,m.sender_id) and not private.users_are_blocked(actor,m.sender_id) order by m.seq desc limit 50) msg),
    'members',(select coalesce(jsonb_agg(jsonb_build_object('userId',m.user_id,'name',p.display_name,'role',m.role,'status',m.status)),'[]'::jsonb) from public.channel_members m join public.profiles p on p.id=m.user_id where m.channel_id=p_channel_id and private.is_active_member(p_organization_id,m.user_id) and not private.users_are_blocked(actor,m.user_id) and (m.status='active' or selected.owner_id=actor or exists(select 1 from public.channel_members me where me.channel_id=p_channel_id and me.user_id=actor and me.role='manager' and me.status='active'))));
end; $$;

-- Rich operations are separate from the existing command function, keeping
-- its established management behavior unchanged.
create or replace function private.channel_rich_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); source public.channel_messages%rowtype; destination public.community_channels%rowtype; existing public.channel_messages%rowtype; v_message_id uuid; target uuid; emoji_value text; attachment jsonb; mention_value jsonb;
begin
  if p_channel_id is null or jsonb_typeof(p_payload) is distinct from 'object' or (p_payload->>'expectedActorId')::uuid is distinct from actor then raise exception 'channel_access_denied' using errcode='42501'; end if;
  if not private.channel_is_participant(p_channel_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  if p_action='react' then
    v_message_id:=(p_payload->>'messageId')::uuid; emoji_value:=p_payload->>'emoji';
    if emoji_value not in ('👍','❤️','🙏','😂','😮','😢') or not exists(select 1 from public.channel_messages m where m.id=v_message_id and m.channel_id=p_channel_id and m.hidden_at is null) then raise exception 'invalid_channel_reaction' using errcode='22023'; end if;
    perform private.consume_rate_limit(actor,'channel:react',120,60);
    if exists(select 1 from public.channel_message_reactions r where r.message_id=v_message_id and r.user_id=actor and r.emoji=emoji_value) then delete from public.channel_message_reactions r where r.message_id=v_message_id and r.user_id=actor and r.emoji=emoji_value; else insert into public.channel_message_reactions values(v_message_id,actor,emoji_value,clock_timestamp()); end if;
    return jsonb_build_object('id',v_message_id);
  elsif p_action='forward' then
    select * into source from public.channel_messages where id=(p_payload->>'messageId')::uuid and channel_id=p_channel_id and hidden_at is null;
    target:=(p_payload->>'targetChannelId')::uuid;
    select * into destination from public.community_channels where id=target and not archived;
    if not found or source.id is null or nullif(btrim(source.body),'') is null or destination.organization_id is distinct from (select organization_id from public.community_channels where id=p_channel_id) or not private.channel_is_participant(target,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
    perform private.consume_rate_limit(actor,'channel:send',30,60); v_message_id:=(p_payload->>'operationId')::uuid;
    if v_message_id is null then raise exception 'invalid_channel_message' using errcode='22023'; end if;
    select * into existing from public.channel_messages where id=v_message_id;
    if found then
      if existing.channel_id=target and existing.sender_id=actor and existing.forwarded_from_id=coalesce(source.forwarded_from_id,source.id) then return jsonb_build_object('id',v_message_id); end if;
      raise exception 'channel_operation_conflict' using errcode='23505';
    end if;
    insert into public.channel_messages(id,channel_id,sender_id,body,forwarded_from_id,forwarded_sender_name)
      select v_message_id,target,actor,source.body,coalesce(source.forwarded_from_id,source.id),coalesce(source.forwarded_sender_name,p.display_name) from public.profiles p where p.id=source.sender_id
      on conflict(id) do nothing;
    return jsonb_build_object('id',v_message_id);
  elsif p_action='send' then
    select * into destination from public.community_channels where id=p_channel_id and not archived;
    if not found then raise exception 'channel_archived' using errcode='23514'; end if;
    v_message_id:=(p_payload->>'messageId')::uuid;
    if v_message_id is null or char_length(coalesce(p_payload->>'body',''))>4000 or (nullif(btrim(coalesce(p_payload->>'body','')),'') is null and coalesce(jsonb_array_length(p_payload->'attachments'),0)=0) then raise exception 'invalid_channel_message' using errcode='22023'; end if;
    if coalesce(jsonb_array_length(p_payload->'attachments'),0)>4 or coalesce(jsonb_array_length(p_payload->'mentionUserIds'),0)>10 then raise exception 'invalid_channel_message' using errcode='22023'; end if;
    if nullif(btrim(coalesce(p_payload->>'body','')),'') is not null and not private.ugc_text_is_allowed(p_payload->>'body') then raise exception 'unsafe_content_rejected' using errcode='22023'; end if;
    select * into existing from public.channel_messages where id=v_message_id;
    if found then
      if existing.channel_id=p_channel_id and existing.sender_id=actor and existing.body=btrim(coalesce(p_payload->>'body','')) then return jsonb_build_object('id',v_message_id); end if;
      raise exception 'channel_operation_conflict' using errcode='23505';
    end if;
    perform private.consume_rate_limit(actor,'channel:send',30,60);
    insert into public.channel_messages(id,channel_id,sender_id,body) values(v_message_id,p_channel_id,actor,btrim(coalesce(p_payload->>'body',''))) on conflict(id) do nothing;
    for mention_value in select value from jsonb_array_elements(coalesce(p_payload->'mentionUserIds','[]'::jsonb)) loop
      target:=(mention_value#>>'{}')::uuid;
      if not exists(select 1 from public.channel_members cm where cm.channel_id=p_channel_id and cm.user_id=target and cm.status='active') or not private.is_active_member(destination.organization_id,target) or private.users_are_blocked(actor,target) then raise exception 'invalid_channel_mention' using errcode='22023'; end if;
      insert into public.channel_message_mentions values(v_message_id,target) on conflict do nothing;
      if found and target<>actor then
        insert into public.notifications(user_id,kind,title,body,entity_type,entity_id,metadata)
        values(target,'new_message'::public.notification_kind,'채널에서 회원님을 태그했습니다','# '||destination.name||' 채널에서 새 태그를 확인해 주세요.','channel',p_channel_id,jsonb_build_object('message_id',v_message_id));
      end if;
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
create or replace function public.channel_rich_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.channel_rich_command(p_action,p_channel_id,p_payload);$$;
revoke all on function public.channel_rich_command(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.channel_rich_command(text,uuid,jsonb) to authenticated;

-- Replace Storage policies so the updated channel-aware predicates are used.
drop policy if exists jaegun_community_media_select on storage.objects;
create policy jaegun_community_media_select on storage.objects for select to authenticated using(bucket_id='community-media' and private.can_read_community_media(name,auth.uid()));
drop policy if exists jaegun_community_media_insert on storage.objects;
create policy jaegun_community_media_insert on storage.objects for insert to authenticated with check(private.has_current_required_consents(auth.uid()) and bucket_id='community-media' and ((owner_id=auth.uid()::text and (owner is null or owner=auth.uid())) or (owner_id is null and owner=auth.uid())) and private.authorize_direct_media_upload(bucket_id,name,auth.uid(),metadata));
drop policy if exists jaegun_community_media_delete on storage.objects;
create policy jaegun_community_media_delete on storage.objects for delete to authenticated using(private.has_current_required_consents(auth.uid()) and bucket_id='community-media' and ((owner_id=auth.uid()::text and (owner is null or owner=auth.uid())) or (owner_id is null and owner=auth.uid())) and private.can_mutate_direct_media_object(bucket_id,name,auth.uid()));

-- Hiding the original also hides every forwarded copy. Reporting a copy hides
-- only that copy, preserving the original moderation target and audit trail.
create or replace function public.resolve_content_report(p_report_id uuid,p_action text,p_reason text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); report public.content_reports%rowtype; action_id uuid;
begin
  select * into report from public.content_reports where id=p_report_id for update;
  if not found or not private.can_moderate_organization(report.organization_id,actor) then raise exception 'content_report_not_found_or_forbidden' using errcode='P0002'; end if;
  if report.target_type<>'channel_message' or p_action is distinct from 'content_hidden' then return private.resolve_content_report_before_current_consent_gate(p_report_id,p_action,p_reason); end if;
  perform private.require_aal2('moderation_sanction');
  if report.status in ('resolved','dismissed') or nullif(btrim(p_reason),'') is null or char_length(p_reason)>2000 then raise exception 'invalid_moderation_action' using errcode='22023'; end if;
  update public.channel_messages m set hidden_at=clock_timestamp() from public.community_channels c where (m.id=report.target_id or m.forwarded_from_id=report.target_id) and c.id=m.channel_id and c.organization_id=report.organization_id;
  if not found then raise exception 'moderation_target_not_found_in_scope' using errcode='P0002'; end if;
  insert into public.moderation_actions(report_id,actor_id,organization_id,target_type,target_id,target_user_id,action_code,note) values(report.id,actor,report.organization_id,report.target_type,report.target_id,report.reported_user_id,p_action,btrim(p_reason)) returning id into action_id;
  update public.content_reports set status='resolved',assigned_to=actor,reviewed_at=clock_timestamp(),resolved_at=clock_timestamp(),resolution_code=p_action,resolution_note=btrim(p_reason) where id=report.id;
  perform private.write_audit(actor,'moderation.report_resolved','content_report',report.id,report.organization_id,report.reported_user_id,jsonb_build_object('action',p_action));
  return jsonb_build_object('id',report.id,'status','resolved','action_id',action_id);
end; $$;
revoke all on function public.resolve_content_report(uuid,text,text) from public,anon,authenticated;
grant execute on function public.resolve_content_report(uuid,text,text) to authenticated;
