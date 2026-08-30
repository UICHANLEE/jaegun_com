import { createClient } from "@supabase/supabase-js";

import {
  corsHeaders,
  isOriginAllowed,
  parseAccountDeletionRequest,
  parseAllowedOrigins,
  parseBearerToken,
  RequestValidationError,
  verifyPasswordUserWithCleanup,
  verifiedTokenHasAal2,
} from "./security.ts";

type RuntimeConfig = {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
  allowedOrigins: Set<string>;
};

function loadConfig(): RuntimeConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey || anonKey === serviceRoleKey) {
    throw new Error("invalid_runtime_configuration");
  }
  return {
    supabaseUrl,
    anonKey,
    serviceRoleKey,
    allowedOrigins: parseAllowedOrigins(Deno.env.get("ALLOWED_ORIGINS")),
  };
}

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  headers: Headers,
): Response {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

function publicErrorResponse(
  status: number,
  code: string,
  headers: Headers,
): Response {
  const publicMessage = status === 401
    ? "인증 정보를 확인할 수 없습니다."
    : status === 403
    ? "허용되지 않은 요청입니다."
    : status >= 500
    ? "잠시 후 다시 시도해 주세요."
    : "요청 내용을 확인해 주세요.";
  return jsonResponse({ error: code, message: publicMessage }, status, headers);
}

function authClientOptions(authorization?: string) {
  return {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    ...(authorization
      ? { global: { headers: { Authorization: authorization } } }
      : {}),
  };
}

Deno.serve(async (request: Request): Promise<Response> => {
  const origin = request.headers.get("origin");

  let config: RuntimeConfig;
  try {
    config = loadConfig();
  } catch {
    const headers = corsHeaders(null, new Set());
    return publicErrorResponse(500, "service_unavailable", headers);
  }

  const headers = corsHeaders(origin, config.allowedOrigins);
  if (!isOriginAllowed(origin, config.allowedOrigins)) {
    return publicErrorResponse(403, "origin_not_allowed", headers);
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "POST") {
    headers.set("Allow", "POST, OPTIONS");
    return publicErrorResponse(405, "method_not_allowed", headers);
  }

  let token: string;
  let payload: Awaited<ReturnType<typeof parseAccountDeletionRequest>>;
  try {
    token = parseBearerToken(request.headers.get("authorization"));
    payload = await parseAccountDeletionRequest(request);
  } catch (error) {
    if (error instanceof RequestValidationError) {
      const publicCode = error.status === 401 ? "invalid_credentials" : error.code;
      return publicErrorResponse(error.status, publicCode, headers);
    }
    return publicErrorResponse(400, "invalid_request", headers);
  }

  let currentUser: { id: string; email?: string } | null = null;
  try {
    const currentUserClient = createClient(
      config.supabaseUrl,
      config.anonKey,
      authClientOptions(`Bearer ${token}`),
    );
    const { data, error } = await currentUserClient.auth.getUser(token);
    if (!error && data.user) {
      currentUser = { id: data.user.id, email: data.user.email };
    }
  } catch {
    // Keep Auth transport and parsing failures indistinguishable from an
    // invalid credential. Never log the request or its Authorization header.
  }
  if (!currentUser) {
    return publicErrorResponse(401, "invalid_credentials", headers);
  }

  const hasAal2 = verifiedTokenHasAal2(token, currentUser.id);
  if (!hasAal2) {
    if (!payload.password || !currentUser.email) {
      return publicErrorResponse(401, "invalid_credentials", headers);
    }

    let passwordVerified = false;
    try {
      const passwordVerifier = createClient(
        config.supabaseUrl,
        config.anonKey,
        authClientOptions(),
      );
      passwordVerified = await verifyPasswordUserWithCleanup(
        currentUser.id,
        async () => {
          const { data, error } = await passwordVerifier.auth.signInWithPassword({
            email: currentUser.email!,
            password: payload.password!,
          });
          return error ? null : data.user?.id ?? null;
        },
        async () => {
          await passwordVerifier.auth.signOut({ scope: "local" });
        },
      );
    } catch {
      // Deliberately return the same response for wrong passwords, Auth rate
      // limits, and Auth transport failures.
    }
    if (!passwordVerified) {
      return publicErrorResponse(401, "invalid_credentials", headers);
    }
  }

  let scheduled = false;
  try {
    const serviceClient = createClient(
      config.supabaseUrl,
      config.serviceRoleKey,
      authClientOptions(),
    );
    const { error } = await serviceClient.rpc(
      "request_account_deletion_verified",
      {
        p_user_id: currentUser.id,
        p_reason: payload.reason,
        p_confirmation_text: payload.confirmation,
      },
    );
    scheduled = !error;
  } catch {
    // Service/database errors are intentionally opaque to callers.
  }
  if (!scheduled) {
    return publicErrorResponse(503, "request_not_scheduled", headers);
  }

  return jsonResponse({ ok: true, status: "scheduled" }, 202, headers);
});
