// Read-only checks. A successful result is not App Review approval.
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";

const project = await readFile(new URL("../ios/App/App.xcodeproj/project.pbxproj", import.meta.url), "utf8");
const ids = [...project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);/g)].map((m) => m[1].trim().replaceAll('"', ""));
const teams = [...project.matchAll(/DEVELOPMENT_TEAM\s*=\s*([^;]+);/g)].map((m) => m[1].trim().replaceAll('"', ""));
const checks = [];
const record = (name, ok, detail) => checks.push({ name, ok, detail });
const team = teams[0];
const bundle = ids[0];
record("bundle_consistency", ids.length >= 2 && ids.every((id) => id === bundle), bundle);
record("signing_team", teams.length >= 2 && /^[A-Z0-9]{10}$/.test(team ?? "") && teams.every((id) => id === team), team ? "configured" : "missing");
try {
  const identities = execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], { encoding: "utf8" });
  record("signing_identity", /\b[1-9]\d* valid identities found/.test(identities), "Local identity check; provisioning and Archive validation still required");
} catch {
  record("signing_identity", false, "Could not inspect signing identities");
}
const origin = "https://jaegun-com.vercel.app";
await Promise.all(["/support", "/account-deletion", "/legal/privacy/2026-08-30", "/legal/terms/2026-08-30"].map(async (path) => {
  try {
    const response = await fetch(origin + path, { redirect: "error", signal: AbortSignal.timeout(15000) });
    record(path, response.ok, `HTTP ${response.status}; rendered content requires manual review`);
    await response.body?.cancel();
  } catch {
    record(path, false, "Request failed or timed out");
  }
}));
try {
  const response = await fetch(origin + "/.well-known/apple-app-site-association", { redirect: "error", signal: AbortSignal.timeout(15000) });
  const jsonType = (response.headers.get("content-type") ?? "").includes("application/json");
  const aasa = response.ok && jsonType ? await response.json() : null;
  const matching = aasa?.applinks?.details?.find((entry) => entry.appIDs?.includes(`${team}.${bundle}`) || entry.appID === `${team}.${bundle}`);
  const paths = ["/auth/callback/signup", "/auth/callback/recovery"];
  record("universal_links", Boolean(team && matching && paths.every((path) => matching.paths?.includes(path) || matching.components?.some((entry) => entry["/"] === path && entry.exclude !== true))), `HTTP ${response.status}; JSON=${jsonType}; exact signup/recovery paths required`);
} catch {
  record("universal_links", false, "AASA unavailable or invalid");
}
console.log(JSON.stringify({ checks, manualGates: ["Legal entity and final Bundle ID confirmed", "Signed Archive validated", "Physical iPhone and TestFlight verified", "Synthetic review accounts and screenshots", "Account deletion and moderation operations verified"] }, null, 2));
if (checks.some((check) => !check.ok)) process.exitCode = 1;
