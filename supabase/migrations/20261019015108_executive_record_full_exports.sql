-- All means every year and event in scopes the current executive may read.
-- A single statement produces the records, history and counts from one snapshot.
create function public.export_executive_records(p_kind text,p_expected_actor_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); result jsonb;
begin
 if a is distinct from p_expected_actor_id then raise exception 'actor_changed' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('minutes','finance') then raise exception 'invalid_record_kind'; end if;
 if not coalesce(private.operations_session_is_live(),false) then raise exception 'live_session_required' using errcode='42501'; end if;
 perform private.require_aal2('executive_records.export_all');
 perform private.consume_rate_limit(a,'records:full_export',6,3600);
 with allowed as materialized (
  select s.id,s.display_name from public.governance_scopes s where private.can_scoped_records(s.id,a,p_kind)
 ), records as materialized (
  select r.*,s.display_name as scope_label,e.title as event_title
  from private.scoped_records r join allowed s on s.id=r.scope_id
  left join public.events e on e.id=r.event_id and e.scope_id=r.scope_id where r.kind=p_kind
 ), histories as materialized (
  select h.* from private.scoped_record_history h join records r on r.id=h.record_id
 ), bounds as (
  select coalesce((select sum(octet_length(to_jsonb(r)::text)) from records r),0)
   +coalesce((select sum(octet_length(to_jsonb(h)::text)) from histories h),0) as bytes
 )
 select jsonb_build_object('format','jaegun-records-v1','kind',p_kind,'generated_at',statement_timestamp(),
 'scope_count',(select count(*) from allowed),'record_count',(select count(*) from records),
 'history_count',(select count(*) from histories),
 -- Never silently return a truncated workbook, or assemble an oversized response.
 'entries',case when (select count(*) from records)<=10000 and (select bytes from bounds)<=19000000 then coalesce((select jsonb_agg(to_jsonb(r) order by r.scope_id,r.event_id,r.record_date,r.id) from records r),'[]') else null end,
 'history',case when (select count(*) from histories)<=40000 and (select bytes from bounds)<=19000000 then coalesce((select jsonb_agg(to_jsonb(h) order by h.record_id,h.revision) from histories h),'[]') else null end) into result;
 if (result->>'scope_count')::integer=0 then raise exception 'record_scope_forbidden' using errcode='42501'; end if;
 if result->'entries'='null'::jsonb or result->'history'='null'::jsonb or octet_length(result::text)>20000000 then
  raise exception 'full_export_too_large_no_partial_file';
 end if;
 perform private.write_audit(a,'records.full_exported','executive_records',null,null,null,
 jsonb_build_object('kind',p_kind,'records',result->'record_count','histories',result->'history_count','all_years',true,'includes_events',true));
 return result;
end $$;
revoke all on function public.export_executive_records(text,uuid) from public,anon;
grant execute on function public.export_executive_records(text,uuid) to authenticated;
