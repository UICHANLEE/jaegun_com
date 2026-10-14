import { spawnSync } from "node:child_process";
import { androidEnvironment, appRoot } from "./android-toolchain.mjs";

const mode = process.argv[2];
const tasks = { debug: "assembleDebug", release: "assembleRelease", instrumented: ":app:connectedDebugAndroidTest" };
if (!Object.hasOwn(tasks, mode)) throw new Error("Choose debug, release, or instrumented.");
const result = spawnSync(process.platform === "win32" ? "gradlew.bat" : "./gradlew",
  [tasks[mode], "--no-daemon"], {
    cwd: new URL("android/", appRoot), env: await androidEnvironment(), stdio: "inherit",
  });
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
