import { createClient } from "@supabase/supabase-js";

import {
  decryptPushToken,
  parsePushKeyRing,
  parsePushWorkerRequest,
  PushValidationError,
  secretsEqual,
} from "../_shared/push-security.ts";
import {
  type ClaimedPushDelivery,
  parseProviderConfig,
  sendProviderPush,
} from "./providers.ts";

type RuntimeConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  workerSecret: string;
  keyRing: ReturnType<typeof parsePushKeyRing>;
  providerConfig: ReturnType<typeof parseProviderConfig>;
};

function loadConfig(): RuntimeConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  const workerSecret = Deno.env.get("PUSH_WORKER_SECRET")?.trim() ?? "";
  if (!supabaseUrl || !serviceRoleKey || workerSecret.length < 32 || workerSecret.length > 256) {
    throw new Error("invalid_runtime_configuration");
  }
  return {
    supabaseUrl,
    serviceRoleKey,
    workerSecret,
    keyRing: parsePushKeyRing(Deno.env.get("PUSH_TOKEN_ENCRYPTION_KEYS")),
    providerConfig: parseProviderConfig(Deno.env),
  };
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
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9._~-]{32,256})$/.exec(header);
  return match?.[1] ?? "";
}

function isClaimedDelivery(value: unknown): value is ClaimedPushDelivery {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return (
    typeof row.delivery_id === "string" &&
    typeof row.job_id === "string" &&
    typeof row.device_id === "string" &&
    (row.platform === "ios" || row.platform === "android" || row.platform === "web") &&
    typeof row.token_ciphertext === "string" &&
    Number.isInteger(row.encryption_key_version) &&
    typeof row.event_code === "string" &&
    typeof row.entity_type === "string" &&
    (row.entity_id === null || typeof row.entity_id === "string") &&
    (row.title === "새 메시지가 있습니다" || row.title === "새 알림이 있습니다" || row.title === "보안 알림이 있습니다") &&
    row.body === "앱에서 내용을 확인해 주세요." &&
    typeof row.is_silent === "boolean" &&
    (row.collapse_key === null || typeof row.collapse_key === "string") &&
    Number.isInteger(row.delivery_attempts)
  );
}

async function runWithConcurrency<T>(
  values: T[],
  concurrency: number,
  worker: (value: T) => Promise<void>,
): Promise<void> {
  let nextIndex = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (nextIndex < values.length) {
      const value = values[nextIndex++];
      await worker(value);
    }
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

  const client = serviceClient(config);
  const { data, error } = await client.rpc("service_claim_push_jobs", { p_limit: limit });
  if (error || !Array.isArray(data) || data.some((row) => !isClaimedDelivery(row))) {
    return response({ error: "claim_failed" }, 503);
  }

  const deliveries = data as ClaimedPushDelivery[];
  const totals = { delivered: 0, failed: 0, invalidTokens: 0, completionErrors: 0 };
  await runWithConcurrency(deliveries, 8, async (delivery) => {
    let result;
    try {
      const rawToken = await decryptPushToken(
        delivery.token_ciphertext,
        delivery.platform,
        delivery.encryption_key_version,
        config.keyRing,
      );
      result = await sendProviderPush(delivery, rawToken, config.providerConfig);
    } catch {
      result = {
        success: false,
        invalidToken: false,
        errorCode: "push_token_decryption_failed",
        retryAfterSeconds: 300,
      };
    }

    if (result.success) totals.delivered += 1;
    else totals.failed += 1;
    if (result.invalidToken) totals.invalidTokens += 1;
    const { error: completionError } = await client.rpc("service_complete_push_delivery", {
      p_delivery_id: delivery.delivery_id,
      p_success: result.success,
      p_invalid_token: result.invalidToken,
      p_error_code: result.errorCode,
      p_retry_after_seconds: result.retryAfterSeconds,
    });
    if (completionError) totals.completionErrors += 1;
  });

  return response({ ok: totals.completionErrors === 0, claimed: deliveries.length, ...totals }, totals.completionErrors ? 503 : 200);
});
