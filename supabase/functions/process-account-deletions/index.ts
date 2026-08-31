import { createClient } from "@supabase/supabase-js";

import { secretsEqual } from "../_shared/push-security.ts";
import {
  type AccountCleanupItem,
  type AccountDeletionClaim,
  identityPresence,
  isAccountDeletionClaim,
  isAccountDeletionWorkerHealth,
  isIdentityDeletionClaim,
  parseWorkerBearer,
  parseProviderSchedulerCredential,
  parseWorkerRequest,
  PROVIDER_SCHEDULER_HEADER_NAMES,
  requestIdFromUnknown,
  storageDeleteOutcome,
  verifyProviderSchedulerCredential,
  WorkerValidationError,
} from "./security.ts";

type RuntimeConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  workerSecret: string;
};

type Totals = {
  cleanupClaims: number;
  cleanupObjects: number;
  cleanupFailures: number;
  anonymized: number;
  identityClaims: number;
  identitiesDeleted: number;
  completed: number;
  retryRequired: number;
};

function loadConfig(): RuntimeConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  const workerSecret = Deno.env.get("ACCOUNT_DELETION_WORKER_SECRET")?.trim() ?? "";
  if (
    !supabaseUrl ||
    !serviceRoleKey ||
    workerSecret.length < 32 ||
    workerSecret.length > 256 ||
    workerSecret === serviceRoleKey
  ) {
    throw new Error("invalid_runtime_configuration");
  }
  return { supabaseUrl, serviceRoleKey, workerSecret };
}

function response(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

async function runWithConcurrency<T>(
  values: T[],
  concurrency: number,
  worker: (value: T) => Promise<void>,
): Promise<void> {
  let nextIndex = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, async () => {
      while (nextIndex < values.length) {
        const value = values[nextIndex];
        nextIndex += 1;
        await worker(value);
      }
    }),
  );
}

function serviceClient(config: RuntimeConfig) {
  return createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
  });
}

async function markRequestFailed(
  client: ReturnType<typeof serviceClient>,
  requestId: string,
  failureCode: string,
): Promise<boolean> {
  const { error } = await client.rpc("service_fail_account_deletion", {
    p_request_id: requestId,
    p_failure_code: failureCode,
  });
  return !error;
}

async function removeCleanupItem(
  client: ReturnType<typeof serviceClient>,
  item: AccountCleanupItem,
  totals: Totals,
): Promise<boolean> {
  if (item.status === "deleted" || item.status === "not_found") return true;
  if (item.status === "dead") return false;

  let outcome: ReturnType<typeof storageDeleteOutcome>;
  try {
    const { data, error } = await client.storage
      .from(item.bucket_id)
      .remove([item.storage_path]);
    outcome = storageDeleteOutcome(error, data);
  } catch {
    outcome = { status: "failed", code: "storage_transport_error" };
  }

  const { error: markError } = await client.rpc("service_mark_account_cleanup_item", {
    p_item_id: item.id,
    p_status: outcome.status,
    p_error_code: outcome.code,
  });
  if (markError || outcome.status === "failed") {
    totals.cleanupFailures += 1;
    return false;
  }
  totals.cleanupObjects += 1;
  return true;
}

async function processCleanupClaim(
  client: ReturnType<typeof serviceClient>,
  claim: AccountDeletionClaim,
  totals: Totals,
): Promise<void> {
  if (claim.cleanup_items.some((item) => item.status === "dead")) {
    if (!await markRequestFailed(client, claim.request_id, "storage_cleanup_retry_exhausted")) {
      totals.retryRequired += 1;
    }
    totals.cleanupFailures += 1;
    return;
  }

  let cleanupComplete = true;
  await runWithConcurrency(claim.cleanup_items, 4, async (item) => {
    if (!await removeCleanupItem(client, item, totals)) cleanupComplete = false;
  });
  if (!cleanupComplete) {
    totals.retryRequired += 1;
    return;
  }

  const { data, error } = await client.rpc("service_finalize_account_anonymization", {
    p_request_id: claim.request_id,
  });
  if (
    error ||
    !data ||
    typeof data !== "object" ||
    Array.isArray(data) ||
    (data as Record<string, unknown>).request_id !== claim.request_id ||
    (data as Record<string, unknown>).user_id !== claim.user_id ||
    (data as Record<string, unknown>).status !== "awaiting_identity_deletion"
  ) {
    totals.retryRequired += 1;
    return;
  }
  totals.anonymized += 1;
}

async function completeIdentityClaim(
  client: ReturnType<typeof serviceClient>,
  requestId: string,
  totals: Totals,
): Promise<void> {
  const { data, error } = await client.rpc("service_complete_account_deletion", {
    p_request_id: requestId,
  });
  if (
    error ||
    !data ||
    typeof data !== "object" ||
    Array.isArray(data) ||
    (data as Record<string, unknown>).status !== "completed"
  ) {
    totals.retryRequired += 1;
    return;
  }
  totals.completed += 1;
}

async function processIdentityClaim(
  client: ReturnType<typeof serviceClient>,
  claim: ReturnType<typeof normalizeIdentityClaim>,
  totals: Totals,
): Promise<void> {
  if (claim.user_id === null) {
    await completeIdentityClaim(client, claim.request_id, totals);
    return;
  }

  try {
    await client.auth.admin.deleteUser(claim.user_id, false);
  } catch {
    // A lost Admin API response is recoverable: absence is verified below and,
    // if that check also fails, the nullable-FK claim is retried after its lease.
  }

  let presence: ReturnType<typeof identityPresence> = "unknown";
  try {
    const { data, error } = await client.auth.admin.getUserById(claim.user_id);
    presence = identityPresence(data, error);
  } catch {
    // Transport failures are not proof that an identity is absent.
  }
  if (presence !== "absent") {
    totals.retryRequired += 1;
    return;
  }

  totals.identitiesDeleted += 1;
  await completeIdentityClaim(client, claim.request_id, totals);
}

function normalizeIdentityClaim(value: unknown) {
  if (!isIdentityDeletionClaim(value)) throw new Error("invalid_identity_claim");
  return value;
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") return response({ error: "method_not_allowed" }, 405);
  if (request.headers.has("origin")) {
    return response({ error: "browser_requests_not_allowed" }, 403);
  }

  let config: RuntimeConfig;
  try {
    config = loadConfig();
  } catch {
    return response({ error: "service_unavailable" }, 503);
  }
  const hasProviderCredential = PROVIDER_SCHEDULER_HEADER_NAMES.some((name) =>
    request.headers.has(name)
  );
  const authorization = request.headers.get("authorization");
  if (authorization !== null && hasProviderCredential) {
    return response({ error: "invalid_worker_credentials" }, 401);
  }

  let authentication: "bearer" | "provider" | null = null;
  if (authorization !== null) {
    if (await secretsEqual(config.workerSecret, parseWorkerBearer(authorization))) {
      authentication = "bearer";
    }
  } else if (hasProviderCredential) {
    const credential = parseProviderSchedulerCredential(request.headers);
    if (credential && await verifyProviderSchedulerCredential(credential, config.workerSecret)) {
      authentication = "provider";
    }
  }
  if (authentication === null) {
    return response({ error: "invalid_worker_credentials" }, 401);
  }

  let workerRequest: Awaited<ReturnType<typeof parseWorkerRequest>>;
  try {
    workerRequest = await parseWorkerRequest(request);
  } catch (error) {
    if (error instanceof WorkerValidationError) {
      return response({ error: error.code }, error.status);
    }
    return response({ error: "invalid_request" }, 400);
  }

  const client = serviceClient(config);
  if (authentication === "provider") {
    if (workerRequest.operation !== "process" || workerRequest.limit !== 5) {
      return response({ error: "invalid_provider_request" }, 400);
    }
    const credential = parseProviderSchedulerCredential(request.headers);
    if (!credential) return response({ error: "invalid_worker_credentials" }, 401);
    const { data, error } = await client.rpc(
      "service_claim_account_deletion_scheduler_nonce",
      {
        p_nonce: credential.nonce,
        p_issued_at: new Date(credential.issuedAtSeconds * 1000).toISOString(),
      },
    );
    if (error || data !== true) {
      return response({ error: "invalid_worker_credentials" }, 401);
    }
  }

  if (workerRequest.operation === "status") {
    const { data, error } = await client.rpc("service_account_deletion_worker_health");
    if (error || !isAccountDeletionWorkerHealth(data)) {
      return response({ error: "worker_health_unavailable" }, 503);
    }
    return response({ ...data }, 200);
  }

  const { limit } = workerRequest;
  const totals: Totals = {
    cleanupClaims: 0,
    cleanupObjects: 0,
    cleanupFailures: 0,
    anonymized: 0,
    identityClaims: 0,
    identitiesDeleted: 0,
    completed: 0,
    retryRequired: 0,
  };

  const { data: rawCleanupClaims, error: cleanupClaimError } = await client.rpc(
    "service_claim_due_account_deletions",
    { p_limit: limit },
  );
  if (cleanupClaimError || !Array.isArray(rawCleanupClaims)) {
    return response({ error: "cleanup_claim_failed" }, 503);
  }

  const cleanupClaims: AccountDeletionClaim[] = [];
  for (const rawClaim of rawCleanupClaims) {
    if (isAccountDeletionClaim(rawClaim)) {
      cleanupClaims.push(rawClaim);
      continue;
    }
    const requestId = requestIdFromUnknown(rawClaim);
    if (requestId) {
      await markRequestFailed(client, requestId, "invalid_storage_cleanup_contract");
    }
    totals.cleanupFailures += 1;
  }
  totals.cleanupClaims = cleanupClaims.length;
  await runWithConcurrency(cleanupClaims, 2, async (claim) => {
    await processCleanupClaim(client, claim, totals);
  });

  const { data: rawIdentityClaims, error: identityClaimError } = await client.rpc(
    "service_claim_pending_identity_deletions",
    { p_limit: limit },
  );
  if (identityClaimError || !Array.isArray(rawIdentityClaims)) {
    return response({ error: "identity_claim_failed" }, 503);
  }

  const identityClaims = rawIdentityClaims.filter(isIdentityDeletionClaim);
  totals.identityClaims = identityClaims.length;
  if (identityClaims.length !== rawIdentityClaims.length) {
    totals.retryRequired += rawIdentityClaims.length - identityClaims.length;
  }
  await runWithConcurrency(identityClaims, 2, async (claim) => {
    await processIdentityClaim(client, normalizeIdentityClaim(claim), totals);
  });

  const ok = totals.cleanupFailures === 0 && totals.retryRequired === 0;
  return response({ ok, ...totals }, ok ? 200 : 503);
});
