import {
  classifyApnsResponse,
  classifyFcmResponse,
  type ProviderResult,
  safePushRoute,
} from "../_shared/push-security.ts";

export type ClaimedPushDelivery = {
  delivery_id: string;
  job_id: string;
  device_id: string;
  platform: "ios" | "android" | "web";
  token_ciphertext: string;
  encryption_key_version: number;
  event_code: string;
  entity_type: string;
  entity_id: string | null;
  title: "새 메시지가 있습니다" | "새 알림이 있습니다" | "보안 알림이 있습니다";
  body: "앱에서 내용을 확인해 주세요.";
  is_silent: boolean;
  collapse_key: string | null;
  delivery_attempts: number;
};

type FcmConfig = {
  projectId: string;
  clientEmail: string;
  privateKey: string;
};

type ApnsConfig = {
  teamId: string;
  keyId: string;
  privateKey: string;
  bundleId: string;
  environment: "production" | "sandbox";
};

export type ProviderConfig = {
  fcm: FcmConfig | null;
  apns: ApnsConfig | null;
};

type CachedToken = { value: string; expiresAt: number };
let cachedFcmToken: CachedToken | null = null;
let cachedApnsToken: CachedToken | null = null;

function base64Url(value: Uint8Array | string): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function pemBytes(pem: string): Uint8Array {
  const encoded = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  if (!encoded || !/^[A-Za-z0-9+/=]+$/.test(encoded)) throw new Error("invalid_provider_private_key");
  let binary: string;
  try {
    binary = atob(encoded);
  } catch {
    throw new Error("invalid_provider_private_key");
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function signJwt(
  algorithm: "RS256" | "ES256",
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  privateKey: string,
): Promise<string> {
  const encodedHeader = base64Url(JSON.stringify({ ...header, alg: algorithm, typ: "JWT" }));
  const encodedClaims = base64Url(JSON.stringify(claims));
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const keyBytes = pemBytes(privateKey);

  if (algorithm === "RS256") {
    const key = await crypto.subtle.importKey(
      "pkcs8",
      keyBytes,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(signingInput),
    );
    return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
  }

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(toJoseEs256Signature(new Uint8Array(signature)))}`;
}

function toJoseEs256Signature(signature: Uint8Array): Uint8Array {
  if (signature.byteLength === 64) return signature;
  if (signature.byteLength < 8 || signature[0] !== 0x30) {
    throw new Error("invalid_es256_signature");
  }
  let offset = 1;
  const sequenceLength = readDerLength(signature, offset);
  offset = sequenceLength.offset;
  if (sequenceLength.length !== signature.byteLength - offset || signature[offset++] !== 0x02) {
    throw new Error("invalid_es256_signature");
  }
  const rLength = readDerLength(signature, offset);
  offset = rLength.offset;
  const r = signature.slice(offset, offset + rLength.length);
  offset += rLength.length;
  if (signature[offset++] !== 0x02) throw new Error("invalid_es256_signature");
  const sLength = readDerLength(signature, offset);
  offset = sLength.offset;
  const s = signature.slice(offset, offset + sLength.length);
  offset += sLength.length;
  if (offset !== signature.byteLength) throw new Error("invalid_es256_signature");
  return Uint8Array.from([...leftPadInteger(r), ...leftPadInteger(s)]);
}

function readDerLength(bytes: Uint8Array, offset: number): { length: number; offset: number } {
  const first = bytes[offset++];
  if (first === undefined) throw new Error("invalid_es256_signature");
  if ((first & 0x80) === 0) return { length: first, offset };
  const count = first & 0x7f;
  if (count < 1 || count > 2 || offset + count > bytes.length) throw new Error("invalid_es256_signature");
  let length = 0;
  for (let index = 0; index < count; index += 1) length = length * 256 + bytes[offset++];
  return { length, offset };
}

function leftPadInteger(value: Uint8Array): Uint8Array {
  let start = 0;
  while (start < value.length - 1 && value[start] === 0) start += 1;
  const normalized = value.slice(start);
  if (normalized.length > 32) throw new Error("invalid_es256_signature");
  const result = new Uint8Array(32);
  result.set(normalized, 32 - normalized.length);
  return result;
}

export function parseProviderConfig(env: { get(name: string): string | undefined }): ProviderConfig {
  let fcm: FcmConfig | null = null;
  const rawFcm = env.get("FCM_SERVICE_ACCOUNT_JSON")?.trim();
  if (rawFcm) {
    let value: unknown;
    try {
      value = JSON.parse(rawFcm);
    } catch {
      throw new Error("invalid_fcm_configuration");
    }
    const record = value as Record<string, unknown>;
    const projectId = record.project_id;
    const clientEmail = record.client_email;
    const privateKey = record.private_key;
    if (
      typeof projectId !== "string" || !/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(projectId) ||
      typeof clientEmail !== "string" || !/^[^\s@]+@[^\s@]+\.gserviceaccount\.com$/.test(clientEmail) ||
      typeof privateKey !== "string" || privateKey.length < 500 || privateKey.length > 10000
    ) {
      throw new Error("invalid_fcm_configuration");
    }
    fcm = { projectId, clientEmail, privateKey };
  }

  let apns: ApnsConfig | null = null;
  const apnsTeamId = env.get("APNS_TEAM_ID")?.trim();
  const apnsKeyId = env.get("APNS_KEY_ID")?.trim();
  const apnsPrivateKey = env.get("APNS_PRIVATE_KEY")?.trim();
  const apnsBundleId = env.get("APNS_BUNDLE_ID")?.trim();
  const apnsEnvironment = env.get("APNS_ENVIRONMENT")?.trim() || "production";
  const anyApns = Boolean(apnsTeamId || apnsKeyId || apnsPrivateKey || apnsBundleId);
  if (anyApns) {
    if (
      !apnsTeamId || !/^[A-Z0-9]{10}$/.test(apnsTeamId) ||
      !apnsKeyId || !/^[A-Z0-9]{10}$/.test(apnsKeyId) ||
      !apnsPrivateKey || apnsPrivateKey.length < 150 || apnsPrivateKey.length > 5000 ||
      !apnsBundleId || !/^[A-Za-z0-9.-]{3,255}$/.test(apnsBundleId) ||
      (apnsEnvironment !== "production" && apnsEnvironment !== "sandbox")
    ) {
      throw new Error("invalid_apns_configuration");
    }
    apns = {
      teamId: apnsTeamId,
      keyId: apnsKeyId,
      privateKey: apnsPrivateKey,
      bundleId: apnsBundleId,
      environment: apnsEnvironment,
    };
  }

  if (!fcm && !apns) throw new Error("push_provider_not_configured");
  return { fcm, apns };
}

async function fcmAccessToken(config: FcmConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedFcmToken && cachedFcmToken.expiresAt > now + 60) return cachedFcmToken.value;
  const assertion = await signJwt(
    "RS256",
    {},
    {
      iss: config.clientEmail,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    },
    config.privateKey,
  );
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) throw new Error(`fcm_oauth_http_${response.status}`);
  const value = await response.json() as Record<string, unknown>;
  if (typeof value.access_token !== "string" || value.access_token.length < 20) {
    throw new Error("invalid_fcm_oauth_response");
  }
  const expiresIn = typeof value.expires_in === "number" ? Math.max(300, Math.min(value.expires_in, 3600)) : 3600;
  cachedFcmToken = { value: value.access_token, expiresAt: now + expiresIn };
  return value.access_token;
}

async function apnsAccessToken(config: ApnsConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedApnsToken && cachedApnsToken.expiresAt > now + 60) return cachedApnsToken.value;
  const token = await signJwt(
    "ES256",
    { kid: config.keyId },
    { iss: config.teamId, iat: now },
    config.privateKey,
  );
  cachedApnsToken = { value: token, expiresAt: now + 50 * 60 };
  return token;
}

function genericData(delivery: ClaimedPushDelivery): Record<string, string> {
  return {
    event_code: delivery.event_code,
    entity_type: delivery.entity_type,
    entity_id: delivery.entity_id ?? "",
    route: safePushRoute(delivery.entity_type, delivery.entity_id),
    delivery_id: delivery.delivery_id,
  };
}

async function sendFcm(
  delivery: ClaimedPushDelivery,
  rawToken: string,
  config: FcmConfig,
): Promise<ProviderResult> {
  const accessToken = await fcmAccessToken(config);
  const message: Record<string, unknown> = {
    token: rawToken,
    data: genericData(delivery),
    android: {
      priority: delivery.event_code === "security_notice" ? "high" : "normal",
      collapse_key: delivery.collapse_key?.slice(0, 64) || undefined,
    },
  };
  if (!delivery.is_silent) {
    message.notification = { title: delivery.title, body: delivery.body };
  }
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(config.projectId)}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify({ message }),
    },
  );
  return classifyFcmResponse(response);
}

async function sendApns(
  delivery: ClaimedPushDelivery,
  rawToken: string,
  config: ApnsConfig,
): Promise<ProviderResult> {
  const accessToken = await apnsAccessToken(config);
  const host = config.environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  const aps = delivery.is_silent
    ? { "content-available": 1 }
    : { alert: { title: delivery.title, body: delivery.body }, sound: "default" };
  const headers: Record<string, string> = {
    Authorization: `bearer ${accessToken}`,
    "Content-Type": "application/json; charset=utf-8",
    "apns-topic": config.bundleId,
    "apns-push-type": delivery.is_silent ? "background" : "alert",
    "apns-priority": delivery.is_silent ? "5" : "10",
    "apns-id": delivery.delivery_id,
  };
  if (delivery.collapse_key) headers["apns-collapse-id"] = delivery.collapse_key.slice(0, 64);
  const response = await fetch(`${host}/3/device/${encodeURIComponent(rawToken)}`, {
    method: "POST",
    headers,
    body: JSON.stringify({ aps, jaegun: genericData(delivery) }),
  });
  return classifyApnsResponse(response);
}

export async function sendProviderPush(
  delivery: ClaimedPushDelivery,
  rawToken: string,
  config: ProviderConfig,
): Promise<ProviderResult> {
  try {
    if (delivery.platform === "ios") {
      if (!config.apns) throw new Error("apns_not_configured");
      return await sendApns(delivery, rawToken, config.apns);
    }
    if (!config.fcm) throw new Error("fcm_not_configured");
    return await sendFcm(delivery, rawToken, config.fcm);
  } catch (error) {
    const code = error instanceof Error && /^[a-z0-9_]{1,100}$/.test(error.message)
      ? error.message
      : "provider_transport_error";
    return { success: false, invalidToken: false, errorCode: code, retryAfterSeconds: 60 };
  }
}
