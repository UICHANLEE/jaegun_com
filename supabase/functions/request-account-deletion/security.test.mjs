import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  ACCOUNT_DELETION_CONFIRMATION,
  corsHeaders,
  isOriginAllowed,
  parseAccountDeletionRequest,
  parseAllowedOrigins,
  parseBearerToken,
  RequestValidationError,
  verifyPasswordUserWithCleanup,
  verifiedTokenHasAal2,
} from "./security.ts";

function jwt(claims) {
  const encode = (value) => Buffer.from(JSON.stringify(value))
    .toString("base64url");
  return `${encode({ alg: "RS256", typ: "JWT" })}.${encode(claims)}.signature`;
}

function deletionRequest(body, headers = {}) {
  return new Request("https://project.functions.supabase.co/request-account-deletion", {
    method: "POST",
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("allows exact configured web origins plus narrow native origins", () => {
  const allowed = parseAllowedOrigins(
    "https://jaegun.example, http://localhost:5173, capacitor://localhost",
  );
  assert.equal(isOriginAllowed("https://jaegun.example", allowed), true);
  assert.equal(isOriginAllowed("http://localhost:5173", allowed), true);
  assert.equal(isOriginAllowed("capacitor://localhost", allowed), true);
  assert.equal(isOriginAllowed("https://evil.example", allowed), false);
  assert.equal(isOriginAllowed("null", allowed), false);
  assert.equal(isOriginAllowed(null, allowed), true);

  const headers = corsHeaders("https://jaegun.example", allowed);
  assert.equal(headers.get("access-control-allow-origin"), "https://jaegun.example");
  assert.equal(headers.get("vary"), "Origin");
});

test("rejects wildcard, path-bearing, and insecure remote origin configuration", () => {
  assert.throws(() => parseAllowedOrigins("*"), /invalid_allowed_origin/);
  assert.throws(
    () => parseAllowedOrigins("https://jaegun.example/path"),
    /invalid_allowed_origin/,
  );
  assert.throws(
    () => parseAllowedOrigins("http://jaegun.example"),
    /insecure_allowed_origin/,
  );
});

test("parses only the explicit deletion payload", async () => {
  const result = await parseAccountDeletionRequest(deletionRequest({
    confirmation: ACCOUNT_DELETION_CONFIRMATION,
    reason: "  앱을 더 이상 사용하지 않음  ",
    password: "a long password with spaces",
  }));
  assert.deepEqual(result, {
    confirmation: ACCOUNT_DELETION_CONFIRMATION,
    reason: "앱을 더 이상 사용하지 않음",
    password: "a long password with spaces",
  });

  await assert.rejects(
    parseAccountDeletionRequest(deletionRequest({
      confirmation: ACCOUNT_DELETION_CONFIRMATION,
      admin: true,
    })),
    (error) => error instanceof RequestValidationError && error.code === "unexpected_field",
  );
});

test("rejects wrong media type, bad confirmation, malformed JSON, and oversized bodies", async () => {
  await assert.rejects(
    parseAccountDeletionRequest(deletionRequest("{}", { "content-type": "text/plain" })),
    (error) => error instanceof RequestValidationError && error.status === 415,
  );
  await assert.rejects(
    parseAccountDeletionRequest(deletionRequest({ confirmation: "delete" })),
    (error) => error instanceof RequestValidationError && error.code === "confirmation_mismatch",
  );
  await assert.rejects(
    parseAccountDeletionRequest(deletionRequest("{")),
    (error) => error instanceof RequestValidationError && error.code === "invalid_json",
  );
  await assert.rejects(
    parseAccountDeletionRequest(deletionRequest(JSON.stringify({
      confirmation: ACCOUNT_DELETION_CONFIRMATION,
      reason: "x".repeat(9000),
    }))),
    (error) => error instanceof RequestValidationError && error.status === 413,
  );
});

test("requires one syntactically valid bearer JWT", () => {
  const token = jwt({ sub: "user-id", aal: "aal2" });
  assert.equal(parseBearerToken(`Bearer ${token}`), token);
  assert.throws(() => parseBearerToken(null), /invalid_credentials/);
  assert.throws(() => parseBearerToken(`Basic ${token}`), /invalid_credentials/);
  assert.throws(() => parseBearerToken(`Bearer ${token},other`), /invalid_credentials/);
});

test("treats malformed supplied passwords as generic credentials failures", async () => {
  await assert.rejects(
    parseAccountDeletionRequest(deletionRequest({
      confirmation: ACCOUNT_DELETION_CONFIRMATION,
      password: "",
    })),
    (error) => error instanceof RequestValidationError &&
      error.status === 401 && error.code === "invalid_credentials",
  );
});

test("uses AAL2 only when verified token subject matches the verified user", () => {
  const token = jwt({ sub: "user-id", aal: "aal2" });
  assert.equal(verifiedTokenHasAal2(token, "user-id"), true);
  assert.equal(verifiedTokenHasAal2(token, "another-user"), false);
  assert.equal(verifiedTokenHasAal2(jwt({ sub: "user-id", aal: "aal1" }), "user-id"), false);
  assert.equal(verifiedTokenHasAal2("not.a.jwt", "user-id"), false);
});

test("always cleans up the ephemeral password session", async () => {
  let cleanupCount = 0;
  assert.equal(await verifyPasswordUserWithCleanup(
    "user-id",
    async () => "user-id",
    async () => { cleanupCount += 1; },
  ), true);
  assert.equal(cleanupCount, 1);

  assert.equal(await verifyPasswordUserWithCleanup(
    "user-id",
    async () => { throw new Error("provider failure"); },
    async () => { cleanupCount += 1; },
  ), false);
  assert.equal(cleanupCount, 2);

  assert.equal(await verifyPasswordUserWithCleanup(
    "user-id",
    async () => "user-id",
    async () => { throw new Error("cleanup failure"); },
  ), true);
  assert.equal(cleanupCount, 2);
});

test("entry point verifies JWT before AAL use and locally revokes verifier session", async () => {
  const source = await readFile(new URL("./index.ts", import.meta.url), "utf8");
  const getUserIndex = source.indexOf("auth.getUser(token)");
  const aalIndex = source.indexOf("verifiedTokenHasAal2(token, currentUser.id)");
  assert.ok(getUserIndex >= 0 && aalIndex > getUserIndex);
  assert.match(
    source,
    /passwordVerifier\.auth\.signOut\(\{\s*scope:\s*"local"\s*\}\)/,
  );
});
