import { createClient } from "@supabase/supabase-js";

import {
  parsePushWorkerRequest,
  PushValidationError,
  secretsEqual,
} from "../_shared/push-security.ts";
import {
  isMediaCleanupItem,
  type MediaCleanupItem,
  storageFailure,
} from "./security.ts";

type RuntimeConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  workerSecret: string;
};

function loadConfig(): RuntimeConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  const workerSecret = Deno.env.get("MEDIA_CLEANUP_WORKER_SECRET")?.trim() ?? "";
  if (!supabaseUrl || !serviceRoleKey || workerSecret.length < 32 || workerSecret.length > 256) {
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

function bearerSecret(request: Request): string {
  const match = /^Bearer ([A-Za-z0-9._~-]{32,256})$/.exec(request.headers.get("authorization") ?? "");
  return match?.[1] ?? "";
}

async function runWithConcurrency<T>(
  values: T[],
  concurrency: number,
  worker: (value: T) => Promise<void>,
): Promise<void> {
  let nextIndex = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (nextIndex < values.length) await worker(values[nextIndex++]);
  }));
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") return response({ error: "method_not_allowed" }, 405);
  if (request.headers.has("origin")) return response({ error: "browser_requests_not_allowed" }, 403);

  let config: RuntimeConfig;
  try {
    config = loadConfig();
  } catch {
    return response({ error: "service_unavailable" }, 503);
  }
  if (!await secretsEqual(config.workerSecret, bearerSecret(request))) {
    return response({ error: "invalid_worker_credentials" }, 401);
  }

  let limit: number;
  try {
    ({ limit } = await parsePushWorkerRequest(request));
  } catch (error) {
    if (error instanceof PushValidationError) return response({ error: error.code }, error.status);
    return response({ error: "invalid_request" }, 400);
  }

  const client = createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
  });
  const { data, error } = await client.rpc("service_claim_media_cleanup_items", { p_limit: limit });
  if (error || !Array.isArray(data) || data.some((row) => !isMediaCleanupItem(row))) {
    return response({ error: "claim_failed" }, 503);
  }

  const items = data as MediaCleanupItem[];
  const totals = { deleted: 0, notFound: 0, failed: 0, completionErrors: 0 };
  await runWithConcurrency(items, 8, async (item) => {
    let status: "deleted" | "not_found" | "failed" = "deleted";
    let errorCode: string | null = null;
    try {
      const { error: deleteError } = await client.storage.from(item.bucket_id).remove([item.storage_path]);
      if (deleteError) {
        const failure = storageFailure(deleteError);
        status = failure.status;
        errorCode = failure.code;
      }
    } catch {
      status = "failed";
      errorCode = "storage_transport_error";
    }

    if (status === "deleted") totals.deleted += 1;
    else if (status === "not_found") totals.notFound += 1;
    else totals.failed += 1;

    const { error: completionError } = await client.rpc("service_complete_media_cleanup_item", {
      p_item_id: item.item_id,
      p_status: status,
      p_error_code: errorCode,
      p_retry_after_seconds: status === "failed" ? 300 : 60,
    });
    if (completionError) totals.completionErrors += 1;
  });

  return response(
    { ok: totals.completionErrors === 0, claimed: items.length, ...totals },
    totals.completionErrors ? 503 : 200,
  );
});
