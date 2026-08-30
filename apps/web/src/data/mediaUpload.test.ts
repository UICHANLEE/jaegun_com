import { beforeEach, describe, expect, it, vi } from "vitest";

const mediaMocks = vi.hoisted(() => {
  const state = {
    tusAutoComplete: true,
    onTusStart: undefined as undefined | (() => void),
  };
  const calls = {
    rpc: vi.fn(),
    storageFrom: vi.fn(),
    upload: vi.fn(async () => ({ error: null })),
    createSignedUrl: vi.fn(async (path: string): Promise<{
      data: { signedUrl: string | null };
      error: Error | null;
    }> => ({ data: { signedUrl: `signed:${path}` }, error: null })),
    getSession: vi.fn(async () => ({
      data: { session: { access_token: "upload-token" } },
      error: null,
    })),
    tusStart: vi.fn(),
    tusAbort: vi.fn(async () => undefined),
  };
  const tus = {
    options: null as null | Record<string, unknown>,
  };
  return { state, calls, tus };
});

vi.mock("./supabase", () => ({
  supabasePublicKey: "sb_publishable_test_public_key_1234567890",
  supabaseUrl: "https://project.supabase.co",
  supabase: {
    auth: { getSession: mediaMocks.calls.getSession },
    rpc: mediaMocks.calls.rpc,
    storage: {
      from: vi.fn((bucket: string) => {
        mediaMocks.calls.storageFrom(bucket);
        return {
          upload: mediaMocks.calls.upload,
          createSignedUrl: mediaMocks.calls.createSignedUrl,
        };
      }),
    },
  },
}));

vi.mock("tus-js-client", () => ({
  Upload: class MockUpload {
    constructor(_file: File, options: Record<string, unknown>) {
      mediaMocks.tus.options = options;
    }

    start() {
      mediaMocks.calls.tusStart();
      mediaMocks.state.onTusStart?.();
      const options = mediaMocks.tus.options as {
        onProgress?: (uploaded: number, total: number) => void;
        onSuccess?: () => void;
      };
      options.onProgress?.(7, 14);
      if (mediaMocks.state.tusAutoComplete) options.onSuccess?.();
    }

    abort() {
      return mediaMocks.calls.tusAbort();
    }
  },
}));

import {
  type CommunityMediaUploadRequest,
  type MediaUploadPurpose,
  uploadCommunityFile,
  validateMediaFile,
  validateMediaSignature,
} from "./mediaUpload";

const FILE_HEADERS: Readonly<Record<string, readonly number[]>> = {
  "image/jpeg": [0xff, 0xd8, 0xff, 0xe0],
  "image/png": [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  "video/mp4": [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d],
  "video/quicktime": [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20],
};
const ORGANIZATION_ID = "40000000-0000-4000-8000-000000000004";
const TARGET_ID = "20000000-0000-4000-8000-000000000002";
const USER_ID = "30000000-0000-4000-8000-000000000003";
const CANONICAL_UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function fileOfSize(name: string, type: string, byteSize: number) {
  const file = new File([Uint8Array.from(FILE_HEADERS[type] ?? [1]).buffer], name, { type });
  Object.defineProperty(file, "size", { value: byteSize });
  return file;
}

function expectFinalObjectPath(path: string, parentSegments: readonly string[], extension: string) {
  const segments = path.split("/");
  expect(segments.slice(0, -1)).toEqual(parentSegments);
  const filenameSegments = (segments.at(-1) ?? "").split(".");
  expect(filenameSegments).toHaveLength(2);
  expect(filenameSegments[0]).toMatch(CANONICAL_UUID_V4);
  expect(filenameSegments[1]).toBe(extension);
}

function uploadRequest(
  purpose: MediaUploadPurpose = "message",
  overrides: Partial<CommunityMediaUploadRequest> = {},
): CommunityMediaUploadRequest {
  const targetId = purpose === "avatar"
    ? USER_ID
    : purpose === "organization_hero"
      ? ORGANIZATION_ID
      : TARGET_ID;
  return {
    purpose,
    targetId,
    ...(purpose === "avatar" ? {} : { organizationId: ORGANIZATION_ID }),
    ...overrides,
  };
}

describe("direct private media upload", () => {
  beforeEach(() => {
    mediaMocks.state.tusAutoComplete = true;
    mediaMocks.state.onTusStart = undefined;
    mediaMocks.tus.options = null;
    for (const mock of Object.values(mediaMocks.calls)) mock.mockClear();
    mediaMocks.calls.upload.mockResolvedValue({ error: null });
    mediaMocks.calls.createSignedUrl.mockImplementation(async (path: string) => ({
      data: { signedUrl: `signed:${path}` },
      error: null,
    }));
    mediaMocks.calls.getSession.mockResolvedValue({
      data: { session: { access_token: "upload-token" } },
      error: null,
    });
  });

  it("accepts supported photos and videos within service limits", () => {
    expect(validateMediaFile(fileOfSize("photo.jpg", "image/jpeg", 15 * 1024 * 1024))).toBeNull();
    expect(validateMediaFile(fileOfSize("video.mp4", "video/mp4", 500 * 1024 * 1024))).toBeNull();
  });

  it("uses canonical UUID fixtures that match the database path contract", () => {
    expect(ORGANIZATION_ID).toMatch(CANONICAL_UUID_V4);
    expect(TARGET_ID).toMatch(CANONICAL_UUID_V4);
    expect(USER_ID).toMatch(CANONICAL_UUID_V4);
  });

  it("rejects oversized, empty, misleading, and unsupported files", async () => {
    expect(validateMediaFile(new File([], "empty.jpg", { type: "image/jpeg" }))).toContain("비어 있는");
    expect(validateMediaFile(fileOfSize("photo.png", "image/jpeg", 100))).toContain("확장자");
    expect(validateMediaFile(fileOfSize("photo.png", "image/png", 15 * 1024 * 1024 + 1))).toContain("15MB");
    expect(validateMediaFile(fileOfSize("video.mov", "video/quicktime", 500 * 1024 * 1024 + 1))).toContain("500MB");
    expect(validateMediaFile(fileOfSize("document.pdf", "application/pdf", 100))).toContain("JPG, PNG");
    expect(await validateMediaSignature(new File([
      Uint8Array.from(FILE_HEADERS["image/png"]).buffer,
    ], "forged.jpg", { type: "image/jpeg" }))).toContain("파일 내용");
  });

  it.each([
    ["post", "community-media", [ORGANIZATION_ID, "posts", TARGET_ID], 60],
    ["message", "community-media", [ORGANIZATION_ID, "messages", TARGET_ID], 60],
    ["application_evidence", "community-media", [ORGANIZATION_ID, "applications", TARGET_ID], 60],
    ["organization_hero", "community-media", [ORGANIZATION_ID, "organization"], 60],
    ["avatar", "avatars", [USER_ID], 60],
  ] as const)("uploads %s directly to its final private path", async (
    purpose,
    bucket,
    parentSegments,
    previewTtlSeconds,
  ) => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    const onObjectPathCreated = vi.fn();
    const progress = vi.fn();

    const uploaded = await uploadCommunityFile(
      file,
      uploadRequest(purpose, { onObjectPathCreated }),
      progress,
    );
    const path = onObjectPathCreated.mock.calls[0]?.[0] as string;

    expectFinalObjectPath(path, parentSegments, "jpg");
    expect(uploaded).toEqual({
      bucket,
      path,
      url: `signed:${path}`,
      kind: "image",
      mimeType: "image/jpeg",
      byteSize: 1_024,
    });
    expect(mediaMocks.calls.upload).toHaveBeenLastCalledWith(
      path,
      file,
      { contentType: "image/jpeg", upsert: false },
    );
    expect(mediaMocks.calls.createSignedUrl).toHaveBeenLastCalledWith(path, previewTtlSeconds);
    expect(mediaMocks.calls.storageFrom).toHaveBeenNthCalledWith(
      mediaMocks.calls.storageFrom.mock.calls.length - 1,
      bucket,
    );
    expect(mediaMocks.calls.storageFrom).toHaveBeenLastCalledWith(bucket);
    expect(progress).toHaveBeenLastCalledWith(1);
  });

  it("never creates an intent or writes to quarantine", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);

    await uploadCommunityFile(file, uploadRequest("post"), vi.fn());

    expect(mediaMocks.calls.rpc).not.toHaveBeenCalled();
    expect(mediaMocks.calls.storageFrom).not.toHaveBeenCalledWith("community-media-quarantine");
  });

  it("uses the final community-media path for large resumable uploads", async () => {
    const file = fileOfSize("large-video.mp4", "video/mp4", 7 * 1024 * 1024);
    const onObjectPathCreated = vi.fn();
    const progress = vi.fn();

    await uploadCommunityFile(file, uploadRequest("message", { onObjectPathCreated }), progress);

    const path = onObjectPathCreated.mock.calls[0]?.[0] as string;
    const options = mediaMocks.tus.options as {
      endpoint: string;
      headers: Record<string, string>;
      metadata: Record<string, string>;
      storeFingerprintForResuming: boolean;
      removeFingerprintOnSuccess: boolean;
    };
    expectFinalObjectPath(path, [ORGANIZATION_ID, "messages", TARGET_ID], "mp4");
    expect(mediaMocks.calls.tusStart).toHaveBeenCalledTimes(1);
    expect(options.endpoint).toBe("https://project.supabase.co/storage/v1/upload/resumable");
    expect(options.headers).toMatchObject({ authorization: "Bearer upload-token" });
    expect(options.storeFingerprintForResuming).toBe(false);
    expect(options.removeFingerprintOnSuccess).toBe(true);
    expect(options.metadata).toMatchObject({
      bucketName: "community-media",
      objectName: path,
      contentType: "video/mp4",
    });
    expect(progress).toHaveBeenCalledWith(0.5);
    expect(progress).toHaveBeenLastCalledWith(1);
    expect(mediaMocks.calls.storageFrom).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.storageFrom).toHaveBeenCalledWith("community-media");
  });

  it("aborts an in-flight TUS upload and leaves the path available for cleanup", async () => {
    const file = fileOfSize("large-video.mp4", "video/mp4", 7 * 1024 * 1024);
    const controller = new AbortController();
    const onObjectPathCreated = vi.fn();
    let notifyStarted!: () => void;
    const started = new Promise<void>((resolve) => { notifyStarted = resolve; });
    mediaMocks.state.tusAutoComplete = false;
    mediaMocks.state.onTusStart = notifyStarted;

    const upload = uploadCommunityFile(
      file,
      uploadRequest("message", { signal: controller.signal, onObjectPathCreated }),
      vi.fn(),
    );
    await started;
    controller.abort();

    await expect(upload).rejects.toMatchObject({ name: "AbortError" });
    expect(onObjectPathCreated).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.tusAbort).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
  });

  it("checks abort again after a small upload so the caller can clean partial bytes", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    const controller = new AbortController();
    const onObjectPathCreated = vi.fn();
    mediaMocks.calls.upload.mockImplementationOnce(async () => {
      controller.abort();
      return { error: null };
    });

    await expect(uploadCommunityFile(
      file,
      uploadRequest("post", { signal: controller.signal, onObjectPathCreated }),
      vi.fn(),
    )).rejects.toMatchObject({ name: "AbortError" });
    expect(onObjectPathCreated).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
  });

  it("keeps a cleanup handle when signing fails after bytes are stored", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    const onObjectPathCreated = vi.fn();
    mediaMocks.calls.createSignedUrl.mockResolvedValueOnce({
      data: { signedUrl: null },
      error: new Error("signing failed"),
    });

    await expect(uploadCommunityFile(
      file,
      uploadRequest("post", { onObjectPathCreated }),
      vi.fn(),
    )).rejects.toThrow("signing failed");
    expect(onObjectPathCreated).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.upload).toHaveBeenCalledTimes(1);
  });

  it("fails closed for invalid scopes and image-only destinations", async () => {
    const photo = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    const video = fileOfSize("video.mp4", "video/mp4", 1_024);

    await expect(uploadCommunityFile(
      photo,
      uploadRequest("post", { organizationId: "../other" }),
      vi.fn(),
    )).rejects.toThrow("교회 정보");
    await expect(uploadCommunityFile(
      photo,
      uploadRequest("message", { targetId: "../other" }),
      vi.fn(),
    )).rejects.toThrow("업로드 대상");
    await expect(uploadCommunityFile(
      video,
      uploadRequest("organization_hero"),
      vi.fn(),
    )).rejects.toThrow("사진 파일만");
    await expect(uploadCommunityFile(
      fileOfSize("avatar.jpg", "image/jpeg", 5 * 1024 * 1024 + 1),
      uploadRequest("avatar"),
      vi.fn(),
    )).rejects.toThrow("5MB");
    expect(mediaMocks.calls.upload).not.toHaveBeenCalled();
    expect(mediaMocks.calls.tusStart).not.toHaveBeenCalled();
  });
});
