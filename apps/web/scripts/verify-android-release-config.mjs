import { readFile } from "node:fs/promises";
import { appRoot } from "./android-toolchain.mjs";

const read = (path) => readFile(new URL(path, appRoot), "utf8");
const [packageSource, manifest, configSource, generatedSource, network, backup, extraction, activity, storage, variables, gradle, cordova, styles] = await Promise.all([
  "package.json", "android/app/src/main/AndroidManifest.xml", "capacitor.config.ts",
  "android/app/src/main/assets/capacitor.config.json", "android/app/src/main/res/xml/network_security_config.xml",
  "android/app/src/main/res/xml/backup_rules.xml", "android/app/src/main/res/xml/data_extraction_rules.xml",
  "android/app/src/main/java/com/uichanlee/jaegun/MainActivity.java",
  "android/app/src/main/java/com/uichanlee/jaegun/JaegunSecureStoragePlugin.java", "android/variables.gradle",
  "android/app/build.gradle", "android/app/src/main/res/xml/config.xml", "android/app/src/main/res/values/styles.xml",
].map(read));
const failures = [];
const expect = (condition, message) => { if (!condition) failures.push(message); };
const generated = JSON.parse(generatedSource);
const pkg = JSON.parse(packageSource);
expect(pkg.devDependencies?.["@capacitor/android"] === "8.5.3" && pkg.dependencies?.["@capacitor/core"] === "8.5.3", "Android and core must stay pinned at 8.5.3");
expect(generated.appId === "com.uichanlee.jaegun" && /applicationId "com\.uichanlee\.jaegun"/u.test(gradle), "Android application identifiers must agree");
expect(generated.appName === "재건 공동체", "Android display name must remain 재건 공동체");
expect(generated.server?.hostname === "localhost" && generated.server?.androidScheme === "https", "Android local origin must be https://localhost");
expect(generated.server?.url === undefined && generated.server?.cleartext === false && generated.server?.allowNavigation?.length === 0 && Array.isArray(generated.server?.allowNavigation), "Native bundle must be local-only with cleartext and navigation disabled");
expect(generated.android?.allowMixedContent === false && generated.android?.webContentsDebuggingEnabled === false && generated.android?.useLegacyBridge === false, "Android must reject mixed content, release WebView debugging and legacy bridge");
expect(generated.loggingBehavior === "none" && generated.android?.loggingBehavior === "none", "Native production logging must be disabled");
expect(generated.plugins?.SystemBars?.insetsHandling === "css" && generated.plugins?.SystemBars?.style === "DEFAULT" && generated.plugins?.SystemBars?.initialViewportFitValueHint === "cover", "SystemBars must own CSS insets and follow system theme");
expect(generated.plugins?.Keyboard?.resizeOnFullScreen !== true, "Keyboard must not override SystemBars IME sizing");
expect(!configSource.includes("@capacitor/push-notifications"), "No native push provider may be added");
expect(manifest.includes('android:allowBackup="false"') && manifest.includes('android:fullBackupContent="@xml/backup_rules"') && manifest.includes('android:dataExtractionRules="@xml/data_extraction_rules"'), "Backup and device-transfer exclusions must be attached to application");
expect(manifest.includes('android:usesCleartextTraffic="false"') && manifest.includes('android:networkSecurityConfig="@xml/network_security_config"'), "Application must use restrictive network policy");
const permissions = [...manifest.matchAll(/<uses-permission\s+android:name="([^"]+)"/gu)].map((match) => match[1]);
expect(JSON.stringify(permissions) === JSON.stringify(["android.permission.INTERNET"]), "Only INTERNET permission is needed");
const appLinks = [...manifest.matchAll(/<data\s+android:scheme="([^"]+)"\s+android:host="([^"]+)"\s+android:path="([^"]+)"\s*\/>/gu)].map((match) => match.slice(1));
expect(JSON.stringify(appLinks) === JSON.stringify([
  ["https", "jaegun-com.vercel.app", "/auth/callback/social"],
]), "App links must have exactly the HTTPS public social callback path");
expect(manifest.includes('android:autoVerify="true"') && !/pathPrefix|pathPattern|android:scheme="http"/u.test(manifest), "App links must request verification without broader matching");
expect(network.includes('cleartextTrafficPermitted="false"') && network.includes('<certificates src="system" />') && !/debug-overrides|src="user"|cleartextTrafficPermitted="true"/u.test(network), "Network trust must allow system certificates only and no cleartext");
for (const domain of ["root", "file", "database", "sharedpref", "external"]) {
  expect(backup.includes(`<exclude domain="${domain}" path="." />`), `Legacy backup must exclude ${domain}`);
  for (const section of ["cloud-backup", "device-transfer"]) {
    const body = extraction.match(new RegExp(`<${section}[^>]*>([\\s\\S]*?)</${section}>`, "u"))?.[1];
    expect(body?.includes(`<exclude domain="${domain}" path="." />`), `${section} must exclude ${domain}`);
  }
}
expect(activity.includes("registerPlugin(JaegunSecureStoragePlugin.class)") && activity.includes("FLAG_SECURE") && activity.includes("sanitizeAuthIntent(intent)"), "Activity must register secure storage, shield recents and validate incoming links");
expect(activity.includes('"/auth/callback/social".equals(path)') && activity.includes('uri.getPort() == -1') && !activity.includes("/auth/callback/signup") && !activity.includes("/auth/callback/recovery"), "Activity incoming link guard must accept only the exact social return origin and path");
for (const invariant of ["AndroidKeyStore", "AES/GCM/NoPadding", "getNoBackupFilesDir()", "setRandomizedEncryptionRequired(true)", "setKeySize(256)", "cipher.updateAAD", "MAX_VALUE_BYTES = 1_048_576", "[A-Za-z0-9_-]{8,64}-code-verifier", 'name = "JaegunSecureStorage"']) {
  expect(storage.includes(invariant), `Secure storage invariant missing: ${invariant}`);
}
expect(storage.includes('SOCIAL_INTENT_KEY = "com.uichanlee.jaegun.social-auth-intent.v1"') && storage.includes("RECOVERY_KEY, SOCIAL_INTENT_KEY"), "Secure storage must allow the exact social intent key and legacy recovery cleanup key");
expect(!storage.includes("getSharedPreferences") && !storage.includes("java.util.Base64"), "Authentication storage must remain binary ciphertext-only");
expect(/compileSdkVersion = 36/u.test(variables) && /targetSdkVersion = 36/u.test(variables), "Android must target API 36");
expect(styles.includes("Theme.AppCompat.DayNight.NoActionBar"), "Native theme must follow system dark mode");
const origins = [...cordova.matchAll(/<access\s+origin="([^"]+)"/gu)].map((match) => match[1]);
expect(JSON.stringify(origins) === JSON.stringify(["https://opwzujhfsxqaivtbjewg.supabase.co"]), "Cordova network origin must remain exact public backend");
for (const [density, size] of [["mdpi", 48], ["hdpi", 72], ["xhdpi", 96], ["xxhdpi", 144], ["xxxhdpi", 192]]) {
  const icon = await readFile(new URL(`android/app/src/main/res/mipmap-${density}/ic_launcher.png`, appRoot));
  expect(icon.subarray(0, 8).toString("hex") === "89504e470d0a1a0a" && icon.readUInt32BE(16) === size && icon.readUInt32BE(20) === size, `${density} launcher must be a ${size}px PNG`);
}
if (failures.length) {
  console.error("Android release configuration verification failed:\n" + failures.map((message) => `- ${message}`).join("\n"));
  process.exitCode = 1;
} else {
  console.log("Android configuration verified: local HTTPS bundle, Keystore ciphertext-only auth, no backup/transfer, exact auth app links, system theme/insets. Signing and deployed assetlinks verification remain separate store prerequisites.");
}
