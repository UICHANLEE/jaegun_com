-- Occurrence-only staff, explicit surveys, revision-safe logistics and online badges.
create table private.event_staff (
 occurrence_id uuid not null references public.event_occurrences(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 capabilities text[] not null check (cardinality(capabilities)>0 and capabilities <@ array['logistics','checkin','export','fees']::text[]),
 expires_at timestamptz not null, granted_by uuid not null references public.profiles(id),
 primary key(occurrence_id,user_id)
);
create table private.event_surveys (
 occurrence_id uuid not null, user_id uuid not null,
 attendance_start timestamptz, attendance_end timestamptz,
 departure text not null default '' check(char_length(departure)<=200),
 driver_seats integer not null default 0 check(driver_seats between 0 and 100),
 revision integer not null default 1,
 primary key(occurrence_id,user_id),
 foreign key(occurrence_id,user_id) references public.event_rsvps(occurrence_id,user_id) on delete cascade,
 check((attendance_start is null and attendance_end is null) or (attendance_start is not null and attendance_end is not null and attendance_end>attendance_start))
);
alter table private.event_logistics_groups add column capacity integer not null default 100 check(capacity between 1 and 1000);
create table private.event_logistics_rooms (
 id uuid primary key, occurrence_id uuid not null references private.event_logistics_plans(occurrence_id) on delete cascade,
 name text not null check(char_length(btrim(name)) between 1 and 100), capacity integer not null check(capacity between 1 and 1000),
 unique(occurrence_id,id)
);
alter table private.event_logistics_assignments add column room_id uuid;
alter table private.event_logistics_assignments add foreign key(occurrence_id,room_id) references private.event_logistics_rooms(occurrence_id,id);
create table private.event_badges (
 token_hash bytea primary key, occurrence_id uuid not null references public.event_occurrences(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 expires_at timestamptz not null, issued_at timestamptz not null default clock_timestamp(),
 unique(occurrence_id,user_id)
);
create index event_badges_user_idx on private.event_badges(user_id,occurrence_id);
create table private.event_checkins (
 occurrence_id uuid not null references public.event_occurrences(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 checked_at timestamptz not null default clock_timestamp(), checked_by uuid not null references public.profiles(id),
 primary key(occurrence_id,user_id)
);
alter table private.event_staff enable row level security;
alter table private.event_surveys enable row level security;
alter table private.event_logistics_rooms enable row level security;
alter table private.event_badges enable row level security;
alter table private.event_checkins enable row level security;
revoke all on private.event_staff,private.event_surveys,private.event_logistics_rooms,private.event_badges,private.event_checkins from public,anon,authenticated;

create function private.can_event_field(p_occurrence_id uuid,p_actor_id uuid,p_capability text)
returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 -- Finance owns financial-office eligibility and cancellation/refund semantics.
 -- Resolved at first invocation after the following finance migration is applied.
 if p_capability='fees' then
  return private.can_manage_event_fees(p_occurrence_id,p_actor_id);
 end if;
 return p_capability=any(array['logistics','checkin','export']) and exists(
 select 1 from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and o.status='scheduled' and e.status='scheduled'
 and private.is_eligible_event_attendee(e.scope_id,p_actor_id)
 and (private.can_manage_event_logistics(e.scope_id,p_actor_id) or exists(
 select 1 from private.event_staff s where s.occurrence_id=o.id and s.user_id=p_actor_id
 and s.expires_at>statement_timestamp() and p_capability=any(s.capabilities))));
end;
$$;
revoke all on function private.can_event_field(uuid,uuid,text) from public,anon,authenticated;

create function public.set_event_staff(p_occurrence_id uuid,p_user_id uuid,p_capabilities text[],p_expires_at timestamptz)
returns void language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); s uuid; ending timestamptz;
begin
 select e.scope_id,o.ends_at into s,ending from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and o.status='scheduled' and e.status='scheduled';
 if s is null or not private.can_manage_events(s,a) then raise exception 'event_staff_forbidden' using errcode='42501'; end if;
 perform private.require_aal2('event_staff_grant');
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 perform private.require_current_consent_actor();
 select e.scope_id,o.ends_at into s,ending from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and o.status='scheduled' and e.status='scheduled' for update of o;
 if s is null or not private.can_manage_events(s,a) then raise exception 'event_staff_forbidden' using errcode='42501'; end if;
 if cardinality(p_capabilities)=0 then delete from private.event_staff where occurrence_id=p_occurrence_id and user_id=p_user_id;
 else
 if p_capabilities is null or not private.is_eligible_event_attendee(s,p_user_id) or p_expires_at is null or p_expires_at<=statement_timestamp()
 or p_expires_at>ending+interval '1 day' or p_expires_at>statement_timestamp()+interval '30 days' then raise exception 'invalid_event_staff_grant' using errcode='23514'; end if;
 insert into private.event_staff values(p_occurrence_id,p_user_id,p_capabilities,p_expires_at,a)
 on conflict(occurrence_id,user_id) do update set capabilities=excluded.capabilities,expires_at=excluded.expires_at,granted_by=a;
 end if;
 perform private.write_audit(a,'event.staff_changed','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),null,jsonb_build_object('user_id',p_user_id,'capabilities',p_capabilities,'expires_at',p_expires_at));
end $$;

create function public.save_event_survey(p_occurrence_id uuid,p_revision integer,p_attendance_start timestamptz,p_attendance_end timestamptz,p_departure text,p_driver_seats integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); o public.event_occurrences%rowtype; s uuid; r integer;
begin
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 select * into o from public.event_occurrences where id=p_occurrence_id for update;
 select scope_id into s from public.events where id=o.event_id and status='scheduled';
 if s is null or o.status<>'scheduled' or o.ends_at<=statement_timestamp() or not private.is_eligible_event_attendee(s,a)
 or not exists(select 1 from public.event_rsvps where occurrence_id=p_occurrence_id and user_id=a and response in('yes','waitlist','maybe')) then raise exception 'event_survey_forbidden' using errcode='42501'; end if;
 if (p_attendance_start is not null or p_attendance_end is not null) and (p_attendance_start is null or p_attendance_end is null or p_attendance_start<o.starts_at or p_attendance_end>o.ends_at or p_attendance_start>=p_attendance_end) then raise exception 'invalid_attendance_interval' using errcode='23514'; end if;
 select revision into r from private.event_surveys where occurrence_id=p_occurrence_id and user_id=a;
 if p_revision is null or p_revision<0 or coalesce(r,0)<>p_revision then raise exception 'event_survey_revision_conflict' using errcode='40001'; end if;
 insert into private.event_surveys values(p_occurrence_id,a,p_attendance_start,p_attendance_end,btrim(p_departure),p_driver_seats,1)
 on conflict(occurrence_id,user_id) do update set attendance_start=excluded.attendance_start,attendance_end=excluded.attendance_end,departure=excluded.departure,driver_seats=excluded.driver_seats,revision=private.event_surveys.revision+1;
 update private.event_logistics_vehicles set driver_user_id=null
 where occurrence_id=p_occurrence_id and driver_user_id=a and seat_count>p_driver_seats;
 perform private.sanitize_event_logistics(p_occurrence_id,true);
 perform private.write_audit(a,'event.survey_saved','event_occurrence',p_occurrence_id,
 (select organization_id from public.governance_scopes where id=s),null,jsonb_build_object('revision',coalesce(r,0)+1));
 return (select to_jsonb(x)-'user_id'-'occurrence_id' from private.event_surveys x where occurrence_id=p_occurrence_id and user_id=a);
end $$;

create function public.get_event_field(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); s uuid; caps text[]; roster jsonb; can_allocate boolean;
begin
 select e.scope_id into s from public.event_occurrences o join public.events e on e.id=o.event_id where o.id=p_occurrence_id and private.is_eligible_event_attendee(e.scope_id,a);
 if s is null then raise exception 'event_field_forbidden' using errcode='42501'; end if;
 -- Read capabilities only after acquiring the same lock as eligibility cleanup.
 perform private.consume_rate_limit(a,'event_field_reads',120,60,1);
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 perform private.require_current_consent_actor();
 if not private.is_eligible_event_attendee(s,a) then raise exception 'event_field_forbidden' using errcode='42501'; end if;
 select coalesce(array_agg(c),'{}') into caps from unnest(array['logistics','checkin','export','fees']) c where private.can_event_field(p_occurrence_id,a,c);
 can_allocate:=caps&&array['logistics','export'];
 if can_allocate then
 insert into private.event_logistics_plans(occurrence_id) values(p_occurrence_id) on conflict do nothing;
 perform private.sanitize_event_logistics(p_occurrence_id);
 end if;
 if cardinality(caps)>0 then
 select coalesce(jsonb_agg(jsonb_build_object('user_id',r.user_id,'display_name',p.display_name,'response',r.response,
 'church_id',church.id,'church_name',church.name,'survey',case when can_allocate then to_jsonb(su)-'user_id'-'occurrence_id' else null end,
 'group_id',case when can_allocate then la.group_id else null end,'vehicle_id',case when can_allocate then la.vehicle_id else null end,'room_id',case when can_allocate then la.room_id else null end,'checked_at',ci.checked_at) order by p.display_name,r.user_id),'[]') into roster
 from public.event_rsvps r join public.profiles p on p.id=r.user_id
 left join lateral(select org.id,org.display_name as name from public.organization_memberships m join public.organizations org on org.id=m.organization_id
 where m.user_id=r.user_id and m.status='active' and org.status='active' order by org.id limit 1) church on true
 left join private.event_surveys su on su.occurrence_id=r.occurrence_id and su.user_id=r.user_id
 left join private.event_logistics_assignments la on la.occurrence_id=r.occurrence_id and la.user_id=r.user_id
 left join private.event_checkins ci on ci.occurrence_id=r.occurrence_id and ci.user_id=r.user_id
 where r.occurrence_id=p_occurrence_id and private.is_eligible_event_attendee(s,r.user_id);
 end if;
 return jsonb_build_object('capabilities',caps,'can_grant',private.can_manage_events(s,a) and exists(select 1 from public.event_occurrences o join public.events e on e.id=o.event_id where o.id=p_occurrence_id and o.status='scheduled' and e.status='scheduled'),
 'is_closed',(select o.status<>'scheduled' or e.status<>'scheduled' from public.event_occurrences o join public.events e on e.id=o.event_id where o.id=p_occurrence_id),
 'starts_at',(select starts_at from public.event_occurrences where id=p_occurrence_id),
 'ends_at',(select ends_at from public.event_occurrences where id=p_occurrence_id),
 'survey',(select to_jsonb(x)-'user_id'-'occurrence_id' from private.event_surveys x where occurrence_id=p_occurrence_id and user_id=a),
 'plan',case when can_allocate then private.event_logistics_snapshot(p_occurrence_id)-'participants' else jsonb_build_object('revision',0,'vehicles','[]'::jsonb) end,
 'groups',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'capacity',capacity) order by name,id),'[]') from private.event_logistics_groups where occurrence_id=p_occurrence_id and can_allocate),
 'rooms',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'capacity',capacity) order by name,id),'[]') from private.event_logistics_rooms where occurrence_id=p_occurrence_id and can_allocate),
 'participants',coalesce(roster,'[]'),
 'staff',case when private.can_manage_events(s,a) then (select coalesce(jsonb_agg(to_jsonb(x)-'granted_by'),'[]') from private.event_staff x where occurrence_id=p_occurrence_id) else '[]' end);
end $$;

create function public.save_event_field_plan(p_occurrence_id uuid,p_revision integer,p_groups jsonb,p_vehicles jsonb,p_rooms jsonb,p_assignments jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); s uuid; rev integer;
begin
 if not private.can_event_field(p_occurrence_id,a,'logistics') then raise exception 'event_field_forbidden' using errcode='42501'; end if;
 perform private.require_aal2('event_logistics_save');
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 perform 1 from public.event_occurrences where id=p_occurrence_id for update;
 if not private.can_event_field(p_occurrence_id,a,'logistics') then raise exception 'event_field_forbidden' using errcode='42501'; end if;
 select e.scope_id into s from public.events e join public.event_occurrences o on o.event_id=e.id where o.id=p_occurrence_id;
 insert into private.event_logistics_plans(occurrence_id) values(p_occurrence_id) on conflict do nothing;
 perform private.sanitize_event_logistics(p_occurrence_id);
 select revision into rev from private.event_logistics_plans where occurrence_id=p_occurrence_id;
 if p_revision is distinct from rev then raise exception 'event_logistics_revision_conflict' using errcode='40001'; end if;
 if jsonb_typeof(p_groups) is distinct from 'array' or jsonb_typeof(p_rooms) is distinct from 'array' or jsonb_typeof(p_vehicles) is distinct from 'array' or jsonb_typeof(p_assignments) is distinct from 'array'
 or jsonb_array_length(p_groups)>50 or jsonb_array_length(p_rooms)>100 or jsonb_array_length(p_vehicles)>50 then raise exception 'invalid_event_plan' using errcode='23514'; end if;
 if exists(select 1 from jsonb_array_elements(p_groups||p_rooms) x where jsonb_typeof(x->'name') is distinct from 'string' or jsonb_typeof(x->'capacity') is distinct from 'number' or (x->>'capacity')!~'^[1-9][0-9]{0,3}$')
 or exists(select 1 from jsonb_array_elements(p_vehicles) x where jsonb_typeof(x->'label') is distinct from 'string' or jsonb_typeof(x->'seat_count') is distinct from 'number' or (x->>'seat_count')!~'^([1-9][0-9]?|100)$')
 then raise exception 'invalid_event_plan_resources' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_assignments) x(user_id uuid,group_id uuid,vehicle_id uuid,room_id uuid)
 where not exists(select 1 from public.event_rsvps r where r.occurrence_id=p_occurrence_id and r.user_id=x.user_id and r.response='yes' and private.is_eligible_event_attendee(s,r.user_id))
 or (group_id is not null and not exists(select 1 from jsonb_to_recordset(p_groups) g(id uuid) where g.id=x.group_id))
 or (vehicle_id is not null and not exists(select 1 from jsonb_to_recordset(p_vehicles) g(id uuid) where g.id=x.vehicle_id))
 or (room_id is not null and not exists(select 1 from jsonb_to_recordset(p_rooms) g(id uuid) where g.id=x.room_id))) then raise exception 'ineligible_event_assignment' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_groups) g(id uuid,capacity integer) where capacity is null or capacity<(select count(*) from jsonb_to_recordset(p_assignments) x(group_id uuid) where x.group_id=g.id))
 or exists(select 1 from jsonb_to_recordset(p_rooms) g(id uuid,capacity integer) where capacity is null or capacity<(select count(*) from jsonb_to_recordset(p_assignments) x(room_id uuid) where x.room_id=g.id))
 or exists(select 1 from jsonb_to_recordset(p_vehicles) g(id uuid,seat_count integer) where seat_count<(select count(*) from jsonb_to_recordset(p_assignments) x(vehicle_id uuid) where x.vehicle_id=g.id)) then raise exception 'event_plan_capacity_exceeded' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_vehicles) v(id uuid,driver_user_id uuid,seat_count integer) where driver_user_id is not null and
 (not exists(select 1 from jsonb_to_recordset(p_assignments) x(user_id uuid,vehicle_id uuid) where x.user_id=v.driver_user_id and x.vehicle_id=v.id)
 or not exists(select 1 from private.event_surveys su where su.occurrence_id=p_occurrence_id and su.user_id=v.driver_user_id and su.driver_seats>=v.seat_count))) then raise exception 'event_driver_not_volunteered' using errcode='23514'; end if;
 -- Identifiers cannot be moved from another occurrence; primary keys fail closed.
 delete from private.event_logistics_assignments where occurrence_id=p_occurrence_id;
 delete from private.event_logistics_groups where occurrence_id=p_occurrence_id;
 delete from private.event_logistics_rooms where occurrence_id=p_occurrence_id;
 delete from private.event_logistics_vehicles where occurrence_id=p_occurrence_id;
 insert into private.event_logistics_groups(id,occurrence_id,name,capacity) select id,p_occurrence_id,btrim(name),capacity from jsonb_to_recordset(p_groups) x(id uuid,name text,capacity integer);
 insert into private.event_logistics_rooms(id,occurrence_id,name,capacity) select id,p_occurrence_id,btrim(name),capacity from jsonb_to_recordset(p_rooms) x(id uuid,name text,capacity integer);
 insert into private.event_logistics_vehicles(id,occurrence_id,label,seat_count,driver_user_id) select id,p_occurrence_id,btrim(label),seat_count,driver_user_id from jsonb_to_recordset(p_vehicles) x(id uuid,label text,seat_count integer,driver_user_id uuid);
 insert into private.event_logistics_assignments(occurrence_id,user_id,group_id,vehicle_id,room_id) select p_occurrence_id,user_id,group_id,vehicle_id,room_id from jsonb_to_recordset(p_assignments) x(user_id uuid,group_id uuid,vehicle_id uuid,room_id uuid);
 update private.event_logistics_plans set revision=revision+1,updated_by=a,updated_at=clock_timestamp() where occurrence_id=p_occurrence_id;
 perform private.write_audit(a,'event.field_plan_saved','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),null,jsonb_build_object('revision',rev+1));
 return public.get_event_field(p_occurrence_id);
end $$;

create function public.issue_event_badge(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); t text; expiry timestamptz;
begin
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 select least(clock_timestamp()+interval '5 minutes',o.ends_at) into expiry from public.event_occurrences o join public.events e on e.id=o.event_id
 join public.event_rsvps r on r.occurrence_id=o.id and r.user_id=a and r.response='yes'
 where o.id=p_occurrence_id and o.status='scheduled' and e.status='scheduled' and o.ends_at>statement_timestamp() and private.is_eligible_event_attendee(e.scope_id,a);
 if expiry is null then raise exception 'event_badge_ineligible' using errcode='42501'; end if;
 perform private.consume_rate_limit(a,'event_badges',20,60,1);
 t:='jg3.'||encode(extensions.gen_random_bytes(24),'hex');
 delete from private.event_badges where occurrence_id=p_occurrence_id and user_id=a;
 insert into private.event_badges(token_hash,occurrence_id,user_id,expires_at) values(extensions.digest(t,'sha256'),p_occurrence_id,a,expiry);
 return jsonb_build_object('token',t,'expires_at',expiry);
end $$;

create function public.verify_event_badge(p_occurrence_id uuid,p_token text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); badge private.event_badges%rowtype; at_time timestamptz; s uuid;
begin
 if not private.can_event_field(p_occurrence_id,a,'checkin') then raise exception 'event_checkin_forbidden' using errcode='42501'; end if;
 if p_token is null or p_token!~'^jg3\.[a-f0-9]{48}$' then raise exception 'invalid_event_badge' using errcode='22023'; end if;
 perform private.consume_rate_limit(a,'event_scans',120,60,1);
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 select * into badge from private.event_badges where token_hash=extensions.digest(p_token,'sha256') and occurrence_id=p_occurrence_id and expires_at>statement_timestamp() for update;
 if not found or not private.can_event_field(p_occurrence_id,a,'checkin') then raise exception 'expired_or_revoked_event_badge' using errcode='42501'; end if;
 select e.scope_id into s from public.event_occurrences o join public.events e on e.id=o.event_id where o.id=p_occurrence_id and o.ends_at>statement_timestamp();
 if s is null or not private.is_eligible_event_attendee(s,badge.user_id) or not exists(select 1 from public.event_rsvps r where r.occurrence_id=p_occurrence_id and r.user_id=badge.user_id and r.response='yes') then raise exception 'expired_or_revoked_event_badge' using errcode='42501'; end if;
 insert into private.event_checkins(occurrence_id,user_id,checked_by) values(p_occurrence_id,badge.user_id,a) on conflict do nothing;
 select checked_at into at_time from private.event_checkins where occurrence_id=p_occurrence_id and user_id=badge.user_id;
 perform private.write_audit(a,'event.checkin','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),null,jsonb_build_object('user_id',badge.user_id,'checked_at',at_time));
 return jsonb_build_object('user_id',badge.user_id,'display_name',(select display_name from public.profiles where id=badge.user_id),'checked_at',at_time);
end $$;

create function public.export_event_field(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); result jsonb;
begin
 if not private.can_event_field(p_occurrence_id,a,'export') then raise exception 'event_export_forbidden' using errcode='42501'; end if;
 perform private.require_aal2('event_roster_export');
 result:=public.get_event_field(p_occurrence_id);
 if not private.can_event_field(p_occurrence_id,a,'export') then raise exception 'event_export_forbidden' using errcode='42501'; end if;
 perform private.write_audit(a,'event.roster_export','event_occurrence',p_occurrence_id,null,null,jsonb_build_object('rows',jsonb_array_length(result->'participants')));
 return result || jsonb_build_object('staff','[]'::jsonb,'survey',null,'can_grant',false);
end $$;

-- Physical revocation on eligibility-related writes, including cancellation; current
-- eligibility is independently rechecked on every verification (future document changes).
create function private.revoke_event_badges() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if tg_table_name='user_consents' then
 if tg_op='DELETE' then delete from private.event_badges where user_id=old.user_id;
 else delete from private.event_badges where user_id=new.user_id; end if;
 elsif tg_table_name='event_rsvps' then
 delete from private.event_badges where occurrence_id=old.occurrence_id and user_id=old.user_id;
 elsif tg_table_name='events' then
 delete from private.event_badges where occurrence_id in(select id from public.event_occurrences where event_id=old.id);
 elsif tg_table_name='event_occurrences' then delete from private.event_badges where occurrence_id=old.id;
 elsif tg_table_name='profiles' then delete from private.event_badges where user_id=old.id;
 else delete from private.event_badges where user_id=old.user_id;
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
create trigger revoke_badges_rsvp after update or delete on public.event_rsvps for each row execute function private.revoke_event_badges();
create trigger revoke_badges_events after update on public.events for each row execute function private.revoke_event_badges();
create trigger revoke_badges_occurrences after update on public.event_occurrences for each row execute function private.revoke_event_badges();
create trigger revoke_badges_profiles after update on public.profiles for each row execute function private.revoke_event_badges();
create trigger revoke_badges_memberships after update or delete on public.organization_memberships for each row execute function private.revoke_event_badges();
create trigger revoke_badges_consents after insert or update or delete on public.user_consents for each row execute function private.revoke_event_badges();

revoke all on function private.revoke_event_badges() from public,anon,authenticated;
revoke all on function public.set_event_staff(uuid,uuid,text[],timestamptz),public.save_event_survey(uuid,integer,timestamptz,timestamptz,text,integer),public.get_event_field(uuid),public.save_event_field_plan(uuid,integer,jsonb,jsonb,jsonb,jsonb),public.issue_event_badge(uuid),public.verify_event_badge(uuid,text),public.export_event_field(uuid) from public,anon,authenticated;
grant execute on function public.set_event_staff(uuid,uuid,text[],timestamptz),public.save_event_survey(uuid,integer,timestamptz,timestamptz,text,integer),public.get_event_field(uuid),public.save_event_field_plan(uuid,integer,jsonb,jsonb,jsonb,jsonb),public.issue_event_badge(uuid),public.verify_event_badge(uuid,text),public.export_event_field(uuid) to authenticated;

-- The existing group/vehicle editor updates only those dimensions. Preserve room
-- allocations and existing group limits; it must not be a weaker write path.
create or replace function public.save_event_logistics(
 p_occurrence_id uuid,p_revision integer,p_groups jsonb,p_vehicles jsonb,p_assignments jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare
 a uuid:=private.require_current_consent_actor(); s uuid; rev integer; rooms jsonb; limits jsonb;
begin
 select e.scope_id into s from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and private.can_manage_event_logistics(e.scope_id,a);
 if s is null then raise exception 'event_logistics_not_found_or_forbidden' using errcode='P0002'; end if;
 perform private.require_aal2('event_logistics_save');
 perform pg_advisory_xact_lock(hashtextextended('event-rsvp:'||p_occurrence_id::text,0));
 perform 1 from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and o.status='scheduled' and e.status='scheduled' for update of o;
 if not found then raise exception 'event_logistics_closed' using errcode='55000'; end if;
 if not private.can_manage_event_logistics(s,a) then raise exception 'event_logistics_not_found_or_forbidden' using errcode='P0002'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_groups) is distinct from 'array'
 or jsonb_typeof(p_vehicles) is distinct from 'array' or jsonb_typeof(p_assignments) is distinct from 'array'
 then raise exception 'invalid_event_logistics_payload' using errcode='22023'; end if;
 if jsonb_array_length(p_groups)>50 or jsonb_array_length(p_vehicles)>50 then raise exception 'event_logistics_item_limit' using errcode='23514'; end if;
 insert into private.event_logistics_plans(occurrence_id) values(p_occurrence_id) on conflict do nothing;
 perform private.sanitize_event_logistics(p_occurrence_id);
 select revision into rev from private.event_logistics_plans where occurrence_id=p_occurrence_id;
 if p_revision<>rev then raise exception 'event_logistics_revision_conflict' using errcode='40001'; end if;
 if exists(select 1 from jsonb_to_recordset(p_groups) g(id uuid,name text) where id is null or nullif(btrim(name),'') is null or char_length(btrim(name))>100)
 or (select count(*)<>count(distinct id) from jsonb_to_recordset(p_groups) g(id uuid)) then raise exception 'invalid_event_logistics_groups' using errcode='23514'; end if;
 if exists(select 1 from jsonb_array_elements(p_vehicles) x where jsonb_typeof(x->'label') is distinct from 'string' or jsonb_typeof(x->'seat_count') is distinct from 'number' or (x->>'seat_count')!~'^([1-9][0-9]?|100)$')
 then raise exception 'invalid_event_logistics_vehicles' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_vehicles) v(id uuid,label text,seat_count integer) where id is null or nullif(btrim(label),'') is null or char_length(btrim(label))>100 or seat_count is null or seat_count not between 1 and 100)
 or (select count(*)<>count(distinct id) from jsonb_to_recordset(p_vehicles) v(id uuid))
 or exists(select driver_user_id from jsonb_to_recordset(p_vehicles) v(driver_user_id uuid) where driver_user_id is not null group by driver_user_id having count(*)>1)
 then raise exception 'invalid_event_logistics_vehicles' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_groups) g(id uuid) join private.event_logistics_groups x on x.id=g.id where x.occurrence_id<>p_occurrence_id)
 or exists(select 1 from jsonb_to_recordset(p_vehicles) g(id uuid) join private.event_logistics_vehicles x on x.id=g.id where x.occurrence_id<>p_occurrence_id)
 then raise exception 'event_logistics_cross_occurrence_id' using errcode='23514'; end if;
 if (select count(*)<>count(distinct user_id) from jsonb_to_recordset(p_assignments) x(user_id uuid))
 or exists(select 1 from jsonb_to_recordset(p_assignments) x(user_id uuid,group_id uuid,vehicle_id uuid) where user_id is null
 or not exists(select 1 from public.event_rsvps r where r.occurrence_id=p_occurrence_id and r.user_id=x.user_id and r.response='yes' and private.is_eligible_event_attendee(s,r.user_id))
 or (group_id is not null and not exists(select 1 from jsonb_to_recordset(p_groups) g(id uuid) where g.id=x.group_id))
 or (vehicle_id is not null and not exists(select 1 from jsonb_to_recordset(p_vehicles) g(id uuid) where g.id=x.vehicle_id)))
 then raise exception 'invalid_event_logistics_assignments' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_vehicles) v(id uuid,driver_user_id uuid) where driver_user_id is not null
 and not exists(select 1 from jsonb_to_recordset(p_assignments) x(user_id uuid,vehicle_id uuid) where x.user_id=v.driver_user_id and x.vehicle_id=v.id))
 then raise exception 'invalid_event_logistics_driver' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_vehicles) v(id uuid,seat_count integer) where seat_count<(select count(*) from jsonb_to_recordset(p_assignments) x(vehicle_id uuid) where x.vehicle_id=v.id))
 then raise exception 'event_logistics_vehicle_capacity_exceeded' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_groups) g(id uuid) where coalesce((select capacity from private.event_logistics_groups where id=g.id and occurrence_id=p_occurrence_id),100)<(select count(*) from jsonb_to_recordset(p_assignments) x(group_id uuid) where x.group_id=g.id))
 then raise exception 'event_plan_capacity_exceeded' using errcode='23514'; end if;
 if exists(select 1 from jsonb_to_recordset(p_vehicles) v(driver_user_id uuid,seat_count integer) where driver_user_id is not null
 and not exists(select 1 from private.event_surveys su where su.occurrence_id=p_occurrence_id and su.user_id=v.driver_user_id and su.driver_seats>=v.seat_count))
 then raise exception 'event_driver_not_volunteered' using errcode='23514'; end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rooms from private.event_logistics_assignments x where occurrence_id=p_occurrence_id;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into limits from private.event_logistics_groups x where occurrence_id=p_occurrence_id;
 perform private.consume_rate_limit(a,'event_logistics_mutations',30,3600,1);
 delete from private.event_logistics_assignments where occurrence_id=p_occurrence_id;
 delete from private.event_logistics_groups where occurrence_id=p_occurrence_id;
 delete from private.event_logistics_vehicles where occurrence_id=p_occurrence_id;
 insert into private.event_logistics_groups(id,occurrence_id,name,capacity)
 select g.id,p_occurrence_id,btrim(g.name),coalesce((select capacity from jsonb_to_recordset(limits) old(id uuid,capacity integer) where old.id=g.id),100)
 from jsonb_to_recordset(p_groups) g(id uuid,name text);
 insert into private.event_logistics_vehicles(id,occurrence_id,label,seat_count,driver_user_id)
 select id,p_occurrence_id,btrim(label),seat_count,driver_user_id from jsonb_to_recordset(p_vehicles) v(id uuid,label text,seat_count integer,driver_user_id uuid);
 insert into private.event_logistics_assignments(occurrence_id,user_id,group_id,vehicle_id,room_id)
 select p_occurrence_id,x.user_id,x.group_id,x.vehicle_id,(select old.room_id from jsonb_to_recordset(rooms) old(user_id uuid,room_id uuid) where old.user_id=x.user_id)
 from jsonb_to_recordset(p_assignments) x(user_id uuid,group_id uuid,vehicle_id uuid);
 update private.event_logistics_plans set revision=revision+1,updated_by=a,updated_at=clock_timestamp() where occurrence_id=p_occurrence_id;
 perform private.write_audit(a,'event.logistics_saved','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),null,jsonb_build_object('revision',rev+1));
 return private.event_logistics_snapshot(p_occurrence_id);
end $$;
