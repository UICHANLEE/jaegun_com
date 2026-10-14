import { describe, expect, it } from "vitest";
import {
  assertAcceptedConsentVersions,
  bundledCurrentConsentDocuments,
  classifyRequiredConsentDocuments,
  legalDocumentUrl,
  validateActiveConsentRows,
  type AcceptedConsentVersions,
  type RequiredConsentDocument,
} from "../data/legalConsentContract";
import {
  CURRENT_LEGAL_DOCUMENTS,
  LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION,
  LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION,
  findLegalDocument,
  type ConsentDocumentKey,
} from "../data/legalDocuments";

function rowFor(key: ConsentDocumentKey, version: string) {
  const document = findLegalDocument(key, version);
  if (!document) throw new Error(`missing fixture ${key}@${version}`);
  const compositeKey = `${key}@${version}`;
  return {
    document_key: key,
    version,
    locale: "ko-KR",
    title: LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION[compositeKey],
    document_url: legalDocumentUrl(key, version),
    content_sha256: LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION[compositeKey],
    required: true,
    effective_at: "2026-08-30T00:00:00+09:00",
    retired_at: null,
  };
}

function acceptedFor(documents: readonly RequiredConsentDocument[]): AcceptedConsentVersions {
  return Object.fromEntries(documents.map((document) => [document.key, document.version]));
}

describe("active legal-consent contract", () => {
  it("accepts the exact current five-document set and validates explicit decisions", async () => {
    const rows = CURRENT_LEGAL_DOCUMENTS.map((document) => rowFor(document.key, document.version));
    const documents = await validateActiveConsentRows(rows);
    const accepted = acceptedFor(documents);

    expect(classifyRequiredConsentDocuments(documents)).toBe("independent-v2");
    expect(documents.map((document) => document.key)).toEqual([
      "privacy_policy",
      "sensitive_information",
      "overseas_transfer",
      "terms_of_service",
      "community_guidelines",
    ]);
    expect(() => assertAcceptedConsentVersions(documents, accepted)).not.toThrow();
  });

  it("recognizes exact immutable historical contracts without mixing versions", async () => {
    const documents = await validateActiveConsentRows([
      rowFor("privacy_policy", "2026-08-27"),
      rowFor("community_guidelines", "2026-08-27"),
    ]);

    expect(classifyRequiredConsentDocuments(documents)).toBe("legacy-v1");
    const previous = CURRENT_LEGAL_DOCUMENTS.map((document) => rowFor(document.key, "2026-08-30"));
    expect(classifyRequiredConsentDocuments(await validateActiveConsentRows(previous))).toBe("independent-v2");
    const mixed = previous.map((row, index) => index === 0 ? rowFor(row.document_key, "2026-10-14") : row);
    await expect(validateActiveConsentRows(mixed)).rejects.toThrow("구성이 안전한 출시 계약과 일치하지 않습니다");
  });

  it("fails closed for a partial, duplicate, unknown, or extra submitted set", async () => {
    const current = bundledCurrentConsentDocuments();
    await expect(validateActiveConsentRows([
      rowFor("privacy_policy", "2026-08-30"),
      rowFor("community_guidelines", "2026-08-30"),
    ])).rejects.toThrow("구성이 안전한 출시 계약과 일치하지 않습니다");
    await expect(validateActiveConsentRows([
      rowFor("privacy_policy", "2026-08-27"),
      rowFor("privacy_policy", "2026-08-27"),
    ])).rejects.toThrow();
    await expect(validateActiveConsentRows([{
      ...rowFor("privacy_policy", "2026-08-27"),
      document_key: "unknown_document",
    }, rowFor("community_guidelines", "2026-08-27")])).rejects.toThrow("알 수 없는 필수 동의 문서");

    expect(() => assertAcceptedConsentVersions(current, {
      ...acceptedFor(current),
      arbitrary_runtime_key: "2026-08-30",
    } as AcceptedConsentVersions)).toThrow("현재 필수 동의 문서와 다른 항목");
  });

  it("rejects database metadata that diverges from the bundled immutable archive", async () => {
    const validRows = CURRENT_LEGAL_DOCUMENTS.map((document) => rowFor(document.key, document.version));
    await expect(validateActiveConsentRows(validRows.map((row, index) => (
      index === 0 ? { ...row, title: "변조된 제목" } : row
    )))).rejects.toThrow("제목이 배포된 본문과 일치하지 않습니다");
    await expect(validateActiveConsentRows(validRows.map((row, index) => (
      index === 1 ? { ...row, document_url: "/legal/sensitive-information/2026-08-30" } : row
    )))).rejects.toThrow("주소가 배포된 본문과 일치하지 않습니다");
    await expect(validateActiveConsentRows(validRows.map((row, index) => (
      index === 2 ? { ...row, content_sha256: "0".repeat(64) } : row
    )))).rejects.toThrow("본문의 무결성을 확인하지 못했습니다");
  });
});
