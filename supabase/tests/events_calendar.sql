begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;

select no_plan();

select has_table('public', 'events', 'events are first-class records separate from posts');
select has_table('public', 'event_occurrences', 'finite generated occurrences exist');
select has_table('public', 'event_rsvps', 'RSVPs have a dedicated table');
select has_table('public', 'event_revisions', 'event revisions are append-only records');
select has_table('private', 'event_reminder_deliveries', 'event reminder delivery keys are stored privately');

insert into auth.users (id, email, raw_user_meta_data)
values
  ('11000000-0000-4000-8000-000000000001', 'event-admin@example.com', '{"display_name":"일정관리자"}'),
  ('11000000-0000-4000-8000-000000000002', 'event-church-president@example.com', '{"display_name":"교회회장"}'),
  ('11000000-0000-4000-8000-000000000003', 'event-presbytery-president@example.com', '{"display_name":"노회회장"}'),
  ('11000000-0000-4000-8000-000000000004', 'event-member@example.com', '{"display_name":"참석회원"}'),
  ('11000000-0000-4000-8000-000000000005', 'event-wait-one@example.com', '{"display_name":"대기회원1"}'),
  ('11000000-0000-4000-8000-000000000006', 'event-wait-two@example.com', '{"display_name":"대기회원2"}'),
  ('11000000-0000-4000-8000-000000000007', 'event-outsider@example.com', '{"display_name":"다른교회회원"}'),
  ('11000000-0000-4000-8000-000000000008', 'event-muted@example.com', '{"display_name":"일정알림끔"}');

insert into public.user_consents (
  user_id, document_key, document_version, accepted, source
)
select profile.id, document.document_key, document.version, true, 'admin_migration'
from public.profiles as profile
cross join public.consent_documents as document
where profile.id::text like '11000000-0000-4000-8000-00000000000%'
  and document.required
  and document.retired_at is null
  and document.published_at <= pg_catalog.statement_timestamp()
  and document.effective_at <= pg_catalog.statement_timestamp();

insert into public.platform_admins (user_id, note)
values ('11000000-0000-4000-8000-000000000001', 'event calendar pgTAP');

update public.organizations
set status = 'active'
where slug in ('jaegun-bupyeong', 'jaegun-busan');

insert into public.organization_memberships (user_id, organization_id, role)
values
  ('11000000-0000-4000-8000-000000000002', (select id from public.organizations where slug = 'jaegun-bupyeong'), 'executive'),
  ('11000000-0000-4000-8000-000000000003', (select id from public.organizations where slug = 'jaegun-bupyeong'), 'executive'),
  ('11000000-0000-4000-8000-000000000004', (select id from public.organizations where slug = 'jaegun-bupyeong'), 'member'),
  ('11000000-0000-4000-8000-000000000005', (select id from public.organizations where slug = 'jaegun-bupyeong'), 'member'),
  ('11000000-0000-4000-8000-000000000006', (select id from public.organizations where slug = 'jaegun-bupyeong'), 'member'),
  ('11000000-0000-4000-8000-000000000007', (select id from public.organizations where slug = 'jaegun-busan'), 'member'),
  ('11000000-0000-4000-8000-000000000008', (select id from public.organizations where slug = 'jaegun-bupyeong'), 'member');

insert into public.governance_office_assignments (
  scope_id, user_id, service_year, office_code, assigned_by
)
values
  (
    (select id from public.governance_scopes where scope_type = 'church' and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')),
    '11000000-0000-4000-8000-000000000002',
    private.current_service_year(),
    'president',
    '11000000-0000-4000-8000-000000000001'
  ),
  (
    (select id from public.governance_scopes where scope_type = 'presbytery' and display_name = (select presbytery from public.organizations where slug = 'jaegun-bupyeong')),
    '11000000-0000-4000-8000-000000000003',
    private.current_service_year(),
    'president',
    '11000000-0000-4000-8000-000000000001'
  );

select set_config('test.governance_service_year', private.current_service_year()::text, true);
select set_config('test.event_start', (
  (
    date_trunc('day', pg_catalog.timezone('Asia/Seoul', statement_timestamp()))
    + interval '2 days 10 hours'
  ) at time zone 'Asia/Seoul'
)::text, true);
select set_config('test.event_weekday', extract(isodow from pg_catalog.timezone('Asia/Seoul', current_setting('test.event_start')::timestamptz))::text, true);
select set_config('test.church_scope', (
  select id::text from public.governance_scopes
  where scope_type = 'church'
    and organization_id = (select id from public.organizations where slug = 'jaegun-bupyeong')
), true);
select set_config('test.presbytery_scope', (
  select id::text from public.governance_scopes
  where scope_type = 'presbytery'
    and display_name = (select presbytery from public.organizations where slug = 'jaegun-bupyeong')
), true);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;

select lives_ok(
  format(
    'select public.save_event(%L, true, %L, %L, %L, %L, %L, %L, 1, %L, 1, array[%s]::smallint[], null, null, 4, array[1440,60]::integer[])',
    '12000000-0000-4000-8000-000000000001',
    current_setting('test.church_scope'),
    '4주 기도회',
    '반복 일정 테스트',
    '본당',
    current_setting('test.event_start')::timestamptz,
    current_setting('test.event_start')::timestamptz + interval '90 minutes',
    'weekly',
    current_setting('test.event_weekday')
  ),
  'platform admin creates a finite weekly event'
);
reset role;
select is(
  (select count(*) from public.event_occurrences where event_id = '12000000-0000-4000-8000-000000000001'),
  4::bigint,
  'weekly recurrence generates the exact requested occurrence count'
);
select is(
  (
    select count(distinct to_char(starts_at at time zone 'Asia/Seoul', 'HH24:MI'))
    from public.event_occurrences
    where event_id = '12000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'all generated recurrences preserve the Asia/Seoul wall-clock time'
);
select is(
  (
    select min((lead_start - starts_at))
    from (
      select starts_at, lead(starts_at) over (order by starts_at) as lead_start
      from public.event_occurrences
      where event_id = '12000000-0000-4000-8000-000000000001'
    ) as intervals
    where lead_start is not null
  ),
  interval '7 days',
  'weekly recurrences are exactly one Seoul week apart'
);
set local role authenticated;
select lives_ok(
  format(
    'select public.save_event(%L, true, %L, %L, %L, %L, %L, %L, 1, %L, 1, array[%s]::smallint[], null, null, 4, array[1440,60]::integer[])',
    '12000000-0000-4000-8000-000000000001',
    current_setting('test.church_scope'),
    '4주 기도회',
    '반복 일정 테스트',
    '본당',
    current_setting('test.event_start')::timestamptz,
    current_setting('test.event_start')::timestamptz + interval '90 minutes',
    'weekly',
    current_setting('test.event_weekday')
  ),
  'lost-response create retry is idempotent'
);
reset role;
select is((select revision from public.events where id = '12000000-0000-4000-8000-000000000001'), 1, 'idempotent save does not create a revision');

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000003', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  format(
    'select public.save_event(%L, true, %L, %L, null, null, %L, %L, null, %L, 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000002',
    current_setting('test.church_scope'),
    '하위 범위 침범',
    current_setting('test.event_start')::timestamptz,
    current_setting('test.event_start')::timestamptz + interval '1 hour',
    'none'
  ),
  'P0002',
  'event_save_not_found_or_forbidden',
  'a presbytery president cannot write a child church event'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select throws_ok(
  format(
    'select public.save_event(%L, true, %L, %L, null, null, %L, %L, null, %L, 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000003',
    current_setting('test.church_scope'),
    '일반 회원 작성 시도',
    current_setting('test.event_start')::timestamptz,
    current_setting('test.event_start')::timestamptz + interval '1 hour',
    'none'
  ),
  'P0002',
  'event_save_not_found_or_forbidden',
  'an ordinary member cannot create events'
);
select is(
  (
    select count(*) from public.list_event_occurrences(
      statement_timestamp(), statement_timestamp() + interval '90 days', current_setting('test.church_scope')::uuid, 100
    )
  ),
  4::bigint,
  'an active exact-scope member can read upcoming occurrences'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000007', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000007","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select throws_ok(
  format(
    'select * from public.list_event_occurrences(statement_timestamp(), statement_timestamp() + interval ''90 days'', %L, 100)',
    current_setting('test.church_scope')
  ),
  '42501',
  'event_read_forbidden',
  'a member of another church cannot read a church-scoped calendar'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select lives_ok(
  format(
    'select public.save_event(%L, true, %L, %L, null, %L, %L, %L, 1, %L, 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000004',
    current_setting('test.church_scope'),
    '정원 한 명 모임',
    '소그룹실',
    current_setting('test.event_start')::timestamptz + interval '1 day',
    current_setting('test.event_start')::timestamptz + interval '1 day 1 hour',
    'none'
  ),
  'the exact church president can create a church event'
);
select ok(
  exists (
    select 1 from public.get_my_event_scopes()
    where scope_id = current_setting('test.church_scope')::uuid
      and can_manage_events
  ),
  'event manager access is reported only for the exact scope'
);
reset role;
select set_config('test.capacity_occurrence', (
  select id::text from public.event_occurrences where event_id = '12000000-0000-4000-8000-000000000004'
), true);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select is(
  public.respond_to_event(current_setting('test.capacity_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000001') ->> 'response',
  'yes',
  'first yes response fills capacity'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000005', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select is(
  public.respond_to_event(current_setting('test.capacity_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000002') ->> 'response',
  'waitlist',
  'second yes response enters the waitlist'
);
select is(
  (public.respond_to_event(current_setting('test.capacity_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000002') ->> 'waitlist_position')::integer,
  1,
  'an identical operation id returns the original result'
);
reset role;
select is(
  (select count(*) from public.event_rsvps where occurrence_id = current_setting('test.capacity_occurrence')::uuid and user_id = auth.uid()),
  1::bigint,
  'idempotent RSVP retry does not duplicate rows'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000006', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000006","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select is(
  public.respond_to_event(current_setting('test.capacity_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000003') ->> 'response',
  'waitlist',
  'a later response enters behind the first waitlisted member'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select is(
  public.respond_to_event(current_setting('test.capacity_occurrence')::uuid, 'no', '13000000-0000-4000-8000-000000000004') ->> 'response',
  'no',
  'confirmed member can release their seat'
);
reset role;
select is(
  (select response from public.event_rsvps where occurrence_id = current_setting('test.capacity_occurrence')::uuid and user_id = '11000000-0000-4000-8000-000000000005'),
  'yes',
  'FIFO promotion moves the earliest waitlisted member to yes'
);
select is(
  (select response from public.event_rsvps where occurrence_id = current_setting('test.capacity_occurrence')::uuid and user_id = '11000000-0000-4000-8000-000000000006'),
  'waitlist',
  'later waitlisted member remains waiting'
);
select ok(
  exists (
    select 1 from public.notifications
    where user_id = '11000000-0000-4000-8000-000000000005'
      and entity_type = 'event_occurrence'
      and entity_id = current_setting('test.capacity_occurrence')::uuid
  ),
  'waitlist promotion creates an in-app notification'
);
select ok(
  exists (
    select 1 from private.push_outbox
    where user_id = '11000000-0000-4000-8000-000000000005'
      and entity_type = 'event_occurrence'
      and entity_id = current_setting('test.capacity_occurrence')::uuid
      and title = '새 알림이 있습니다'
  ),
  'waitlist promotion creates a generic event-preference push job'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  format(
    'select public.save_event(%L, false, %L, %L, null, %L, %L, %L, 2, %L, 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000004',
    current_setting('test.church_scope'),
    '정원 변경 시도',
    '소그룹실',
    current_setting('test.event_start')::timestamptz + interval '1 day',
    current_setting('test.event_start')::timestamptz + interval '1 day 1 hour',
    'none'
  ),
  '55000',
  'event_schedule_locked_after_rsvp',
  'capacity and schedule are locked after any RSVP'
);
select is(
  public.cancel_event('12000000-0000-4000-8000-000000000004', '14000000-0000-4000-8000-000000000001', '장소 사정으로 취소') ->> 'status',
  'cancelled',
  'exact-scope manager cancels the event'
);
select is(
  public.cancel_event('12000000-0000-4000-8000-000000000004', '14000000-0000-4000-8000-000000000001', '장소 사정으로 취소') ->> 'status',
  'cancelled',
  'cancellation retry is idempotent'
);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
select throws_ok(
  $$select public.cancel_event(
    '12000000-0000-4000-8000-000000000004',
    '14000000-0000-4000-8000-000000000001',
    '장소 사정으로 취소'
  )$$,
  '42501',
  'aal2_required:event_cancel',
  'cancellation replay revalidates AAL2 before returning a cached result'
);
reset role;
select is((select revision from public.events where id = '12000000-0000-4000-8000-000000000004'), 2, 'cancellation increments the event revision once');
select is((select count(*) from public.event_revisions where event_id = '12000000-0000-4000-8000-000000000004'), 2::bigint, 'create and cancel revisions are retained');
select is((select status from public.event_occurrences where event_id = '12000000-0000-4000-8000-000000000004'), 'cancelled', 'cancellation closes every occurrence');

-- Reminder delivery is driven only by the service-role worker and DB clock.
reset role;
select set_config('request.jwt.claims', '{"role":"authenticated","aal":"aal2"}', true);
select throws_ok(
  'select * from public.service_dispatch_due_event_reminders(10)',
  '42501',
  'service_role_required:dispatch_due_event_reminders',
  'an authenticated JWT cannot invoke the reminder dispatcher even through a privileged connection'
);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select lives_ok(
  format(
    'select public.save_event(%L, true, %L, %L, null, null, statement_timestamp() + interval ''60 minutes'', statement_timestamp() + interval ''90 minutes'', null, %L, 1, array[]::smallint[], null, null, 2, array[60,30]::integer[])',
    '12000000-0000-4000-8000-000000000005',
    current_setting('test.church_scope'),
    '반복 일정 알림 시험',
    'daily'
  ),
  'an exact-scope president creates a due recurring event'
);
reset role;
select is(
  (select count(*) from public.event_occurrences where event_id = '12000000-0000-4000-8000-000000000005'),
  2::bigint,
  'the reminder test retains separate recurring occurrences'
);
select set_config('test.reminder_occurrence', (
  select id::text from public.event_occurrences
  where event_id = '12000000-0000-4000-8000-000000000005' and occurrence_index = 0
), true);
select set_config('test.reminder_second_occurrence', (
  select id::text from public.event_occurrences
  where event_id = '12000000-0000-4000-8000-000000000005' and occurrence_index = 1
), true);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select public.respond_to_event(current_setting('test.reminder_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000011');
reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000005', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select public.respond_to_event(current_setting('test.reminder_occurrence')::uuid, 'maybe', '13000000-0000-4000-8000-000000000012');
reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000006', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000006","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select public.respond_to_event(current_setting('test.reminder_occurrence')::uuid, 'no', '13000000-0000-4000-8000-000000000013');
reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000008', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000008","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select public.respond_to_event(current_setting('test.reminder_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000014');
reset role;
insert into public.notification_preferences (user_id, events_enabled)
values ('11000000-0000-4000-8000-000000000008', false);

select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
select set_config('test.reminder_dispatch', pg_catalog.to_jsonb(dispatch_result)::text, true)
from public.service_dispatch_due_event_reminders(100) as dispatch_result;
reset role;
select is(
  (current_setting('test.reminder_dispatch')::jsonb ->> 'dispatched_count')::integer,
  2,
  'the due batch dispatches only yes and maybe RSVPs'
);
select is(
  (current_setting('test.reminder_dispatch')::jsonb ->> 'has_more')::boolean,
  false,
  'the bounded dispatcher reports when no due work remains'
);
select is(
  (select count(*) from private.event_reminder_deliveries where occurrence_id = current_setting('test.reminder_occurrence')::uuid),
  2::bigint,
  'one private idempotency record is stored for each eligible RSVP'
);
select ok(
  not exists (
    select 1 from private.event_reminder_deliveries
    where occurrence_id = current_setting('test.reminder_occurrence')::uuid
      and user_id not in (
        '11000000-0000-4000-8000-000000000004',
        '11000000-0000-4000-8000-000000000005'
      )
  ),
  'no, waitlist, disabled-preference, and unauthorized users receive no reminder'
);
select ok(
  coalesce((
    select bool_and(
      delivery.scheduled_for = delivery.occurrence_starts_at - interval '60 minutes'
      and delivery.event_revision = 1
      and delivery.notification_id is not null
    )
    from private.event_reminder_deliveries as delivery
    where delivery.occurrence_id = current_setting('test.reminder_occurrence')::uuid
  ), false),
  'delivery ledger records the exact occurrence schedule, offset, revision, and notification'
);
select is(
  (
    select count(*) from public.notifications
    where entity_type = 'event_occurrence'
      and entity_id = current_setting('test.reminder_occurrence')::uuid
      and title = '일정 알림'
  ),
  2::bigint,
  'due reminders create exact-occurrence in-app notifications'
);
select is(
  (
    select count(*) from private.push_outbox
    where entity_type = 'event_occurrence'
      and entity_id = current_setting('test.reminder_occurrence')::uuid
      and event_code = 'community_notice'
      and title = '새 알림이 있습니다'
      and body = '앱에서 내용을 확인해 주세요.'
  ),
  2::bigint,
  'event preferences route reminders to generic push outbox jobs'
);

select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
select set_config('test.reminder_retry', pg_catalog.to_jsonb(dispatch_result)::text, true)
from public.service_dispatch_due_event_reminders(100) as dispatch_result;
reset role;
select is(
  (current_setting('test.reminder_retry')::jsonb ->> 'dispatched_count')::integer,
  0,
  'a repeated scheduler invocation is idempotent'
);
select is(
  (select count(*) from private.event_reminder_deliveries where occurrence_id = current_setting('test.reminder_occurrence')::uuid),
  2::bigint,
  'a scheduler retry cannot duplicate occurrence/user/offset delivery records'
);
select is(
  (
    select count(*) from private.event_reminder_deliveries
    where occurrence_id = current_setting('test.reminder_occurrence')::uuid
      and reminder_offset_minutes = 30
  ),
  0::bigint,
  'future reminder offsets are not dispatched early'
);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
select set_config('test.reminder_event_start', (
  select starts_at::text from public.events where id = '12000000-0000-4000-8000-000000000005'
), true);
select set_config('test.reminder_event_end', (
  select ends_at::text from public.events where id = '12000000-0000-4000-8000-000000000005'
), true);
set local role authenticated;
select throws_ok(
  format(
    'select public.save_event(%L, false, %L, %L, null, null, %L, %L, null, %L, 1, array[]::smallint[], null, null, 2, array[60,30,10]::integer[])',
    '12000000-0000-4000-8000-000000000005',
    current_setting('test.church_scope'),
    '반복 일정 알림 시험',
    current_setting('test.reminder_event_start')::timestamptz,
    current_setting('test.reminder_event_end')::timestamptz,
    'daily'
  ),
  '55000',
  'event_reminders_locked_after_delivery',
  'reminder schedule cannot be rewritten after a delivery was recorded'
);
select lives_ok(
  format(
    'select public.save_event(%L, true, %L, %L, null, null, statement_timestamp() + interval ''60 minutes'', statement_timestamp() + interval ''90 minutes'', null, %L, 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000006',
    current_setting('test.church_scope'),
    '취소 일정 알림 시험',
    'none'
  ),
  'a second due event is created for cancellation guarding'
);
reset role;
select set_config('test.cancelled_reminder_occurrence', (
  select id::text from public.event_occurrences where event_id = '12000000-0000-4000-8000-000000000006'
), true);
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select public.respond_to_event(current_setting('test.cancelled_reminder_occurrence')::uuid, 'yes', '13000000-0000-4000-8000-000000000015');
reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select is(
  public.cancel_event('12000000-0000-4000-8000-000000000006', '14000000-0000-4000-8000-000000000006', '알림 취소 검증') ->> 'status',
  'cancelled',
  'the reminder test event is cancelled before worker dispatch'
);
reset role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
select set_config('test.cancelled_dispatch', pg_catalog.to_jsonb(dispatch_result)::text, true)
from public.service_dispatch_due_event_reminders(100) as dispatch_result;
reset role;
select is(
  (current_setting('test.cancelled_dispatch')::jsonb ->> 'dispatched_count')::integer,
  0,
  'the service worker skips cancelled events and occurrences'
);
select is(
  (
    select count(*) from private.event_reminder_deliveries
    where occurrence_id = current_setting('test.cancelled_reminder_occurrence')::uuid
  ),
  0::bigint,
  'a cancelled occurrence never receives a reminder delivery key'
);
select ok(
  pg_catalog.pg_get_function_arguments(
    'public.service_dispatch_due_event_reminders(integer)'::regprocedure
  ) !~* '(now|clock|time)',
  'the service RPC accepts no caller-provided clock'
);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  'select * from public.service_dispatch_due_event_reminders(101)',
  '22023',
  'invalid_event_reminder_batch_limit',
  'the service RPC rejects oversized batches'
);
select ok(
  not exists (
    select 1 from private.event_reminder_deliveries
    where occurrence_id = current_setting('test.reminder_second_occurrence')::uuid
  ),
  'a recurring event reminder is bound to the exact RSVP occurrence'
);
select ok(
  not exists (
    select 1 from public.notifications
    where user_id = '11000000-0000-4000-8000-000000000008'
      and entity_type = 'event_occurrence'
      and entity_id = current_setting('test.reminder_occurrence')::uuid
  ),
  'events_enabled=false suppresses the scheduled in-app reminder'
);
select ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'public.service_dispatch_due_event_reminders(integer)',
    'EXECUTE'
  ) and pg_catalog.has_function_privilege(
    'service_role',
    'public.service_dispatch_due_event_reminders(integer)',
    'EXECUTE'
  ),
  'only service_role has EXECUTE privilege on the dispatcher'
);

-- Target-consent boundary: RSVP rows are retained but excluded from direct
-- reads, capacity, aggregates, wait-list position, and promotion until the
-- target records the current exact consent set again.
reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select lives_ok(
  format(
    'select public.save_event(%L, true, %L, %L, null, %L, %L, %L, 1, %L, 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000009',
    current_setting('test.church_scope'),
    '동의 경계 정원 테스트',
    '소그룹실',
    current_setting('test.event_start')::timestamptz + interval '4 days',
    current_setting('test.event_start')::timestamptz + interval '4 days 1 hour',
    'none'
  ),
  'target-consent aggregate fixture event is created while the manager is authorized'
);
reset role;
select set_config('test.capacity_occurrence', (
  select id::text
  from public.event_occurrences
  where event_id = '12000000-0000-4000-8000-000000000009'
), true);
insert into public.event_rsvps (
  occurrence_id, user_id, response, responded_at
)
values
  (
    current_setting('test.capacity_occurrence')::uuid,
    '11000000-0000-4000-8000-000000000005',
    'yes',
    pg_catalog.clock_timestamp() - interval '2 minutes'
  ),
  (
    current_setting('test.capacity_occurrence')::uuid,
    '11000000-0000-4000-8000-000000000006',
    'waitlist',
    pg_catalog.clock_timestamp() - interval '1 minute'
  );
insert into public.user_consents (
  user_id, document_key, document_version, accepted, source, withdrawn_at
)
values
  (
    '11000000-0000-4000-8000-000000000005',
    'privacy_policy',
    '2026-08-30',
    false,
    'app',
    pg_catalog.clock_timestamp()
  ),
  (
    '11000000-0000-4000-8000-000000000006',
    'privacy_policy',
    '2026-08-30',
    false,
    'app',
    pg_catalog.clock_timestamp()
  );
select is(
  (
    select count(*)
    from public.event_rsvps
    where occurrence_id = current_setting('test.capacity_occurrence')::uuid
      and user_id in (
        '11000000-0000-4000-8000-000000000005',
        '11000000-0000-4000-8000-000000000006'
      )
  ),
  2::bigint,
  'withdrawal preserves both raw RSVP rows for later re-consent'
);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select ok(
  not pg_catalog.has_table_privilege(
    'authenticated',
    'public.event_rsvps',
    'select'
  ),
  'authenticated users have no direct REST RSVP table read surface'
);
select ok(
  (public.get_event_occurrence(
    current_setting('test.capacity_occurrence')::uuid
  ) ->> 'yes_count')::integer = 0
  and (public.get_event_occurrence(
    current_setting('test.capacity_occurrence')::uuid
  ) ->> 'waitlist_count')::integer = 0,
  'event detail excludes non-current yes and wait-list targets from aggregates'
);
select ok(
  exists (
    select 1
    from public.list_event_occurrences(
      statement_timestamp(),
      statement_timestamp() + interval '90 days',
      current_setting('test.church_scope')::uuid,
      100
    ) as occurrence
    where occurrence.occurrence_id = current_setting('test.capacity_occurrence')::uuid
      and occurrence.yes_count = 0
      and occurrence.waitlist_count = 0
  ),
  'event list excludes non-current RSVP targets from aggregates'
);
select is(
  public.respond_to_event(
    current_setting('test.capacity_occurrence')::uuid,
    'yes',
    '13000000-0000-4000-8000-000000000016'
  ) ->> 'response',
  'yes',
  'a non-current yes RSVP does not consume capacity'
);
select is(
  public.respond_to_event(
    current_setting('test.capacity_occurrence')::uuid,
    'no',
    '13000000-0000-4000-8000-000000000017'
  ) ->> 'response',
  'no',
  'the current member can release the newly acquired seat'
);
reset role;
select is(
  (
    select response
    from public.event_rsvps
    where occurrence_id = current_setting('test.capacity_occurrence')::uuid
      and user_id = '11000000-0000-4000-8000-000000000006'
  ),
  'waitlist',
  'seat release does not promote a non-current wait-list target'
);
select ok(
  not exists (
    select 1
    from public.notifications
    where user_id = '11000000-0000-4000-8000-000000000006'
      and entity_type = 'event_occurrence'
      and entity_id = current_setting('test.capacity_occurrence')::uuid
  ),
  'non-current wait-list target receives no promotion notification'
);

-- Operation ledgers are not authorization tokens. Once exact-scope access is
-- revoked, known operation IDs cannot return cached cancellation payloads or
-- freshly recomputed RSVP aggregates.
reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '{"role":"service_role","aal":"aal2"}', true);
update public.organization_memberships
set status = 'revoked',
    ended_at = pg_catalog.clock_timestamp()
where user_id in (
  '11000000-0000-4000-8000-000000000002',
  '11000000-0000-4000-8000-000000000004'
)
  and organization_id = (
    select id from public.organizations where slug = 'jaegun-bupyeong'
  );

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select throws_ok(
  $$select public.respond_to_event(
    current_setting('test.capacity_occurrence')::uuid,
    'yes',
    '13000000-0000-4000-8000-000000000016'
  )$$,
  'P0002',
  'event_occurrence_not_found_or_forbidden',
  'RSVP replay revalidates the current event scope before returning aggregates'
);
select throws_ok(
  $$select public.respond_to_event(
    '15000000-0000-4000-8000-000000000099',
    'yes',
    '13000000-0000-4000-8000-000000000099'
  )$$,
  'P0002',
  'event_occurrence_not_found_or_forbidden',
  'RSVP returns the same response for an unknown occurrence'
);
select throws_ok(
  $$select public.respond_to_event(
    current_setting('test.capacity_occurrence')::uuid,
    'invalid-response',
    '13000000-0000-4000-8000-000000000098'
  )$$,
  'P0002',
  'event_occurrence_not_found_or_forbidden',
  'RSVP checks current scope before validating a protected occurrence payload'
);

reset role;
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select public.cancel_event(
    '12000000-0000-4000-8000-000000000004',
    '14000000-0000-4000-8000-000000000001',
    '장소 사정으로 취소'
  )$$,
  'P0002',
  'event_not_found_or_forbidden',
  'cancellation replay revalidates exact-scope management authority'
);
select throws_ok(
  $$select public.cancel_event(
    '12000000-0000-4000-8000-000000000099',
    '14000000-0000-4000-8000-000000000099',
    'unknown event probe'
  )$$,
  'P0002',
  'event_not_found_or_forbidden',
  'cancellation gives the same response for an unknown event'
);
select throws_ok(
  $$select public.cancel_event(
    '12000000-0000-4000-8000-000000000004',
    '14000000-0000-4000-8000-000000000098',
    ''
  )$$,
  'P0002',
  'event_not_found_or_forbidden',
  'cancellation checks scope before validating a protected event payload'
);
select throws_ok(
  $$select * from public.list_event_revisions(
    '12000000-0000-4000-8000-000000000004'
  )$$,
  'P0002',
  'event_revision_not_found_or_forbidden',
  'revision history hides a known event after management authority is lost'
);
select throws_ok(
  $$select * from public.list_event_revisions(
    '12000000-0000-4000-8000-000000000099'
  )$$,
  'P0002',
  'event_revision_not_found_or_forbidden',
  'revision history gives the same response for an unknown event'
);
select throws_ok(
  format(
    'select public.save_event(%L, false, %L, %L, null, null, statement_timestamp() + interval ''1 day'', statement_timestamp() + interval ''1 day 1 hour'', null, ''none'', 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000004',
    current_setting('test.church_scope'),
    'known forbidden event probe'
  ),
  'P0002',
  'event_save_not_found_or_forbidden',
  'event save hides a known event after exact-scope authority is lost'
);
select throws_ok(
  format(
    'select public.save_event(%L, false, %L, %L, null, null, statement_timestamp() + interval ''1 day'', statement_timestamp() + interval ''1 day 1 hour'', null, ''none'', 1, array[]::smallint[], null, null, null, array[60]::integer[])',
    '12000000-0000-4000-8000-000000000099',
    current_setting('test.church_scope'),
    'unknown event probe'
  ),
  'P0002',
  'event_save_not_found_or_forbidden',
  'event save gives the same response for a missing event'
);
select throws_ok(
  format(
    'select public.save_event(%L, false, %L, null, null, null, null, null, null, ''invalid'', 0, array[0]::smallint[], 0, null, 0, array[-1]::integer[])',
    '12000000-0000-4000-8000-000000000004',
    current_setting('test.church_scope')
  ),
  'P0002',
  'event_save_not_found_or_forbidden',
  'event save checks authority before validating a protected existing payload'
);

reset role;
delete from public.events
where id = '12000000-0000-4000-8000-000000000004';
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"11000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select throws_ok(
  $$select public.cancel_event(
    '12000000-0000-4000-8000-000000000004',
    '14000000-0000-4000-8000-000000000001',
    '장소 사정으로 취소'
  )$$,
  'P0002',
  'event_not_found_or_forbidden',
  'cancellation replay fails closed when the cached event no longer exists'
);

select * from finish();
rollback;
