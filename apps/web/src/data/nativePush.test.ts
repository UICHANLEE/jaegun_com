import { describe, expect, it } from "vitest";
import {
  isNativePushBridge,
  validateNativePushRegistration,
} from "./nativePush";

describe("native push bridge contract", () => {
  it("accepts only an explicit callable bridge", () => {
    expect(isNativePushBridge({ requestPermissionAndRegistration: async () => ({}) })).toBe(true);
    expect(isNativePushBridge({ requestPermissionAndRegistration: true })).toBe(false);
    expect(isNativePushBridge(null)).toBe(false);
  });

  it("validates iOS and Android registration values before they leave the client", () => {
    expect(validateNativePushRegistration({
      installationId: "123e4567-e89b-42d3-a456-426614174000",
      platform: "ios",
      token: "a".repeat(64),
      appVersion: " 1.2.3 ",
    })).toEqual({
      installationId: "123e4567-e89b-42d3-a456-426614174000",
      platform: "ios",
      token: "a".repeat(64),
      appVersion: "1.2.3",
    });
    expect(() => validateNativePushRegistration({
      installationId: "123e4567-e89b-42d3-a456-426614174000",
      platform: "ios",
      token: "not-an-apns-token",
    })).toThrow(/알림 토큰/);
    expect(() => validateNativePushRegistration({
      installationId: "../installation",
      platform: "android",
      token: "android_token_value_1234567890",
    })).toThrow(/설치 식별자/);
  });
});
