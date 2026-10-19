-- Finance delegation never promotes an ordinary event volunteer to executive.
create or replace function private.can_manage_event_fees(p_occurrence_id uuid,p_actor_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select exists(select 1 from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and private.is_eligible_event_attendee(e.scope_id,p_actor_id)
 and private.can_scoped_records(e.scope_id,p_actor_id,'finance')
 and (private.can_scoped_records(e.scope_id,p_actor_id,'finance',true) or exists(
 select 1 from private.event_staff staff where staff.occurrence_id=o.id and staff.user_id=p_actor_id
 and staff.expires_at>statement_timestamp() and 'fees'=any(staff.capabilities))));
$$;
revoke all on function private.can_manage_event_fees(uuid,uuid) from public,anon,authenticated;
create or replace function public.set_event_staff(p_occurrence_id uuid,p_user_id uuid,p_capabilities text[],p_expires_at timestamptz)
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
 if 'fees'=any(p_capabilities) and not private.can_scoped_records(s,p_user_id,'finance') then raise exception 'fees_requires_executive' using errcode='42501'; end if;
 insert into private.event_staff values(p_occurrence_id,p_user_id,p_capabilities,p_expires_at,a)
 on conflict(occurrence_id,user_id) do update set capabilities=excluded.capabilities,expires_at=excluded.expires_at,granted_by=a;
 end if;
 perform private.write_audit(a,'event.staff_changed','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),null,jsonb_build_object('user_id',p_user_id,'capabilities',p_capabilities,'expires_at',p_expires_at));
end $$;

revoke all on function public.set_event_staff(uuid,uuid,text[],timestamptz) from public,anon;
grant execute on function public.set_event_staff(uuid,uuid,text[],timestamptz) to authenticated;
