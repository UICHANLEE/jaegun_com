import { supabase, supabasePublicKey, supabaseUrl } from "./supabase";

const LARGE_FILE_THRESHOLD = 6 * 1024 * 1024;
const MAX_AVATAR_SIZE = 5 * 1024 * 1024;
const MAX_IMAGE_SIZE = 15 * 1024 * 1024;
const MAX_VIDEO_SIZE = 500 * 1024 * 1024;

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

const CANONICAL_EXTENSION_BY_MIME: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/avif": "avif",
  "image/heic": "heic",
  "image/heif": "heif",
  "video/mp4": "mp4",
  "video/quicktime": "mov",
  "video/webm": "webm",
};

const DIRECTORY_BY_PURPOSE = {
  post: "posts",
  message: "messages",
  organization_hero: "organization",
  application_evidence: "applications",
} as const;

export type MediaUploadPurpose =
  | "post"
  | "message"
  | "organization_hero"
  | "application_evidence"
  | "avatar";

export interface ApprovedMediaUpload {
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

export interface CommunityMediaUploadRequest {
  purpose: MediaUploadPurpose;
  targetId: string;
  /** Required for every purpose except avatar. */
  organizationId?: string;
  signal?: AbortSignal;
  /**
   * Called before bytes are uploaded so a caller can remove a partially
   * uploaded object even when signing or the following database write fails.
  */
  onObjectPathCreated?: (objectPath: string) => void;
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

function isSafePathSegment(value: unknown): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.length <= 200
    && value === value.trim()
    && value !== "."
    && value !== ".."
    && !value.includes("/")
    && !value.includes("\\")
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function abortError() {
  return new DOMException("업로드가 취소되었습니다.", "AbortError");
}

function throwIfAborted(signal?: AbortSignal) {
  if (signal?.aborted) throw abortError();
}

function mediaDestination(file: File, request: CommunityMediaUploadRequest) {
  if (!isSafePathSegment(request.targetId)) {
    throw new Error("안전한 업로드 대상을 확인할 수 없습니다.");
  }
  const extension = CANONICAL_EXTENSION_BY_MIME[file.type];
  if (!extension) throw new Error("안전한 업로드 파일 형식을 확인할 수 없습니다.");
  const objectId = crypto.randomUUID();

  if (request.purpose === "avatar") {
    return {
      bucket: "avatars" as const,
      path: `${request.targetId}/${objectId}.${extension}`,
    };
  }

  if (!isSafePathSegment(request.organizationId)) {
    throw new Error("업로드할 교회 정보를 확인할 수 없습니다.");
  }
  if (request.purpose === "organization_hero" && request.organizationId !== request.targetId) {
    throw new Error("교회 대표 사진의 업로드 대상이 현재 교회와 일치하지 않습니다.");
  }
  const directory = DIRECTORY_BY_PURPOSE[request.purpose];
  const targetDirectory = request.purpose === "organization_hero" ? "" : `/${request.targetId}`;
  return {
    bucket: "community-media" as const,
    path: `${request.organizationId}/${directory}${targetDirectory}/${objectId}.${extension}`,
  };
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

async function uploadDirectFile(
  file: File,
  destination: Pick<ApprovedMediaUpload, "bucket" | "path">,
  onProgress: (progress: number) => void,
  signal?: AbortSignal,
) {
  if (!supabase) throw new Error("Supabase가 연결되지 않았습니다.");
  throwIfAborted(signal);
  if (file.size < LARGE_FILE_THRESHOLD) {
    const { error } = await supabase.storage
      .from(destination.bucket)
      .upload(destination.path, file, { contentType: file.type, upsert: false });
    throwIfAborted(signal);
    if (error) throw error;
    onProgress(1);
    return;
  }

  const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
  throwIfAborted(signal);
  if (sessionError) throw sessionError;
  const accessToken = sessionData.session?.access_token;
  if (!accessToken) throw new Error("업로드를 계속하려면 다시 로그인해 주세요.");
  const uploadServerUrl = supabaseUrl;
  const uploadPublicKey = supabasePublicKey;
  if (!uploadServerUrl || !uploadPublicKey) throw new Error("업로드 서버 설정을 확인할 수 없습니다.");
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
      endpoint: `${uploadServerUrl}/storage/v1/upload/resumable`,
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: uploadPublicKey,
      },
      uploadDataDuringCreation: true,
      storeFingerprintForResuming: false,
      removeFingerprintOnSuccess: true,
      metadata: {
        bucketName: destination.bucket,
        objectName: destination.path,
        contentType: file.type,
        cacheControl: "3600",
      },
      chunkSize: 6 * 1024 * 1024,
      onError: (error) => settle(() => reject(signal?.aborted ? abortError() : error)),
      onProgress: (uploaded, total) => {
        if (!settled && !signal?.aborted) onProgress(total ? Math.min(Math.max(uploaded / total, 0), 1) : 0);
      },
      onSuccess: () => settle(() => {
        if (signal?.aborted) reject(abortError());
        else {
          onProgress(1);
          resolve();
        }
      }),
    });
    const onAbort = () => {
      try {
        const abortResult = typeof upload.abort === "function" ? upload.abort(false) : undefined;
        void Promise.resolve(abortResult).then(
          () => settle(() => reject(abortError())),
          () => settle(() => reject(abortError())),
        );
      } catch {
        settle(() => reject(abortError()));
      }
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
  throwIfAborted(request.signal);
  const signatureError = await validateMediaSignature(file);
  if (signatureError) throw new Error(signatureError);
  const kind = file.type.startsWith("video/") ? "video" as const : "image" as const;
  if (["organization_hero", "application_evidence", "avatar"].includes(request.purpose) && kind !== "image") {
    throw new Error("이 항목에는 사진 파일만 업로드할 수 있습니다.");
  }
  if (request.purpose === "avatar" && file.size > MAX_AVATAR_SIZE) {
    throw new Error("프로필 사진은 5MB까지 업로드할 수 있습니다.");
  }
  throwIfAborted(request.signal);

  const destination = mediaDestination(file, request);
  request.onObjectPathCreated?.(destination.path);
  throwIfAborted(request.signal);
  await uploadDirectFile(file, destination, onProgress, request.signal);
  throwIfAborted(request.signal);

  const previewTtlSeconds = 60;
  const signed = await supabase.storage
    .from(destination.bucket)
    .createSignedUrl(destination.path, previewTtlSeconds);
  throwIfAborted(request.signal);
  if (signed.error || !signed.data?.signedUrl) {
    throw signed.error ?? new Error("업로드 파일 URL을 만들 수 없습니다.");
  }
  return {
    ...destination,
    url: signed.data.signedUrl,
    kind,
    mimeType: file.type,
    byteSize: file.size,
  };
}
