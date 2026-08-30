import {
  CONSENT_DOCUMENT_KEYS,
  CURRENT_LEGAL_DOCUMENTS,
  LEGACY_LEGAL_DOCUMENT_VERSION,
  LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION,
  LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION,
  findLegalDocument,
  type ConsentDocumentKey,
} from "./legalDocuments";
import { supabase } from "./supabase";

export const LEGACY_REQUIRED_CONSENT_KEYS = [
  "privacy_policy",
  "community_guidelines",
] as const satisfies readonly ConsentDocumentKey[];

export const CURRENT_REQUIRED_CONSENT_KEYS = [
  "privacy_policy",
  "sensitive_information",
  "overseas_transfer",
  "terms_of_service",
  "community_guidelines",
] as const satisfies readonly ConsentDocumentKey[];

export type ConsentContract = "legacy-v1" | "independent-v2";

export interface RequiredConsentDocument {
  key: ConsentDocumentKey;
  version: string;
  title: string;
  documentUrl: string;
  required: true;
}

export interface ActiveConsentDocument extends RequiredConsentDocument {
  locale: "ko-KR";
  contentSha256: string;
  effectiveAt: string;
}

export type AcceptedConsentVersions = Partial<Record<ConsentDocumentKey, string>>;

interface ConsentDocumentRow {
  document_key?: unknown;
  version?: unknown;
  locale?: unknown;
  title?: unknown;
  document_url?: unknown;
  content_sha256?: unknown;
  required?: unknown;
  effective_at?: unknown;
  retired_at?: unknown;
}

const CONSENT_DOCUMENT_FIELDS = [
  "document_key",
  "version",
  "locale",
  "title",
  "document_url",
  "content_sha256",
  "required",
  "effective_at",
  "retired_at",
].join(", ");

const DOCUMENT_ROUTE_PREFIX: Readonly<Record<ConsentDocumentKey, string>> = {
  privacy_policy: "/legal/privacy",
  sensitive_information: "/legal/sensitive",
  overseas_transfer: "/legal/overseas",
  terms_of_service: "/legal/terms",
  community_guidelines: "/legal/community",
};

const KEY_ORDER = new Map<ConsentDocumentKey, number>(
  CONSENT_DOCUMENT_KEYS.map((key, index) => [key, index]),
);

function isConsentDocumentKey(value: unknown): value is ConsentDocumentKey {
  return typeof value === "string" && CONSENT_DOCUMENT_KEYS.includes(value as ConsentDocumentKey);
}

function requiredString(value: unknown, field: string) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`필수 동의 문서의 ${field} 값을 확인하지 못했습니다.`);
  }
  return value;
}

function sameKeys(actual: readonly ConsentDocumentKey[], expected: readonly ConsentDocumentKey[]) {
  if (actual.length !== expected.length) return false;
  const actualSet = new Set(actual);
  return actualSet.size === expected.length && expected.every((key) => actualSet.has(key));
}

export function legalDocumentUrl(key: ConsentDocumentKey, version: string) {
  return `${DOCUMENT_ROUTE_PREFIX[key]}/${encodeURIComponent(version)}`;
}

export function classifyRequiredConsentDocuments(
  documents: readonly Pick<RequiredConsentDocument, "key" | "version">[],
): ConsentContract {
  const keys = documents.map((document) => document.key);
  if (sameKeys(keys, LEGACY_REQUIRED_CONSENT_KEYS)
    && documents.every((document) => document.version === LEGACY_LEGAL_DOCUMENT_VERSION)) {
    return "legacy-v1";
  }
  if (sameKeys(keys, CURRENT_REQUIRED_CONSENT_KEYS)
    && documents.every((document) => (
      CURRENT_LEGAL_DOCUMENTS.find((current) => current.key === document.key)?.version === document.version
    ))) {
    return "independent-v2";
  }
  throw new Error("서버의 필수 동의 문서 구성이 안전한 출시 계약과 일치하지 않습니다.");
}

export function consentSetFingerprint(documents: readonly RequiredConsentDocument[]) {
  return documents
    .map((document) => `${document.key}@${document.version}:${document.documentUrl}`)
    .sort()
    .join("|");
}

export function assertAcceptedConsentVersions(
  documents: readonly RequiredConsentDocument[],
  accepted: AcceptedConsentVersions,
) {
  classifyRequiredConsentDocuments(documents);
  const activeKeys = new Set(documents.map((document) => document.key));
  const submittedKeys = Object.keys(accepted);
  if (submittedKeys.length !== documents.length || submittedKeys.some((key) => !isConsentDocumentKey(key) || !activeKeys.has(key))) {
    throw new Error("현재 필수 동의 문서와 다른 항목이 제출되었습니다.");
  }
  for (const key of CONSENT_DOCUMENT_KEYS) {
    const submittedVersion = accepted[key];
    if (!activeKeys.has(key)) {
      if (submittedVersion !== undefined) {
        throw new Error("현재 필수가 아닌 동의 문서가 제출되었습니다.");
      }
      continue;
    }
    const document = documents.find((candidate) => candidate.key === key);
    if (!document || submittedVersion !== document.version) {
      throw new Error("필수 동의 문서가 변경되었습니다. 새 내용을 확인해 주세요.");
    }
  }
}

export function buildSignupConsentMetadata(
  documents: readonly RequiredConsentDocument[],
  accepted: AcceptedConsentVersions,
) {
  const contract = classifyRequiredConsentDocuments(documents);
  assertAcceptedConsentVersions(documents, accepted);
  const acceptedRequiredConsents = Object.fromEntries(documents.map((document) => [
    document.key,
    { accepted: true, version: document.version },
  ]));
  const generic = {
    consent_contract: contract === "independent-v2" ? "required-consents-v2" : "required-consents-v1",
    accepted_required_consents: acceptedRequiredConsents,
  };
  if (contract === "independent-v2") return generic;
  const privacy = documents.find((document) => document.key === "privacy_policy")!;
  const community = documents.find((document) => document.key === "community_guidelines")!;
  return {
    ...generic,
    accepted_privacy: true,
    accepted_privacy_version: privacy.version,
    accepted_community: true,
    accepted_community_version: community.version,
  };
}

export function bundledCurrentConsentDocuments(): RequiredConsentDocument[] {
  return CURRENT_LEGAL_DOCUMENTS.map((document) => ({
    key: document.key,
    version: document.version,
    title: document.title,
    documentUrl: legalDocumentUrl(document.key, document.version),
    required: true,
  }));
}

export async function validateActiveConsentRows(rows: unknown): Promise<ActiveConsentDocument[]> {
  if (!Array.isArray(rows)) {
    throw new Error("필수 동의 문서를 불러오지 못했습니다.");
  }
  const documents = rows.map((value): ActiveConsentDocument => {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("필수 동의 문서 형식이 올바르지 않습니다.");
    }
    const row = value as ConsentDocumentRow;
    if (!isConsentDocumentKey(row.document_key)) {
      throw new Error("알 수 없는 필수 동의 문서가 반환되었습니다.");
    }
    const version = requiredString(row.version, "버전");
    const documentUrl = requiredString(row.document_url, "주소");
    const contentSha256 = requiredString(row.content_sha256, "해시");
    if (row.locale !== "ko-KR" || row.required !== true || row.retired_at != null) {
      throw new Error("활성 필수 동의 문서의 공개 상태가 올바르지 않습니다.");
    }
    return {
      key: row.document_key,
      version,
      locale: "ko-KR",
      title: requiredString(row.title, "제목"),
      documentUrl,
      contentSha256,
      effectiveAt: requiredString(row.effective_at, "시행 시각"),
      required: true,
    };
  });

  classifyRequiredConsentDocuments(documents);
  if (new Set(documents.map((document) => document.key)).size !== documents.length) {
    throw new Error("필수 동의 문서가 중복되었습니다.");
  }
  await Promise.all(documents.map(async (document) => {
    const bundled = findLegalDocument(document.key, document.version);
    if (!bundled) {
      throw new Error("이 앱에서 확인할 수 없는 필수 동의 문서 버전입니다. 앱을 새로고침해 주세요.");
    }
    if (document.documentUrl !== legalDocumentUrl(document.key, document.version)) {
      throw new Error("필수 동의 문서 주소가 배포된 본문과 일치하지 않습니다.");
    }
    if (document.title !== LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION[`${bundled.key}@${bundled.version}`]) {
      throw new Error("필수 동의 문서 제목이 배포된 본문과 일치하지 않습니다.");
    }
    if (document.contentSha256 !== LEGAL_DOCUMENT_SHA256_BY_KEY_VERSION[`${bundled.key}@${bundled.version}`]) {
      throw new Error("필수 동의 문서 본문의 무결성을 확인하지 못했습니다.");
    }
  }));

  return [...documents].sort((left, right) => (
    (KEY_ORDER.get(left.key) ?? Number.MAX_SAFE_INTEGER)
    - (KEY_ORDER.get(right.key) ?? Number.MAX_SAFE_INTEGER)
  ));
}

export async function fetchActiveConsentDocuments(signal?: AbortSignal) {
  if (!supabase) throw new Error("필수 동의 문서 서비스에 연결하지 못했습니다.");
  const request = supabase
    .from("consent_documents")
    .select(CONSENT_DOCUMENT_FIELDS)
    .eq("locale", "ko-KR")
    .eq("required", true)
    .is("retired_at", null)
    .order("document_key");
  const result = signal ? await request.abortSignal(signal) : await request;
  if (result.error) throw result.error;
  return validateActiveConsentRows(result.data);
}
