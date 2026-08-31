begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions, pg_catalog;
select no_plan();

select ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.service_claim_account_deletion_scheduler_nonce(text,timestamp with time zone)',
    'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.service_claim_account_deletion_scheduler_nonce(text,timestamp with time zone)',
    'execute'
  ),
  'only the service role can claim a provider scheduler nonce'
);

select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(
  public.service_claim_account_deletion_scheduler_nonce(
    '91800000000000000000000000000001',
    pg_catalog.clock_timestamp()
  ),
  true,
  'a fresh provider scheduler nonce is claimed once'
);
select is(
  public.service_claim_account_deletion_scheduler_nonce(
    '91800000000000000000000000000001',
    pg_catalog.clock_timestamp()
  ),
  false,
  'the same provider scheduler nonce cannot be replayed'
);

insert into private.account_deletion_worker_dispatches (net_request_id)
values (918000000000000001);

insert into net._http_response (
  id,
  status_code,
  content_type,
  headers,
  content,
  timed_out,
  error_msg
)
values (
  918000000000000001,
  200,
  'application/json',
  '{}'::jsonb,
  '{"ok":true,"cleanupClaims":1,"cleanupObjects":1.5,"cleanupFailures":0,"anonymized":0,"identityClaims":0,"identitiesDeleted":0,"completed":0,"retryRequired":0}',
  false,
  null
);

select lives_ok(
  'select private.reconcile_account_deletion_worker_dispatches()',
  'a fractional provider counter cannot poison the reconciler loop'
);

select results_eq(
  $sql$
    select dispatch.status, dispatch.failure_code
    from private.account_deletion_worker_dispatches as dispatch
    where dispatch.net_request_id = 918000000000000001
  $sql$,
  $$ values ('failed'::text, 'provider_response_invalid'::text) $$,
  'fractional provider counters are durably classified as invalid'
);

insert into private.account_deletion_worker_dispatches (net_request_id)
values (918000000000000002);

insert into net._http_response (
  id,
  status_code,
  content_type,
  headers,
  content,
  timed_out,
  error_msg
)
values (
  918000000000000002,
  200,
  'application/json',
  '{}'::jsonb,
  '{"ok":true,"cleanupClaims":1,"cleanupObjects":2,"cleanupFailures":0,"anonymized":1,"identityClaims":1,"identitiesDeleted":1,"completed":1,"retryRequired":0}',
  false,
  null
);

select lives_ok(
  'select private.reconcile_account_deletion_worker_dispatches()',
  'an integral bounded provider response reconciles successfully'
);

select results_eq(
  $sql$
    select
      dispatch.status,
      dispatch.cleanup_objects,
      dispatch.completed
    from private.account_deletion_worker_dispatches as dispatch
    where dispatch.net_request_id = 918000000000000002
  $sql$,
  $$ values ('succeeded'::text, 2::integer, 1::integer) $$,
  'integral counters are stored only after bounded validation'
);

select * from finish();
rollback;
