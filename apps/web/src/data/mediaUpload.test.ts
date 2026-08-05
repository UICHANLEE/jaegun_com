import { beforeEach, describe, expect, it, vi } from "vitest";

const uploadMocks = vi.hoisted(() => ({
  start: vi.fn(),
  findPreviousUploads: vi.fn(async () => [{ uploadUrl: "https://stale.example/upload" }]),
  resumeFromPreviousUpload: vi.fn(),
  options: null as null | {
    onProgress?: (uploaded: number, total: number) => void;
    onSuccess?: () => void;
    storeFingerprintForResuming?: boolean;
  },
  createSignedUrl: vi.fn(async (path: string) => ({ data: { signedUrl: `signed:${path}` }, error: null })),
}));

vi.mock("./supabase", () => ({
  supabase: {
    auth: {
      getSession: vi.fn(async () => ({ data: { session: { access_token: "upload-token" } }, error: null })),
    },
    storage: {
      from: vi.fn(() => ({
        upload: vi.fn(async () => ({ error: null })),
        createSignedUrl: uploadMocks.createSignedUrl,
      })),
    },
  },
}));

vi.mock("tus-js-client", () => ({
  Upload: class MockUpload {
    constructor(_file: File, options: typeof uploadMocks.options) {
      uploadMocks.options = options;
    }

    findPreviousUploads = uploadMocks.findPreviousUploads;
    resumeFromPreviousUpload = uploadMocks.resumeFromPreviousUpload;

    start() {
      uploadMocks.start();
      uploadMocks.options?.onProgress?.(7, 7);
      uploadMocks.options?.onSuccess?.();
    }
  },
}));

import { uploadCommunityFile, validateMediaFile } from "./mediaUpload";

function fileOfSize(name: string, type: string, byteSize: number) {
  const file = new File([new Uint8Array(1)], name, { type });
  Object.defineProperty(file, "size", { value: byteSize });
  return file;
}

describe("media upload validation", () => {
  beforeEach(() => {
    uploadMocks.start.mockClear();
    uploadMocks.findPreviousUploads.mockClear();
    uploadMocks.resumeFromPreviousUpload.mockClear();
    uploadMocks.createSignedUrl.mockClear();
    uploadMocks.options = null;
  });

  it("accepts supported photos and videos within service limits", () => {
    expect(validateMediaFile(fileOfSize("photo.jpg", "image/jpeg", 15 * 1024 * 1024))).toBeNull();
    expect(validateMediaFile(fileOfSize("video.mp4", "video/mp4", 500 * 1024 * 1024))).toBeNull();
  });

  it("rejects oversized files and MIME types that private Storage does not allow", () => {
    expect(validateMediaFile(fileOfSize("photo.png", "image/png", 15 * 1024 * 1024 + 1))).toContain("15MB");
    expect(validateMediaFile(fileOfSize("video.mov", "video/quicktime", 500 * 1024 * 1024 + 1))).toContain("500MB");
    expect(validateMediaFile(fileOfSize("document.pdf", "application/pdf", 100))).toContain("JPG, PNG");
    expect(validateMediaFile(fileOfSize("animation.gif", "image/gif", 100))).toContain("JPG, PNG");
    expect(validateMediaFile(fileOfSize("vector.svg", "image/svg+xml", 100))).toContain("JPG, PNG");
  });

  it("never resumes a TUS URL whose fingerprint may belong to a different object path", async () => {
    const file = fileOfSize("large-video.mp4", "video/mp4", 7 * 1024 * 1024);
    const progress = vi.fn();

    await expect(uploadCommunityFile(file, "church/messages/chat/new-object.mp4", progress)).resolves.toEqual({
      path: "church/messages/chat/new-object.mp4",
      url: "signed:church/messages/chat/new-object.mp4",
    });

    expect(uploadMocks.start).toHaveBeenCalledTimes(1);
    expect(uploadMocks.findPreviousUploads).not.toHaveBeenCalled();
    expect(uploadMocks.resumeFromPreviousUpload).not.toHaveBeenCalled();
    expect(uploadMocks.options?.storeFingerprintForResuming).toBe(false);
    expect(progress).toHaveBeenLastCalledWith(1);
  });
});
