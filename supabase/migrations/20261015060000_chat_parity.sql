-- Native collaboration uses actor-bound access checks on WebSocket heartbeat,
-- not message polling, and revision-safe channel metadata edits.
create function public.validate_chat_access(p_channel_id uuid default null,p_conversation_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor();
begin
  if (p_channel_id is null)=(p_conversation_id is null) then raise exception 'invalid_chat_scope' using errcode='22023'; end if;
  if (p_channel_id is not null and not private.channel_is_participant(p_channel_id,actor))
    or (p_conversation_id is not null and not private.can_access_conversation(p_conversation_id,actor)) then
    raise exception 'chat_access_denied' using errcode='42501';
  end if;
  return jsonb_build_object('actorId',actor,'channelId',p_channel_id,'conversationId',p_conversation_id);
end; $$;
revoke all on function public.validate_chat_access(uuid,uuid) from public,anon,authenticated;
grant execute on function public.validate_chat_access(uuid,uuid) to authenticated;

create function public.update_community_channel(p_channel_id uuid,p_expected_actor_id uuid,p_name text,p_description text,p_expected_name text,p_expected_description text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); channel public.community_channels%rowtype;
begin
  if actor is distinct from p_expected_actor_id then raise exception 'channel_access_denied' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('channel:'||p_channel_id::text,0));
  select * into channel from public.community_channels where id=p_channel_id for update;
  if not found or not private.channel_is_participant(channel.id,actor)
    or not (channel.owner_id=actor or exists(select 1 from public.channel_members where channel_id=channel.id and user_id=actor and status='active' and role='manager')) then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  if channel.archived then raise exception 'channel_archived' using errcode='23514'; end if;
  if p_name is null or p_description is null or char_length(btrim(p_name)) not between 2 and 60 or char_length(p_description)>500
    or not private.ugc_text_is_allowed(p_name||' '||p_description) then raise exception 'invalid_channel_input' using errcode='22023'; end if;
  if channel.name=btrim(p_name) and channel.description=p_description then return jsonb_build_object('id',channel.id); end if;
  if channel.name is distinct from p_expected_name or channel.description is distinct from p_expected_description then
    raise exception 'channel_revision_conflict' using errcode='40001';
  end if;
  perform private.consume_rate_limit(actor,'channel:edit',30,60);
  update public.community_channels set name=btrim(p_name),description=p_description where id=channel.id;
  perform private.write_audit(actor,'channel.updated','channel',channel.id,channel.organization_id,null,'{}'::jsonb);
  return jsonb_build_object('id',channel.id);
end; $$;
revoke all on function public.update_community_channel(uuid,uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.update_community_channel(uuid,uuid,text,text,text,text) to authenticated;

-- Removing an invitation/participant is a desired state, not a toggle. A lost
-- response must not make a second remove fail or recreate private membership.
create table private.native_channel_departures (
  operation_id uuid primary key,
  channel_id uuid not null references public.community_channels(id) on delete cascade,
  actor_id uuid not null references public.profiles(id) on delete cascade
);
alter table private.native_channel_departures enable row level security;
revoke all on private.native_channel_departures from public,anon,authenticated;
alter function private.channel_command(text,uuid,jsonb) rename to channel_command_before_native_parity;
revoke all on function private.channel_command_before_native_parity(text,uuid,jsonb) from public,anon,authenticated;
create function private.channel_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_current_consent_actor(); channel public.community_channels%rowtype; target uuid; operation uuid; departure private.native_channel_departures%rowtype;
begin
  if p_action in ('remove','leave','transfer') then
    if p_channel_id is null or jsonb_typeof(p_payload) is distinct from 'object'
      or (p_payload->>'expectedActorId' is not null and (p_payload->>'expectedActorId')::uuid is distinct from actor) then
      raise exception 'channel_access_denied' using errcode='42501';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('channel:'||p_channel_id::text,0));
    select * into channel from public.community_channels where id=p_channel_id for update;
    if not found or not private.is_active_member(channel.organization_id,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
    if p_action='transfer' and (p_payload->>'userId')::uuid=channel.owner_id and private.channel_is_participant(channel.id,actor)
      and exists(select 1 from public.channel_members where channel_id=channel.id and user_id=actor and status='active' and role='manager') then
      return jsonb_build_object('id',channel.id);
    end if;
    if p_action='leave' and p_payload->>'operationId' is not null then
      operation:=(p_payload->>'operationId')::uuid;
      select * into departure from private.native_channel_departures where operation_id=operation;
      if found then
        if departure.actor_id=actor and departure.channel_id=channel.id then return jsonb_build_object('id',channel.id); end if;
        raise exception 'channel_operation_conflict' using errcode='23505';
      end if;
      if not exists(select 1 from public.channel_members where channel_id=channel.id and user_id=actor) then
        raise exception 'channel_access_denied' using errcode='42501';
      end if;
      if channel.owner_id=actor and not channel.archived then raise exception 'transfer_owner_first' using errcode='23514'; end if;
      perform private.consume_rate_limit(actor,'channel:leave',30,60);
      delete from public.channel_members where channel_id=channel.id and user_id=actor;
      insert into private.native_channel_departures values(operation,channel.id,actor);
      perform private.write_audit(actor,'channel.left','channel',channel.id,channel.organization_id,null,'{}'::jsonb);
      return jsonb_build_object('id',channel.id);
    end if;
    if p_action='remove' then
      target:=(p_payload->>'userId')::uuid;
      if not private.channel_is_participant(channel.id,actor)
        or not (channel.owner_id=actor or exists(select 1 from public.channel_members where channel_id=channel.id and user_id=actor and status='active' and role='manager'))
        or target is null or target=actor or target=channel.owner_id then raise exception 'channel_access_denied' using errcode='42501'; end if;
      if not exists(select 1 from public.channel_members where channel_id=channel.id and user_id=target) then return jsonb_build_object('id',channel.id); end if;
    end if;
  end if;
  return private.channel_command_before_native_parity(p_action,p_channel_id,p_payload);
end; $$;
revoke all on function private.channel_command(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.channel_command(text,uuid,jsonb) to authenticated;
