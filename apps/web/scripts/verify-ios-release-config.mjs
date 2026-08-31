import { readFile } from "node:fs/promises";

const appRoot = new URL("../", import.meta.url);
const readAppFile = (relativePath) => readFile(new URL(relativePath, appRoot), "utf8");
const readAppBuffer = (relativePath) => readFile(new URL(relativePath, appRoot));

const [
  capacitorConfigSource,
  generatedConfig,
  cordovaConfig,
  project,
  infoPlist,
  swiftPackage,
  entitlements,
  privacyManifest,
  appIconContents,
  appIcon,
] = await Promise.all([
  readAppFile("capacitor.config.ts"),
  readAppFile("ios/App/App/capacitor.config.json"),
  readAppFile("ios/App/App/config.xml"),
  readAppFile("ios/App/App.xcodeproj/project.pbxproj"),
  readAppFile("ios/App/App/Info.plist"),
  readAppFile("ios/App/CapApp-SPM/Package.swift"),
  readAppFile("ios/App/App/App.entitlements"),
  readAppFile("ios/App/App/PrivacyInfo.xcprivacy"),
  readAppFile("ios/App/App/Assets.xcassets/AppIcon.appiconset/Contents.json"),
  readAppBuffer("ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"),
]);

const failures = [];
const expect = (condition, message) => {
  if (!condition) failures.push(message);
};

const expectedAccessOrigins = ["https://opwzujhfsxqaivtbjewg.supabase.co"];

let generated;
try {
  generated = JSON.parse(generatedConfig);
} catch {
  failures.push("generated capacitor.config.json is not valid JSON");
}

expect(
  capacitorConfigSource.includes('allowNavigation: []'),
  "capacitor.config.ts must keep server.allowNavigation empty",
);
expect(
  expectedAccessOrigins.every((origin) => capacitorConfigSource.includes(`accessOrigins: ["${origin}"]`)),
  "capacitor.config.ts must keep the exact Cordova access origin allowlist",
);
expect(generated?.server?.hostname === "localhost", "generated native hostname must remain localhost");
expect(generated?.server?.iosScheme === "capacitor", "generated native scheme must remain capacitor");
expect(generated?.server?.cleartext === false, "generated native config must reject cleartext traffic");
expect(generated?.server?.url === undefined, "generated native config must not load a remote server URL");
expect(
  Array.isArray(generated?.server?.allowNavigation) && generated.server.allowNavigation.length === 0,
  "generated native allowNavigation must remain empty",
);
expect(
  cordovaConfig.match(/<access\s+origin=["']\*["']\s*\/>/u) === null,
  "generated Cordova config must not contain a wildcard access origin",
);

const bundleIdentifiers = Array.from(
  project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);/gu),
  (match) => match[1].trim().replaceAll('"', ""),
);
expect(
  typeof generated?.appId === "string"
    && bundleIdentifiers.length === 2
    && bundleIdentifiers.every((identifier) => identifier === generated.appId),
  "Capacitor and Xcode Debug/Release bundle identifiers must stay identical",
);
const marketingVersions = Array.from(
  project.matchAll(/MARKETING_VERSION\s*=\s*([^;]+);/gu),
  (match) => match[1].trim().replaceAll('"', ""),
);
const buildVersions = Array.from(
  project.matchAll(/CURRENT_PROJECT_VERSION\s*=\s*([^;]+);/gu),
  (match) => match[1].trim().replaceAll('"', ""),
);
expect(
  marketingVersions.length === 2 && marketingVersions.every((version) => version === "1.0"),
  "iOS release marketing version must remain 1.0 in Debug and Release",
);
expect(
  buildVersions.length === 2 && buildVersions.every((version) => version === "1"),
  "iOS release build number must remain 1 in Debug and Release",
);

const disallowedUsageDescriptions = [
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
  disallowedUsageDescriptions.every((key) => !infoPlist.includes(`<key>${key}</key>`)),
  "iOS 1.0 must not declare unused camera, media-library, microphone, location, contact, calendar, Bluetooth, or Face ID permissions",
);
expect(
  !entitlements.includes("aps-environment")
    && !capacitorConfigSource.includes("@capacitor/push-notifications"),
  "iOS 1.0 must not contain APNs entitlements or the native push plugin",
);
const entitlementKeys = Array.from(
  entitlements.matchAll(/<key>([^<]+)<\/key>/gu),
  (match) => match[1],
);
expect(
  JSON.stringify(entitlementKeys) === JSON.stringify(["com.apple.developer.associated-domains"])
    && entitlements.includes("<string>applinks:jaegun-com.vercel.app</string>"),
  "iOS 1.0 entitlements must contain only the exact production associated domain",
);

const expectedPrivacyDataTypes = [
  "NSPrivacyCollectedDataTypeName",
  "NSPrivacyCollectedDataTypeEmailAddress",
  "NSPrivacyCollectedDataTypeUserID",
  "NSPrivacyCollectedDataTypeSensitiveInfo",
  "NSPrivacyCollectedDataTypeEmailsOrTextMessages",
  "NSPrivacyCollectedDataTypeOtherFinancialInfo",
  "NSPrivacyCollectedDataTypeOtherUserContent",
  "NSPrivacyCollectedDataTypePhotosorVideos",
  "NSPrivacyCollectedDataTypeOtherUsageData",
  "NSPrivacyCollectedDataTypeCustomerSupport",
  "NSPrivacyCollectedDataTypeCoarseLocation",
  "NSPrivacyCollectedDataTypeOtherDiagnosticData",
].sort();
const privacyDataTypes = Array.from(
  privacyManifest.matchAll(/<string>(NSPrivacyCollectedDataType(?!Purpose)[^<]+)<\/string>/gu),
  (match) => match[1],
).sort();
expect(
  JSON.stringify(privacyDataTypes) === JSON.stringify(expectedPrivacyDataTypes),
  "PrivacyInfo.xcprivacy must keep the reviewed 12-type App Privacy inventory",
);
expect(
  privacyManifest.includes("<string>NSPrivacyAccessedAPICategoryUserDefaults</string>")
    && privacyManifest.includes("<string>CA92.1</string>")
    && /<key>NSPrivacyTracking<\/key>\s*<false\/>/u.test(privacyManifest),
  "PrivacyInfo.xcprivacy must keep the UserDefaults reason and tracking disabled",
);

let iconCatalog;
try {
  iconCatalog = JSON.parse(appIconContents);
} catch {
  failures.push("AppIcon Contents.json is not valid JSON");
}
expect(
  iconCatalog?.images?.length === 1
    && iconCatalog.images[0]?.filename === "AppIcon-512@2x.png"
    && iconCatalog.images[0]?.size === "1024x1024",
  "AppIcon catalog must reference exactly one 1024x1024 universal iOS icon",
);
const pngSignature = "89504e470d0a1a0a";
const pngWidth = appIcon.length >= 26 ? appIcon.readUInt32BE(16) : 0;
const pngHeight = appIcon.length >= 26 ? appIcon.readUInt32BE(20) : 0;
const pngColorType = appIcon.length >= 26 ? appIcon[25] : 255;
expect(
  appIcon.subarray(0, 8).toString("hex") === pngSignature
    && pngWidth === 1_024
    && pngHeight === 1_024
    && ![4, 6].includes(pngColorType),
  "App Store icon must be a 1024x1024 PNG without an alpha channel",
);

const generatedAccessOrigins = Array.from(
  cordovaConfig.matchAll(/<access\s+origin=["']([^"']+)["']\s*\/>/gu),
  (match) => match[1],
);
expect(
  JSON.stringify(generatedAccessOrigins) === JSON.stringify(expectedAccessOrigins),
  `generated Cordova access origins must be exactly ${expectedAccessOrigins.join(", ")}`,
);

const targetedFamilies = Array.from(
  project.matchAll(/TARGETED_DEVICE_FAMILY\s*=\s*([^;]+);/gu),
  (match) => match[1].trim().replaceAll('"', ""),
);
expect(targetedFamilies.length === 2, "Xcode target must declare Debug and Release device families");
expect(
  targetedFamilies.length > 0 && targetedFamilies.every((family) => family === "1"),
  "iOS 1.0 Xcode target must remain iPhone-only (TARGETED_DEVICE_FAMILY = 1)",
);
const deploymentTargets = Array.from(
  project.matchAll(/IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([^;]+);/gu),
  (match) => match[1].trim().replaceAll('"', ""),
);
expect(
  deploymentTargets.length > 0 && deploymentTargets.every((target) => target === "16.0"),
  "iOS 1.0 must require iOS 16.0 so every supported WebKit provides crypto.randomUUID",
);
expect(
  swiftPackage.includes("platforms: [.iOS(.v16)]"),
  "CapApp-SPM must keep its iOS package floor aligned at iOS 16",
);
expect(
  !infoPlist.includes("UISupportedInterfaceOrientations~ipad"),
  "iPhone-only iOS 1.0 must not retain iPad-specific orientation metadata",
);
expect(
  infoPlist.includes("<string>UIInterfaceOrientationPortrait</string>"),
  "iOS 1.0 must support the portrait orientation",
);
expect(
  !infoPlist.includes("UIInterfaceOrientationLandscape")
    && !infoPlist.includes("UIInterfaceOrientationPortraitUpsideDown"),
  "iOS 1.0 must remain portrait-only until rotation QA is complete",
);

if (failures.length > 0) {
  console.error("iOS release configuration verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log("iOS release configuration verified: local bundle, restricted origins, iOS 16 iPhone portrait-only target.");
}
