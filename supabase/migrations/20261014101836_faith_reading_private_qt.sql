-- Personal faith records are RPC-only; no church officer or platform admin read bypass.
create table private.faith_consents (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 document_version text not null,
 content_sha256 text not null check(content_sha256 ~ '^[0-9a-f]{64}$'),
 accepted_at timestamptz not null,
 withdrawn_at timestamptz
);
alter table private.faith_consents enable row level security;
revoke all on private.faith_consents from public,anon,authenticated;
create function private.faith_document_manifest() returns jsonb
language sql immutable set search_path=pg_catalog as $$
 select jsonb_build_object('document_key','faith_private_records','version','2026-10-14',
 'content_sha256','4572f759bdcf51050b55f208af2513c63761db5127bc7c754175b4c8a31b8aa4',
 'title','개인 통독·QT 기록 이용 동의','url','/legal/faith/2026-10-14');
$$;
revoke all on function private.faith_document_manifest() from public,anon,authenticated;
create table private.faith_reading_chapters (
 user_id uuid not null references public.profiles(id) on delete cascade,
 service_year integer not null check(service_year between 2000 and 9999),
 chapter_id integer not null check(chapter_id between 1 and 1189),
 completed_on date not null,
 primary key(user_id,service_year,chapter_id)
);
create index faith_reading_day_idx on private.faith_reading_chapters(user_id,service_year,completed_on);
create table private.faith_qt_entries (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 reference text not null check(char_length(reference) between 1 and 80),
 body text not null check(char_length(body) between 1 and 500),
 created_at timestamptz not null default statement_timestamp()
);
create index faith_qt_owner_date_idx on private.faith_qt_entries(user_id,created_at desc,id desc);
create table private.faith_qt_receipts (
 user_id uuid not null references public.profiles(id) on delete cascade,
 client_request_id uuid not null,
 payload_hash bytea not null check(octet_length(payload_hash)=32),
 qt_id uuid not null,
 created_at timestamptz not null default statement_timestamp(),
 primary key(user_id,client_request_id)
);
create index faith_qt_receipt_day_idx on private.faith_qt_receipts(user_id,created_at);
alter table private.faith_reading_chapters enable row level security;
alter table private.faith_qt_entries enable row level security;
alter table private.faith_qt_receipts enable row level security;
revoke all on private.faith_reading_chapters,private.faith_qt_entries,private.faith_qt_receipts from public,anon,authenticated;

create function private.require_faith_eligible_actor(p_organization_id uuid) returns uuid
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid := private.require_current_consent_actor();
begin
 if not private.is_active_member(p_organization_id,v_actor) then
  raise exception 'faith_active_church_membership_required' using errcode='42501';
 end if;
 return v_actor;
end; $$;
revoke all on function private.require_faith_eligible_actor(uuid) from public,anon,authenticated;

create function private.require_faith_actor(p_organization_id uuid) returns uuid
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_eligible_actor(p_organization_id); v_document jsonb:=private.faith_document_manifest();
begin
 if not exists(select 1 from private.faith_consents where user_id=v_actor and withdrawn_at is null
  and document_version=v_document->>'version' and content_sha256=v_document->>'content_sha256') then
  raise exception 'faith_optional_consent_required' using errcode='42501';
 end if;
 return v_actor;
end; $$;
revoke all on function private.require_faith_actor(uuid) from public,anon,authenticated;

create function public.get_faith_consent_status(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_eligible_actor(p_organization_id); v_document jsonb:=private.faith_document_manifest();
begin
 return jsonb_build_object('accepted',exists(select 1 from private.faith_consents where user_id=v_actor
  and withdrawn_at is null and document_version=v_document->>'version' and content_sha256=v_document->>'content_sha256'),
  'document',v_document);
end; $$;

create function public.accept_faith_consent(p_organization_id uuid,p_version text,p_content_sha256 text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_eligible_actor(p_organization_id); v_document jsonb:=private.faith_document_manifest();
begin
 if v_document->>'content_sha256'='0000000000000000000000000000000000000000000000000000000000000000'
  or p_version is distinct from v_document->>'version' or p_content_sha256 is distinct from v_document->>'content_sha256' then
  raise exception 'faith_consent_document_mismatch' using errcode='23514';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 perform private.require_faith_eligible_actor(p_organization_id);
 insert into private.faith_consents(user_id,document_version,content_sha256,accepted_at)
 values(v_actor,p_version,p_content_sha256,statement_timestamp())
 on conflict(user_id) do update set document_version=excluded.document_version,content_sha256=excluded.content_sha256,
 accepted_at=case when private.faith_consents.withdrawn_at is null and private.faith_consents.document_version=excluded.document_version
  and private.faith_consents.content_sha256=excluded.content_sha256 then private.faith_consents.accepted_at else excluded.accepted_at end,withdrawn_at=null;
 return public.get_faith_consent_status(p_organization_id);
end; $$;

create function private.require_faith_withdrawal_actor() returns uuid
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid(); v_claims jsonb:=auth.jwt(); v_session uuid; v_now timestamptz:=statement_timestamp();
begin
 if v_actor is null or v_claims->>'role' is distinct from 'authenticated' or v_claims->'is_anonymous' is distinct from 'false'::jsonb
 or not coalesce(v_claims->'aud'='"authenticated"'::jsonb or v_claims->'aud' @> '["authenticated"]'::jsonb,false)
 or coalesce(v_claims->>'session_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or jsonb_typeof(v_claims->'iat') is distinct from 'number' or jsonb_typeof(v_claims->'exp') is distinct from 'number'
 or coalesce(v_claims->>'iat','') !~ '^[0-9]{1,12}$' or coalesce(v_claims->>'exp','') !~ '^[0-9]{1,12}$'
 then raise exception 'authentication_required' using errcode='42501'; end if;
 v_session:=(v_claims->>'session_id')::uuid;
 if to_timestamp((v_claims->>'iat')::bigint)>v_now or to_timestamp((v_claims->>'exp')::bigint)<=v_now
 or not exists(select 1 from auth.sessions where id=v_session and user_id=v_actor and (not_after is null or not_after>v_now))
 or not exists(select 1 from public.profiles where id=v_actor and deactivated_at is null)
 then raise exception 'authentication_required' using errcode='42501'; end if;
 return v_actor;
end; $$;
revoke all on function private.require_faith_withdrawal_actor() from public,anon,authenticated;

create function public.withdraw_faith_consent(p_organization_id uuid,p_confirm_delete boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_withdrawal_actor();
begin
 if p_confirm_delete is distinct from true then raise exception 'faith_withdrawal_delete_confirmation_required' using errcode='23514'; end if;
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 perform private.require_faith_withdrawal_actor();
 delete from private.faith_reading_chapters where user_id=v_actor;
 delete from private.faith_qt_entries where user_id=v_actor;
 delete from private.faith_qt_receipts where user_id=v_actor;
 update private.faith_consents set withdrawn_at=coalesce(withdrawn_at,statement_timestamp()) where user_id=v_actor;
 return jsonb_build_object('accepted',false,'deleted',true);
end; $$;

create function public.list_my_qt(p_organization_id uuid,p_limit integer default 25,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_actor(p_organization_id); v_result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset not between 0 and 10000 then
  raise exception 'invalid_faith_pagination' using errcode='23514';
 end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc),'[]'::jsonb) into v_result
 from (select id,reference,body,created_at from private.faith_qt_entries where user_id=v_actor
 order by created_at desc,id desc limit p_limit offset p_offset) q;
 return v_result;
end; $$;

create function public.get_faith_snapshot(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_actor(p_organization_id);
 v_today date:=(statement_timestamp() at time zone 'Asia/Seoul')::date;
 v_year integer:=extract(year from statement_timestamp() at time zone 'Asia/Seoul')::integer;
 v_chapters jsonb; v_count integer; v_last date; v_cursor date; v_streak integer:=0;
begin
 select coalesce(jsonb_agg(chapter_id order by chapter_id),'[]'::jsonb),count(*)::integer,max(completed_on)
 into v_chapters,v_count,v_last from private.faith_reading_chapters where user_id=v_actor and service_year=v_year;
 if v_last in(v_today,v_today-1) then
  v_cursor:=v_last;
  while exists(select 1 from private.faith_reading_chapters where user_id=v_actor and service_year=v_year and completed_on=v_cursor) loop
   v_streak:=v_streak+1; v_cursor:=v_cursor-1;
  end loop;
 end if;
 return jsonb_build_object('server_today',v_today,'service_year',v_year,'completed_chapters',v_chapters,
 'completed_count',v_count,'total_chapters',1189,'streak_days',v_streak,'last_read_date',v_last,
 'latest_private_qt',public.list_my_qt(p_organization_id,25,0));
end; $$;

create function public.set_my_reading_chapter(p_organization_id uuid,p_service_year integer,p_chapter_id integer,p_completed boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_actor(p_organization_id);
 v_today date:=(statement_timestamp() at time zone 'Asia/Seoul')::date;
begin
 if p_service_year is null or p_service_year<>extract(year from v_today)::integer or
 p_chapter_id is null or p_chapter_id not between 1 and 1189 or p_completed is null then
  raise exception 'invalid_reading_chapter_year_or_state' using errcode='23514';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 perform private.require_faith_actor(p_organization_id);
 if p_completed then
  insert into private.faith_reading_chapters(user_id,service_year,chapter_id,completed_on)
  values(v_actor,p_service_year,p_chapter_id,v_today) on conflict(user_id,service_year,chapter_id) do nothing;
 else
  delete from private.faith_reading_chapters where user_id=v_actor and service_year=p_service_year and chapter_id=p_chapter_id;
 end if;
 return public.get_faith_snapshot(p_organization_id);
end; $$;

create function public.create_my_qt(p_organization_id uuid,p_client_request_id uuid,p_reference text,p_body text)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_actor(p_organization_id); v_hash bytea; v_receipt private.faith_qt_receipts%rowtype; v_id uuid;
 v_day_start timestamptz:=date_trunc('day',statement_timestamp() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
begin
 if p_client_request_id is null or p_reference is null or char_length(btrim(p_reference)) not between 1 and 80
 or p_body is null or char_length(btrim(p_body)) not between 1 and 500 then
  raise exception 'invalid_qt_reference_or_body' using errcode='23514';
 end if;
 v_hash:=extensions.digest(jsonb_build_object('reference',btrim(p_reference),'body',btrim(p_body))::text,'sha256');
 -- Actor-wide serialization protects both receipts and quotas across different request IDs.
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 perform private.require_faith_actor(p_organization_id);
 select * into v_receipt from private.faith_qt_receipts where user_id=v_actor and client_request_id=p_client_request_id for update;
 if found then
  if v_receipt.payload_hash<>v_hash then raise exception 'qt_client_payload_mismatch' using errcode='23514'; end if;
  return v_receipt.qt_id;
 end if;
 if (select count(*) from private.faith_qt_receipts where user_id=v_actor and created_at>=v_day_start and created_at<v_day_start+interval '1 day')>=20 then
  raise exception 'qt_daily_creation_limit' using errcode='23514';
 end if;
 if (select count(*) from private.faith_qt_entries where user_id=v_actor)>=1000 then
  raise exception 'qt_storage_limit' using errcode='23514';
 end if;
 insert into private.faith_qt_entries(user_id,reference,body) values(v_actor,btrim(p_reference),btrim(p_body)) returning id into v_id;
 insert into private.faith_qt_receipts(user_id,client_request_id,payload_hash,qt_id) values(v_actor,p_client_request_id,v_hash,v_id);
 return v_id;
end; $$;

create function public.delete_my_qt(p_organization_id uuid,p_qt_id uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.require_faith_actor(p_organization_id); v_count integer;
begin
 if p_qt_id is null then raise exception 'invalid_qt_id' using errcode='23514'; end if;
 perform pg_advisory_xact_lock(hashtextextended('faith-actor:'||v_actor::text,0));
 perform private.require_faith_actor(p_organization_id);
 delete from private.faith_qt_entries where id=p_qt_id and user_id=v_actor;
 get diagnostics v_count=row_count;
 return v_count=1;
end; $$;

revoke all on function public.get_faith_snapshot(uuid),public.set_my_reading_chapter(uuid,integer,integer,boolean),
 public.list_my_qt(uuid,integer,integer),public.create_my_qt(uuid,uuid,text,text),public.delete_my_qt(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_faith_snapshot(uuid),public.set_my_reading_chapter(uuid,integer,integer,boolean),
 public.list_my_qt(uuid,integer,integer),public.create_my_qt(uuid,uuid,text,text),public.delete_my_qt(uuid,uuid) to authenticated;
notify pgrst,'reload schema';

revoke all on function public.get_faith_consent_status(uuid),public.accept_faith_consent(uuid,text,text),
 public.withdraw_faith_consent(uuid,boolean) from public,anon,authenticated;
grant execute on function public.get_faith_consent_status(uuid),public.accept_faith_consent(uuid,text,text),
 public.withdraw_faith_consent(uuid,boolean) to authenticated;
