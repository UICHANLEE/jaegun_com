import text from "../legal/faith-private-records-2026-10-14.md?raw";

export const FAITH_CONSENT = {
  document_key: "faith_private_records", version: "2026-10-14",
  content_sha256: "4572f759bdcf51050b55f208af2513c63761db5127bc7c754175b4c8a31b8aa4",
  title: "개인 통독·QT 기록 이용 동의", url: "/legal/faith/2026-10-14",
} as const;
export const FAITH_CONSENT_TEXT = text;
export function parseFaithConsentStatus(value: unknown): boolean {
  const row = value as { accepted?: unknown; document?: Record<string, unknown> } | null;
  if (!row || typeof row.accepted !== "boolean" || !row.document
    || !Object.entries(FAITH_CONSENT).every(([key, expected]) => row.document![key] === expected)) {
    throw new Error("개인 기록 동의 문서의 버전·무결성을 확인하지 못했습니다.");
  }
  return row.accepted;
}
export async function verifyFaithConsentText() {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  const hex = [...new Uint8Array(digest)].map((value) => value.toString(16).padStart(2, "0")).join("");
  if (hex !== FAITH_CONSENT.content_sha256) throw new Error("개인 기록 안내가 변경되었습니다. 앱 업데이트를 확인해 주세요.");
}
