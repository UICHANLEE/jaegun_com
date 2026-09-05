-- Church-scoped, member-created channels. RPC-only access: no table/realtime
-- payload can bypass current consent, active membership or block checks.
create table public.community_channels (
  id uuid primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  owner_id uuid references public.profiles(id) on delete set null,
  name text not null check (char_length(btrim(name)) between 2 and 60),
  description text not null default '' check (char_length(description) <= 500),
  visibility text not null check (visibility in ('public', 'private')),
  archived boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create index community_channels_org_idx on public.community_channels(organization_id, created_at desc);
create index community_channels_owner_idx on public.community_channels(owner_id);
create table public.channel_members (
  channel_id uuid not null references public.community_channels(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('invited', 'active')),
  role text not null default 'member' check (role in ('member', 'manager')),
  last_read_seq bigint not null default 0,
  primary key(channel_id, user_id)
);
create index channel_members_user_idx on public.channel_members(user_id, channel_id);
create table public.channel_messages (
  id uuid primary key,
  channel_id uuid not null references public.community_channels(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  seq bigint generated always as identity unique,
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  hidden_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);
create index channel_messages_page_idx on public.channel_messages(channel_id, seq desc);
create index channel_messages_sender_idx on public.channel_messages(sender_id);
alter table public.community_channels enable row level security;
alter table public.channel_members enable row level security;
alter table public.channel_messages enable row level security;
revoke all on public.community_channels, public.channel_members, public.channel_messages from public, anon, authenticated;
revoke all on sequence public.channel_messages_seq_seq from public, anon, authenticated;

create function private.channel_is_participant(p_channel uuid, p_actor uuid)
returns boolean language sql stable security definer set search_path = pg_catalog as $$
  select exists (select 1 from public.community_channels c
    join public.channel_members m on m.channel_id=c.id and m.user_id=p_actor and m.status='active'
    where c.id=p_channel and private.is_active_member(c.organization_id,p_actor));
$$;
revoke all on function private.channel_is_participant(uuid,uuid) from public,anon,authenticated;

create function private.channel_snapshot(p_organization_id uuid, p_channel_id uuid default null, p_before_seq bigint default null)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare
  actor uuid := private.require_current_consent_actor();
  result jsonb;
  selected public.community_channels%rowtype;
begin
  if not private.is_active_member(p_organization_id,actor) then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  select jsonb_build_object('channels',coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb)) into result
  from (select c.created_at, jsonb_build_object('id',c.id,'name',c.name,'description',c.description,
    'visibility',c.visibility,'archived',c.archived,'ownerId',c.owner_id,
    'status',m.status,'role',m.role,
    'unreadCount',case when m.status='active' then (select count(*) from public.channel_messages msg
      where msg.channel_id=c.id and msg.seq>m.last_read_seq and msg.sender_id<>actor
      and msg.hidden_at is null and private.is_active_member(c.organization_id,msg.sender_id)
      and not private.users_are_blocked(actor,msg.sender_id)) else 0 end) row_data
    from public.community_channels c
    left join public.channel_members m on m.channel_id=c.id and m.user_id=actor
    where c.organization_id=p_organization_id and (c.visibility='public' or m.user_id is not null)
    order by c.created_at desc limit 200) visible;
  result := result || jsonb_build_object('actorId',actor);
  if p_channel_id is null then return result; end if;
  select * into selected from public.community_channels where id=p_channel_id and organization_id=p_organization_id;
  if not found or not private.channel_is_participant(p_channel_id,actor) then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  return result || jsonb_build_object(
    'messages', (select coalesce(jsonb_agg(to_jsonb(msg) order by msg.seq), '[]'::jsonb) from (
      select m.id,m.seq,m.body,m.sender_id as "senderId",p.display_name as "senderName",m.created_at as "createdAt"
      from public.channel_messages m join public.profiles p on p.id=m.sender_id
      where m.channel_id=p_channel_id and m.hidden_at is null
      and (p_before_seq is null or m.seq<p_before_seq)
      and private.is_active_member(p_organization_id,m.sender_id)
      and not private.users_are_blocked(actor,m.sender_id)
      order by m.seq desc limit 50) msg),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('userId',m.user_id,'name',p.display_name,'role',m.role,'status',m.status)), '[]'::jsonb)
      from public.channel_members m join public.profiles p on p.id=m.user_id
      where m.channel_id=p_channel_id and private.is_active_member(p_organization_id,m.user_id)
      and not private.users_are_blocked(actor,m.user_id)
      and (m.status='active' or selected.owner_id=actor or exists(select 1 from public.channel_members me
        where me.channel_id=p_channel_id and me.user_id=actor and me.role='manager' and me.status='active'))));
end;
$$;
revoke all on function private.channel_snapshot(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function private.channel_snapshot(uuid,uuid,bigint) to authenticated;
create function public.channel_snapshot(p_organization_id uuid,p_channel_id uuid default null,p_before_seq bigint default null)
returns jsonb language sql security invoker set search_path = pg_catalog as $$
  select private.channel_snapshot(p_organization_id,p_channel_id,p_before_seq);
$$;
revoke all on function public.channel_snapshot(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.channel_snapshot(uuid,uuid,bigint) to authenticated;

create function private.channel_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  actor uuid := private.require_current_consent_actor();
  c public.community_channels%rowtype;
  target uuid;
  org uuid;
  operation uuid;
  participant public.channel_members%rowtype;
  old_message public.channel_messages%rowtype;
  body_value text;
  manager boolean;
begin
  if p_channel_id is null or p_action is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'invalid_channel_input' using errcode='22023';
  end if;
  if p_payload->>'expectedActorId' is not null and (p_payload->>'expectedActorId')::uuid<>actor then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  -- Serialize retry/create and all per-channel operations, including ownership changes.
  perform pg_advisory_xact_lock(hashtextextended('channel:'||p_channel_id::text,0));
  if p_action='create' then
    org := (p_payload->>'organizationId')::uuid;
    if not private.is_active_member(org,actor) then raise exception 'channel_access_denied' using errcode='42501'; end if;
    perform pg_advisory_xact_lock(hashtextextended('channel-org:'||org::text,0));
    select * into c from public.community_channels where id=p_channel_id;
    if found then
      if c.owner_id=actor and c.organization_id=org and c.name=btrim(p_payload->>'name')
        and c.description=coalesce(p_payload->>'description','') and c.visibility=p_payload->>'visibility' then
        return jsonb_build_object('id',c.id);
      end if;
      raise exception 'channel_operation_conflict' using errcode='23505';
    end if;
    if not private.ugc_text_is_allowed(coalesce(p_payload->>'name','')||' '||coalesce(p_payload->>'description','')) then
      raise exception 'unsafe_content_rejected' using errcode='22023';
    end if;
    perform private.consume_rate_limit(actor,'channel:create',5,3600);
    if (select count(*) from public.community_channels where organization_id=org)>=200 then
      raise exception 'channel_limit_reached' using errcode='54000';
    end if;
    insert into public.community_channels(id,organization_id,owner_id,name,description,visibility)
    values(p_channel_id,org,actor,btrim(p_payload->>'name'),coalesce(p_payload->>'description',''),p_payload->>'visibility');
    insert into public.channel_members(channel_id,user_id,status,role) values(p_channel_id,actor,'active','manager');
    perform private.write_audit(actor,'channel.created','channel',p_channel_id,org,null,'{}'::jsonb);
    return jsonb_build_object('id',p_channel_id);
  end if;
  select * into c from public.community_channels where id=p_channel_id for update;
  if not found or not private.is_active_member(c.organization_id,actor) then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  select * into participant from public.channel_members where channel_id=c.id and user_id=actor;
  if c.visibility='private' and participant.user_id is null then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  manager := participant.status='active' and (c.owner_id=actor or participant.role='manager');
  if p_action='join' then
    if c.archived or (c.visibility<>'public' and coalesce(participant.status,'') not in ('invited','active')) then
      raise exception 'channel_access_denied' using errcode='42501';
    end if;
    perform private.consume_rate_limit(actor,'channel:join',30,60);
    insert into public.channel_members(channel_id,user_id,status) values(c.id,actor,'active')
      on conflict(channel_id,user_id) do update set status='active';
  elsif p_action='leave' then
    if c.owner_id=actor and not c.archived then raise exception 'transfer_owner_first' using errcode='23514'; end if;
    delete from public.channel_members where channel_id=c.id and user_id=actor;
  else
    if participant.status is distinct from 'active' then raise exception 'channel_access_denied' using errcode='42501'; end if;
    if p_action='read' then
      update public.channel_members set last_read_seq=greatest(last_read_seq,coalesce((select max(seq) from public.channel_messages
        where channel_id=c.id and seq<=coalesce((p_payload->>'seq')::bigint,0)),0)) where channel_id=c.id and user_id=actor;
    elsif p_action='send' then
      if c.archived then raise exception 'channel_archived' using errcode='23514'; end if;
      operation := (p_payload->>'messageId')::uuid;
      body_value := btrim(p_payload->>'body');
      if operation is null or body_value is null or char_length(body_value) not between 1 and 4000 then
        raise exception 'invalid_channel_message' using errcode='22023';
      end if;
      select * into old_message from public.channel_messages where id=operation;
      if found then
        if old_message.channel_id=c.id and old_message.sender_id=actor and old_message.body=body_value then
          return jsonb_build_object('id',operation);
        end if;
        raise exception 'channel_operation_conflict' using errcode='23505';
      end if;
      if not private.ugc_text_is_allowed(body_value) then raise exception 'unsafe_content_rejected' using errcode='22023'; end if;
      perform private.consume_rate_limit(actor,'channel:send',30,60);
      insert into public.channel_messages(id,channel_id,sender_id,body) values(operation,c.id,actor,body_value);
    elsif p_action in ('invite','remove','manager','transfer','archive') then
      if not coalesce(manager,false) then raise exception 'channel_access_denied' using errcode='42501'; end if;
      if p_action='archive' then
        if c.owner_id is distinct from actor then raise exception 'channel_owner_required' using errcode='42501'; end if;
        update public.community_channels set archived=true where id=c.id;
      else
        if c.archived then raise exception 'channel_archived' using errcode='23514'; end if;
        target := (p_payload->>'userId')::uuid;
        if target is null or target=actor or target=c.owner_id then raise exception 'invalid_channel_target' using errcode='22023'; end if;
        if p_action='invite' then
          if not private.is_active_member(c.organization_id,target) or private.users_are_blocked(actor,target) then
            raise exception 'channel_access_denied' using errcode='42501';
          end if;
          perform private.consume_rate_limit(actor,'channel:invite',30,60);
          insert into public.channel_members(channel_id,user_id,status) values(c.id,target,'invited') on conflict do nothing;
        else
          if not exists(select 1 from public.channel_members where channel_id=c.id and user_id=target) then
            raise exception 'channel_access_denied' using errcode='42501';
          end if;
          if p_action='remove' then
            if c.owner_id<>actor and exists(select 1 from public.channel_members where channel_id=c.id and user_id=target and role='manager') then
              raise exception 'channel_owner_required' using errcode='42501';
            end if;
            delete from public.channel_members where channel_id=c.id and user_id=target;
          else
            if c.owner_id is distinct from actor or not private.is_active_member(c.organization_id,target)
              or not exists(select 1 from public.channel_members where channel_id=c.id and user_id=target and status='active') then
              raise exception 'channel_owner_required' using errcode='42501';
            end if;
            if p_action='transfer' then update public.community_channels set owner_id=target where id=c.id; end if;
            update public.channel_members set role=case when p_action='transfer' then 'manager' else p_payload->>'role' end
              where channel_id=c.id and user_id=target;
          end if;
        end if;
      end if;
      perform private.write_audit(actor,'channel.'||p_action,'channel',c.id,c.organization_id,target,'{}'::jsonb);
    else raise exception 'invalid_channel_action' using errcode='22023';
    end if;
  end if;
  return jsonb_build_object('id',c.id);
end;
$$;
revoke all on function private.channel_command(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.channel_command(text,uuid,jsonb) to authenticated;
create function public.channel_command(p_action text,p_channel_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path = pg_catalog as $$
  select private.channel_command(p_action,p_channel_id,p_payload);
$$;
revoke all on function public.channel_command(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.channel_command(text,uuid,jsonb) to authenticated;

-- A membership revocation must not silently resurrect a private invitation
-- when the person rejoins later. Deactivation separately fails the read gate.
create function private.revoke_departed_channel_membership()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  if tg_op='DELETE' or new.status is distinct from 'active' or new.organization_id<>old.organization_id or new.user_id<>old.user_id then
    delete from public.channel_members m using public.community_channels c
      where m.channel_id=c.id and c.organization_id=old.organization_id and m.user_id=old.user_id;
    update public.community_channels set archived=true,owner_id=null
      where organization_id=old.organization_id and owner_id=old.user_id;
  end if;
  return null;
end;
$$;
revoke all on function private.revoke_departed_channel_membership() from public,anon,authenticated;
create trigger revoke_departed_channel_membership after update or delete on public.organization_memberships
for each row execute function private.revoke_departed_channel_membership();

create function private.archive_departed_channel_owner()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  if tg_op='DELETE' or new.deactivated_at is not null then
    update public.community_channels set archived=true,owner_id=null where owner_id=old.id;
    delete from public.channel_members where user_id=old.id;
  end if;
  return old;
end;
$$;
revoke all on function private.archive_departed_channel_owner() from public,anon,authenticated;
create trigger archive_deleted_channel_owner before delete on public.profiles
for each row execute function private.archive_departed_channel_owner();
create trigger archive_deactivated_channel_owner after update of deactivated_at on public.profiles
for each row execute function private.archive_departed_channel_owner();

alter table public.content_reports drop constraint content_reports_target_type_check;
alter table public.content_reports add constraint content_reports_target_type_check
  check(target_type in ('post','comment','message','profile','channel_message'));
alter table public.moderation_actions drop constraint moderation_actions_target_type_check;
alter table public.moderation_actions add constraint moderation_actions_target_type_check
  check(target_type in ('post','comment','message','profile','channel_message'));

create function private.report_channel_message(p_target_id uuid,p_reason_code text,p_details text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog as $$
declare
  actor uuid := private.require_current_consent_actor();
  msg public.channel_messages%rowtype;
  org uuid;
  report_id uuid;
begin
  select * into msg from public.channel_messages where id=p_target_id and hidden_at is null;
  if not found or not private.channel_is_participant(msg.channel_id,actor) or msg.sender_id=actor
    or private.users_are_blocked(actor,msg.sender_id) then
    raise exception 'channel_access_denied' using errcode='42501';
  end if;
  select organization_id into org from public.community_channels where id=msg.channel_id;
  if not private.is_active_member(org,msg.sender_id) then raise exception 'channel_access_denied' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('channel-report:'||actor::text||':'||msg.id::text,0));
  select id into report_id from public.content_reports where reporter_id=actor and target_type='channel_message'
    and target_id=msg.id and status in ('open','reviewing','escalated');
  if found then return report_id; end if;
  perform private.consume_rate_limit(actor,'report:create',10,3600);
  insert into public.content_reports(reporter_id,organization_id,target_type,target_id,reported_user_id,reason_code,details,evidence_snapshot)
    values(actor,org,'channel_message',msg.id,msg.sender_id,p_reason_code,p_details,
      jsonb_build_object('channel_id',msg.channel_id,'body_excerpt',left(msg.body,1000),
        'display_name','채널 메시지 · '||left(msg.body,240))) returning id into report_id;
  perform private.write_audit(actor,'moderation.report_created','content_report',report_id,org,msg.sender_id,'{}'::jsonb);
  return report_id;
end;
$$;
revoke all on function private.report_channel_message(uuid,text,text) from public,anon,authenticated;
grant execute on function private.report_channel_message(uuid,text,text) to authenticated;
create function public.report_channel_message(p_target_id uuid,p_reason_code text,p_details text default null)
returns uuid language sql security invoker set search_path = pg_catalog as $$
  select private.report_channel_message(p_target_id,p_reason_code,p_details);
$$;
revoke all on function public.report_channel_message(uuid,text,text) from public,anon,authenticated;
grant execute on function public.report_channel_message(uuid,text,text) to authenticated;

-- Existing warning/suspension/escalation flow already handles generic targets.
-- Channel-message hiding adds the same MFA, scope and audit boundaries.
create or replace function public.resolve_content_report(p_report_id uuid,p_action text,p_reason text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  actor uuid := private.require_current_consent_actor();
  report public.content_reports%rowtype;
  action_id uuid;
begin
  select * into report from public.content_reports where id=p_report_id for update;
  if not found or not private.can_moderate_organization(report.organization_id,actor) then
    raise exception 'content_report_not_found_or_forbidden' using errcode='P0002';
  end if;
  if report.target_type<>'channel_message' or p_action is distinct from 'content_hidden' then
    return private.resolve_content_report_before_current_consent_gate(p_report_id,p_action,p_reason);
  end if;
  perform private.require_aal2('moderation_sanction');
  if report.status in ('resolved','dismissed') or nullif(btrim(p_reason),'') is null or char_length(p_reason)>2000 then
    raise exception 'invalid_moderation_action' using errcode='22023';
  end if;
  update public.channel_messages m set hidden_at=clock_timestamp() from public.community_channels c
    where m.id=report.target_id and c.id=m.channel_id and c.organization_id=report.organization_id;
  if not found then raise exception 'moderation_target_not_found_in_scope' using errcode='P0002'; end if;
  insert into public.moderation_actions(report_id,actor_id,organization_id,target_type,target_id,target_user_id,action_code,note)
    values(report.id,actor,report.organization_id,report.target_type,report.target_id,report.reported_user_id,p_action,btrim(p_reason))
    returning id into action_id;
  update public.content_reports set status='resolved',assigned_to=actor,reviewed_at=clock_timestamp(),resolved_at=clock_timestamp(),
    resolution_code=p_action,resolution_note=btrim(p_reason) where id=report.id;
  perform private.write_audit(actor,'moderation.report_resolved','content_report',report.id,report.organization_id,report.reported_user_id,jsonb_build_object('action',p_action));
  return jsonb_build_object('id',report.id,'status','resolved','action_id',action_id);
end;
$$;
revoke all on function public.resolve_content_report(uuid,text,text) from public,anon,authenticated;
grant execute on function public.resolve_content_report(uuid,text,text) to authenticated;
