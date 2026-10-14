import { execFile } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { promisify } from "node:util";

const runFile = promisify(execFile);
const appRoot = new URL("../", import.meta.url);
const simulator = process.argv[2] === "--simulator";
if (process.argv.length > 3 || (process.argv[2] !== undefined && !simulator)) {
  console.error("Usage: node scripts/verify-ios-built-app.mjs [--simulator]");
  process.exit(1);
}
const buildLabel = simulator ? "Simulator" : "Release";
const builtApp = new URL(
  `.native-build/Build/Products/${simulator ? "Debug-iphonesimulator" : "Release-iphoneos"}/App.app/`,
  appRoot,
);
const readAppFile = (relativePath, encoding) => readFile(new URL(relativePath, appRoot), encoding);
const readBuiltFile = (relativePath, encoding) => readFile(new URL(relativePath, builtApp), encoding);

const failures = [];
const expect = (condition, message) => {
  if (!condition) failures.push(message);
};

let infoXml = "";
let deviceFamilies = [];
let minimumOsVersion = "";
let bundleIdentifier = "";
let marketingVersion = "";
let buildVersion = "";
let supportedPlatforms = [];
let executable = "";
try {
  const infoPath = new URL("Info.plist", builtApp).pathname;
  infoXml = (await runFile("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", infoPath])).stdout;
  deviceFamilies = JSON.parse((await runFile(
    "/usr/bin/plutil",
    ["-extract", "UIDeviceFamily", "json", "-o", "-", infoPath],
  )).stdout);
  minimumOsVersion = (await runFile(
    "/usr/bin/plutil",
    ["-extract", "MinimumOSVersion", "raw", "-o", "-", infoPath],
  )).stdout.trim();
  bundleIdentifier = (await runFile(
    "/usr/bin/plutil",
    ["-extract", "CFBundleIdentifier", "raw", "-o", "-", infoPath],
  )).stdout.trim();
  marketingVersion = (await runFile(
    "/usr/bin/plutil",
    ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", infoPath],
  )).stdout.trim();
  buildVersion = (await runFile(
    "/usr/bin/plutil",
    ["-extract", "CFBundleVersion", "raw", "-o", "-", infoPath],
  )).stdout.trim();
  supportedPlatforms = JSON.parse((await runFile(
    "/usr/bin/plutil",
    ["-extract", "CFBundleSupportedPlatforms", "json", "-o", "-", infoPath],
  )).stdout);
  executable = (await runFile(
    "/usr/bin/plutil",
    ["-extract", "CFBundleExecutable", "raw", "-o", "-", infoPath],
  )).stdout.trim();
} catch {
  failures.push(`built ${buildLabel} App.app Info.plist is missing or unreadable`);
}

let generatedConfig;
try {
  generatedConfig = JSON.parse(await readAppFile("ios/App/App/capacitor.config.json", "utf8"));
} catch {
  failures.push("generated source capacitor.config.json is missing or invalid");
}

expect(
  JSON.stringify(supportedPlatforms) === JSON.stringify([simulator ? "iPhoneSimulator" : "iPhoneOS"]),
  `built ${buildLabel} app must target the expected platform`,
);
expect(
  JSON.stringify(deviceFamilies) === JSON.stringify([1]),
  `built ${buildLabel} app must target only iPhone (UIDeviceFamily [1])`,
);
expect(minimumOsVersion === "16.0", `built ${buildLabel} app must require iOS 16.0`);
expect(
  typeof generatedConfig?.appId === "string" && bundleIdentifier === generatedConfig.appId,
  `built ${buildLabel} bundle identifier must match the generated Capacitor App ID`,
);
expect(marketingVersion === "1.0" && buildVersion === "1", `built ${buildLabel} app must be version 1.0 (1)`);
expect(
  infoXml.includes("<string>UIInterfaceOrientationPortrait</string>")
    && !infoXml.includes("UIInterfaceOrientationLandscape")
    && !infoXml.includes("UIInterfaceOrientationPortraitUpsideDown"),
  `built ${buildLabel} app must remain portrait-only`,
);

if (simulator) {
  try {
    expect(executable === "App", "built Simulator executable must be App");
    const executablePath = new URL("App", builtApp).pathname;
    await runFile("/usr/bin/codesign", ["--verify", "--strict", builtApp.pathname]);
    // Xcode embeds simulator entitlements in Mach-O, not the code-signature plist.
    // An ad-hoc signature alone cannot authorize the data-protection Keychain.
    const { stdout } = await runFile("/usr/bin/otool", [
      "-arch", process.arch === "arm64" ? "arm64" : "x86_64",
      "-X", "-s", "__TEXT", "__entitlements", executablePath,
    ]);
    const bytes = [];
    for (const line of stdout.split("\n")) {
      const row = line.match(/^[0-9a-f]+\s+((?:[0-9a-f]{2,8}\s*)+)$/iu);
      if (!row) continue;
      for (const hex of row[1].trim().split(/\s+/u)) {
        const word = Buffer.from(hex, "hex");
        // otool prints arm64 little-endian words, but x86_64 individual bytes.
        bytes.push(hex.length === 8 ? word.reverse() : word);
      }
    }
    const entitlementsXml = Buffer.concat(bytes).toString("utf8");
    const applicationIdentifier = entitlementsXml.match(
      /<key>application-identifier<\/key>\s*<string>([^<]+)<\/string>/u,
    )?.[1];
    expect(
      applicationIdentifier === `B9KPYFH6QC.${bundleIdentifier}`,
      "built Simulator app must embed its configured-team application identifier for Keychain access",
    );
  } catch {
    failures.push("built Simulator app signature or embedded Keychain identity is missing or unreadable");
  }
}

const forbiddenInfoKeys = [
  "NSCameraUsageDescription",
  "NSPhotoLibraryUsageDescription",
  "NSPhotoLibraryAddUsageDescription",
  "NSMicrophoneUsageDescription",
  "NSLocationWhenInUseUsageDescription",
  "NSLocationAlwaysUsageDescription",
  "NSContactsUsageDescription",
  "NSCalendarsUsageDescription",
  "NSBluetoothAlwaysUsageDescription",
  "NSFaceIDUsageDescription",
];
expect(
  forbiddenInfoKeys.every((key) => !infoXml.includes(`<key>${key}</key>`)),
  `built ${buildLabel} app must not request permissions excluded from iOS 1.0`,
);

try {
  const [sourcePrivacy, builtPrivacy, builtConfig, builtIndex] = await Promise.all([
    readAppFile("ios/App/App/PrivacyInfo.xcprivacy"),
    readBuiltFile("PrivacyInfo.xcprivacy"),
    readBuiltFile("capacitor.config.json", "utf8"),
    readBuiltFile("public/index.html", "utf8"),
  ]);
  expect(sourcePrivacy.equals(builtPrivacy), `built ${buildLabel} privacy manifest must match the reviewed source manifest`);
  const parsedBuiltConfig = JSON.parse(builtConfig);
  expect(
    parsedBuiltConfig?.server?.url === undefined
      && parsedBuiltConfig?.server?.cleartext === false
      && Array.isArray(parsedBuiltConfig?.server?.allowNavigation)
      && parsedBuiltConfig.server.allowNavigation.length === 0,
    `built ${buildLabel} app must bundle local web assets without remote or cleartext navigation`,
  );
  expect(
    builtIndex.includes("Content-Security-Policy") && builtIndex.includes("/assets/"),
    `built ${buildLabel} app must include its local CSP-protected web entry`,
  );
} catch {
  failures.push(`built ${buildLabel} app is missing its privacy manifest, local config, or web entry`);
}

try {
  const frameworkEntries = await readdir(new URL("Frameworks/", builtApp));
  expect(
    frameworkEntries.every((name) => !/push|notification/iu.test(name)),
    `built ${buildLabel} app must not link a native push or notification framework`,
  );
} catch {
  failures.push(`built ${buildLabel} Frameworks directory is missing or unreadable`);
}

if (failures.length > 0) {
  console.error(`Built iOS ${buildLabel} verification failed:`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log(`Built iOS ${buildLabel} verified: local bundle, reviewed privacy, iOS 16 iPhone portrait-only, no push or media permissions${simulator ? ", signed Keychain identity" : ""}.`);
}
