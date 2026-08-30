import { describe, expect, it } from "vitest";
import { normalizeSupportEmail } from "./runtimeConfig";

describe("public support contact configuration", () => {
  it("accepts a normalized mailbox and rejects missing or unsafe values", () => {
    expect(normalizeSupportEmail(" Help@Jaegun.kr ")).toBe("help@jaegun.kr");
    expect(normalizeSupportEmail(undefined)).toBeNull();
    expect(normalizeSupportEmail("not-an-email")).toBeNull();
    expect(normalizeSupportEmail("support@example.org?subject=secret")).toBeNull();
    expect(normalizeSupportEmail("support@example.org")).toBeNull();
  });
});
