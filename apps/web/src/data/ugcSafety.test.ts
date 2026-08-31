import { describe, expect, it } from "vitest";
import {
  assertNativeMediaUploadsAllowed,
  getUgcSubmissionErrorMessage,
  IOS_NATIVE_MEDIA_UPLOAD_NOTICE,
  isIosNativeMediaUploadDisabled,
  UGC_REJECTION_MESSAGE,
} from "./ugcSafety";

describe("official-client App Store UGC behavior", () => {
  it("disables media only in iOS native and unidentified native shells", () => {
    expect(isIosNativeMediaUploadDisabled({
      Capacitor: { isNativePlatform: () => true, getPlatform: () => "ios" },
    })).toBe(true);
    expect(isIosNativeMediaUploadDisabled({
      Capacitor: { isNativePlatform: () => true },
    })).toBe(true);
    expect(isIosNativeMediaUploadDisabled({
      Capacitor: { isNativePlatform: () => true, getPlatform: () => "android" },
    })).toBe(false);
    expect(isIosNativeMediaUploadDisabled({
      Capacitor: { isNativePlatform: () => false, getPlatform: () => "ios" },
    })).toBe(false);
    expect(isIosNativeMediaUploadDisabled({
      Capacitor: { isNativePlatform: () => { throw new Error("bridge unavailable"); } },
    })).toBe(true);
    expect(isIosNativeMediaUploadDisabled({})).toBe(false);
  });

  it("keeps web media uploads available while blocking bundled iOS upload calls", () => {
    expect(() => assertNativeMediaUploadsAllowed(1, {
      Capacitor: { isNativePlatform: () => false, getPlatform: () => "web" },
    })).not.toThrow();
    expect(() => assertNativeMediaUploadsAllowed(0, {
      Capacitor: { isNativePlatform: () => true, getPlatform: () => "ios" },
    })).not.toThrow();
    expect(() => assertNativeMediaUploadsAllowed(1, {
      Capacitor: { isNativePlatform: () => true, getPlatform: () => "ios" },
    })).toThrow(IOS_NATIVE_MEDIA_UPLOAD_NOTICE);
  });

  it("converts the generic server rejection token into respectful guidance", () => {
    expect(getUgcSubmissionErrorMessage(
      new Error("PostgresError: unsafe_content_rejected"),
      "등록하지 못했어요.",
    )).toBe(UGC_REJECTION_MESSAGE);
    expect(getUgcSubmissionErrorMessage(new Error("네트워크 오류"), "기본 오류"))
      .toBe("네트워크 오류");
    expect(getUgcSubmissionErrorMessage(null, "기본 오류")).toBe("기본 오류");
  });
});
