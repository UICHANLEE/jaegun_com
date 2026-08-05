import { supabase } from "./supabase";

const LARGE_FILE_THRESHOLD = 6 * 1024 * 1024;
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

export function validateMediaFile(file: File): string | null {
  if (ALLOWED_IMAGE_TYPES.has(file.type)) {
    return file.size <= MAX_IMAGE_SIZE ? null : "사진은 파일당 15MB까지 업로드할 수 있습니다.";
  }
  if (ALLOWED_VIDEO_TYPES.has(file.type)) {
    return file.size <= MAX_VIDEO_SIZE ? null : "영상은 파일당 500MB까지 업로드할 수 있습니다.";
  }
  return "JPG, PNG, WebP, AVIF, HEIC, HEIF 사진 또는 MP4, MOV, WebM 영상만 업로드할 수 있습니다.";
}

export async function uploadCommunityFile(
  file: File,
  objectPath: string,
  onProgress: (progress: number) => void,
): Promise<{ path: string; url: string }> {
  if (!supabase) throw new Error("Supabase가 연결되지 않았습니다.");
  if (!objectPath || objectPath.startsWith("/") || objectPath.includes("..")) {
    throw new Error("안전한 업로드 경로를 만들지 못했습니다.");
  }

  if (file.size < LARGE_FILE_THRESHOLD) {
    const { error } = await supabase.storage
      .from("community-media")
      .upload(objectPath, file, { contentType: file.type, upsert: false });
    if (error) throw error;
    onProgress(1);
    const { data } = await supabase.storage.from("community-media").createSignedUrl(objectPath, 60 * 60);
    if (!data?.signedUrl) throw new Error("업로드 파일 URL을 만들 수 없습니다.");
    return { path: objectPath, url: data.signedUrl };
  }

  const { data: sessionData } = await supabase.auth.getSession();
  const accessToken = sessionData.session?.access_token;
  if (!accessToken) throw new Error("업로드를 계속하려면 다시 로그인해 주세요.");
  const { Upload } = await import("tus-js-client");

  await new Promise<void>((resolve, reject) => {
    const upload = new Upload(file, {
      endpoint: `${import.meta.env.VITE_SUPABASE_URL}/storage/v1/upload/resumable`,
      headers: {
        authorization: `Bearer ${accessToken}`,
        apikey: import.meta.env.VITE_SUPABASE_ANON_KEY!,
      },
      uploadDataDuringCreation: true,
      storeFingerprintForResuming: false,
      removeFingerprintOnSuccess: true,
      metadata: {
        bucketName: "community-media",
        objectName: objectPath,
        contentType: file.type,
        cacheControl: "3600",
      },
      chunkSize: 6 * 1024 * 1024,
      onError: reject,
      onProgress: (uploaded, total) => onProgress(total ? uploaded / total : 0),
      onSuccess: () => resolve(),
    });
    // Each caller provides a unique, authorization-scoped objectPath. The TUS
    // library's default fingerprint does not include that path, so resuming a
    // previous URL can upload bytes to one object while the caller signs another.
    // Start this explicit destination directly; failed partial uploads expire on
    // the Storage service and are never reused for a different object path.
    upload.start();
  });

  const { data } = await supabase.storage.from("community-media").createSignedUrl(objectPath, 60 * 60);
  if (!data?.signedUrl) throw new Error("업로드 파일 URL을 만들 수 없습니다.");
  return { path: objectPath, url: data.signedUrl };
}
