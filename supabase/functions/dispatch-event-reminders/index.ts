import { createClient } from "@supabase/supabase-js";

import {
  parsePushWorkerRequest,
  PushValidationError,
  secretsEqual,
} from "../_shared/push-security.ts";
import {
  bearerSchedulerSecret,
  isEventReminderDispatchResult,
  isValidSchedulerSecret,
} from "./security.ts";

type RuntimeConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  schedulerSecret: string;
};

function loadConfig(): RuntimeConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  const schedulerSecret = Deno.env.get("EVENT_REMINDER_SCHEDULER_SECRET")?.trim() ?? "";
  if (
    !supabaseUrl ||
    !serviceRoleKey ||
    !isValidSchedulerSecret(schedulerSecret) ||
    schedulerSecret === serviceRoleKey
  ) {
    throw new Error("invalid_runtime_configuration");
  }
  return { supabaseUrl, serviceRoleKey, schedulerSecret };
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

  if (!await secretsEqual(config.schedulerSecret, bearerSchedulerSecret(request))) {
    return response({ error: "invalid_scheduler_credentials" }, 401);
  }

  let limit: number;
  try {
    ({ limit } = await parsePushWorkerRequest(request));
  } catch (error) {
    if (error instanceof PushValidationError) {
      return response({ error: error.code }, error.status);
    }
    return response({ error: "invalid_request" }, 400);
  }

  const client = createClient(config.supabaseUrl, config.serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
  });
  const { data, error } = await client.rpc("service_dispatch_due_event_reminders", {
    p_limit: limit,
  });
  if (
    error ||
    !Array.isArray(data) ||
    data.length !== 1 ||
    !isEventReminderDispatchResult(data[0])
  ) {
    return response({ error: "dispatch_failed" }, 503);
  }

  const result = data[0];
  return response({
    ok: true,
    dispatched: result.dispatched_count,
    hasMore: result.has_more,
  }, 200);
});
