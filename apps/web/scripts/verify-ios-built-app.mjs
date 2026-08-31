import { execFile } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { promisify } from "node:util";

const runFile = promisify(execFile);
const appRoot = new URL("../", import.meta.url);
const builtApp = new URL(".native-build/Build/Products/Release-iphoneos/App.app/", appRoot);
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
} catch {
  failures.push("unsigned Release App.app Info.plist is missing or unreadable");
}

let generatedConfig;
try {
  generatedConfig = JSON.parse(await readAppFile("ios/App/App/capacitor.config.json", "utf8"));
} catch {
  failures.push("generated source capacitor.config.json is missing or invalid");
}

expect(
  JSON.stringify(deviceFamilies) === JSON.stringify([1]),
  "built Release app must target only iPhone (UIDeviceFamily [1])",
);
expect(minimumOsVersion === "16.0", "built Release app must require iOS 16.0");
expect(
  typeof generatedConfig?.appId === "string" && bundleIdentifier === generatedConfig.appId,
  "built Release bundle identifier must match the generated Capacitor App ID",
);
expect(marketingVersion === "1.0" && buildVersion === "1", "built Release app must be version 1.0 (1)");
expect(
  infoXml.includes("<string>UIInterfaceOrientationPortrait</string>")
    && !infoXml.includes("UIInterfaceOrientationLandscape")
    && !infoXml.includes("UIInterfaceOrientationPortraitUpsideDown"),
  "built Release app must remain portrait-only",
);

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
  "built Release app must not request permissions excluded from iOS 1.0",
);

try {
  const [sourcePrivacy, builtPrivacy, builtConfig, builtIndex] = await Promise.all([
    readAppFile("ios/App/App/PrivacyInfo.xcprivacy"),
    readBuiltFile("PrivacyInfo.xcprivacy"),
    readBuiltFile("capacitor.config.json", "utf8"),
    readBuiltFile("public/index.html", "utf8"),
  ]);
  expect(sourcePrivacy.equals(builtPrivacy), "built Release privacy manifest must match the reviewed source manifest");
  const parsedBuiltConfig = JSON.parse(builtConfig);
  expect(
    parsedBuiltConfig?.server?.url === undefined
      && parsedBuiltConfig?.server?.cleartext === false
      && Array.isArray(parsedBuiltConfig?.server?.allowNavigation)
      && parsedBuiltConfig.server.allowNavigation.length === 0,
    "built Release app must bundle local web assets without remote or cleartext navigation",
  );
  expect(
    builtIndex.includes("Content-Security-Policy") && builtIndex.includes("/assets/"),
    "built Release app must include its local CSP-protected web entry",
  );
} catch {
  failures.push("built Release app is missing its privacy manifest, local config, or web entry");
}

try {
  const frameworkEntries = await readdir(new URL("Frameworks/", builtApp));
  expect(
    frameworkEntries.every((name) => !/push|notification/iu.test(name)),
    "built Release app must not link a native push or notification framework",
  );
} catch {
  failures.push("built Release Frameworks directory is missing or unreadable");
}

if (failures.length > 0) {
  console.error("Built iOS Release verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log("Built iOS Release verified: local bundle, reviewed privacy, iOS 16 iPhone portrait-only, no push or media permissions.");
}
