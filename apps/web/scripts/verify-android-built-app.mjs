import { spawnSync } from "node:child_process";
import { access, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { androidEnvironment, appRoot } from "./android-toolchain.mjs";

const args = process.argv.slice(2);
const store = args.includes("--store");
const debug = args.includes("--debug");
if (store && debug) throw new Error("A debug APK cannot pass store readiness.");
const requestedPath = args.find((arg) => !arg.startsWith("--")) ?? process.env.JAEGUN_ANDROID_RELEASE_APK;
if (!requestedPath) throw new Error("Pass a real APK path, or set JAEGUN_ANDROID_RELEASE_APK. Store readiness requires the organization-signed release APK.");
const apk = resolve(fileURLToPath(appRoot), requestedPath);
await access(apk);
const env = await androidEnvironment();
const sdk = env.ANDROID_HOME;
const run = (binary, argv) => {
  const result = spawnSync(binary, argv, { env, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${binary} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
};
const analyzer = join(sdk, "cmdline-tools/latest/bin", process.platform === "win32" ? "apkanalyzer.bat" : "apkanalyzer");
const apksigner = join(sdk, "build-tools/36.0.0", process.platform === "win32" ? "apksigner.bat" : "apksigner");
const failures = [];
const expect = (condition, message) => { if (!condition) failures.push(message); };
const manifest = run(analyzer, ["manifest", "print", apk]);
expect(/package="com\.uichanlee\.jaegun"/u.test(manifest), "Compiled APK must have the exact app ID");
expect(/android:targetSdkVersion="36"/u.test(manifest), "Compiled APK must target API 36");
expect(/android:allowBackup="false"/u.test(manifest), "Compiled APK must disable auth backups");
expect(/android:usesCleartextTraffic="false"/u.test(manifest), "Compiled APK must disable cleartext");
const isDebuggable = /android:debuggable="true"/u.test(manifest);
expect(debug ? isDebuggable : !isDebuggable, debug ? "Debug artifact must be debuggable" : "Release artifact must not be debuggable");
const permissions = [...manifest.matchAll(/<uses-permission\b[^>]*android:name="([^"]+)"/gu)].map((match) => match[1]);
const allowedPermissions = new Set(["android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE", "com.uichanlee.jaegun.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"]);
expect(permissions.includes("android.permission.INTERNET") && permissions.every((permission) => allowedPermissions.has(permission)), "Compiled APK must not request unrelated native permissions");
expect(manifest.includes('android:autoVerify="true"') && manifest.includes('android:host="jaegun-com.vercel.app"') && manifest.includes('android:path="/auth/callback/social"') && !/android:pathPrefix|android:pathPattern|\/auth\/callback\/(?:signup|recovery)/u.test(manifest), "Compiled APK must retain only the exact verified social auth link path");
const network = run(analyzer, ["resources", "xml", "--file", "res/xml/network_security_config.xml", apk]);
expect(network.includes('cleartextTrafficPermitted="false"') && network.includes('src="system"') && !network.includes('src="user"'), "Packaged network policy must reject cleartext and user-added trust anchors");
const extraction = run(analyzer, ["resources", "xml", "--file", "res/xml/data_extraction_rules.xml", apk]);
expect(extraction.includes("<cloud-backup") && extraction.includes("<device-transfer") && [...extraction.matchAll(/<exclude\b/gu)].length >= 18, "Packaged backup/transfer policy must retain all exclusion domains");
const dexPackages = run(analyzer, ["dex", "packages", "--defined-only", apk]);
expect(dexPackages.includes("JaegunSecureStoragePlugin") && dexPackages.includes("MainActivity"), "Compiled APK must contain native secure storage and registered activity");
const generated = JSON.parse(run("unzip", ["-p", apk, "assets/capacitor.config.json"]));
expect(generated.server?.hostname === "localhost" && generated.server?.androidScheme === "https" && generated.server?.url === undefined && generated.server?.cleartext === false && Array.isArray(generated.server?.allowNavigation) && generated.server.allowNavigation.length === 0, "Packaged runtime config must only serve a restricted local HTTPS bundle");
expect(generated.android?.allowMixedContent === false && generated.android?.webContentsDebuggingEnabled === false && generated.android?.useLegacyBridge === false, "Packaged runtime must disable mixed content, release debugging and legacy bridge");
const workspace = await mkdtemp(join(tmpdir(), "jaegun-apk-check-"));
try {
  run("unzip", ["-q", apk, "assets/public/*", "-d", workspace]);
  // Examine the actual APK assets, not an unrelated source dist directory.
  run(process.execPath, [fileURLToPath(new URL("scripts/verify-production-bundle.mjs", appRoot)), join(workspace, "assets/public")]);
} finally {
  await rm(workspace, { recursive: true, force: true });
}
if (store) {
  const signature = run(apksigner, ["verify", "--verbose", "--print-certs", apk]);
  const fingerprint = signature.match(/Signer #1 certificate SHA-256 digest:\s*([a-f0-9]+)/iu)?.[1]?.toUpperCase();
  expect(typeof fingerprint === "string" && fingerprint.length === 64, "Release APK must have a verifiable signing certificate");
  expect(!/Signer #1 certificate DN:.*CN=Android Debug/iu.test(signature), "Debug signing must not pass store readiness");
  const response = await fetch("https://jaegun-com.vercel.app/.well-known/assetlinks.json", { redirect: "error", signal: AbortSignal.timeout(15_000) });
  expect(response.ok && response.headers.get("content-type")?.includes("application/json"), "Production assetlinks.json must exist with JSON content type and no redirects");
  const links = response.ok ? await response.json() : null;
  expect(Array.isArray(links) && links.some((link) => link?.relation?.includes("delegate_permission/common.handle_all_urls") && link?.target?.namespace === "android_app" && link.target.package_name === "com.uichanlee.jaegun" && link.target.sha256_cert_fingerprints?.some((value) => value.replaceAll(":", "").toUpperCase() === fingerprint)), "Deployed assetlinks.json must authorize this APK signing certificate and exact app ID");
}
if (failures.length) {
  console.error("Android built artifact verification failed:\n" + failures.map((message) => `- ${message}`).join("\n"));
  process.exitCode = 1;
} else {
  console.log(`Android ${store ? "signed store artifact and deployed app-link association" : debug ? "debug artifact" : "unsigned release preflight artifact"} verified: ${apk}`);
  if (!store) console.log("Not store-ready: organization release signing and matching deployed assetlinks.json still require the separate --store gate.");
}
