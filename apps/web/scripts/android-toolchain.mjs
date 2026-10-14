import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const appRoot = new URL("../", import.meta.url);
const cache = join(homedir(), "Library/Caches/jaegun-native");
const exists = async (path) => { try { await access(path); return true; } catch { return false; } };

export async function androidEnvironment() {
  const env = { ...process.env };
  if (!env.ANDROID_HOME && !env.ANDROID_SDK_ROOT) {
    for (const sdk of [join(homedir(), "Library/Android/sdk"), join(cache, "sdk")]) {
      if (await exists(join(sdk, "platforms/android-36/android.jar"))) { env.ANDROID_HOME = sdk; break; }
    }
  }
  env.ANDROID_HOME ??= env.ANDROID_SDK_ROOT;
  if (!env.ANDROID_HOME) throw new Error("Set ANDROID_HOME to an SDK containing Android API 36 and build-tools 36.0.0.");
  env.ANDROID_SDK_ROOT ??= env.ANDROID_HOME;
  if (env.ANDROID_HOME !== env.ANDROID_SDK_ROOT) throw new Error("ANDROID_HOME and ANDROID_SDK_ROOT must agree.");
  if (!env.JAVA_HOME) {
    const isolatedJdk = join(cache, "jdk/Contents/Home");
    if (await exists(join(isolatedJdk, "bin/java"))) env.JAVA_HOME = isolatedJdk;
  }
  if (env.JAVA_HOME) env.PATH = `${join(env.JAVA_HOME, "bin")}${process.platform === "win32" ? ";" : ":"}${env.PATH ?? ""}`;
  return env;
}
