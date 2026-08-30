import { createClient } from "@supabase/supabase-js";

import {
  corsHeaders,
  isOriginAllowed,
  parseAllowedOrigins,
  parseBearerToken,
  RequestValidationError,
} from "../request-account-deletion/security.ts";
import {
  encryptPushToken,
  parsePushKeyRing,
  parsePushRegistrationRequest,
  PushValidationError,
} from "../_shared/push-security.ts";

type RuntimeConfig = {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
  allowedOrigins: Set<string>;
  keyRing: ReturnType<typeof parsePushKeyRing>;
  keyVersion: number;
};

function loadConfig(): RuntimeConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  const keyRing = parsePushKeyRing(Deno.env.get("PUSH_TOKEN_ENCRYPTION_KEYS"));
  const keyVersion = Number(Deno.env.get("PUSH_TOKEN_ENCRYPTION_KEY_VERSION"));
  if (
    !supabaseUrl ||
    !anonKey ||
    !serviceRoleKey ||
    anonKey === serviceRoleKey ||
    !Number.isInteger(keyVersion) ||
    !keyRing.has(keyVersion)
  ) {
    throw new Error("invalid_runtime_configuration");
  }
  return {
    supabaseUrl,
    anonKey,
    serviceRoleKey,
    allowedOrigins: parseAllowedOrigins(Deno.env.get("ALLOWED_ORIGINS")),
    keyRing,
    keyVersion,
  };
}

function authClientOptions(authorization?: string) {
  return {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    ...(authorization ? { global: { headers: { Authorization: authorization } } } : {}),
  };
}

function jsonResponse(body: Record<string, unknown>, status: number, headers: Headers): Response {
  const nextHeaders = new Headers(headers);
  nextHeaders.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { status, headers: nextHeaders });
}

function errorResponse(status: number, code: string, headers: Headers): Response {
  const message = status === 401
    ? "인증 정보를 확인할 수 없습니다."
    : status === 403
    ? "허용되지 않은 요청입니다."
    : status >= 500
    ? "알림 기기를 등록할 수 없습니다. 잠시 후 다시 시도해 주세요."
    : "알림 기기 정보를 확인해 주세요.";
  return jsonResponse({ error: code, message }, status, headers);
}

Deno.serve(async (request: Request): Promise<Response> => {
  let config: RuntimeConfig;
  try {
    config = loadConfig();
  } catch {
    return errorResponse(500, "service_unavailable", corsHeaders(null, new Set()));
  }

  const origin = request.headers.get("origin");
  const headers = corsHeaders(origin, config.allowedOrigins);
  if (!isOriginAllowed(origin, config.allowedOrigins)) {
    return errorResponse(403, "origin_not_allowed", headers);
  }
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (request.method !== "POST") {
    headers.set("Allow", "POST, OPTIONS");
    return errorResponse(405, "method_not_allowed", headers);
  }

  let token: string;
  let payload: Awaited<ReturnType<typeof parsePushRegistrationRequest>>;
  try {
    token = parseBearerToken(request.headers.get("authorization"));
    payload = await parsePushRegistrationRequest(request);
  } catch (error) {
    if (error instanceof RequestValidationError || error instanceof PushValidationError) {
      const publicCode = error.status === 401 ? "invalid_credentials" : error.code;
      return errorResponse(error.status, publicCode, headers);
    }
    return errorResponse(400, "invalid_request", headers);
  }

  let userId: string | null = null;
  try {
    const userClient = createClient(
      config.supabaseUrl,
      config.anonKey,
      authClientOptions(`Bearer ${token}`),
    );
    const { data, error } = await userClient.auth.getUser(token);
    if (!error && data.user) userId = data.user.id;
  } catch {
    // Auth transport and invalid credentials intentionally share one response.
  }
  if (!userId) return errorResponse(401, "invalid_credentials", headers);

  try {
    const encrypted = await encryptPushToken(
      payload.token,
      payload.platform,
      config.keyVersion,
      config.keyRing,
    );
    const serviceClient = createClient(
      config.supabaseUrl,
      config.serviceRoleKey,
      authClientOptions(),
    );
    const { data, error } = await serviceClient.rpc("service_register_push_device", {
      p_user_id: userId,
      p_installation_id: payload.installationId,
      p_platform: payload.platform,
      p_token_ciphertext: encrypted.ciphertext,
      p_token_fingerprint: encrypted.fingerprint,
      p_encryption_key_version: config.keyVersion,
      p_app_version: payload.appVersion,
    });
    if (error || typeof data !== "string") {
      return errorResponse(503, "registration_failed", headers);
    }
    return jsonResponse({ ok: true, deviceId: data }, 200, headers);
  } catch {
    // Never log the provider token, ciphertext, Authorization header, or request.
    return errorResponse(503, "registration_failed", headers);
  }
});
