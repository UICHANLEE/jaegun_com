import { supabase, supabasePublicKey, supabaseUrl } from "./supabase";

const QUARANTINE_BUCKET = "community-media-quarantine";
const LARGE_FILE_THRESHOLD = 6 * 1024 * 1024;
const MAX_IMAGE_SIZE = 15 * 1024 * 1024;
const MAX_VIDEO_SIZE = 500 * 1024 * 1024;
const DEFAULT_APPROVAL_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_APPROVAL_POLL_INTERVAL_MS = 1_500;
const MAX_CONSECUTIVE_POLL_ERRORS = 3;

const ALLOWED_IMAGE_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/avif",
  "image/heic",
  "image/heif",
]);
const ALLOWED_VIDEO_TYPES = new Set([
  "video/mp4",
  "video/quicktime",
  "video/webm",
]);

const EXTENSIONS_BY_MIME: Readonly<Record<string, readonly string[]>> = {
  "image/jpeg": ["jpg", "jpeg"],
  "image/png": ["png"],
  "image/webp": ["webp"],
  "image/avif": ["avif"],
  "image/heic": ["heic"],
  "image/heif": ["heif"],
  "video/mp4": ["mp4", "m4v"],
  "video/quicktime": ["mov"],
  "video/webm": ["webm"],
};

export type MediaUploadPurpose =
  | "post"
  | "message"
  | "organization_hero"
  | "application_evidence"
  | "avatar";

export interface ApprovedMediaUpload {
  intentId: string;
  bucket: "community-media" | "avatars";
  path: string;
  url: string;
  kind: "image" | "video";
  mimeType: string;
  byteSize: number;
  width?: number;
  height?: number;
  durationSeconds?: number;
}

interface MediaApprovalPollingOptions {
  timeoutMs?: number;
  pollIntervalMs?: number;
  now?: () => number;
  wait?: (milliseconds: number, signal?: AbortSignal) => Promise<void>;
}

export interface CommunityMediaUploadRequest extends MediaApprovalPollingOptions {
  purpose: MediaUploadPurpose;
  targetId: string;
  signal?: AbortSignal;
  /**
   * Called as soon as the backend creates the intent. The approved path is the
   * cleanup handle; quarantine paths are deliberately never exposed or read.
   */
  onIntentCreated?: (approvedPath: string) => void;
}

interface UploadIntentContract {
  id: string;
  bucketId: typeof QUARANTINE_BUCKET;
  quarantinePath: string;
  approvedPath: string;
  approvedBucketId: "community-media" | "avatars";
  expiresAt: string;
  expectedMimeType: string;
  expectedByteSize: number;
  expectedKind: "image" | "video";
  status: "quarantine";
}

interface MediaIntentRow {
  id: string;
  purpose: MediaUploadPurpose;
  targetId: string;
  kind: "image" | "video";
  status: "quarantine" | "scanning" | "approved" | "attached" | "rejected" | "expired";
  rejectionCode?: string;
  approvedBucketId: "community-media" | "avatars";
  approvedPath: string;
  approvedMimeType?: string;
  approvedByteSize?: number;
  approvedWidth?: number;
  approvedHeight?: number;
  approvedDurationSeconds?: number;
  expiresAt: string;
}

function fileExtension(name: string) {
  const normalized = name.normalize("NFKC").trim().toLowerCase();
  const separator = normalized.lastIndexOf(".");
  return separator > -1 ? normalized.slice(separator + 1) : "";
}

function ascii(bytes: Uint8Array, start: number, length: number) {
  return String.fromCharCode(...bytes.slice(start, start + length));
}

function detectedMime(bytes: Uint8Array): string | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes.length >= 8
    && bytes[0] === 0x89
    && ascii(bytes, 1, 3) === "PNG"
    && bytes[4] === 0x0d
    && bytes[5] === 0x0a
    && bytes[6] === 0x1a
    && bytes[7] === 0x0a) return "image/png";
  if (bytes.length >= 12 && ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WEBP") return "image/webp";
  if (bytes.length >= 4 && bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3) return "video/webm";
  if (bytes.length >= 12 && ascii(bytes, 4, 4) === "ftyp") {
    const brand = ascii(bytes, 8, 4);
    if (brand === "avif" || brand === "avis") return "image/avif";
    if (["heic", "heix", "hevc", "hevx"].includes(brand)) return "image/heic";
    if (["heif", "heim", "heis", "mif1", "msf1"].includes(brand)) return "image/heif";
    if (brand === "qt  ") return "video/quicktime";
    return "video/mp4";
  }
  return null;
}

function rowOf(value: unknown): Record<string, unknown> | null {
  if (Array.isArray(value)) return rowOf(value[0]);
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}

function isSafeObjectPath(value: unknown): value is string {
  if (typeof value !== "string" || !value || value.length > 1_000) return false;
  if (value.startsWith("/") || value.includes("\\") || /[\u0000-\u001f\u007f]/u.test(value)) return false;
  return value.split("/").every((segment) => Boolean(segment) && segment !== "." && segment !== "..");
}

function requiredString(row: Record<string, unknown>, key: string) {
  const value = row[key];
  if (typeof value !== "string" || !value) throw new Error("업로드 승인 정보를 확인할 수 없습니다.");
  return value;
}

function optionalPositiveNumber(value: unknown) {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) && number > 0 ? number : undefined;
}

function parseUploadIntent(
  value: unknown,
  file: File,
  expectedKind: "image" | "video",
): UploadIntentContract {
  const row = rowOf(value);
  if (!row) throw new Error("안전한 업로드 공간을 만들지 못했습니다.");
  const bucketId = requiredString(row, "bucket_id");
  const quarantinePath = row.quarantine_path;
  const approvedPath = row.approved_path;
  const approvedBucketId = requiredString(row, "approved_bucket_id");
  const expectedByteSize = Number(row.expected_byte_size);
  const expiresAt = typeof row.expires_at === "string" ? row.expires_at : "";
  if (bucketId !== QUARANTINE_BUCKET
    || !isSafeObjectPath(quarantinePath)
    || !isSafeObjectPath(approvedPath)
    || !["community-media", "avatars"].includes(approvedBucketId)
    || row.status !== "quarantine"
    || row.expected_mime_type !== file.type
    || expectedByteSize !== file.size
    || !Number.isFinite(Date.parse(expiresAt))) {
    throw new Error("서버가 반환한 업로드 승인 정보가 요청과 일치하지 않습니다.");
  }
  return {
    id: requiredString(row, "id"),
    bucketId,
    quarantinePath,
    approvedPath,
    approvedBucketId: approvedBucketId as UploadIntentContract["approvedBucketId"],
    expiresAt,
    expectedMimeType: String(row.expected_mime_type),
    expectedByteSize,
    expectedKind,
    status: "quarantine",
  };
}

function parseMediaIntentRow(value: unknown): MediaIntentRow {
  const row = rowOf(value);
  if (!row) throw new Error("업로드 처리 상태를 확인할 수 없습니다.");
  const purpose = requiredString(row, "purpose");
  const kind = requiredString(row, "kind");
  const status = requiredString(row, "status");
  const approvedBucketId = requiredString(row, "approved_bucket_id");
  const approvedPath = row.approved_path;
  if (!["post", "message", "organization_hero", "application_evidence", "avatar"].includes(purpose)
    || !["image", "video"].includes(kind)
    || !["quarantine", "scanning", "approved", "attached", "rejected", "expired"].includes(status)
    || !["community-media", "avatars"].includes(approvedBucketId)
    || !isSafeObjectPath(approvedPath)) {
    throw new Error("업로드 처리 상태가 올바르지 않습니다.");
  }
  return {
    id: requiredString(row, "id"),
    purpose: purpose as MediaUploadPurpose,
    targetId: requiredString(row, "target_id"),
    kind: kind as MediaIntentRow["kind"],
    status: status as MediaIntentRow["status"],
    rejectionCode: typeof row.rejection_code === "string" ? row.rejection_code : undefined,
    approvedBucketId: approvedBucketId as MediaIntentRow["approvedBucketId"],
    approvedPath,
    approvedMimeType: typeof row.approved_mime_type === "string" ? row.approved_mime_type : undefined,
    approvedByteSize: optionalPositiveNumber(row.approved_byte_size),
    approvedWidth: optionalPositiveNumber(row.approved_width),
    approvedHeight: optionalPositiveNumber(row.approved_height),
    approvedDurationSeconds: row.approved_duration_seconds === 0
      ? 0
      : optionalPositiveNumber(row.approved_duration_seconds),
    expiresAt: requiredString(row, "expires_at"),
  };
}

function abortError() {
  return new DOMException("업로드가 취소되었습니다.", "AbortError");
}

function throwIfAborted(signal?: AbortSignal) {
  if (signal?.aborted) throw abortError();
}

function abortableDelay(milliseconds: number, signal?: AbortSignal): Promise<void> {
  if (milliseconds <= 0) return Promise.resolve();
  throwIfAborted(signal);
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, milliseconds);
    const onAbort = () => {
      window.clearTimeout(timeout);
      reject(abortError());
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function isNonRetryablePollError(error: unknown) {
  const row = rowOf(error);
  const code = String(row?.code ?? "");
  const status = Number(row?.status ?? 0);
  return code === "42501" || code === "PGRST301" || status === 401 || status === 403;
}

async function waitForMediaApproval(
  contract: UploadIntentContract,
  request: CommunityMediaUploadRequest,
): Promise<Omit<ApprovedMediaUpload, "url">> {
  if (!supabase) throw new Error("Supabase가 연결되지 않았습니다.");
  const now = request.now ?? (() => performance.now());
  const wait = request.wait ?? abortableDelay;
  const timeoutMs = Math.max(1, request.timeoutMs ?? DEFAULT_APPROVAL_TIMEOUT_MS);
  const pollIntervalMs = Math.max(0, request.pollIntervalMs ?? DEFAULT_APPROVAL_POLL_INTERVAL_MS);
  // Use a monotonic client deadline. Device wall clocks can be wrong; the
  // backend remains authoritative for the intent's absolute expiry.
  const deadline = now() + timeoutMs;
  let consecutiveErrors = 0;

  for (;;) {
    throwIfAborted(request.signal);
    let query = supabase
      .from("media_upload_intents")
      .select("id, purpose, target_id, kind, status, rejection_code, approved_bucket_id, approved_path, approved_mime_type, approved_byte_size, approved_width, approved_height, approved_duration_seconds, expires_at")
      .eq("id", contract.id);
    if (request.signal && typeof query.abortSignal === "function") query = query.abortSignal(request.signal);
    const result = await query.single();
    throwIfAborted(request.signal);

    if (result.error) {
      consecutiveErrors += 1;
      if (isNonRetryablePollError(result.error) || consecutiveErrors >= MAX_CONSECUTIVE_POLL_ERRORS) {
        throw new Error("업로드 처리 상태를 확인하지 못했습니다. 네트워크를 확인한 뒤 다시 시도해 주세요.");
      }
    } else {
      consecutiveErrors = 0;
      const row = parseMediaIntentRow(result.data);
      if (row.id !== contract.id
        || row.purpose !== request.purpose
        || row.targetId !== request.targetId
        || row.approvedBucketId !== contract.approvedBucketId
        || row.approvedPath !== contract.approvedPath) {
        throw new Error("업로드 승인 대상이 요청과 일치하지 않습니다.");
      }
      if (row.status === "rejected") {
        throw new Error(row.rejectionCode === "malware_detected"
          ? "안전하지 않은 파일이 감지되어 업로드가 차단되었습니다."
          : "파일 안전성 검사를 통과하지 못했습니다. 다른 원본 파일을 선택해 주세요.");
      }
      if (row.status === "expired") {
        throw new Error("업로드 승인 시간이 만료되었습니다. 파일을 다시 선택해 주세요.");
      }
      if (row.status === "attached") {
        throw new Error("이 업로드는 이미 다른 콘텐츠에 연결되었습니다. 파일을 다시 선택해 주세요.");
      }
      if (row.status === "approved") {
        if (!row.approvedMimeType || !row.approvedByteSize) {
          throw new Error("승인된 파일의 검사 결과가 완전하지 않습니다.");
        }
        if (row.kind !== contract.expectedKind
          || (row.kind === "image" && (!ALLOWED_IMAGE_TYPES.has(row.approvedMimeType) || row.approvedByteSize > MAX_IMAGE_SIZE))
          || (row.kind === "video" && (!ALLOWED_VIDEO_TYPES.has(row.approvedMimeType) || row.approvedByteSize > MAX_VIDEO_SIZE))) {
          throw new Error("승인된 파일 형식이 서비스 정책과 일치하지 않습니다.");
        }
        return {
          intentId: row.id,
          bucket: row.approvedBucketId,
          path: row.approvedPath,
          kind: row.kind,
          mimeType: row.approvedMimeType,
          byteSize: row.approvedByteSize,
          width: row.approvedWidth,
          height: row.approvedHeight,
          durationSeconds: row.approvedDurationSeconds,
        };
      }
    }

    const remaining = deadline - now();
    if (remaining <= 0) {
      throw new Error("파일 안전성 검사가 예상보다 오래 걸리고 있습니다. 잠시 후 다시 시도해 주세요.");
    }
    await wait(Math.min(pollIntervalMs, remaining), request.signal);
  }
}

export function validateMediaFile(file: File): string | null {
  if (!file.size) return "비어 있는 파일은 업로드할 수 없습니다.";
  if (!file.name || file.name.length > 180) return "파일 이름은 180자 이하로 입력해 주세요.";
  const allowedExtensions = EXTENSIONS_BY_MIME[file.type];
  if (allowedExtensions && !allowedExtensions.includes(fileExtension(file.name))) {
    return "파일 형식과 확장자가 일치하지 않습니다. 원본 사진이나 영상을 다시 선택해 주세요.";
  }
  if (ALLOWED_IMAGE_TYPES.has(file.type)) {
    return file.size <= MAX_IMAGE_SIZE ? null : "사진은 파일당 15MB까지 업로드할 수 있습니다.";
  }
  if (ALLOWED_VIDEO_TYPES.has(file.type)) {
    return file.size <= MAX_VIDEO_SIZE ? null : "영상은 파일당 500MB까지 업로드할 수 있습니다.";
  }
  return "JPG, PNG, WebP, AVIF, HEIC, HEIF 사진 또는 MP4, MOV, WebM 영상만 업로드할 수 있습니다.";
}

export async function validateMediaSignature(file: File): Promise<string | null> {
  const basicError = validateMediaFile(file);
  if (basicError) return basicError;
  const header = new Uint8Array(await file.slice(0, 32).arrayBuffer());
  const actualMime = detectedMime(header);
  if (!actualMime || actualMime !== file.type) {
    return "파일 내용과 표시된 형식이 일치하지 않습니다. 원본 파일을 다시 선택해 주세요.";
  }
  return null;
}

async function uploadQuarantineFile(
  file: File,
  contract: UploadIntentContract,
  onProgress: (progress: number) => void,
  signal?: AbortSignal,
) {
  if (!supabase) throw new Error("Supabase가 연결되지 않았습니다.");
  throwIfAborted(signal);
  if (file.size < LARGE_FILE_THRESHOLD) {
    const { error } = await supabase.storage
      .from(contract.bucketId)
      .upload(contract.quarantinePath, file, { contentType: file.type, upsert: false });
    throwIfAborted(signal);
    if (error) throw error;
    onProgress(1);
    return;
  }

  const { data: sessionData } = await supabase.auth.getSession();
  throwIfAborted(signal);
  const accessToken = sessionData.session?.access_token;
  if (!accessToken) throw new Error("업로드를 계속하려면 다시 로그인해 주세요.");
  const { Upload } = await import("tus-js-client");

  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const settle = (callback: () => void) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", onAbort);
      callback();
    };
    const upload = new Upload(file, {
      endpoint: `${supabaseUrl!}/storage/v1/upload/resumable`,
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: supabasePublicKey!,
      },
      uploadDataDuringCreation: true,
      storeFingerprintForResuming: false,
      removeFingerprintOnSuccess: true,
      metadata: {
        bucketName: contract.bucketId,
        objectName: contract.quarantinePath,
        contentType: file.type,
        cacheControl: "3600",
      },
      chunkSize: 6 * 1024 * 1024,
      onError: (error) => settle(() => reject(signal?.aborted ? abortError() : error)),
      onProgress: (uploaded, total) => onProgress(total ? uploaded / total : 0),
      onSuccess: () => settle(() => signal?.aborted ? reject(abortError()) : resolve()),
    });
    const onAbort = () => {
      const abortResult = typeof upload.abort === "function" ? upload.abort(false) : undefined;
      void Promise.resolve(abortResult).then(
        () => settle(() => reject(abortError())),
        () => settle(() => reject(abortError())),
      );
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();
    else upload.start();
  });
}

export async function uploadCommunityFile(
  file: File,
  request: CommunityMediaUploadRequest,
  onProgress: (progress: number) => void,
): Promise<ApprovedMediaUpload> {
  if (!supabase) throw new Error("Supabase가 연결되지 않았습니다.");
  if (!request.targetId || !request.purpose) throw new Error("안전한 업로드 대상을 확인할 수 없습니다.");
  throwIfAborted(request.signal);
  const signatureError = await validateMediaSignature(file);
  if (signatureError) throw new Error(signatureError);
  throwIfAborted(request.signal);

  const kind = file.type.startsWith("video/") ? "video" : "image";
  const intentResult = await supabase.rpc("create_media_upload_intent", {
    p_purpose: request.purpose,
    p_target_id: request.targetId,
    p_kind: kind,
    p_expected_mime_type: file.type,
    p_expected_byte_size: file.size,
  });
  if (intentResult.error) throw intentResult.error;
  const contract = parseUploadIntent(intentResult.data, file, kind);
  const expectedApprovedBucket = request.purpose === "avatar" ? "avatars" : "community-media";
  if (contract.approvedBucketId !== expectedApprovedBucket) {
    throw new Error("서버가 반환한 승인 저장소가 업로드 목적과 일치하지 않습니다.");
  }
  request.onIntentCreated?.(contract.approvedPath);
  throwIfAborted(request.signal);

  await uploadQuarantineFile(file, contract, onProgress, request.signal);
  const approved = await waitForMediaApproval(contract, request);
  throwIfAborted(request.signal);
  const signed = await supabase.storage.from(approved.bucket).createSignedUrl(approved.path, 60 * 60);
  throwIfAborted(request.signal);
  if (signed.error || !signed.data?.signedUrl) {
    throw signed.error ?? new Error("승인된 업로드 파일 URL을 만들 수 없습니다.");
  }
  return { ...approved, url: signed.data.signedUrl };
}
