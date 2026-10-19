-- Exact-scope executive records; church legacy records are retained and imported.
-- Freeze legacy writes while taking the transactional copy; fail rather than
-- silently importing an incomplete organization mapping.
lock table public.meeting_minutes,public.ledger_entries in share row exclusive mode;
create table private.scoped_records (
 id uuid primary key, kind text not null check(kind in ('minutes','finance')),
 scope_id uuid not null references public.governance_scopes(id) on delete restrict,
 event_id uuid references public.events(id) on delete restrict,
 service_year integer not null check(service_year between 2000 and 2100),
 record_date date not null, title text not null check(char_length(title) between 1 and 500),
 body text not null default '' check(char_length(body)<=50000),
 status text not null default 'draft' check(status in ('draft','published')),
 entry_type text check(entry_type in ('income','expense')),
 category text check(char_length(category) between 1 and 80),
 amount numeric(15,2), currency text not null default 'KRW' check(currency='KRW'),
 revision integer not null default 1 check(revision>0),
 author_id uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 deleted_at timestamptz, reversal_of uuid references private.scoped_records(id),
 source_operation_id uuid,
 fee_user_id uuid, fee_occurrence_id uuid references public.event_occurrences(id) on delete restrict,
 legacy_record_id uuid,
 check(service_year=extract(year from record_date)),
 check((kind='minutes' and entry_type is null and amount is null) or
       (kind='finance' and entry_type is not null and category is not null and amount>0))
);
create index scoped_records_scope_year on private.scoped_records(scope_id,service_year,event_id,record_date,id);
create table private.scoped_record_history (
 record_id uuid not null references private.scoped_records(id), revision integer not null,
 snapshot jsonb not null, actor_id uuid references public.profiles(id) on delete set null,
 action text not null, reason text, occurred_at timestamptz not null default now(),
 primary key(record_id,revision)
);
create table private.scoped_record_operations (
 operation_id uuid primary key, actor_id uuid not null, request jsonb not null, result jsonb not null
);
create table private.finance_period_closes (
 id uuid primary key default gen_random_uuid(), scope_id uuid not null references public.governance_scopes(id),
 event_id uuid references public.events(id), starts_on date not null, ends_on date not null,
 actor_id uuid references public.profiles(id) on delete set null, closed_at timestamptz not null default now(),
 report jsonb not null, check(ends_on>=starts_on)
);
create table private.event_fee_states (
 occurrence_id uuid not null references public.event_occurrences(id) on delete restrict,
 user_id uuid not null, -- Stable private payer reference; account deletion must not erase or prevent an audited refund.
 paid boolean not null default false, amount numeric(15,2) not null default 0 check(amount>=0),
 currency text not null default 'KRW' check(currency='KRW'), revision integer not null default 0,
 income_id uuid references private.scoped_records(id), primary key(occurrence_id,user_id)
);
create table private.finance_receipts (
 id uuid primary key, record_id uuid not null references private.scoped_records(id),
 path text not null unique, uploader_id uuid references public.profiles(id) on delete set null,
 provider text not null check(provider in ('supabase','r2')), uploaded_at timestamptz, object_size bigint, object_etag text,
 expected_size bigint not null check(expected_size between 1 and 10485760),
 notice_version text, processing_approved_at timestamptz,
 check((provider='supabase' and notice_version is null and processing_approved_at is null) or
       (provider='r2' and nullif(btrim(notice_version),'') is not null and processing_approved_at is not null)),
 created_at timestamptz not null default now(), attached_at timestamptz, deleted_at timestamptz
);
alter table private.scoped_records enable row level security;
alter table private.scoped_record_history enable row level security;
alter table private.scoped_record_operations enable row level security;
alter table private.finance_period_closes enable row level security;
alter table private.event_fee_states enable row level security;
alter table private.finance_receipts enable row level security;
revoke all on private.scoped_records,private.scoped_record_history,private.scoped_record_operations,
 private.finance_period_closes,private.event_fee_states,private.finance_receipts from public,anon,authenticated;

insert into private.scoped_records(id,kind,scope_id,service_year,record_date,title,body,status,author_id,created_at,updated_at,legacy_record_id)
select m.id,'minutes',s.id,m.meeting_year,m.meeting_date,m.title,m.body,m.status,m.author_id,m.created_at,m.updated_at,m.id
from public.meeting_minutes m join public.governance_scopes s on s.organization_id=m.organization_id and s.scope_type='church';
insert into private.scoped_records(id,kind,scope_id,service_year,record_date,title,body,status,entry_type,category,amount,author_id,created_at,updated_at,legacy_record_id)
select case when exists(select 1 from private.scoped_records existing where existing.id=l.id) then gen_random_uuid() else l.id end,
 'finance',s.id,l.fiscal_year,l.entry_date,l.description,coalesce(l.memo,''),'published',l.entry_type,l.category,l.amount,l.author_id,l.created_at,l.updated_at,l.id
from public.ledger_entries l join public.governance_scopes s on s.organization_id=l.organization_id and s.scope_type='church';
insert into private.scoped_record_history(record_id,revision,snapshot,actor_id,action)
select id,revision,to_jsonb(r),author_id,'legacy.imported' from private.scoped_records r;

do $import_gate$
begin
 if (select count(*) from private.scoped_records where kind='minutes')<>(select count(*) from public.meeting_minutes)
 or (select count(*) from private.scoped_records where kind='finance')<>(select count(*) from public.ledger_entries)
 or exists(select 1 from public.meeting_minutes m left join private.scoped_records r on r.kind='minutes' and r.legacy_record_id=m.id
   left join public.governance_scopes s on s.id=r.scope_id
   where r.id is null or s.organization_id is distinct from m.organization_id
   or (r.service_year,r.record_date,r.title,r.body,r.status,r.author_id,r.created_at,r.updated_at)
      is distinct from (m.meeting_year::integer,m.meeting_date,m.title,m.body,m.status,m.author_id,m.created_at,m.updated_at))
 or exists(select 1 from public.ledger_entries l left join private.scoped_records r on r.kind='finance' and r.legacy_record_id=l.id
   left join public.governance_scopes s on s.id=r.scope_id
   where r.id is null or s.organization_id is distinct from l.organization_id
   or (r.service_year,r.record_date,r.title,r.body,r.entry_type,r.category,r.amount,r.author_id,r.created_at,r.updated_at)
      is distinct from (l.fiscal_year::integer,l.entry_date,l.description,coalesce(l.memo,''),l.entry_type,l.category,l.amount,l.author_id,l.created_at,l.updated_at))
 then raise exception 'legacy_record_import_mismatch'; end if;
end;
$import_gate$;

create function private.can_scoped_records(p_scope_id uuid,p_actor uuid,p_kind text,p_write boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select p_write is not null and coalesce(p_kind in ('minutes','finance'),false) and private.has_current_required_consents(p_actor)
 and exists(select 1 from public.governance_scopes s where s.id=p_scope_id and s.is_active
 and private.is_user_active_in_governance_scope(s.id,p_actor)
 -- Office metadata alone never promotes a member or minister to executive.
 and exists(select 1 from public.organization_memberships membership join public.organizations organization on organization.id=membership.organization_id
 where membership.user_id=p_actor and membership.role='executive' and membership.status='active' and organization.status='active'
 and private.scope_contains_organization(s.id,membership.organization_id))
 and (s.scope_type='church' or private.has_current_governance_office(s.id,p_actor,
 array['president','vice_president','general_secretary','secretary','treasurer']))
 and (not p_write or private.has_current_governance_office(s.id,p_actor,
 case when p_kind='minutes' then array['president','vice_president','general_secretary','secretary']
 else array['president','treasurer'] end)))
$$;
revoke all on function private.can_scoped_records(uuid,uuid,text,boolean) from public,anon,authenticated;

create function public.list_scoped_record_scopes() returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor();
begin
 return coalesce((select jsonb_agg(x order by x->>'label') from (
 select jsonb_build_object('scope_id',s.id,'organization_id',s.organization_id,'event_id',null,'label',s.display_name,
 'can_minutes',private.can_scoped_records(s.id,a,'minutes',true),'can_finance',private.can_scoped_records(s.id,a,'finance',true)) x
 from public.governance_scopes s where private.can_scoped_records(s.id,a,'minutes')
 union all
 select jsonb_build_object('scope_id',s.id,'organization_id',s.organization_id,'event_id',e.id,'label',s.display_name||' · '||e.title,
 'can_minutes',private.can_scoped_records(s.id,a,'minutes',true),'can_finance',private.can_scoped_records(s.id,a,'finance',true))
 from public.events e join public.governance_scopes s on s.id=e.scope_id where private.can_scoped_records(s.id,a,'minutes')
 ) q),'[]'::jsonb);
end $$;

create function public.get_scoped_records(p_scope_id uuid,p_event_id uuid,p_year integer,p_kind text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor();
begin
 if not private.can_scoped_records(p_scope_id,a,p_kind) then raise exception 'record_scope_forbidden' using errcode='42501'; end if;
 if p_event_id is not null and not exists(select 1 from public.events where id=p_event_id and scope_id=p_scope_id) then raise exception 'event_scope_mismatch'; end if;
 return jsonb_build_object('can_write',p_year=private.current_service_year() and private.can_scoped_records(p_scope_id,a,p_kind,true),
 'rows',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('receipts',coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'provider',f.provider)) from private.finance_receipts f where f.record_id=r.id and f.attached_at is not null and f.deleted_at is null),'[]'::jsonb)) order by r.record_date desc,r.id)
 from private.scoped_records r where scope_id=p_scope_id and event_id is not distinct from p_event_id and service_year=p_year and kind=p_kind),'[]'::jsonb));
end $$;

create function public.save_scoped_record(p_id uuid,p_scope_id uuid,p_event_id uuid,p_kind text,p_expected_revision integer,p_record_date date,p_title text,p_body text,p_status text,p_entry_type text,p_category text,p_amount numeric,p_currency text,p_operation_id uuid,p_expected_actor_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); r private.scoped_records; op private.scoped_record_operations;
 req jsonb:=jsonb_build_array(p_id,p_scope_id,p_event_id,p_kind,p_expected_revision,p_record_date,p_title,p_body,p_status,p_entry_type,p_category,p_amount,p_currency); result jsonb;
begin
 perform private.require_aal2('scoped_record.save');
 if a is distinct from p_expected_actor_id then raise exception 'actor_changed' using errcode='42501'; end if;
 if not private.can_scoped_records(p_scope_id,a,p_kind,true) then raise exception 'record_write_forbidden' using errcode='42501'; end if;
 if p_record_date is null or extract(year from p_record_date)<>private.current_service_year() then raise exception 'current_year_required'; end if;
 if p_currency is distinct from 'KRW' or p_expected_revision is null or p_expected_revision<0 or p_operation_id is null or p_id is null then raise exception 'invalid_record_request'; end if;
 if p_kind='finance' and (p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999999.99) then raise exception 'invalid_finance_amount'; end if;
 if p_event_id is not null and not exists(select 1 from public.events where id=p_event_id and scope_id=p_scope_id) then raise exception 'event_scope_mismatch'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_scope_id::text||coalesce(p_event_id::text,''),0));
 select * into op from private.scoped_record_operations where operation_id=p_operation_id;
 if found then if op.actor_id<>a or op.request<>req then raise exception 'operation_conflict'; end if; return op.result; end if;
 if p_kind='finance' and exists(select 1 from private.finance_period_closes where scope_id=p_scope_id and event_id is not distinct from p_event_id and p_record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 select * into r from private.scoped_records where id=p_id for update;
 if found then
 if r.scope_id<>p_scope_id or r.event_id is distinct from p_event_id or r.kind<>p_kind or r.deleted_at is not null or r.revision<>p_expected_revision or r.source_operation_id is not null or r.reversal_of is not null then raise exception 'record_revision_conflict' using errcode='40001'; end if;
 if r.kind='finance' and exists(select 1 from private.scoped_records where reversal_of=r.id) then raise exception 'already_reversed'; end if;
 if r.kind='finance' and exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 update private.scoped_records set record_date=p_record_date,title=btrim(p_title),body=coalesce(p_body,''),status=p_status,
 entry_type=p_entry_type,category=p_category,amount=p_amount,revision=revision+1,updated_at=now() where id=p_id returning * into r;
 else
 if p_expected_revision<>0 then raise exception 'record_revision_conflict' using errcode='40001'; end if;
 insert into private.scoped_records(id,kind,scope_id,event_id,service_year,record_date,title,body,status,entry_type,category,amount,currency,author_id)
 values(p_id,p_kind,p_scope_id,p_event_id,extract(year from p_record_date),p_record_date,btrim(p_title),coalesce(p_body,''),p_status,p_entry_type,p_category,p_amount,p_currency,a) returning * into r;
 end if;
 insert into private.scoped_record_history values(r.id,r.revision,to_jsonb(r),a,'record.saved',null,now());
 result:=to_jsonb(r); insert into private.scoped_record_operations values(p_operation_id,a,req,result);
 perform private.write_audit(a,'executive_record.saved','scoped_record',r.id,(select organization_id from public.governance_scopes where id=r.scope_id),null,jsonb_build_object('kind',r.kind,'revision',r.revision,'scope_id',r.scope_id,'event_id',r.event_id));
 return result;
end $$;

create function public.delete_scoped_record(p_id uuid,p_expected_revision integer,p_operation_id uuid,p_reason text,p_expected_actor_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); r private.scoped_records; op private.scoped_record_operations; req jsonb:=jsonb_build_array('delete',p_id,p_expected_revision,p_reason); result jsonb;
begin
 perform private.require_aal2('scoped_record.delete');
 if a is distinct from p_expected_actor_id then raise exception 'actor_changed' using errcode='42501'; end if;
 select * into r from private.scoped_records where id=p_id;
 if not found or not private.can_scoped_records(r.scope_id,a,r.kind,true) then raise exception 'record_write_forbidden' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(r.scope_id::text||coalesce(r.event_id::text,''),0));
 select * into op from private.scoped_record_operations where operation_id=p_operation_id;
 if found then if op.actor_id<>a or op.request<>req then raise exception 'operation_conflict'; end if; return op.result; end if;
 select * into r from private.scoped_records where id=p_id for update;
 if p_expected_revision is null or r.revision<>p_expected_revision or r.deleted_at is not null or r.service_year<>private.current_service_year() then raise exception 'record_revision_conflict' using errcode='40001'; end if;
 if char_length(btrim(coalesce(p_reason,''))) not between 2 and 500 or p_operation_id is null then raise exception 'reason_required'; end if;
 if r.kind='finance' then
 -- Finance is never erased: cancellation is a separately identified opposite entry.
 if r.source_operation_id is not null then raise exception 'fee_or_reversal_managed_entry'; end if;
 if r.reversal_of is not null or exists(select 1 from private.scoped_records where reversal_of=r.id) then raise exception 'already_reversed'; end if;
 if exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 insert into private.scoped_records(id,kind,scope_id,event_id,service_year,record_date,title,body,status,entry_type,category,amount,author_id,reversal_of,source_operation_id)
 values(p_operation_id,'finance',r.scope_id,r.event_id,r.service_year,r.record_date,'취소: '||left(r.title,490),p_reason,'published',case r.entry_type when 'income' then 'expense' else 'income' end,r.category,r.amount,a,r.id,p_operation_id) returning * into r;
 else update private.scoped_records set deleted_at=now(),revision=revision+1 where id=p_id returning * into r;
 end if;
 insert into private.scoped_record_history values(r.id,r.revision,to_jsonb(r),a,'record.cancelled',p_reason,now());
 result:=to_jsonb(r); insert into private.scoped_record_operations values(p_operation_id,a,req,result);
 perform private.write_audit(a,'executive_record.cancelled','scoped_record',p_id,(select organization_id from public.governance_scopes where id=r.scope_id),null,jsonb_build_object('reason',p_reason,'revision',r.revision,'reversal_id',r.id));
 return result;
end $$;

create function public.get_scoped_record_history(p_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); r private.scoped_records;
begin
 select * into r from private.scoped_records where id=p_id;
 if not found or not private.can_scoped_records(r.scope_id,a,r.kind) then raise exception 'record_scope_forbidden' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(h) order by occurred_at desc,revision desc) from private.scoped_record_history h where record_id=p_id or record_id in (select id from private.scoped_records where reversal_of=p_id)),'[]'::jsonb);
end $$;

create function private.can_manage_event_fees(p_occurrence_id uuid,p_actor_id uuid) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select exists(select 1 from public.event_occurrences o join public.events e on e.id=o.event_id
 where o.id=p_occurrence_id and private.is_eligible_event_attendee(e.scope_id,p_actor_id)
 and (private.can_scoped_records(e.scope_id,p_actor_id,'finance',true) or exists(
 select 1 from private.event_staff staff where staff.occurrence_id=o.id and staff.user_id=p_actor_id
 and staff.expires_at>statement_timestamp() and 'fees'=any(staff.capabilities))));
$$;
revoke all on function private.can_manage_event_fees(uuid,uuid) from public,anon,authenticated;

create function public.get_event_fee_status(p_occurrence_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); s uuid;
begin
 select e.scope_id into s from public.event_occurrences o join public.events e on e.id=o.event_id where o.id=p_occurrence_id;
 if s is null or not private.can_manage_event_fees(p_occurrence_id,a) then raise exception 'event_fee_forbidden' using errcode='42501'; end if;
 perform private.write_audit(a,'event.fees_read','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),null,'{}');
 return jsonb_build_object('can_write',true,'currency','KRW','rows',coalesce((select jsonb_agg(jsonb_build_object('user_id',subjects.user_id,
 'display_name',case when private.is_user_active_in_governance_scope(s,subjects.user_id) then coalesce(p.display_name,'참가자') else '자격이 만료된 참가자' end,
 'paid',coalesce(f.paid,false),'amount',coalesce(f.amount,0),'revision',coalesce(f.revision,0)))
 from (select user_id from public.event_rsvps where occurrence_id=p_occurrence_id
 union select user_id from private.event_fee_states where occurrence_id=p_occurrence_id and paid) subjects
 left join public.profiles p on p.id=subjects.user_id left join private.event_fee_states f on f.occurrence_id=p_occurrence_id and f.user_id=subjects.user_id
 where private.is_user_active_in_governance_scope(s,subjects.user_id) or coalesce(f.paid,false)),'[]'::jsonb));
end $$;

create function public.record_event_fee(p_occurrence_id uuid,p_user_id uuid,p_paid boolean,p_amount numeric,p_operation_id uuid,p_reason text,p_expected_revision integer,p_expected_actor_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); s uuid; ev uuid; f private.event_fee_states; op private.scoped_record_operations;
 req jsonb:=jsonb_build_array('fee',p_occurrence_id,p_user_id,p_paid,p_amount,p_reason,p_expected_revision); r private.scoped_records; income uuid; d date:=timezone('Asia/Seoul',statement_timestamp())::date; result jsonb;
begin
 perform private.require_aal2('event.fee_recorded');
 if a is distinct from p_expected_actor_id then raise exception 'actor_changed' using errcode='42501'; end if;
 select e.scope_id,e.id into s,ev from public.event_occurrences o join public.events e on e.id=o.event_id where o.id=p_occurrence_id;
 if s is null or not private.can_manage_event_fees(p_occurrence_id,a) then raise exception 'event_fee_forbidden' using errcode='42501'; end if;
 if p_operation_id is null or p_user_id is null or p_paid is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999999.99 or char_length(btrim(coalesce(p_reason,''))) not between 2 and 500 then raise exception 'invalid_fee_request'; end if;
 perform pg_advisory_xact_lock(hashtextextended(s::text||ev::text,0));
 select * into op from private.scoped_record_operations where operation_id=p_operation_id;
 if found then if op.actor_id<>a or op.request<>req then raise exception 'operation_conflict'; end if; return op.result; end if;
 if p_paid and (not private.is_user_active_in_governance_scope(s,p_user_id) or not exists(
 select 1 from public.event_rsvps rsvp join public.event_occurrences occurrence on occurrence.id=rsvp.occurrence_id
 join public.events event on event.id=occurrence.event_id where rsvp.occurrence_id=p_occurrence_id and rsvp.user_id=p_user_id
 and occurrence.status='scheduled' and event.status='scheduled')) then raise exception 'fee_attendee_required'; end if;
 if exists(select 1 from private.finance_period_closes where scope_id=s and event_id=ev and d between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 insert into private.event_fee_states(occurrence_id,user_id) values(p_occurrence_id,p_user_id) on conflict do nothing;
 select * into f from private.event_fee_states where occurrence_id=p_occurrence_id and user_id=p_user_id for update;
 if p_expected_revision is null or p_expected_revision<>f.revision then raise exception 'fee_revision_conflict' using errcode='40001'; end if;
 -- Amount is an optimistic state precondition on refunds; a stale amount cannot reverse a newer payment.
 if not p_paid and (not f.paid or f.amount<>p_amount) then raise exception 'fee_revision_conflict' using errcode='40001'; end if;
 if f.paid and (not p_paid or f.amount<>p_amount) then
 insert into private.scoped_records(id,kind,scope_id,event_id,service_year,record_date,title,body,status,entry_type,category,amount,author_id,reversal_of,source_operation_id,fee_user_id,fee_occurrence_id)
 values(gen_random_uuid(),'finance',s,ev,extract(year from d),d,'행사 회비 환불',p_reason,'published','expense','행사 회비',f.amount,a,f.income_id,p_operation_id,p_user_id,p_occurrence_id) returning * into r;
 insert into private.scoped_record_history values(r.id,r.revision,to_jsonb(r),a,'fee.reversed',p_reason,now());
 end if;
 income:=f.income_id;
 if p_paid and (not f.paid or f.amount<>p_amount) then
 insert into private.scoped_records(id,kind,scope_id,event_id,service_year,record_date,title,body,status,entry_type,category,amount,author_id,source_operation_id,fee_user_id,fee_occurrence_id)
 values(gen_random_uuid(),'finance',s,ev,extract(year from d),d,'행사 회비 납부',p_reason,'published','income','행사 회비',p_amount,a,p_operation_id,p_user_id,p_occurrence_id) returning * into r;
 income:=r.id; insert into private.scoped_record_history values(r.id,r.revision,to_jsonb(r),a,'fee.paid',p_reason,now());
 end if;
 update private.event_fee_states set paid=p_paid,amount=p_amount,revision=revision+1,income_id=case when p_paid then income else null end where occurrence_id=p_occurrence_id and user_id=p_user_id returning * into f;
 result:=to_jsonb(f); insert into private.scoped_record_operations values(p_operation_id,a,req,result);
 perform private.write_audit(a,'event.fee_recorded','event_occurrence',p_occurrence_id,(select organization_id from public.governance_scopes where id=s),(select id from public.profiles where id=p_user_id),jsonb_build_object('reason',p_reason,'user_id',p_user_id,'paid',p_paid,'amount',p_amount,'revision',f.revision,'operation_id',p_operation_id));
 return result;
end $$;

create function public.export_finance_report(p_scope_id uuid,p_event_id uuid,p_starts_on date,p_ends_on date,p_close boolean,p_expected_actor_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); result jsonb; close_row private.finance_period_closes;
begin
 if a is distinct from p_expected_actor_id then raise exception 'actor_changed' using errcode='42501'; end if;
 if not private.can_scoped_records(p_scope_id,a,'finance') then raise exception 'record_scope_forbidden' using errcode='42501'; end if;
 if p_starts_on is null or p_ends_on is null or p_ends_on<p_starts_on or p_ends_on>p_starts_on+366 then raise exception 'invalid_report_period'; end if;
 if p_event_id is not null and not exists(select 1 from public.events where id=p_event_id and scope_id=p_scope_id) then raise exception 'event_scope_mismatch'; end if;
 if p_close then
 perform private.require_aal2('finance.period_close');
 if not private.can_scoped_records(p_scope_id,a,'finance',true) then raise exception 'record_write_forbidden' using errcode='42501'; end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_scope_id::text||coalesce(p_event_id::text,''),0));
 select * into close_row from private.finance_period_closes where scope_id=p_scope_id and event_id is not distinct from p_event_id and starts_on=p_starts_on and ends_on=p_ends_on;
 if p_close and found then return close_row.report; end if;
 if p_close and exists(select 1 from private.finance_period_closes where scope_id=p_scope_id and event_id is not distinct from p_event_id and daterange(starts_on,ends_on,'[]') && daterange(p_starts_on,p_ends_on,'[]')) then raise exception 'closed_period_overlap'; end if;
 result:=jsonb_build_object('scope_id',p_scope_id,'event_id',p_event_id,'starts_on',p_starts_on,'ends_on',p_ends_on,'currency','KRW','generated_at',statement_timestamp(),
 'entries',coalesce((select jsonb_agg(to_jsonb(r) order by record_date,id) from private.scoped_records r where kind='finance' and scope_id=p_scope_id and event_id is not distinct from p_event_id and record_date between p_starts_on and p_ends_on),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(h) order by occurred_at) from private.scoped_record_history h join private.scoped_records r on r.id=h.record_id where r.kind='finance' and r.scope_id=p_scope_id and r.event_id is not distinct from p_event_id and r.record_date between p_starts_on and p_ends_on),'[]'::jsonb),
 'income',coalesce((select sum(amount) from private.scoped_records where kind='finance' and entry_type='income' and scope_id=p_scope_id and event_id is not distinct from p_event_id and record_date between p_starts_on and p_ends_on),0),
 'expense',coalesce((select sum(amount) from private.scoped_records where kind='finance' and entry_type='expense' and scope_id=p_scope_id and event_id is not distinct from p_event_id and record_date between p_starts_on and p_ends_on),0),'closed',p_close);
 if p_close then insert into private.finance_period_closes(scope_id,event_id,starts_on,ends_on,actor_id,report) values(p_scope_id,p_event_id,p_starts_on,p_ends_on,a,result); end if;
 perform private.write_audit(a,case when p_close then 'finance.period_closed' else 'finance.exported' end,'governance_scope',p_scope_id,(select organization_id from public.governance_scopes where id=p_scope_id),null,jsonb_build_object('starts_on',p_starts_on,'ends_on',p_ends_on,'event_id',p_event_id));
 return result;
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('finance-receipts','finance-receipts',false,10485760,array['image/webp']) on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['image/webp'];
create function public.prepare_finance_receipt(p_record_id uuid,p_receipt_id uuid,p_provider text,p_expected_size bigint,p_notice_version text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); r private.scoped_records; f private.finance_receipts;
begin
 perform private.require_aal2('finance.receipt_prepare');
 select * into r from private.scoped_records where id=p_record_id and kind='finance';
 if not found or not private.can_scoped_records(r.scope_id,a,'finance',true) or r.deleted_at is not null then raise exception 'receipt_forbidden' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(r.scope_id::text||coalesce(r.event_id::text,''),0));
 select * into r from private.scoped_records where id=p_record_id for update;
 if exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 if p_expected_size is null or p_expected_size not between 1 and 10485760 then raise exception 'invalid_receipt_size'; end if;
 if p_provider is null or p_provider not in ('supabase','r2') then raise exception 'invalid_receipt_provider'; end if;
 if (p_provider='r2' and nullif(btrim(p_notice_version),'') is null) or (p_provider='supabase' and p_notice_version is not null) then raise exception 'receipt_processing_notice_required'; end if;
 insert into private.finance_receipts(id,record_id,path,uploader_id,provider,expected_size,notice_version,processing_approved_at)
 values(p_receipt_id,r.id,a::text||'/'||p_receipt_id::text||'.webp',a,p_provider,p_expected_size,p_notice_version,case when p_provider='r2' then now() else null end) on conflict(id) do nothing;
 select * into f from private.finance_receipts where id=p_receipt_id;
 if f.record_id is distinct from r.id or f.uploader_id is distinct from a or f.deleted_at is not null or f.provider is distinct from p_provider or f.expected_size is distinct from p_expected_size or f.notice_version is distinct from p_notice_version then raise exception 'receipt_conflict'; end if;
 return jsonb_build_object('id',f.id,'path',f.path,'provider',f.provider);
end $$;
create function private.can_finance_receipt(p_path text,p_actor uuid,p_write boolean) returns boolean
language sql stable security definer set search_path=pg_catalog as $$
 select p_actor=auth.uid() and private.has_current_required_consents(p_actor) and exists(select 1 from private.finance_receipts f join private.scoped_records r on r.id=f.record_id
 where f.path=p_path and f.provider='supabase' and f.deleted_at is null and r.deleted_at is null and private.can_scoped_records(r.scope_id,p_actor,'finance',p_write)
 and (not p_write or (private.sensitive_action_auth_expiry() is not null and f.uploader_id=p_actor and f.attached_at is null and f.created_at>now()-interval '1 hour'
 and not exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on))))
$$;
revoke all on function private.can_finance_receipt(text,uuid,boolean) from public,anon,authenticated;
create policy finance_receipts_insert on storage.objects for insert to authenticated with check(bucket_id='finance-receipts' and private.can_finance_receipt(name,auth.uid(),true));
-- Storage policy helper is the only private helper granted to authenticated.
grant execute on function private.can_finance_receipt(text,uuid,boolean) to authenticated;
create function public.attach_finance_receipt(p_receipt_id uuid,p_expected_revision integer) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); f private.finance_receipts; r private.scoped_records;
begin
 perform private.require_aal2('finance.receipt_attach');
 select * into f from private.finance_receipts where id=p_receipt_id;
 select * into r from private.scoped_records where id=f.record_id;
 if r.id is null or not private.can_scoped_records(r.scope_id,a,'finance',true) or f.uploader_id<>a or f.deleted_at is not null then raise exception 'receipt_forbidden' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(r.scope_id::text||coalesce(r.event_id::text,''),0));
 select * into f from private.finance_receipts where id=p_receipt_id for update;
 select * into r from private.scoped_records where id=f.record_id for update;
 if f.deleted_at is not null or f.uploader_id is distinct from a then raise exception 'receipt_forbidden' using errcode='42501'; end if;
 if exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 if f.attached_at is not null then return to_jsonb(f); end if;
 if p_expected_revision is null or r.revision<>p_expected_revision then raise exception 'record_revision_conflict' using errcode='40001'; end if;
 if (f.provider='supabase' and not exists(select 1 from storage.objects where bucket_id='finance-receipts' and name=f.path and metadata->>'mimetype'='image/webp' and (metadata->>'size')::bigint=f.expected_size)) or (f.provider='r2' and f.uploaded_at is null) then raise exception 'receipt_upload_required'; end if;
 update private.finance_receipts set attached_at=now() where id=f.id returning * into f;
 update private.scoped_records set revision=revision+1,updated_at=now() where id=r.id returning * into r;
 insert into private.scoped_record_history values(r.id,r.revision,to_jsonb(r)||jsonb_build_object('receipt_id',f.id),a,'receipt.attached',null,now());
 perform private.write_audit(a,'finance.receipt_attached','scoped_record',r.id,(select organization_id from public.governance_scopes where id=r.scope_id),null,jsonb_build_object('receipt_id',f.id));
 return to_jsonb(f);
end $$;
create function public.delete_finance_receipt(p_receipt_id uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); f private.finance_receipts; r private.scoped_records;
begin
 perform private.require_aal2('finance.receipt_delete');
 select * into f from private.finance_receipts where id=p_receipt_id;
 select * into r from private.scoped_records where id=f.record_id;
 if r.id is null or not private.can_scoped_records(r.scope_id,a,'finance',true) or char_length(btrim(coalesce(p_reason,''))) not between 2 and 500 then raise exception 'receipt_forbidden' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(r.scope_id::text||coalesce(r.event_id::text,''),0));
 select * into f from private.finance_receipts where id=p_receipt_id for update;
 select * into r from private.scoped_records where id=f.record_id for update;
 if exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 if f.deleted_at is not null then return to_jsonb(f); end if;
 update private.finance_receipts set deleted_at=now() where id=f.id returning * into f;
 update private.scoped_records set revision=revision+1,updated_at=now() where id=r.id returning * into r;
 insert into private.scoped_record_history values(r.id,r.revision,to_jsonb(r)||jsonb_build_object('receipt_id',f.id),a,'receipt.removed',p_reason,now());
 perform private.write_audit(a,'finance.receipt_removed','scoped_record',r.id,(select organization_id from public.governance_scopes where id=r.scope_id),null,jsonb_build_object('reason',p_reason,'receipt_id',f.id));
 -- Logical revocation is immediate; the authenticated client then removes the physical Storage object.
 return to_jsonb(f);
end $$;

-- Stop divergent legacy writes after the records cutover; historical tables remain preserved.
drop function public.save_meeting_minute(uuid,boolean,uuid,integer,date,text,text,text);
drop function public.delete_meeting_minute(uuid);
drop function public.save_ledger_entry(uuid,boolean,uuid,integer,date,text,text,text,numeric,text);
drop function public.delete_ledger_entry(uuid);
drop function private.save_meeting_minute_before_resource_gate(uuid,boolean,uuid,integer,date,text,text,text);
drop function private.save_ledger_entry_before_resource_gate(uuid,boolean,uuid,integer,date,text,text,text,numeric,text);
drop function private.delete_meeting_minute_before_current_consent_gate(uuid);
drop function private.delete_ledger_entry_before_current_consent_gate(uuid);
revoke all on function public.list_scoped_record_scopes(),public.get_scoped_records(uuid,uuid,integer,text),
 public.save_scoped_record(uuid,uuid,uuid,text,integer,date,text,text,text,text,text,numeric,text,uuid,uuid),
 public.delete_scoped_record(uuid,integer,uuid,text,uuid),public.get_scoped_record_history(uuid),
 public.get_event_fee_status(uuid),public.record_event_fee(uuid,uuid,boolean,numeric,uuid,text,integer,uuid),
 public.export_finance_report(uuid,uuid,date,date,boolean,uuid),public.prepare_finance_receipt(uuid,uuid,text,bigint,text),
 public.attach_finance_receipt(uuid,integer),public.delete_finance_receipt(uuid,text) from public,anon,authenticated;
grant execute on function public.list_scoped_record_scopes(),public.get_scoped_records(uuid,uuid,integer,text),
 public.save_scoped_record(uuid,uuid,uuid,text,integer,date,text,text,text,text,text,numeric,text,uuid,uuid),
 public.delete_scoped_record(uuid,integer,uuid,text,uuid),public.get_scoped_record_history(uuid),
 public.get_event_fee_status(uuid),public.record_event_fee(uuid,uuid,boolean,numeric,uuid,text,integer,uuid),
 public.export_finance_report(uuid,uuid,date,date,boolean,uuid),public.prepare_finance_receipt(uuid,uuid,text,bigint,text),
 public.attach_finance_receipt(uuid,integer),public.delete_finance_receipt(uuid,text) to authenticated;


create function public.get_finance_receipt_access(p_receipt_id uuid,p_expected_actor_id uuid,p_write boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); f private.finance_receipts; r private.scoped_records;
begin
 if a is distinct from p_expected_actor_id or p_write is null then raise exception 'actor_changed' using errcode='42501'; end if;
 if p_write then perform private.require_aal2('finance.receipt_access'); end if;
 select * into f from private.finance_receipts where id=p_receipt_id;
 select * into r from private.scoped_records where id=f.record_id;
 if r.id is null or not private.can_scoped_records(r.scope_id,a,'finance',p_write) or
 (not p_write and (f.attached_at is null or f.deleted_at is not null)) then raise exception 'receipt_forbidden' using errcode='42501'; end if;
 perform private.write_audit(a,case when p_write then 'finance.receipt_write_access' else 'finance.receipt_read' end,'scoped_record',r.id,
 (select organization_id from public.governance_scopes where id=r.scope_id),null,jsonb_build_object('receipt_id',f.id,'provider',f.provider));
 return jsonb_build_object('id',f.id,'path',f.path,'provider',f.provider,'expected_size',f.expected_size,'notice_version',f.notice_version,'record_id',f.record_id,'uploader_id',f.uploader_id,'deleted_at',f.deleted_at,'attached_at',f.attached_at);
end $$;
revoke all on function public.get_finance_receipt_access(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.get_finance_receipt_access(uuid,uuid,boolean) to authenticated;

create function public.service_confirm_r2_receipt(p_receipt_id uuid,p_actor_id uuid,p_size bigint,p_content_type text,p_etag text) returns void
language plpgsql security definer set search_path=pg_catalog as $$
declare f private.finance_receipts; r private.scoped_records;
begin
 perform private.require_service_role('finance.r2_confirm');
 select * into f from private.finance_receipts where id=p_receipt_id;
 select * into r from private.scoped_records where id=f.record_id;
 if f.provider is distinct from 'r2' or f.uploader_id is distinct from p_actor_id or f.deleted_at is not null
 or not private.can_scoped_records(r.scope_id,p_actor_id,'finance',true)
 or p_size is null or p_size is distinct from f.expected_size or p_size not between 1 and 10485760 or p_content_type is distinct from 'image/webp' or nullif(p_etag,'') is null then raise exception 'receipt_confirm_forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended(r.scope_id::text||coalesce(r.event_id::text,''),0));
 select * into f from private.finance_receipts where id=p_receipt_id for update;
 select * into r from private.scoped_records where id=f.record_id for update;
 if f.deleted_at is not null or f.uploader_id is distinct from p_actor_id then raise exception 'receipt_confirm_forbidden'; end if;
 if exists(select 1 from private.finance_period_closes where scope_id=r.scope_id and event_id is not distinct from r.event_id and r.record_date between starts_on and ends_on) then raise exception 'finance_period_closed'; end if;
 update private.finance_receipts set uploaded_at=now(),object_size=p_size,object_etag=p_etag where id=f.id;
end $$;
revoke all on function public.service_confirm_r2_receipt(uuid,uuid,bigint,text,text) from public,anon,authenticated;
grant execute on function public.service_confirm_r2_receipt(uuid,uuid,bigint,text,text) to service_role;

create function public.abandon_unattached_finance_receipt(p_receipt_id uuid,p_expected_actor_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a uuid:=private.require_current_consent_actor(); f private.finance_receipts; r private.scoped_records;
begin
 perform private.require_aal2('finance.receipt_upload_abandon');
 if a is distinct from p_expected_actor_id then raise exception 'actor_changed' using errcode='42501'; end if;
 select * into f from private.finance_receipts where id=p_receipt_id;
 select * into r from private.scoped_records where id=f.record_id;
 if r.id is null or f.uploader_id is distinct from a or not private.can_scoped_records(r.scope_id,a,'finance',true) then raise exception 'receipt_forbidden' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(r.scope_id::text||coalesce(r.event_id::text,''),0));
 select * into f from private.finance_receipts where id=p_receipt_id for update;
 -- A failed upload reservation is not finalized accounting evidence. Never revoke a concurrently attached object.
 if f.attached_at is not null then return jsonb_build_object('abandoned',false); end if;
 update private.finance_receipts set deleted_at=coalesce(deleted_at,now()) where id=f.id returning * into f;
 perform private.write_audit(a,'finance.receipt_upload_abandoned','scoped_record',r.id,
 (select organization_id from public.governance_scopes where id=r.scope_id),null,jsonb_build_object('receipt_id',f.id,'provider',f.provider));
 return jsonb_build_object('abandoned',true,'path',f.path,'provider',f.provider);
end $$;
revoke all on function public.abandon_unattached_finance_receipt(uuid,uuid) from public,anon,authenticated;
grant execute on function public.abandon_unattached_finance_receipt(uuid,uuid) to authenticated;
