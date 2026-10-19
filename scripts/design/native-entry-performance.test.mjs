import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const source = (file) => readFileSync(new URL(`../../apps/ios-native/Sources/${file}`, import.meta.url), "utf8");

test("actual Swift entry router preserves auth, MFA, consent and membership boundaries", () => {
  const text = source("NativeRootView.swift");
  const route = text.slice(text.indexOf("enum NativeRootRoute"), text.indexOf("struct NativeRootView"));
  assert.ok(route.includes("resolvingEntry"));
  const cases = `
for pending in [false, true] {
  for mfa in [false, true] {
    for consent in [false, true] {
      for admin in [false, true] {
        for active in [false, true] {
          let anonymous = NativeRootRoute.resolve(loading: true, signedIn: false, consentRequired: consent, administrator: admin, activeMember: active, mfaRequired: mfa, resolvingEntry: pending)
          precondition(anonymous == .login)
          let actual = NativeRootRoute.resolve(loading: true, signedIn: true, consentRequired: consent, administrator: admin, activeMember: active, mfaRequired: mfa, resolvingEntry: pending)
          let expected: NativeRootRoute = pending ? .entry : mfa ? .mfa : consent ? .consent : (admin || active) ? .community : .onboarding
          precondition(actual == expected)
        }
      }
    }
  }
}
print("64 entry/auth combinations passed")
`;
  const cache = mkdtempSync(join(tmpdir(), "jaegun-entry-swift-"));
  assert.match(execFileSync("xcrun", ["swift", "-module-cache-path", cache, "-e", route + cases], { encoding: "utf8", timeout: 60000 }), /64 entry\/auth combinations passed/);
});

test("entry overlaps only minimal reads and keeps protected context behind exact consent", () => {
  const session = source("NativeSession.swift");
  const load = session.slice(session.indexOf("private func loadState("), session.indexOf("private func verifiedUserResponse"));
  assert.ok(load.indexOf("async let documentsRequest") < load.indexOf("await verifiedUserResponse"));
  assert.ok(load.indexOf("async let privacyRequest") < load.indexOf("await verifiedUserResponse"));
  assert.ok(load.includes('api.rpc("get_my_native_context")'));
  assert.ok(load.indexOf('state["consent_gate_open"] as? Bool == true') < load.indexOf('api.rpc("get_my_native_context")'));
  assert.ok(load.indexOf("context = row") < load.indexOf("consentRequired = false"));
  assert.ok(session.includes("loadState(verifiedUser: identity.user)"));
  assert.ok(session.includes("if signedIn { try await loadState() }"));
});

test("tab retention has scope isolation and hidden-tab network guards", () => {
  const tabs = source("NativeCommunityViews.swift");
  assert.ok(tabs.includes("TabView(selection: $selectedTab)"));
  assert.ok(!tabs.includes("switch selectedTab"));
  for (const boundary of ["session.sessionGeneration", '"organization_id"', '"status"', '"role"']) assert.ok(tabs.includes(boundary));
  assert.ok(tabs.includes(".environment(\\.nativeTabActive, selectedTab == id)"));
  assert.ok(source("NativeBoardFeedView.swift").includes("guard tabActive, scenePhase != .background"));
  assert.ok(source("NativeCommunityCollaboration.swift").includes("guard tabActive, scenePhase == .active"));
  assert.ok(source("NativeLiveViews.swift").includes("while !Task.isCancelled && tabActive && scenePhase == .active"));
});

test("native has five tabs and lazily reachable account, AI and role tools", () => {
  const tabs = source("NativeCommunityViews.swift");
  const workspace = tabs.slice(tabs.indexOf("private struct NativeCommunityTabWorkspace"), tabs.indexOf("struct NativeMoreView"));
  assert.equal((workspace.match(/\bTab\("/g) ?? []).length, 5);
  for (const id of ['home','events','posts','chats','more']) assert.ok(workspace.includes(`value: "${id}"`));
  assert.ok(tabs.includes('if isManager'));
  for (const view of ['NativeProfileView()', 'NativeAILandingView()', 'NativeOfficeHomeView()', 'NativeManagementHubView()']) assert.ok(tabs.includes(view));
});
