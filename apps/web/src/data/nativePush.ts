import { FunctionRegion } from "@supabase/supabase-js";
import type { AppMode } from "../types/domain";
import { isSupabaseConfigured, supabase } from "./supabase";

export type NativePushPlatform = "ios" | "android";

export interface NativePushRegistration {
  installationId: string;
  platform: NativePushPlatform;
  token: string;
  appVersion?: string;
}

export interface NativePushBridge {
  requestPermissionAndRegistration: () => Promise<NativePushRegistration>;
  getInstallationId?: () => Promise<string | null>;
}

type NativePushGlobal = typeof globalThis & {
  Capacitor?: { isNativePlatform?: () => boolean };
  __JAEGUN_NATIVE_PUSH__?: NativePushBridge;
};

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isNativeRuntime(runtime: NativePushGlobal) {
  try {
    return runtime.Capacitor?.isNativePlatform?.() === true;
  } catch {
    return false;
  }
}

export function isNativePushBridge(value: unknown): value is NativePushBridge {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof (value as Partial<NativePushBridge>).requestPermissionAndRegistration === "function",
  );
}

export function validateNativePushRegistration(value: unknown): NativePushRegistration {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("기기 알림 정보를 확인하지 못했습니다.");
  }
  const registration = value as Record<string, unknown>;
  const installationId = registration.installationId;
  const platform = registration.platform;
  const token = registration.token;
  const appVersion = registration.appVersion;
  if (typeof installationId !== "string" || !UUID_PATTERN.test(installationId)) {
    throw new Error("앱 설치 식별자를 확인하지 못했습니다.");
  }
  if (platform !== "ios" && platform !== "android") {
    throw new Error("지원하지 않는 알림 기기입니다.");
  }
  if (
    typeof token !== "string" ||
    token.length < 20 ||
    token.length > 4096 ||
    !/^[A-Za-z0-9:_\-.]+$/.test(token) ||
    (platform === "ios" && !/^[0-9a-f]{64}$/i.test(token))
  ) {
    throw new Error("운영체제 알림 토큰을 확인하지 못했습니다.");
  }
  if (
    appVersion !== undefined &&
    (typeof appVersion !== "string" ||
      appVersion.trim().length < 1 ||
      appVersion.trim().length > 40 ||
      /[\u0000-\u001f\u007f]/.test(appVersion))
  ) {
    throw new Error("앱 버전 정보를 확인하지 못했습니다.");
  }
  return {
    installationId: installationId.toLowerCase(),
    platform,
    token,
    ...(typeof appVersion === "string" ? { appVersion: appVersion.trim() } : {}),
  };
}

export function nativePushRegistrationAvailable(
  runtime: NativePushGlobal = globalThis as NativePushGlobal,
) {
  return isNativeRuntime(runtime) && isNativePushBridge(runtime.__JAEGUN_NATIVE_PUSH__);
}

export async function registerCurrentNativePushDevice(mode: AppMode, userId: string) {
  if (!userId.trim()) throw new Error("로그인 정보를 확인하지 못했습니다.");
  if (mode === "demo") throw new Error("실제 앱에서만 기기 알림을 연결할 수 있습니다.");
  if (!isSupabaseConfigured || !supabase) throw new Error("알림 등록 서비스에 연결하지 못했습니다.");
  const runtime = globalThis as NativePushGlobal;
  if (!nativePushRegistrationAvailable(runtime)) {
    throw new Error("iOS 또는 Android 앱에서 알림을 연결해 주세요.");
  }

  // This call is deliberately user-initiated so the native shell requests OS
  // notification permission only after the user taps the connect button.
  const registration = validateNativePushRegistration(
    await runtime.__JAEGUN_NATIVE_PUSH__!.requestPermissionAndRegistration(),
  );
  const { data, error } = await supabase.functions.invoke("register-push-device", {
    body: registration,
    region: FunctionRegion.UsEast1,
  });
  const deviceId = data && typeof data === "object"
    ? (data as Record<string, unknown>).deviceId
    : null;
  if (error || typeof deviceId !== "string" || !UUID_PATTERN.test(deviceId)) {
    throw new Error("기기 알림을 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.");
  }
  return deviceId;
}

export async function detachCurrentNativePushDevice(): Promise<boolean> {
  if (!isSupabaseConfigured || !supabase) return false;
  const runtime = globalThis as NativePushGlobal;
  const bridge = runtime.__JAEGUN_NATIVE_PUSH__;
  if (!isNativeRuntime(runtime) || !isNativePushBridge(bridge) || typeof bridge.getInstallationId !== "function") {
    return false;
  }
  try {
    const installationId = await bridge.getInstallationId();
    if (!installationId || !UUID_PATTERN.test(installationId)) return false;
    const { data, error } = await supabase.rpc("remove_my_push_device_by_installation", {
      p_installation_id: installationId.toLowerCase(),
    });
    return !error && data === true;
  } catch {
    // Logout must still revoke the Auth session if the native bridge or push
    // cleanup path is unavailable. A later registration also replaces any old
    // installation owner on the server.
    return false;
  }
}
