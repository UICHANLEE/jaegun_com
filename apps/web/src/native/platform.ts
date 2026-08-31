import { Capacitor } from "@capacitor/core";

export interface CapacitorPlatformRuntime {
  Capacitor?: {
    isNativePlatform?: () => boolean;
    getPlatform?: () => string;
  };
}

const defaultCapacitorRuntime: CapacitorPlatformRuntime = {
  Capacitor: {
    isNativePlatform: () => Capacitor.isNativePlatform(),
    getPlatform: () => Capacitor.getPlatform(),
  },
};

/**
 * Identifies the bundled official iOS client without relying on a spoofable
 * user-agent. An unidentified or broken native bridge takes the conservative
 * iOS release path; ordinary browsers and an explicit Android shell do not.
 */
export function isOfficialIosNativeClient(
  runtime: CapacitorPlatformRuntime = defaultCapacitorRuntime,
) {
  let native = false;
  try {
    native = runtime.Capacitor?.isNativePlatform?.() === true;
  } catch {
    return typeof runtime.Capacitor?.isNativePlatform === "function";
  }
  if (!native) return false;

  try {
    const platform = runtime.Capacitor?.getPlatform?.();
    return platform === undefined || platform === "ios";
  } catch {
    return true;
  }
}
