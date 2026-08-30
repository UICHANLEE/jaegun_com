import { describe, expect, it } from "vitest";
import {
  MAX_PASSWORD_LENGTH,
  MIN_NEW_PASSWORD_LENGTH,
  validateNewPassword,
} from "./authPolicy";

describe("new password policy", () => {
  it("requires a long passphrase without imposing composition tricks", () => {
    expect(MIN_NEW_PASSWORD_LENGTH).toBe(12);
    expect(validateNewPassword("short-pass")).toContain("12자");
    expect(validateNewPassword("길고 안전한 암호 문장입니다")).toBeNull();
  });

  it("rejects control characters and unreasonable input size", () => {
    expect(validateNewPassword(`valid-password\u0000`)).toContain("제어 문자");
    expect(validateNewPassword("x".repeat(MAX_PASSWORD_LENGTH + 1))).toContain("128자");
  });
});
