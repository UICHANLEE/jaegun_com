import {
  isOfficialIosNativeClient,
  type CapacitorPlatformRuntime,
} from "../native/platform";

export const IOS_NATIVE_MEDIA_UPLOAD_NOTICE =
  "사진·영상 업로드는 안전 검수 준비 중이에요. 현재 iPhone 앱에서는 텍스트만 등록할 수 있고, 기존 미디어는 계속 볼 수 있어요.";

export const UGC_REJECTION_MESSAGE =
  "공동체 안전 기준에 맞지 않는 표현이 포함되어 등록하지 못했어요. 상대를 위협하거나 모욕하는 표현을 제거한 뒤 다시 시도해 주세요.";

/**
 * Product-behavior gate for the bundled official client only. Launch keeps the
 * existing web/API media policy unchanged, while the iOS shell stays text-only
 * until its media safety review is complete. Supabase cannot attest that a
 * request came from iOS, so this must never be cited as a backend authorization
 * boundary. An unidentified native platform takes the conservative client
 * path; real Android builds identify themselves as `android` and are unchanged.
 */
export function isIosNativeMediaUploadDisabled(
  runtime?: CapacitorPlatformRuntime,
) {
  return isOfficialIosNativeClient(runtime);
}

export function assertNativeMediaUploadsAllowed(
  fileCount: number,
  runtime?: CapacitorPlatformRuntime,
) {
  if (fileCount > 0 && isIosNativeMediaUploadDisabled(runtime)) {
    throw new Error(IOS_NATIVE_MEDIA_UPLOAD_NOTICE);
  }
}

export function getUgcSubmissionErrorMessage(reason: unknown, fallback: string) {
  const rawMessage = reason instanceof Error
    ? reason.message
    : reason && typeof reason === "object" && "message" in reason
      ? String((reason as { message?: unknown }).message ?? "")
      : "";

  return rawMessage.includes("unsafe_content_rejected")
    ? UGC_REJECTION_MESSAGE
    : rawMessage.trim() || fallback;
}
