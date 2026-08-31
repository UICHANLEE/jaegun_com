-- Provider-owned account-deletion scheduling and durable, identifier-free
-- operational health. Installing the cron jobs is an explicit production
-- operation: applying this migration never invokes an external URL.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create table private.account_deletion_scheduler_config (
  singleton boolean primary key default true check (singleton),
  dispatch_job_id bigint not null,
  reconcile_job_id bigint not null,
  installed_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint account_deletion_scheduler_distinct_jobs_check
    check (dispatch_job_id <> reconcile_job_id)
);

comment on table private.account_deletion_scheduler_config is
  'Exact postgres-owned pg_cron job IDs installed by the explicit account-deletion scheduler cutover.';

revoke all on table private.account_deletion_scheduler_config
  from public, anon, authenticated, service_role;

create table private.account_deletion_scheduler_nonces (
  nonce text primary key check (nonce ~ '^[0-9a-f]{32}$'),
  issued_at timestamptz not null,
  claimed_at timestamptz not null default pg_catalog.clock_timestamp()
);

comment on table private.account_deletion_scheduler_nonces is
  'Short-lived replay guard for provider HMAC credentials. Contains no account identifier or long-lived secret.';

revoke all on table private.account_deletion_scheduler_nonces
  from public, anon, authenticated, service_role;

create table private.account_deletion_worker_dispatches (
  id bigint generated always as identity primary key,
  net_request_id bigint not null unique,
  status text not null default 'pending' check (
    status in ('pending', 'succeeded', 'failed')
  ),
  dispatched_at timestamptz not null default pg_catalog.clock_timestamp(),
  finished_at timestamptz,
  http_status integer check (http_status is null or http_status between 100 and 599),
  failure_code text check (
    failure_code is null
    or failure_code in (
      'provider_http_error',
      'provider_response_invalid',
      'provider_response_missing',
      'provider_transport_error',
      'provider_timeout',
      'worker_reported_failure'
    )
  ),
  cleanup_claims integer check (cleanup_claims is null or cleanup_claims >= 0),
  cleanup_objects integer check (cleanup_objects is null or cleanup_objects >= 0),
  cleanup_failures integer check (cleanup_failures is null or cleanup_failures >= 0),
  anonymized integer check (anonymized is null or anonymized >= 0),
  identity_claims integer check (identity_claims is null or identity_claims >= 0),
  identities_deleted integer check (identities_deleted is null or identities_deleted >= 0),
  completed integer check (completed is null or completed >= 0),
  retry_required integer check (retry_required is null or retry_required >= 0),
  constraint account_deletion_worker_dispatch_state_check check (
    (status = 'pending' and finished_at is null and failure_code is null)
    or (status = 'succeeded' and finished_at is not null and failure_code is null)
    or (status = 'failed' and finished_at is not null and failure_code is not null)
  )
);

create index account_deletion_worker_dispatches_recent_idx
  on private.account_deletion_worker_dispatches (dispatched_at desc);
create index account_deletion_worker_dispatches_pending_idx
  on private.account_deletion_worker_dispatches (dispatched_at)
  where status = 'pending';

comment on table private.account_deletion_worker_dispatches is
  'Sanitized Supabase Cron dispatch results. Never stores credentials, account identifiers, object paths, or raw provider responses.';

revoke all on table private.account_deletion_worker_dispatches
  from public, anon, authenticated, service_role;
revoke all on sequence private.account_deletion_worker_dispatches_id_seq
  from public, anon, authenticated, service_role;

create or replace function private.account_deletion_scheduler_secret()
returns text
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_secret text;
  v_count integer;
begin
  select count(*), min(secret.decrypted_secret)
  into v_count, v_secret
  from vault.decrypted_secrets as secret
  where secret.name = 'account_deletion_worker_secret';

  if v_count <> 1
    or v_secret is null
    or char_length(v_secret) < 32
    or char_length(v_secret) > 256
    or v_secret !~ '^[A-Za-z0-9._~+/=-]+$' then
    raise exception 'account_deletion_scheduler_secret_unavailable'
      using errcode = '55000';
  end if;

  return v_secret;
end;
$$;

revoke all on function private.account_deletion_scheduler_secret()
  from public, anon, authenticated, service_role;

create or replace function private.enqueue_account_deletion_worker()
returns bigint
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_request_id bigint;
  v_secret text;
  v_issued_at bigint;
  v_nonce text;
  v_signature text;
  v_signature_payload text;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('account-deletion-provider-dispatch', 0)
  );

  if exists (
    select 1
    from private.account_deletion_worker_dispatches as dispatch
    where dispatch.status = 'pending'
      and dispatch.dispatched_at > pg_catalog.clock_timestamp() - interval '3 minutes'
  ) then
    return null;
  end if;

  v_secret := private.account_deletion_scheduler_secret();
  v_issued_at := pg_catalog.floor(
    extract(epoch from pg_catalog.clock_timestamp())
  )::bigint;
  v_nonce := pg_catalog.encode(extensions.gen_random_bytes(16), 'hex');
  v_signature_payload := 'v1' || E'\n'
    || v_issued_at::text || E'\n'
    || v_nonce || E'\n'
    || 'POST' || E'\n'
    || '/functions/v1/process-account-deletions' || E'\n'
    || 'limit=5';
  v_signature := pg_catalog.encode(
    extensions.hmac(
      pg_catalog.convert_to(v_signature_payload, 'UTF8'),
      pg_catalog.convert_to(v_secret, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  select net.http_post(
    url := 'https://opwzujhfsxqaivtbjewg.supabase.co/functions/v1/process-account-deletions',
    headers := pg_catalog.jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Jaegun-Scheduler-Timestamp', v_issued_at::text,
      'X-Jaegun-Scheduler-Nonce', v_nonce,
      'X-Jaegun-Scheduler-Signature', v_signature
    ),
    body := '{"limit":5}'::jsonb,
    timeout_milliseconds := 30000
  )
  into v_request_id;

  insert into private.account_deletion_worker_dispatches (net_request_id)
  values (v_request_id);

  return v_request_id;
end;
$$;

revoke all on function private.enqueue_account_deletion_worker()
  from public, anon, authenticated, service_role;

create or replace function public.service_claim_account_deletion_scheduler_nonce(
  p_nonce text,
  p_issued_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_inserted integer := 0;
begin
  perform private.require_service_role('claim_account_deletion_scheduler_nonce');

  if p_nonce is null
    or p_nonce !~ '^[0-9a-f]{32}$'
    or p_issued_at is null
    or p_issued_at < v_now - interval '3 minutes'
    or p_issued_at > v_now + interval '30 seconds' then
    return false;
  end if;

  insert into private.account_deletion_scheduler_nonces (nonce, issued_at, claimed_at)
  values (p_nonce, p_issued_at, v_now)
  on conflict (nonce) do nothing;
  get diagnostics v_inserted = row_count;

  delete from private.account_deletion_scheduler_nonces as nonce
  where nonce.claimed_at < v_now - interval '10 minutes';

  return v_inserted = 1;
end;
$$;

revoke all on function public.service_claim_account_deletion_scheduler_nonce(text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.service_claim_account_deletion_scheduler_nonce(text, timestamptz)
  to service_role;

create or replace function private.reconcile_account_deletion_worker_dispatches()
returns integer
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_dispatch record;
  v_body jsonb;
  v_failure_code text;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_processed integer := 0;
  v_cleanup_claims integer;
  v_cleanup_objects integer;
  v_cleanup_failures integer;
  v_anonymized integer;
  v_identity_claims integer;
  v_identities_deleted integer;
  v_completed integer;
  v_retry_required integer;
  v_successful_body boolean;
  v_valid_body boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('account-deletion-provider-reconcile', 0)
  );

  for v_dispatch in
    select
      dispatch.id,
      dispatch.dispatched_at,
      response.status_code,
      response.timed_out,
      response.error_msg,
      response.content
    from private.account_deletion_worker_dispatches as dispatch
    left join net._http_response as response
      on response.id = dispatch.net_request_id
    where dispatch.status = 'pending'
    order by dispatch.dispatched_at, dispatch.id
    for update of dispatch skip locked
  loop
    if v_dispatch.status_code is null
      and v_dispatch.error_msg is null
      and coalesce(v_dispatch.timed_out, false) is false then
      if v_dispatch.dispatched_at > v_now - interval '3 minutes' then
        continue;
      end if;

      update private.account_deletion_worker_dispatches
      set status = 'failed',
          finished_at = v_now,
          failure_code = 'provider_response_missing'
      where id = v_dispatch.id;
      v_processed := v_processed + 1;
      continue;
    end if;

    if coalesce(v_dispatch.timed_out, false) or v_dispatch.error_msg is not null then
      update private.account_deletion_worker_dispatches
      set status = 'failed',
          finished_at = v_now,
          http_status = v_dispatch.status_code,
          failure_code = case
            when coalesce(v_dispatch.timed_out, false) then 'provider_timeout'
            else 'provider_transport_error'
          end
      where id = v_dispatch.id;
      v_processed := v_processed + 1;
      continue;
    end if;

    v_body := null;
    begin
      v_body := v_dispatch.content::jsonb;
    exception
      when others then
        v_body := null;
    end;

    v_valid_body := coalesce(v_body is not null
      and pg_catalog.jsonb_typeof(v_body) = 'object'
      and pg_catalog.jsonb_typeof(v_body -> 'ok') = 'boolean'
      and pg_catalog.jsonb_typeof(v_body -> 'cleanupClaims') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'cleanupObjects') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'cleanupFailures') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'anonymized') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'identityClaims') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'identitiesDeleted') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'completed') = 'number'
      and pg_catalog.jsonb_typeof(v_body -> 'retryRequired') = 'number', false);

    v_cleanup_claims := null;
    v_cleanup_objects := null;
    v_cleanup_failures := null;
    v_anonymized := null;
    v_identity_claims := null;
    v_identities_deleted := null;
    v_completed := null;
    v_retry_required := null;
    v_successful_body := false;
    if v_dispatch.status_code = 200 and v_valid_body then
      begin
        if (v_body ->> 'cleanupClaims')::numeric between 0 and 10
          and (v_body ->> 'cleanupClaims')::numeric
            = pg_catalog.trunc((v_body ->> 'cleanupClaims')::numeric)
          and (v_body ->> 'identityClaims')::numeric between 0 and 10
          and (v_body ->> 'identityClaims')::numeric
            = pg_catalog.trunc((v_body ->> 'identityClaims')::numeric)
          and (v_body ->> 'cleanupObjects')::numeric between 0 and 1000000
          and (v_body ->> 'cleanupObjects')::numeric
            = pg_catalog.trunc((v_body ->> 'cleanupObjects')::numeric)
          and (v_body ->> 'cleanupFailures')::numeric between 0 and 1000000
          and (v_body ->> 'cleanupFailures')::numeric
            = pg_catalog.trunc((v_body ->> 'cleanupFailures')::numeric)
          and (v_body ->> 'anonymized')::numeric between 0 and 10
          and (v_body ->> 'anonymized')::numeric
            = pg_catalog.trunc((v_body ->> 'anonymized')::numeric)
          and (v_body ->> 'identitiesDeleted')::numeric between 0 and 10
          and (v_body ->> 'identitiesDeleted')::numeric
            = pg_catalog.trunc((v_body ->> 'identitiesDeleted')::numeric)
          and (v_body ->> 'completed')::numeric between 0 and 10
          and (v_body ->> 'completed')::numeric
            = pg_catalog.trunc((v_body ->> 'completed')::numeric)
          and (v_body ->> 'retryRequired')::numeric between 0 and 1000000
          and (v_body ->> 'retryRequired')::numeric
            = pg_catalog.trunc((v_body ->> 'retryRequired')::numeric) then
          v_cleanup_claims := (v_body ->> 'cleanupClaims')::numeric::integer;
          v_cleanup_objects := (v_body ->> 'cleanupObjects')::numeric::integer;
          v_cleanup_failures := (v_body ->> 'cleanupFailures')::numeric::integer;
          v_anonymized := (v_body ->> 'anonymized')::numeric::integer;
          v_identity_claims := (v_body ->> 'identityClaims')::numeric::integer;
          v_identities_deleted := (v_body ->> 'identitiesDeleted')::numeric::integer;
          v_completed := (v_body ->> 'completed')::numeric::integer;
          v_retry_required := (v_body ->> 'retryRequired')::numeric::integer;
          v_successful_body := (v_body ->> 'ok')::boolean is true;
        else
          v_valid_body := false;
        end if;
      exception
        when others then
          v_successful_body := false;
          v_valid_body := false;
      end;
    end if;

    if v_successful_body then
      update private.account_deletion_worker_dispatches
      set status = 'succeeded',
          finished_at = v_now,
          http_status = v_dispatch.status_code,
          cleanup_claims = v_cleanup_claims,
          cleanup_objects = v_cleanup_objects,
          cleanup_failures = v_cleanup_failures,
          anonymized = v_anonymized,
          identity_claims = v_identity_claims,
          identities_deleted = v_identities_deleted,
          completed = v_completed,
          retry_required = v_retry_required
      where id = v_dispatch.id;
    else
      v_failure_code := case
        when v_dispatch.status_code is null
          or v_dispatch.status_code < 200
          or v_dispatch.status_code >= 300
          then 'provider_http_error'
        when not v_valid_body then 'provider_response_invalid'
        else 'worker_reported_failure'
      end;

      update private.account_deletion_worker_dispatches
      set status = 'failed',
          finished_at = v_now,
          http_status = v_dispatch.status_code,
          failure_code = v_failure_code
      where id = v_dispatch.id;
    end if;
    v_processed := v_processed + 1;
  end loop;

  delete from private.account_deletion_worker_dispatches as dispatch
  where dispatch.finished_at < v_now - interval '90 days';

  -- Bound pg_cron's otherwise-unbounded run history, but never touch another
  -- product or provider's jobs. The current reconciler row has no end_time yet.
  delete from cron.job_run_details as run
  using private.account_deletion_scheduler_config as config
  where (
      run.jobid = config.dispatch_job_id
      or run.jobid = config.reconcile_job_id
    )
    and run.end_time < v_now - interval '30 days';

  return v_processed;
end;
$$;

revoke all on function private.reconcile_account_deletion_worker_dispatches()
  from public, anon, authenticated, service_role;

create or replace function public.service_account_deletion_worker_health()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_provider_configured boolean;
  v_last_dispatch_at timestamptz;
  v_last_success_at timestamptz;
  v_last_failure_at timestamptz;
  v_due_count integer;
  v_overdue_count integer;
  v_processing_stale_count integer;
  v_identity_stale_count integer;
  v_failed_count integer;
  v_dead_cleanup_count integer;
  v_retrying_cleanup_count integer;
  v_healthy boolean;
begin
  perform private.require_service_role('account_deletion_worker_health');

  select exists (
    select 1
    from private.account_deletion_scheduler_config as config
    join cron.job as dispatch_job
      on dispatch_job.jobid = config.dispatch_job_id
    join cron.job as reconcile_job
      on reconcile_job.jobid = config.reconcile_job_id
    where dispatch_job.jobname = 'jaegun-account-deletion-worker'
      and dispatch_job.username = 'postgres'
      and dispatch_job.database = pg_catalog.current_database()
      and dispatch_job.schedule = '*/5 * * * *'
      and dispatch_job.command = 'select private.enqueue_account_deletion_worker();'
      and dispatch_job.active
      and reconcile_job.jobname = 'jaegun-account-deletion-reconciler'
      and reconcile_job.username = 'postgres'
      and reconcile_job.database = pg_catalog.current_database()
      and reconcile_job.schedule = '* * * * *'
      and reconcile_job.command = 'select private.reconcile_account_deletion_worker_dispatches();'
      and reconcile_job.active
  )
    and (
      select count(*)
      from vault.decrypted_secrets as secret
      where secret.name = 'account_deletion_worker_secret'
    ) = 1
  into v_provider_configured;

  select
    max(dispatch.dispatched_at),
    max(dispatch.finished_at) filter (where dispatch.status = 'succeeded'),
    max(dispatch.finished_at) filter (where dispatch.status = 'failed')
  into v_last_dispatch_at, v_last_success_at, v_last_failure_at
  from private.account_deletion_worker_dispatches as dispatch;

  select
    count(*) filter (
      where request.status = 'requested'
        and request.scheduled_for <= v_now
    ),
    count(*) filter (
      where request.status = 'requested'
        and request.scheduled_for <= v_now - interval '15 minutes'
    ),
    count(*) filter (
      where request.status = 'processing'
        and coalesce(request.processing_claimed_at, request.processing_started_at)
          <= v_now - interval '30 minutes'
    ),
    count(*) filter (
      where request.status = 'awaiting_identity_deletion'
        and coalesce(request.identity_claimed_at, request.processing_started_at)
          <= v_now - interval '30 minutes'
    ),
    count(*) filter (where request.status = 'failed')
  into
    v_due_count,
    v_overdue_count,
    v_processing_stale_count,
    v_identity_stale_count,
    v_failed_count
  from public.account_deletion_requests as request;

  select
    count(*) filter (where item.status = 'dead'),
    count(*) filter (
      where item.status = 'failed'
        and item.attempt_count >= 3
    )
  into v_dead_cleanup_count, v_retrying_cleanup_count
  from private.account_deletion_cleanup_items as item;

  v_healthy := v_provider_configured
    and v_last_success_at is not null
    and v_last_success_at >= v_now - interval '15 minutes'
    and v_overdue_count = 0
    and v_processing_stale_count = 0
    and v_identity_stale_count = 0
    and v_failed_count = 0
    and v_dead_cleanup_count = 0
    and v_retrying_cleanup_count = 0;

  return pg_catalog.jsonb_build_object(
    'ok', v_healthy,
    'providerConfigured', v_provider_configured,
    'checkedAt', v_now,
    'lastDispatchAt', v_last_dispatch_at,
    'lastSuccessAt', v_last_success_at,
    'lastFailureAt', v_last_failure_at,
    'dueRequests', v_due_count,
    'overdueRequests', v_overdue_count,
    'staleProcessing', v_processing_stale_count,
    'staleIdentityDeletion', v_identity_stale_count,
    'failedRequests', v_failed_count,
    'deadCleanupItems', v_dead_cleanup_count,
    'retryingCleanupItems', v_retrying_cleanup_count
  );
end;
$$;

revoke all on function public.service_account_deletion_worker_health()
  from public, anon, authenticated;
grant execute on function public.service_account_deletion_worker_health()
  to service_role;

create or replace function private.install_account_deletion_scheduler()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_secret text;
  v_dispatch_job_id bigint;
  v_reconcile_job_id bigint;
begin
  -- This function is deliberately not granted to API roles. Before calling it
  -- from the SQL editor, put the same worker credential used by the Edge
  -- Function and GitHub Actions in Vault under this exact name.
  v_secret := private.account_deletion_scheduler_secret();
  if v_secret is null then
    raise exception 'account_deletion_scheduler_secret_unavailable'
      using errcode = '55000';
  end if;

  select cron.schedule(
    'jaegun-account-deletion-worker',
    '*/5 * * * *',
    'select private.enqueue_account_deletion_worker();'
  ) into v_dispatch_job_id;

  select cron.schedule(
    'jaegun-account-deletion-reconciler',
    '* * * * *',
    'select private.reconcile_account_deletion_worker_dispatches();'
  ) into v_reconcile_job_id;

  insert into private.account_deletion_scheduler_config (
    singleton,
    dispatch_job_id,
    reconcile_job_id,
    installed_at
  )
  values (
    true,
    v_dispatch_job_id,
    v_reconcile_job_id,
    pg_catalog.clock_timestamp()
  )
  on conflict (singleton) do update
  set dispatch_job_id = excluded.dispatch_job_id,
      reconcile_job_id = excluded.reconcile_job_id,
      installed_at = excluded.installed_at;

  return pg_catalog.jsonb_build_object(
    'installed', true,
    'dispatchJobId', v_dispatch_job_id,
    'reconcileJobId', v_reconcile_job_id
  );
end;
$$;

revoke all on function private.install_account_deletion_scheduler()
  from public, anon, authenticated, service_role;
grant execute on function private.install_account_deletion_scheduler() to postgres;

comment on function private.install_account_deletion_scheduler() is
  'Explicit production cutover after the shared credential is present in Vault. Applying the migration alone never schedules external calls.';
