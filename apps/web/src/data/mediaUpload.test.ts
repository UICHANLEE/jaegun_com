import { beforeEach, describe, expect, it, vi } from "vitest";

const mediaMocks = vi.hoisted(() => {
  const state = {
    intentId: "10000000-0000-4000-8000-000000000001",
    targetId: "20000000-0000-4000-8000-000000000002",
    purpose: "message",
    quarantinePath: "30000000-0000-4000-8000-000000000003/10000000-0000-4000-8000-000000000001/upload.mp4",
    approvedPath: "40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000001.mp4",
    fileSize: 7 * 1024 * 1024,
    fileType: "video/mp4",
    pollRows: [] as Array<Record<string, unknown>>,
    pollErrors: [] as unknown[],
    tusAutoComplete: true,
    onTusStart: undefined as undefined | (() => void),
  };
  const calls = {
    rpc: vi.fn(),
    storageFrom: vi.fn(),
    upload: vi.fn(async () => ({ error: null })),
    createSignedUrl: vi.fn(async (path: string) => ({ data: { signedUrl: `signed:${path}` }, error: null })),
    queryAbortSignal: vi.fn(),
    tusStart: vi.fn(),
    tusAbort: vi.fn(async () => undefined),
  };
  const tus = {
    options: null as null | Record<string, unknown>,
  };
  return { state, calls, tus };
});

function intentContract() {
  return {
    id: mediaMocks.state.intentId,
    bucket_id: "community-media-quarantine",
    quarantine_path: mediaMocks.state.quarantinePath,
    approved_path: mediaMocks.state.approvedPath,
    approved_bucket_id: "community-media",
    expires_at: "2099-01-01T00:00:00.000Z",
    expected_mime_type: mediaMocks.state.fileType,
    expected_byte_size: mediaMocks.state.fileSize,
    status: "quarantine",
  };
}

function intentRow(overrides: Record<string, unknown> = {}) {
  return {
    id: mediaMocks.state.intentId,
    purpose: mediaMocks.state.purpose,
    target_id: mediaMocks.state.targetId,
    kind: mediaMocks.state.fileType.startsWith("video/") ? "video" : "image",
    status: "approved",
    rejection_code: null,
    approved_bucket_id: "community-media",
    approved_path: mediaMocks.state.approvedPath,
    approved_mime_type: mediaMocks.state.fileType,
    approved_byte_size: mediaMocks.state.fileSize,
    approved_width: 1920,
    approved_height: 1080,
    approved_duration_seconds: 12.5,
    expires_at: "2099-01-01T00:00:00.000Z",
    ...overrides,
  };
}

vi.mock("./supabase", () => {
  const query: Record<string, ReturnType<typeof vi.fn>> = {};
  query.select = vi.fn(() => query);
  query.eq = vi.fn(() => query);
  query.abortSignal = vi.fn((signal: AbortSignal) => {
    mediaMocks.calls.queryAbortSignal(signal);
    return query;
  });
  query.single = vi.fn(async () => {
    const error = mediaMocks.state.pollErrors.shift();
    if (error) return { data: null, error };
    return { data: mediaMocks.state.pollRows.shift() ?? intentRow(), error: null };
  });
  return {
    supabasePublicKey: "sb_publishable_test_public_key_1234567890",
    supabaseUrl: "https://project.supabase.co",
    supabase: {
      auth: {
        getSession: vi.fn(async () => ({ data: { session: { access_token: "upload-token" } }, error: null })),
      },
      rpc: vi.fn(async (name: string, args: Record<string, unknown>) => {
        mediaMocks.calls.rpc(name, args);
        return name === "create_media_upload_intent"
          ? { data: intentContract(), error: null }
          : { data: null, error: new Error("unexpected_rpc") };
      }),
      from: vi.fn(() => query),
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
  };
});

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
      options.onProgress?.(7, 7);
      if (mediaMocks.state.tusAutoComplete) options.onSuccess?.();
    }

    abort() {
      return mediaMocks.calls.tusAbort();
    }
  },
}));

import { uploadCommunityFile, validateMediaFile, validateMediaSignature } from "./mediaUpload";

const FILE_HEADERS: Readonly<Record<string, readonly number[]>> = {
  "image/jpeg": [0xff, 0xd8, 0xff, 0xe0],
  "image/png": [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  "video/mp4": [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d],
  "video/quicktime": [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20],
};

function fileOfSize(name: string, type: string, byteSize: number) {
  const file = new File([Uint8Array.from(FILE_HEADERS[type] ?? [1]).buffer], name, { type });
  Object.defineProperty(file, "size", { value: byteSize });
  return file;
}

function configureFile(file: File, purpose = "message") {
  mediaMocks.state.fileSize = file.size;
  mediaMocks.state.fileType = file.type;
  mediaMocks.state.purpose = purpose;
}

function uploadRequest(overrides: Record<string, unknown> = {}) {
  return {
    purpose: mediaMocks.state.purpose as "message",
    targetId: mediaMocks.state.targetId,
    wait: vi.fn(async () => undefined),
    ...overrides,
  };
}

describe("media upload validation", () => {
  beforeEach(() => {
    mediaMocks.state.intentId = "10000000-0000-4000-8000-000000000001";
    mediaMocks.state.targetId = "20000000-0000-4000-8000-000000000002";
    mediaMocks.state.purpose = "message";
    mediaMocks.state.quarantinePath = "30000000-0000-4000-8000-000000000003/10000000-0000-4000-8000-000000000001/upload.mp4";
    mediaMocks.state.approvedPath = "40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000001.mp4";
    mediaMocks.state.fileSize = 7 * 1024 * 1024;
    mediaMocks.state.fileType = "video/mp4";
    mediaMocks.state.pollRows = [];
    mediaMocks.state.pollErrors = [];
    mediaMocks.state.tusAutoComplete = true;
    mediaMocks.state.onTusStart = undefined;
    mediaMocks.tus.options = null;
    for (const mock of Object.values(mediaMocks.calls)) mock.mockClear();
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

  it("rejects empty files, misleading extensions, and forged MIME metadata", async () => {
    expect(validateMediaFile(new File([], "empty.jpg", { type: "image/jpeg" }))).toContain("비어 있는");
    expect(validateMediaFile(fileOfSize("photo.png", "image/jpeg", 100))).toContain("확장자");
    expect(await validateMediaSignature(new File([
      Uint8Array.from(FILE_HEADERS["image/png"]).buffer,
    ], "forged.jpg", { type: "image/jpeg" }))).toContain("파일 내용");
  });

  it("creates an intent, uploads only to quarantine, polls, then signs only the approved object", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    configureFile(file);
    mediaMocks.state.quarantinePath = "user/intent/upload.jpg";
    mediaMocks.state.approvedPath = "org/messages/chat/intent.jpg";
    mediaMocks.state.pollRows = [
      intentRow({ status: "scanning", approved_mime_type: null, approved_byte_size: null }),
      intentRow({
        approved_mime_type: "image/webp",
        approved_byte_size: 640,
        approved_width: 800,
        approved_height: 600,
        approved_duration_seconds: null,
      }),
    ];
    const progress = vi.fn();
    const onIntentCreated = vi.fn();

    await expect(uploadCommunityFile(file, uploadRequest({ onIntentCreated }), progress)).resolves.toEqual({
      intentId: mediaMocks.state.intentId,
      bucket: "community-media",
      path: mediaMocks.state.approvedPath,
      url: `signed:${mediaMocks.state.approvedPath}`,
      kind: "image",
      mimeType: "image/webp",
      byteSize: 640,
      width: 800,
      height: 600,
      durationSeconds: undefined,
    });

    expect(mediaMocks.calls.rpc).toHaveBeenCalledWith("create_media_upload_intent", {
      p_purpose: "message",
      p_target_id: mediaMocks.state.targetId,
      p_kind: "image",
      p_expected_mime_type: "image/jpeg",
      p_expected_byte_size: 1_024,
    });
    expect(onIntentCreated).toHaveBeenCalledWith(mediaMocks.state.approvedPath);
    expect(mediaMocks.calls.upload).toHaveBeenCalledWith(
      mediaMocks.state.quarantinePath,
      file,
      { contentType: "image/jpeg", upsert: false },
    );
    expect(mediaMocks.calls.storageFrom.mock.calls.map(([bucket]) => bucket)).toEqual([
      "community-media-quarantine",
      "community-media",
    ]);
    expect(mediaMocks.calls.createSignedUrl).toHaveBeenCalledWith(mediaMocks.state.approvedPath, 3600);
    expect(progress).toHaveBeenLastCalledWith(1);
  });

  it("uses the intent quarantine destination for TUS and never resumes a stale upload URL", async () => {
    const file = fileOfSize("large-video.mp4", "video/mp4", 7 * 1024 * 1024);
    configureFile(file);
    const progress = vi.fn();

    await uploadCommunityFile(file, uploadRequest(), progress);

    const options = mediaMocks.tus.options as {
      metadata: Record<string, string>;
      storeFingerprintForResuming: boolean;
    };
    expect(mediaMocks.calls.tusStart).toHaveBeenCalledTimes(1);
    expect(options.storeFingerprintForResuming).toBe(false);
    expect(options.metadata).toMatchObject({
      bucketName: "community-media-quarantine",
      objectName: mediaMocks.state.quarantinePath,
      contentType: "video/mp4",
    });
    expect(progress).toHaveBeenLastCalledWith(1);
    expect(mediaMocks.calls.storageFrom).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.storageFrom).toHaveBeenCalledWith("community-media");
  });

  it("does not sign or expose quarantine when the scanner rejects the file", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    configureFile(file);
    mediaMocks.state.quarantinePath = "user/intent/upload.jpg";
    mediaMocks.state.approvedPath = "org/messages/chat/intent.jpg";
    mediaMocks.state.pollRows = [intentRow({
      status: "rejected",
      rejection_code: "malware_detected",
      approved_mime_type: null,
      approved_byte_size: null,
    })];

    await expect(uploadCommunityFile(file, uploadRequest(), vi.fn())).rejects.toThrow("안전하지 않은 파일");
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
    expect(mediaMocks.calls.storageFrom).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.storageFrom).toHaveBeenCalledWith("community-media-quarantine");
  });

  it("stops polling at a deterministic bounded deadline without real timers", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    configureFile(file);
    mediaMocks.state.quarantinePath = "user/intent/upload.jpg";
    mediaMocks.state.approvedPath = "org/messages/chat/intent.jpg";
    mediaMocks.state.pollRows = Array.from({ length: 4 }, () => intentRow({
      status: "scanning",
      approved_mime_type: null,
      approved_byte_size: null,
    }));
    let currentTime = 1_000;
    const wait = vi.fn(async (milliseconds: number) => { currentTime += milliseconds; });

    await expect(uploadCommunityFile(file, uploadRequest({
      timeoutMs: 25,
      pollIntervalMs: 10,
      now: () => currentTime,
      wait,
    }), vi.fn())).rejects.toThrow("예상보다 오래");

    expect(wait).toHaveBeenCalledTimes(3);
    expect(wait.mock.calls.map(([milliseconds]) => milliseconds)).toEqual([10, 10, 5]);
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
  });

  it("aborts an in-flight approval wait without signing an object", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    configureFile(file);
    mediaMocks.state.quarantinePath = "user/intent/upload.jpg";
    mediaMocks.state.approvedPath = "org/messages/chat/intent.jpg";
    mediaMocks.state.pollRows = [intentRow({
      status: "scanning",
      approved_mime_type: null,
      approved_byte_size: null,
    })];
    const controller = new AbortController();
    const wait = vi.fn(async () => { controller.abort(); });

    await expect(uploadCommunityFile(file, uploadRequest({ signal: controller.signal, wait }), vi.fn()))
      .rejects.toMatchObject({ name: "AbortError" });
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
    expect(mediaMocks.calls.queryAbortSignal).toHaveBeenCalledWith(controller.signal);
  });

  it("aborts an in-flight TUS upload without polling or signing", async () => {
    const file = fileOfSize("large-video.mp4", "video/mp4", 7 * 1024 * 1024);
    configureFile(file);
    mediaMocks.state.tusAutoComplete = false;
    const controller = new AbortController();
    let notifyStarted!: () => void;
    const started = new Promise<void>((resolve) => { notifyStarted = resolve; });
    mediaMocks.state.onTusStart = notifyStarted;

    const upload = uploadCommunityFile(file, uploadRequest({ signal: controller.signal }), vi.fn());
    await started;
    controller.abort();

    await expect(upload).rejects.toMatchObject({ name: "AbortError" });
    expect(mediaMocks.calls.tusAbort).toHaveBeenCalledTimes(1);
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
    expect(mediaMocks.calls.queryAbortSignal).not.toHaveBeenCalled();
  });

  it("fails closed when the server returns an unsafe quarantine path", async () => {
    const file = fileOfSize("photo.jpg", "image/jpeg", 1_024);
    configureFile(file);
    mediaMocks.state.quarantinePath = "../approved/upload.jpg";
    mediaMocks.state.approvedPath = "org/messages/chat/intent.jpg";

    await expect(uploadCommunityFile(file, uploadRequest(), vi.fn())).rejects.toThrow("요청과 일치하지 않습니다");
    expect(mediaMocks.calls.upload).not.toHaveBeenCalled();
    expect(mediaMocks.calls.tusStart).not.toHaveBeenCalled();
    expect(mediaMocks.calls.createSignedUrl).not.toHaveBeenCalled();
  });
});
