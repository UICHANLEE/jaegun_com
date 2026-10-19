-- Explicit aggregate participation is separate from actor-private faith consent.
create table private.faith_ranking_preferences (
 user_id uuid not null references public.profiles(id) on delete cascade,
 organization_id uuid not null references public.organizations(id) on delete cascade,
 service_year integer not null check(service_year between 2000 and 9999),
 opted_in boolean not null default false,
 -- Self-selected reading-challenge grouping only; never membership, age, or authority.
 challenge_department_code text check(challenge_department_code in('adult','young_adult','teen','elementary')),
 constraint faith_ranking_department_optin_check check(opted_in or challenge_department_code is null),
 notice_version text not null default '2026-10-15',
 revision integer not null default 1 check(revision>0),
 updated_at timestamptz not null default statement_timestamp(),
 primary key(user_id,organization_id,service_year)
);
alter table private.faith_ranking_preferences enable row level security;
revoke all on private.faith_ranking_preferences from public,anon,authenticated;

create function public.get_faith_community(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_eligible_actor(p_organization_id);
 v_year integer:=extract(year from statement_timestamp() at time zone 'Asia/Seoul')::integer;
 v_result jsonb; v_pref private.faith_ranking_preferences%rowtype; v_presbytery_scope uuid;
begin
 select parent_scope_id into v_presbytery_scope from public.governance_scopes
 where organization_id=p_organization_id and scope_type='church' and is_active;
 select * into v_pref from private.faith_ranking_preferences where user_id=v_actor and organization_id=p_organization_id and service_year=v_year;
 -- No individual identifiers, chapter dates, QT, or name can leave this aggregate.
 with eligible as (
  select pref.user_id,pref.organization_id,church.id church_scope_id,church.parent_scope_id,pref.challenge_department_code,
   (select count(*) from private.faith_reading_chapters r where r.user_id=pref.user_id and r.service_year=v_year)::integer chapters
  from private.faith_ranking_preferences pref
  join public.governance_scopes church on church.organization_id=pref.organization_id and church.scope_type='church' and church.is_active
  join public.governance_scopes presbytery on presbytery.id=church.parent_scope_id and presbytery.scope_type='presbytery' and presbytery.is_active
  join public.organizations org on org.id=pref.organization_id and org.status='active'
  join private.faith_consents consent on consent.user_id=pref.user_id and consent.withdrawn_at is null
    and consent.document_version=private.faith_document_manifest()->>'version'
    and consent.content_sha256=private.faith_document_manifest()->>'content_sha256'
  join public.profiles profile on profile.id=pref.user_id and profile.deactivated_at is null
  where pref.opted_in and pref.service_year=v_year and pref.notice_version='2026-10-15'
   and church.parent_scope_id=v_presbytery_scope
   and private.has_current_required_consents(pref.user_id) and private.is_active_member(pref.organization_id,pref.user_id)
 ), aggregates as (
  select 'church'::text kind,organization_id id,count(*) participants,sum(chapters) chapters from eligible group by organization_id having count(*)>=5
  union all
  select 'presbytery',parent_scope_id,count(*),sum(chapters) from eligible group by parent_scope_id having count(*)>=5
  union all
  select 'department',department.id,count(*),sum(eligible.chapters)
  from eligible join public.church_departments department on department.church_scope_id=eligible.church_scope_id
   and department.department_code::text=eligible.challenge_department_code and department.is_active
  where eligible.organization_id=p_organization_id
  group by department.id having count(*)>=5
 ), rows as (
  select a.kind,a.id,case when a.kind='church' then org.display_name when a.kind='department' then department.display_name||' 통독 모임' else scope.display_name end name,
    a.participants,a.chapters,round(a.chapters::numeric/a.participants,1) average_chapters,
    dense_rank() over(partition by a.kind order by round(a.chapters::numeric/a.participants,1) desc) rank
  from aggregates a left join public.organizations org on a.kind='church' and org.id=a.id
  left join public.governance_scopes scope on a.kind='presbytery' and scope.id=a.id and scope.is_active
  left join public.church_departments department on a.kind='department' and department.id=a.id and department.is_active
  where (a.kind='church' and a.id=p_organization_id)
    or (a.kind='presbytery' and a.id=v_presbytery_scope)
    or a.kind='department'
 ) select coalesce(jsonb_agg(to_jsonb(rows) order by kind,rank,name),'[]'::jsonb) into v_result from rows;
 return jsonb_build_object('server_today',(statement_timestamp() at time zone 'Asia/Seoul')::date,'service_year',v_year,
 'opted_in',coalesce(v_pref.opted_in,false),'challenge_department_code',v_pref.challenge_department_code,'revision',coalesce(v_pref.revision,0),'notice_version','2026-10-15',
 'notice','선택한 올해의 읽은 장 수만 교회·노회 및 선택한 우리 교회 부서별 통독 모임 집계에 포함합니다. 부서는 본인이 고르는 선택적인 통독 도전 그룹이며 실제 소속·나이·직책·권한을 뜻하거나 변경하지 않습니다. 참여자 5명 미만 그룹은 숨기며 이름·개인 진도·묵상은 공개하지 않습니다. 부서 미선택은 교회·노회 집계에만 참여합니다. 참여 취소·개인 기록 동의 철회·회원 자격 종료 시 즉시 집계에서 제외됩니다. 올해에만 적용되며 내년에 다시 선택합니다.',
 'minimum_group',5,'rankings',v_result);
end; $$;

create function public.set_faith_ranking_participation(p_organization_id uuid,p_service_year integer,p_opted_in boolean,p_notice_version text,p_expected_revision integer,p_expected_actor_id uuid,p_challenge_department_code text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid; v_year integer:=extract(year from statement_timestamp() at time zone 'Asia/Seoul')::integer; v_pref private.faith_ranking_preferences%rowtype;
begin
 if p_service_year is distinct from v_year or p_opted_in is null or p_notice_version is distinct from '2026-10-15' or p_expected_revision is null or p_expected_revision<0 then raise exception 'invalid_faith_ranking_request' using errcode='23514'; end if;
 if (p_challenge_department_code is not null and p_challenge_department_code not in('adult','young_adult','teen','elementary')) or (not p_opted_in and p_challenge_department_code is not null) then raise exception 'invalid_faith_challenge_department' using errcode='23514'; end if;
 -- Opt-out remains self-service even after optional/core consent or membership ends.
 if p_opted_in then v_actor:=private.require_faith_actor(p_organization_id); else v_actor:=private.require_faith_withdrawal_actor(); end if;
 if p_expected_actor_id is distinct from v_actor then raise exception 'faith_actor_changed' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 if p_opted_in then perform private.require_faith_actor(p_organization_id); else perform private.require_faith_withdrawal_actor(); end if;
 select * into v_pref from private.faith_ranking_preferences where user_id=v_actor and organization_id=p_organization_id and service_year=v_year for update;
 if found and v_pref.opted_in=p_opted_in and v_pref.notice_version=p_notice_version and v_pref.challenge_department_code is not distinct from p_challenge_department_code then
  return jsonb_build_object('opted_in',v_pref.opted_in,'challenge_department_code',v_pref.challenge_department_code,'revision',v_pref.revision,'service_year',v_year);
 end if;
 if coalesce(v_pref.revision,0)<>p_expected_revision then raise exception 'faith_ranking_revision_conflict' using errcode='40001'; end if;
 if not p_opted_in and v_pref.user_id is null then return jsonb_build_object('opted_in',false,'challenge_department_code',null,'revision',0,'service_year',v_year); end if;
 insert into private.faith_ranking_preferences(user_id,organization_id,service_year,opted_in,notice_version,challenge_department_code)
 values(v_actor,p_organization_id,v_year,p_opted_in,p_notice_version,p_challenge_department_code)
 on conflict(user_id,organization_id,service_year) do update set opted_in=excluded.opted_in,notice_version=excluded.notice_version,challenge_department_code=excluded.challenge_department_code,revision=private.faith_ranking_preferences.revision+1,updated_at=statement_timestamp()
 returning * into v_pref;
 perform private.write_audit(v_actor,'faith_ranking_participation','faith_ranking',p_organization_id,p_organization_id,v_actor,jsonb_build_object('opted_in',p_opted_in,'service_year',v_year));
 return jsonb_build_object('opted_in',v_pref.opted_in,'challenge_department_code',v_pref.challenge_department_code,'revision',v_pref.revision,'service_year',v_year);
end; $$;

create function private.remove_withdrawn_faith_ranking() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.withdrawn_at is not null then delete from private.faith_ranking_preferences where user_id=new.user_id; end if;
 return new;
end; $$;
create trigger faith_withdrawal_removes_ranking after update of withdrawn_at on private.faith_consents for each row execute function private.remove_withdrawn_faith_ranking();
revoke all on function private.remove_withdrawn_faith_ranking() from public,anon,authenticated;

-- Only an explicit RPC creates a public board copy; private original has no read bypass.
create table private.faith_shared_posts (
 post_id uuid primary key references public.posts(id) on delete cascade,
 actor_id uuid references public.profiles(id) on delete set null,
 qt_id uuid not null,
 created_at timestamptz not null default statement_timestamp()
);
alter table private.faith_shared_posts enable row level security;
revoke all on private.faith_shared_posts from public,anon,authenticated;
create function public.share_my_qt(p_organization_id uuid,p_qt_id uuid,p_client_request_id uuid) returns uuid
language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_actor(p_organization_id); v_qt private.faith_qt_entries%rowtype; v_shared private.faith_shared_posts%rowtype; v_board uuid;
begin
 if p_qt_id is null or p_client_request_id is null then raise exception 'invalid_qt_share_request' using errcode='23514'; end if;
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 perform private.require_faith_actor(p_organization_id);
 select * into v_shared from private.faith_shared_posts where post_id=p_client_request_id;
 if found then
  if v_shared.actor_id is distinct from v_actor or v_shared.qt_id<>p_qt_id or not exists(select 1 from public.posts where id=p_client_request_id and organization_id=p_organization_id) then raise exception 'qt_share_payload_mismatch' using errcode='23514'; end if;
  return v_shared.post_id;
 end if;
 select * into v_qt from private.faith_qt_entries where id=p_qt_id and user_id=v_actor;
 if not found then raise exception 'private_qt_not_found' using errcode='P0002'; end if;
 select id into v_board from public.boards where organization_id=p_organization_id and slug='fellowship' and not is_read_only and not staff_only_posting order by id limit 1;
 if v_board is null then raise exception 'sharing_board_unavailable' using errcode='P0002'; end if;
 if exists(select 1 from public.posts where id=p_client_request_id) then raise exception 'qt_share_request_conflict' using errcode='23505'; end if;
 perform public.save_owned_post_draft(p_client_request_id,v_actor,p_organization_id,v_board,'QT · '||v_qt.reference,v_qt.body);
 perform public.publish_owned_post(p_client_request_id,v_actor,'{}'::text[]);
 insert into private.faith_shared_posts(post_id,actor_id,qt_id) values(p_client_request_id,v_actor,p_qt_id);
 perform private.write_audit(v_actor,'share_private_qt_copy','post',p_client_request_id,p_organization_id,v_actor,'{}'::jsonb);
 return p_client_request_id;
end; $$;
create function public.list_shared_qt(p_organization_id uuid,p_day date default null,p_limit integer default 25,p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_eligible_actor(p_organization_id); v_today date:=(statement_timestamp() at time zone 'Asia/Seoul')::date; v_result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 50 or p_offset is null or p_offset not between 0 and 10000 or p_day>v_today then raise exception 'invalid_qt_feed_pagination' using errcode='23514'; end if;
 select coalesce(jsonb_agg(to_jsonb(feed) order by feed.created_at desc,feed.id desc),'[]'::jsonb) into v_result from (
  select p.id,p.title,p.body,p.created_at,
   (select count(*) from private.post_reactions r where r.post_id=p.id and r.kind='amen') amen_count,
   exists(select 1 from private.post_reactions r where r.post_id=p.id and r.kind='amen' and r.actor_id=v_actor) reacted_amen
  from private.faith_shared_posts shared join public.posts p on p.id=shared.post_id
  where p.organization_id=p_organization_id and p.status='published' and p.deleted_at is null and private.can_read_post(p.id,v_actor)
   and (p.created_at at time zone 'Asia/Seoul')::date=coalesce(p_day,v_today)
  order by p.created_at desc,p.id desc limit p_limit offset p_offset
 ) feed;
 return jsonb_build_object('server_today',v_today,'day',coalesce(p_day,v_today),'items',v_result);
end; $$;
revoke all on function public.get_faith_community(uuid),public.set_faith_ranking_participation(uuid,integer,boolean,text,integer,uuid,text),public.share_my_qt(uuid,uuid,uuid),public.list_shared_qt(uuid,date,integer,integer) from public,anon,authenticated;
grant execute on function public.get_faith_community(uuid),public.set_faith_ranking_participation(uuid,integer,boolean,text,integer,uuid,text),public.share_my_qt(uuid,uuid,uuid),public.list_shared_qt(uuid,date,integer,integer) to authenticated;
