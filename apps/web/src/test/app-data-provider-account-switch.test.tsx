import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => {
  type Result = { data: unknown; error: Error | null };
  type UploadResult = {
    path: string;
    url: string;
    kind?: "image" | "video";
    mimeType?: string;
    byteSize?: number;
    width?: number;
    height?: number;
    durationSeconds?: number;
  };
  type AuthCallback = (event: string, session: { user: Record<string, unknown> } | null) => void;
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const storageRemove = vi.fn(async (): Promise<Result> => ({ data: null, error: null }));
  const createSignedUrl = vi.fn(async () => ({ data: { signedUrl: "https://signed.test/file" }, error: null }));
  const upload = vi.fn(async (_file: File, path: string): Promise<UploadResult> => ({
    path,
    url: `https://media.test/${path}`,
  }));
  let currentUserId = "user-a";
  let authCallback: AuthCallback | null = null;
  let sendHandler: (args: Record<string, unknown>) => Promise<Result> = async () => ({ data: [], error: null });
  let reconcileMessageHandler: (args: Record<string, unknown>) => Promise<Result> = async () => ({ data: [], error: null });
  let publishHandler: (args: Record<string, unknown>) => Promise<Result> = async () => ({
    data: { status: "published", published_at: "2026-08-05T01:00:00.000Z" },
    error: null,
  });
  let saveHandler: ((args: Record<string, unknown>) => Promise<Result>) | null = null;
  let prepareCleanupHandler: (args: Record<string, unknown>) => Promise<Result> = async (args) => ({
    data: { status: "draft", removable_paths: args.p_storage_paths, protected_paths: [], cleanup_queued: true },
    error: null,
  });
  let abandonDirectHandler: (args: Record<string, unknown>) => Promise<Result> = async () => ({
    data: { cleanup_queued: true },
    error: null,
  });
  let consentGateOpen = true;
  let profileAvatarPath: string | null = null;
  let profileBio: string | null = null;
  let includeCommunityMedia = false;
  let contextHandler: (() => Result | Promise<Result>) | null = null;
  const realtimeHandlers = new Map<string, (payload: Record<string, unknown>) => void>();

  const user = (id: string) => ({
    id,
    email: `${id}@example.com`,
    user_metadata: { display_name: id === "user-a" ? "사용자 A" : "사용자 B" },
  });
  const consentDocuments = [{
    document_key: "privacy_policy",
    version: "2026-08-30",
    locale: "ko-KR",
    title: "개인정보 수집·이용 동의",
    document_url: "/legal/privacy/2026-08-30",
    content_sha256: "5a701de8e5f10cf94d8b6309f3c1333282b53c8823d449d0bc0ff9dffa76508d",
    required: true,
    effective_at: "2026-08-30T00:00:00+09:00",
    retired_at: null,
  }, {
    document_key: "sensitive_information",
    version: "2026-08-30",
    locale: "ko-KR",
    title: "종교 관련 민감정보 처리 동의",
    document_url: "/legal/sensitive/2026-08-30",
    content_sha256: "a721d371977ecc486e04ddf98fa3287ff434d74a3b2d1045d6c6aa1b3c52fe9b",
    required: true,
    effective_at: "2026-08-30T00:00:00+09:00",
    retired_at: null,
  }, {
    document_key: "overseas_transfer",
    version: "2026-08-30",
    locale: "ko-KR",
    title: "개인정보 국외 이전 동의",
    document_url: "/legal/overseas/2026-08-30",
    content_sha256: "8a8196a9d5493860a776d07443923410b0e9802de46e9878a08d23fbfaf9e684",
    required: true,
    effective_at: "2026-08-30T00:00:00+09:00",
    retired_at: null,
  }, {
    document_key: "terms_of_service",
    version: "2026-08-30",
    locale: "ko-KR",
    title: "이용약관 및 만 14세 이상 확인",
    document_url: "/legal/terms/2026-08-30",
    content_sha256: "ce6dedf9374ebad0cdd781598209ea773348c585aa34204808d073fc131f2aa9",
    required: true,
    effective_at: "2026-08-30T00:00:00+09:00",
    retired_at: null,
  }, {
    document_key: "community_guidelines",
    version: "2026-08-30",
    locale: "ko-KR",
    title: "공동체 운영정책",
    document_url: "/legal/community/2026-08-30",
    content_sha256: "e0b737c75f94bf3dbb2a7d5a139541f1b95c882c94f620730202aeecdb07c56d",
    required: true,
    effective_at: "2026-08-30T00:00:00+09:00",
    retired_at: null,
  }];
  const safetyPrivacyState = () => ({
    current_documents: Object.fromEntries(consentDocuments.map((document) => [
      document.document_key,
      {
        version: document.version,
        title: document.title,
        url: document.document_url,
        required: true,
      },
    ])),
    required_consents: consentDocuments.map((document) => ({
      document_key: document.document_key,
      document_version: document.version,
      accepted: consentGateOpen,
      recorded_at: consentGateOpen ? "2026-08-30T00:00:00.000Z" : null,
    })),
    consent_gate_open: consentGateOpen,
  });
  const resultBuilder = (result: () => Result | Promise<Result>) => {
    const builder: Record<string, unknown> = {};
    for (const method of ["select", "order", "eq", "in", "is", "limit", "range", "delete", "update", "insert"]) {
      builder[method] = vi.fn(() => builder);
    }
    builder.abortSignal = vi.fn(async () => result());
    builder.single = vi.fn(async () => result());
    builder.maybeSingle = vi.fn(async () => result());
    builder.then = (resolve: (value: Result) => unknown, reject: (reason: unknown) => unknown) =>
      Promise.resolve(result()).then(resolve, reject);
    return builder;
  };
  const loadRpcResult = (name: string, args: Record<string, unknown>): Result => {
    if (name === "get_my_safety_privacy_state") {
      return { data: safetyPrivacyState(), error: null };
    }
    if (name === "get_my_context") {
      return {
        data: {
          profile: { id: currentUserId, display_name: currentUserId === "user-a" ? "사용자 A" : "사용자 B" },
          membership: {
            id: `membership-${currentUserId}`,
            organization_id: "org-1",
            user_id: currentUserId,
            role: "member",
            church_title_code: "deacon",
            status: "active",
            joined_at: "2026-01-01T00:00:00.000Z",
          },
          latest_application: null,
          is_platform_admin: false,
        },
        error: null,
      };
    }
    if (name === "get_service_clock") {
      return { data: { service_year: 2026, milliseconds_until_rollover: 60_000 }, error: null };
    }
    if (name === "get_conversation_summaries") {
      return {
        data: [{
          id: "conversation-1",
          organization_id: "org-1",
          participants: [
            { id: "user-a", display_name: "사용자 A" },
            { id: "user-b", display_name: "사용자 B" },
          ],
          last_message: null,
          unread_count: 0,
        }],
        error: null,
      };
    }
    if (name === "list_visible_profiles") {
      const ids = Array.isArray(args.p_profile_ids) ? args.p_profile_ids.map(String) : [];
      return {
        data: ids.map((id) => ({
          id,
          display_name: id === "user-a" ? "사용자 A" : "사용자 B",
          avatar_path: id === currentUserId ? profileAvatarPath : null,
          bio: id === currentUserId ? profileBio : null,
        })),
        error: null,
      };
    }
    if (name === "list_visible_organization_memberships") {
      return {
        data: Number(args.p_offset) === 0 ? [{
          id: `membership-${currentUserId}`,
          organization_id: "org-1",
          user_id: currentUserId,
          role: "member",
          church_title_code: null,
          status: "active",
          joined_at: "2026-01-01T00:00:00.000Z",
        }] : [],
        error: null,
      };
    }
    return { data: [], error: null };
  };
  const tableResult = (table: string): Result => {
    if (table === "consent_documents") return { data: consentDocuments, error: null };
    if (table === "organizations") {
      return {
        data: [{
          id: "org-1",
          source_name: "재건교회",
          display_name: "재건교회",
          slug: "jaegun",
          presbytery: "서울",
          status: "active",
          claimed_at: "2026-01-01T00:00:00.000Z",
        }],
        error: null,
      };
    }
    if (table === "boards") {
      return {
        data: [
          { id: "board-sharing", organization_id: "org-1", slug: "fellowship", name: "나눔", staff_only_posting: false },
          { id: "board-prayer", organization_id: "org-1", slug: "prayer", name: "기도", staff_only_posting: false },
        ],
        error: null,
      };
    }
    if (table === "posts" && includeCommunityMedia) {
      return {
        data: [{
          id: "post-with-media",
          organization_id: "org-1",
          board_id: "board-sharing",
          author_id: currentUserId,
          author_label: null,
          title: "공개범위 테스트",
          body: "미디어",
          status: "published",
          is_system: false,
          is_pinned: false,
          published_at: "2026-08-30T00:00:00.000Z",
          created_at: "2026-08-30T00:00:00.000Z",
        }],
        error: null,
      };
    }
    if (table === "post_media") {
      return includeCommunityMedia ? {
        data: [{
          id: "media-1",
          post_id: "post-with-media",
          storage_path: "org-1/posts/post-with-media/photo.jpg",
          kind: "image",
          mime_type: "image/jpeg",
          byte_size: 100,
          alt_text: null,
          sort_order: 0,
        }],
        error: null,
      } : { data: { id: "media-1" }, error: null };
    }
    return { data: [], error: null };
  };

  return {
    calls,
    storageRemove,
    createSignedUrl,
    upload,
    get currentUserId() { return currentUserId; },
    get authCallback() { return authCallback; },
    set sendHandler(value: typeof sendHandler) { sendHandler = value; },
    set reconcileMessageHandler(value: typeof reconcileMessageHandler) { reconcileMessageHandler = value; },
    set publishHandler(value: typeof publishHandler) { publishHandler = value; },
    set saveHandler(value: typeof saveHandler) { saveHandler = value; },
    set prepareCleanupHandler(value: typeof prepareCleanupHandler) { prepareCleanupHandler = value; },
    set abandonDirectHandler(value: typeof abandonDirectHandler) { abandonDirectHandler = value; },
    set contextHandler(value: typeof contextHandler) { contextHandler = value; },
    set profileAvatarPath(value: string | null) { profileAvatarPath = value; },
    set profileBio(value: string | null) { profileBio = value; },
    set includeCommunityMedia(value: boolean) { includeCommunityMedia = value; },
    reset() {
      currentUserId = "user-a";
      authCallback = null;
      calls.length = 0;
      storageRemove.mockClear();
      storageRemove.mockImplementation(async () => ({ data: null, error: null }));
      createSignedUrl.mockClear();
      createSignedUrl.mockImplementation(async () => ({ data: { signedUrl: "https://signed.test/file" }, error: null }));
      upload.mockClear();
      upload.mockImplementation(async (_file: File, path: string) => ({ path, url: `https://media.test/${path}` }));
      sendHandler = async () => ({ data: [], error: null });
      reconcileMessageHandler = async () => ({ data: [], error: null });
      publishHandler = async () => ({
        data: { status: "published", published_at: "2026-08-05T01:00:00.000Z" },
        error: null,
      });
      saveHandler = null;
      prepareCleanupHandler = async (args) => ({
        data: { status: "draft", removable_paths: args.p_storage_paths, protected_paths: [], cleanup_queued: true },
        error: null,
      });
      abandonDirectHandler = async () => ({ data: { cleanup_queued: true }, error: null });
      consentGateOpen = true;
      profileAvatarPath = null;
      profileBio = null;
      includeCommunityMedia = false;
      contextHandler = null;
      realtimeHandlers.clear();
    },
    switchUser(id: string) {
      currentUserId = id;
      authCallback?.("SIGNED_IN", { user: user(id) });
    },
    triggerConsentDocumentChange() {
      consentGateOpen = false;
      realtimeHandlers.get("consent_documents")?.({});
    },
    setConsentGateOpen(value: boolean) {
      consentGateOpen = value;
    },
    channel() {
      const channel = {
        on: vi.fn((_type: string, filter: { table?: string }, callback: (payload: Record<string, unknown>) => void) => {
          if (filter.table) realtimeHandlers.set(filter.table, callback);
          return channel;
        }),
        subscribe: vi.fn(() => channel),
      };
      return channel;
    },
    auth: {
      getSession: vi.fn(async () => ({ data: { session: { user: user(currentUserId) } }, error: null })),
      signOut: vi.fn(async () => ({ error: null })),
      onAuthStateChange: vi.fn((callback: AuthCallback) => {
        authCallback = callback;
        return { data: { subscription: { unsubscribe: vi.fn() } } };
      }),
    },
    from(table: string) {
      calls.push({ name: `from:${table}`, args: {} });
      const builder = resultBuilder(() => tableResult(table));
      builder.insert = vi.fn((values: Record<string, unknown>) => {
        calls.push({ name: `insert:${table}`, args: values });
        return builder;
      });
      if (table === "boards") {
        builder.single = vi.fn(async () => ({ data: { id: "board-sharing" }, error: null }));
      }
      return builder;
    },
    rpc(name: string, args: Record<string, unknown> = {}) {
      calls.push({ name, args });
      if (name === "send_message_batch") return sendHandler(args);
      if (name === "reconcile_message_batch") return reconcileMessageHandler(args);
      if (name === "publish_owned_post") return publishHandler(args);
      if (name === "reconcile_post_operation") return Promise.resolve({ data: { status: "draft" }, error: null });
      if (name === "prepare_post_media_cleanup") return prepareCleanupHandler(args);
      if (name === "abandon_direct_media_objects") return abandonDirectHandler(args);
      if (name === "save_owned_post_draft") {
        if (saveHandler) return saveHandler(args);
        return Promise.resolve({
          data: {
            id: args.p_post_id,
            status: "draft",
            organization_id: args.p_organization_id,
            board_id: args.p_board_id,
            title: args.p_title,
            body: args.p_body,
            created_at: "2026-08-05T00:00:00.000Z",
            published_at: null,
            scope_recreated: false,
            media_paths: [],
          },
          error: null,
        });
      }
      if (name === "get_my_context" && contextHandler) return resultBuilder(contextHandler);
      return resultBuilder(() => loadRpcResult(name, args));
    },
  };
});

vi.mock("../data/supabase", () => ({
  canPersistSensitiveClientState: () => true,
  isSupabaseConfigured: true,
  supabase: {
    auth: remote.auth,
    from: (table: string) => remote.from(table),
    rpc: (name: string, args?: Record<string, unknown>) => remote.rpc(name, args),
    storage: {
      from: vi.fn(() => ({
        remove: remote.storageRemove,
        createSignedUrl: remote.createSignedUrl,
      })),
    },
    channel: vi.fn(() => remote.channel()),
    removeChannel: vi.fn(async () => undefined),
  },
}));

vi.mock("../data/mediaUpload", () => ({
  validateMediaFile: vi.fn(() => null),
  uploadCommunityFile: async (file: File, request: {
    purpose: "post" | "message";
    targetId: string;
    organizationId?: string;
    onObjectPathCreated?: (objectPath: string) => void;
  }) => {
    const directory = request.purpose === "post" ? "posts" : "messages";
    const intendedPath = `${request.organizationId ?? "org-1"}/${directory}/${request.targetId}/${file.name}`;
    request.onObjectPathCreated?.(intendedPath);
    const uploaded = await remote.upload(file, intendedPath);
    return {
      bucket: "community-media" as const,
      path: uploaded.path,
      url: uploaded.url,
      kind: uploaded.kind ?? (file.type.startsWith("video/") ? "video" as const : "image" as const),
      mimeType: uploaded.mimeType ?? file.type,
      byteSize: uploaded.byteSize ?? file.size,
      width: uploaded.width,
      height: uploaded.height,
      durationSeconds: uploaded.durationSeconds,
    };
  },
}));

import { AppDataProvider, useAppData } from "../data/AppDataProvider";

const attachment = new File(["image"], "photo.jpg", { type: "image/jpeg", lastModified: 1 });
const replacementAttachment = new File(["replacement"], "replacement.jpg", { type: "image/jpeg", lastModified: 2 });

function Probe() {
  const data = useAppData();
  const [protectedMediaUrl, setProtectedMediaUrl] = useState("none");
  const run = (task: Promise<unknown>) => void task.catch(() => undefined);
  const publish = (file: File) => data.createPost({
    clientOperationId: "10000000-0000-4000-8000-000000000001",
    category: "sharing",
    title: "최신 제목",
    body: "최신 본문",
    files: [file],
  });
  return (
    <>
      <output data-testid="viewer">{data.viewer?.profile.id ?? "none"}</output>
      <output data-testid="membership">{data.viewer?.membership?.id ?? "none"}</output>
      <output data-testid="consent-gate">{String(data.consentGateOpen)}</output>
      <output data-testid="protected-media-url">{protectedMediaUrl}</output>
      <output data-testid="post-media-url">{
        data.posts.find((post) => post.id === "post-with-media")?.media[0]?.url ?? "none"
      }</output>
      <output data-testid="post-media-storage-path">{
        data.posts.find((post) => post.id === "post-with-media")?.media[0]?.storagePath ?? "none"
      }</output>
      <output data-testid="privacy-projection">{JSON.stringify({
        avatarUrl: data.viewer?.profile.avatarUrl ?? null,
        bio: data.viewer?.profile.bio ?? null,
        memberAvatarUrl: data.members[0]?.avatarUrl ?? null,
        memberChurchTitleCode: data.members[0]?.churchTitleCode ?? null,
      })}</output>
      <button type="button" onClick={() => run(data.refresh())}>refresh</button>
      <button type="button" onClick={() => {
        void data.refreshProtectedMediaUrl("org-1/posts/post-with-media/photo.jpg")
          .then((url) => { if (url) setProtectedMediaUrl(url); });
      }}>refresh protected media</button>
      <button type="button" onClick={() => remote.switchUser("user-b")}>switch b</button>
      <button type="button" onClick={() => remote.switchUser("user-a")}>switch a</button>
      <button type="button" onClick={() => run(data.sendMessage("conversation-1", "", [attachment]))}>send</button>
      <button type="button" onClick={() => run(publish(attachment))}>publish</button>
      <button type="button" onClick={() => run(publish(replacementAttachment))}>publish replacement</button>
    </>
  );
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => { resolve = next; });
  return { promise, resolve };
}

async function renderLoadedProvider() {
  render(<AppDataProvider><Probe /></AppDataProvider>);
  await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-a"));
}

describe("AppDataProvider account-switch operation boundaries", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  beforeEach(() => {
    remote.reset();
    Object.defineProperties(URL, {
      createObjectURL: { configurable: true, value: vi.fn(() => "blob:optimistic") },
      revokeObjectURL: { configurable: true, value: vi.fn() },
    });
  });

  it("loads privacy-filtered profiles and memberships only through their RPC projections", async () => {
    await renderLoadedProvider();

    expect(remote.calls.filter((call) => call.name === "from:profiles")).toHaveLength(0);
    expect(remote.calls.filter((call) => call.name === "from:organization_memberships")).toHaveLength(0);
    expect(remote.calls.filter((call) => call.name === "list_visible_profiles").map((call) => call.args))
      .toEqual([{ p_profile_ids: ["user-a"] }]);
    expect(remote.calls.filter((call) => call.name === "list_visible_organization_memberships").map((call) => call.args))
      .toEqual([{
        p_organization_id: "org-1",
        p_limit: 500,
        p_offset: 0,
      }]);
    expect(JSON.parse(screen.getByTestId("privacy-projection").textContent ?? "{}"))
      .toEqual({
        avatarUrl: null,
        bio: null,
        memberAvatarUrl: null,
        memberChurchTitleCode: null,
      });
  });

  it("uses 60-second signed URLs and refreshes them after the 45-second client cache window", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1_000);
    remote.profileAvatarPath = "user-a/avatar.jpg";
    await renderLoadedProvider();

    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(1));
    expect(remote.createSignedUrl).toHaveBeenNthCalledWith(1, "user-a/avatar.jpg", 60);

    now.mockReturnValue(46_001);
    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(2));
    now.mockRestore();
  });

  it("uses a 60-second URL and 45-second cache window for community media", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1_000);
    remote.includeCommunityMedia = true;
    await renderLoadedProvider();

    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(1));
    expect(remote.createSignedUrl).toHaveBeenNthCalledWith(
      1,
      "org-1/posts/post-with-media/photo.jpg",
      60,
    );

    now.mockReturnValue(46_001);
    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(2));
    now.mockRestore();
  });

  it("forces a protected-media refresh and prevents an older same-path request from winning", async () => {
    const first = deferred<{ data: { signedUrl: string }; error: null }>();
    const second = deferred<{ data: { signedUrl: string }; error: null }>();
    remote.createSignedUrl
      .mockImplementationOnce(() => first.promise)
      .mockImplementationOnce(() => second.promise);
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "refresh protected media" }));
    fireEvent.click(screen.getByRole("button", { name: "refresh protected media" }));
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(2));

    await act(async () => {
      second.resolve({ data: { signedUrl: "https://signed.test/newest" }, error: null });
      await second.promise;
    });
    await waitFor(() => expect(screen.getByTestId("protected-media-url"))
      .toHaveTextContent("https://signed.test/newest"));

    await act(async () => {
      first.resolve({ data: { signedUrl: "https://signed.test/stale" }, error: null });
      await first.promise;
    });
    expect(screen.getByTestId("protected-media-url")).toHaveTextContent("https://signed.test/newest");

    remote.includeCommunityMedia = true;
    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(screen.getByTestId("post-media-url"))
      .toHaveTextContent("https://signed.test/newest"));
    expect(screen.getByTestId("post-media-storage-path"))
      .toHaveTextContent("org-1/posts/post-with-media/photo.jpg");
    expect(remote.createSignedUrl).toHaveBeenCalledTimes(2);
  });

  it("ignores a protected-media response that completes after the actor changes", async () => {
    const pending = deferred<{ data: { signedUrl: string }; error: null }>();
    remote.createSignedUrl.mockImplementationOnce(() => pending.promise);
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "refresh protected media" }));
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(1));
    act(() => remote.switchUser("user-b"));
    await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-b"));

    await act(async () => {
      pending.resolve({ data: { signedUrl: "https://signed.test/user-a" }, error: null });
      await pending.promise;
    });
    expect(screen.getByTestId("protected-media-url")).toHaveTextContent("none");
  });

  it("ignores a protected-media response after the consent gate closes", async () => {
    const pending = deferred<{ data: { signedUrl: string }; error: null }>();
    remote.createSignedUrl.mockImplementationOnce(() => pending.promise);
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "refresh protected media" }));
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(1));
    remote.setConsentGateOpen(false);
    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(screen.getByTestId("consent-gate")).toHaveTextContent("false"));

    await act(async () => {
      pending.resolve({ data: { signedUrl: "https://signed.test/gate-closed" }, error: null });
      await pending.promise;
    });
    expect(screen.getByTestId("protected-media-url")).toHaveTextContent("none");
    fireEvent.click(screen.getByRole("button", { name: "refresh protected media" }));
    expect(remote.createSignedUrl).toHaveBeenCalledTimes(1);
  });

  it("clears protected signed URL caches as soon as the consent gate closes", async () => {
    remote.profileAvatarPath = "user-a/avatar.jpg";
    await renderLoadedProvider();
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(1));

    remote.setConsentGateOpen(false);
    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(screen.getByTestId("consent-gate")).toHaveTextContent("false"));

    remote.setConsentGateOpen(true);
    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(screen.getByTestId("consent-gate")).toHaveTextContent("true"));
    await waitFor(() => expect(remote.createSignedUrl).toHaveBeenCalledTimes(2));
  });

  it("clears protected state on a consent-document event and ignores a late pre-transition snapshot", async () => {
    await renderLoadedProvider();
    expect(screen.getByTestId("membership")).toHaveTextContent("membership-user-a");
    const pendingContext = deferred<{ data: unknown; error: null }>();
    remote.contextHandler = () => pendingContext.promise;

    fireEvent.click(screen.getByRole("button", { name: "refresh" }));
    await waitFor(() => expect(
      remote.calls.filter((call) => call.name === "get_my_context"),
    ).toHaveLength(2));

    act(() => remote.triggerConsentDocumentChange());
    await waitFor(() => expect(screen.getByTestId("consent-gate")).toHaveTextContent("false"));
    expect(screen.getByTestId("membership")).toHaveTextContent("none");

    await act(async () => {
      pendingContext.resolve({
        data: {
          profile: { id: "user-a", display_name: "사용자 A" },
          membership: {
            id: "membership-user-a",
            organization_id: "org-1",
            user_id: "user-a",
            role: "member",
            church_title_code: "deacon",
            status: "active",
            joined_at: "2026-01-01T00:00:00.000Z",
          },
          latest_application: null,
          is_platform_admin: false,
        },
        error: null,
      });
      await pendingContext.promise;
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("consent-gate")).toHaveTextContent("false");
    expect(screen.getByTestId("membership")).toHaveTextContent("none");
  });

  it("never removes a queued path that the server classifies as published media", async () => {
    const postId = "10000000-0000-4000-8000-000000000001";
    const livePath = `org-1/posts/${postId}/live.jpg`;
    window.localStorage.setItem("jaegun-storage-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      paths: [livePath],
    }]));
    window.localStorage.setItem("jaegun-draft-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      postIds: [postId],
    }]));
    remote.prepareCleanupHandler = async () => ({
      data: { status: "published", removable_paths: [], protected_paths: [livePath] },
      error: null,
    });

    await renderLoadedProvider();
    await waitFor(() => expect(remote.calls.filter((call) => call.name === "prepare_post_media_cleanup")).toHaveLength(1));
    await waitFor(() => {
      expect(JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]")).toEqual([]);
      expect(JSON.parse(window.localStorage.getItem("jaegun-draft-cleanup-v1") ?? "[]")).toEqual([]);
    });
    expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0);
  });

  it("chunks direct cleanup and falls back to the server queue when Storage delete is denied", async () => {
    const paths = Array.from({ length: 21 }, (_, index) =>
      `40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-${String(index).padStart(12, "0")}.jpg`);
    window.localStorage.setItem("jaegun-storage-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      paths,
    }]));
    remote.storageRemove.mockResolvedValue({ data: null, error: new Error("storage delete denied") });

    await renderLoadedProvider();

    await waitFor(() => expect(
      remote.calls.filter((call) => call.name === "abandon_direct_media_objects"),
    ).toHaveLength(2));
    expect(remote.storageRemove).toHaveBeenNthCalledWith(1, paths.slice(0, 20));
    expect(remote.storageRemove).toHaveBeenNthCalledWith(2, paths.slice(20));
    const fallbackCalls = remote.calls.filter((call) => call.name === "abandon_direct_media_objects");
    expect(fallbackCalls.map((call) => call.args)).toEqual([
      { p_bucket_id: "community-media", p_storage_paths: paths.slice(0, 20) },
      { p_bucket_id: "community-media", p_storage_paths: paths.slice(20) },
    ]);
    await waitFor(() => expect(
      JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]"),
    ).toEqual([]));
  });

  it("does not run the cleanup fallback as a different account after the epoch changes", async () => {
    const path = "40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000001.jpg";
    const removal = deferred<{ data: null; error: Error | null }>();
    window.localStorage.setItem("jaegun-storage-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      paths: [path],
    }]));
    remote.storageRemove.mockImplementationOnce(() => removal.promise);

    await renderLoadedProvider();
    await waitFor(() => expect(remote.storageRemove).toHaveBeenCalledWith([path]));
    fireEvent.click(screen.getByRole("button", { name: "switch b" }));
    await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-b"));
    await act(async () => removal.resolve({ data: null, error: new Error("storage delete denied") }));

    await waitFor(() => expect(
      JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]"),
    ).toEqual([{ userId: "user-a", paths: [path] }]));
    expect(remote.calls.filter((call) => call.name === "abandon_direct_media_objects")).toHaveLength(0);
  });

  it("keeps the local retry when both direct deletion and server queueing fail", async () => {
    const path = "40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000001.jpg";
    window.localStorage.setItem("jaegun-storage-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      paths: [path],
    }]));
    remote.storageRemove.mockResolvedValue({ data: null, error: new Error("storage delete denied") });
    remote.abandonDirectHandler = async () => ({
      data: null,
      error: new Error("server cleanup unavailable"),
    });

    await renderLoadedProvider();

    await waitFor(() => expect(
      remote.calls.filter((call) => call.name === "abandon_direct_media_objects"),
    ).toHaveLength(1));
    expect(JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]"))
      .toEqual([{ userId: "user-a", paths: [path] }]);
  });

  it("accepts idempotent fallback counts that cover the complete chunk", async () => {
    const path = "40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000001.jpg";
    window.localStorage.setItem("jaegun-storage-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      paths: [path],
    }]));
    remote.storageRemove.mockResolvedValue({ data: null, error: new Error("storage delete denied") });
    remote.abandonDirectHandler = async () => ({
      data: { queued_count: 0, already_queued_count: 1 },
      error: null,
    });

    await renderLoadedProvider();

    await waitFor(() => expect(
      remote.calls.filter((call) => call.name === "abandon_direct_media_objects"),
    ).toHaveLength(1));
    await waitFor(() => expect(
      JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]"),
    ).toEqual([]));
  });

  it.each([
    ["missing", { queued_count: 1 }],
    ["partial", { queued_count: 0, already_queued_count: 0 }],
    ["malformed", { queued_count: "1", already_queued_count: 0 }],
  ] as const)("keeps the local retry for %s fallback counts", async (_case, payload) => {
    const path = "40000000-0000-4000-8000-000000000004/messages/20000000-0000-4000-8000-000000000002/10000000-0000-4000-8000-000000000001.jpg";
    window.localStorage.setItem("jaegun-storage-cleanup-v1", JSON.stringify([{
      userId: "user-a",
      paths: [path],
    }]));
    remote.storageRemove.mockResolvedValue({ data: null, error: new Error("storage delete denied") });
    remote.abandonDirectHandler = async () => ({ data: payload, error: null });

    await renderLoadedProvider();

    await waitFor(() => expect(
      remote.calls.filter((call) => call.name === "abandon_direct_media_objects"),
    ).toHaveLength(1));
    expect(JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]"))
      .toEqual([{ userId: "user-a", paths: [path] }]);
  });

  it("preserves A reconciliation and never cleans attachments when B receives an empty result", async () => {
    const reconciliation = deferred<{ data: unknown[]; error: null }>();
    remote.sendHandler = async () => ({ data: null, error: new Error("response lost") });
    remote.reconcileMessageHandler = () => reconciliation.promise;
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "send" }));
    await waitFor(() => expect(remote.calls.some((call) => call.name === "reconcile_message_batch")).toBe(true));
    fireEvent.click(screen.getByRole("button", { name: "switch b" }));
    await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-b"));
    await act(async () => reconciliation.resolve({ data: [], error: null }));

    await waitFor(() => {
      const records = JSON.parse(window.localStorage.getItem("jaegun-message-reconciliation-v1") ?? "[]") as Array<{ userId: string }>;
      expect(records).toEqual([expect.objectContaining({ userId: "user-a" })]);
    });
    expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0);
  });

  it("does not call the batch RPC after a long upload finishes under another account", async () => {
    const upload = deferred<{ path: string; url: string }>();
    remote.upload.mockImplementationOnce(() => upload.promise);
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "send" }));
    await waitFor(() => expect(remote.upload).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole("button", { name: "switch b" }));
    await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-b"));
    await act(async () => upload.resolve({
      path: "org-1/messages/conversation-1/uploaded.jpg",
      url: "https://media.test/uploaded.jpg",
    }));

    await waitFor(() => {
      const queue = JSON.parse(window.localStorage.getItem("jaegun-storage-cleanup-v1") ?? "[]") as Array<{ userId: string }>;
      expect(queue).toEqual([expect.objectContaining({ userId: "user-a" })]);
    });
    expect(remote.calls.filter((call) => call.name === "send_message_batch")).toHaveLength(0);
    expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0);
  });

  it("keeps A's pending publish after account switch and retries without reuploading", async () => {
    const firstPublish = deferred<{ data: null; error: Error }>();
    remote.publishHandler = () => firstPublish.promise;
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "publish" }));
    await waitFor(() => expect(remote.calls.filter((call) => call.name === "publish_owned_post")).toHaveLength(1));
    fireEvent.click(screen.getByRole("button", { name: "switch b" }));
    await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-b"));
    await act(async () => firstPublish.resolve({ data: null, error: new Error("response lost") }));
    await waitFor(() => expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0));

    remote.publishHandler = async () => ({
      data: { status: "published", published_at: "2026-08-05T01:00:00.000Z" },
      error: null,
    });
    fireEvent.click(screen.getByRole("button", { name: "switch a" }));
    await waitFor(() => expect(screen.getByTestId("viewer")).toHaveTextContent("user-a"));
    fireEvent.click(screen.getByRole("button", { name: "publish" }));

    await waitFor(() => expect(remote.calls.filter((call) => call.name === "publish_owned_post")).toHaveLength(2));
    expect(remote.upload).toHaveBeenCalledTimes(1);
    expect(remote.calls.filter((call) => call.name === "reconcile_post_operation")).toHaveLength(0);
    expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0);
    expect(remote.calls.filter((call) => call.name === "publish_owned_post")[1]?.args).toEqual(expect.objectContaining({
      p_expected_author_id: "user-a",
    }));
  });

  it("detaches a recreated-scope draft before falling through to one clean reupload", async () => {
    let publishCalls = 0;
    let saveCalls = 0;
    remote.publishHandler = async () => {
      publishCalls += 1;
      return publishCalls === 1
        ? { data: null, error: new Error("response lost") }
        : { data: { status: "published", published_at: "2026-08-05T01:00:00.000Z" }, error: null };
    };
    remote.saveHandler = async (args) => {
      saveCalls += 1;
      return {
        data: {
          id: args.p_post_id,
          status: "draft",
          organization_id: args.p_organization_id,
          board_id: args.p_board_id,
          title: args.p_title,
          body: args.p_body,
          created_at: "2026-08-05T00:00:00.000Z",
          published_at: null,
          scope_recreated: saveCalls === 2,
          media_paths: saveCalls === 2 ? ["org-1/posts/10000000-0000-4000-8000-000000000001/old.jpg"] : [],
        },
        error: null,
      };
    };
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "publish" }));
    await waitFor(() => expect(remote.calls.filter((call) => call.name === "reconcile_post_operation")).toHaveLength(1));
    fireEvent.click(screen.getByRole("button", { name: "publish" }));

    await waitFor(() => expect(remote.calls.filter((call) => call.name === "publish_owned_post")).toHaveLength(2));
    expect(saveCalls).toBe(3);
    expect(remote.calls.filter((call) => call.name === "prepare_post_media_cleanup")).toHaveLength(1);
    expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0);
    expect(remote.storageRemove).toHaveBeenCalledWith(
      remote.calls.find((call) => call.name === "prepare_post_media_cleanup")?.args.p_storage_paths,
    );
    expect(remote.upload).toHaveBeenCalledTimes(2);
  });

  it("never publishes the old pending attachment after the user replaces it", async () => {
    let publishCalls = 0;
    remote.publishHandler = async () => {
      publishCalls += 1;
      return publishCalls === 1
        ? { data: null, error: new Error("response lost") }
        : { data: { status: "published", published_at: "2026-08-05T01:00:00.000Z" }, error: null };
    };
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "publish" }));
    await waitFor(() => expect(remote.calls.filter((call) => call.name === "reconcile_post_operation")).toHaveLength(1));
    const firstPublish = remote.calls.find((call) => call.name === "publish_owned_post");
    const firstPaths = firstPublish?.args.p_expected_media_paths as string[];
    expect(firstPaths).toHaveLength(1);

    fireEvent.click(screen.getByRole("button", { name: "publish replacement" }));
    await waitFor(() => expect(remote.calls.filter((call) => call.name === "publish_owned_post")).toHaveLength(2));

    const publishOperations = remote.calls.filter((call) => call.name === "publish_owned_post");
    const replacementPaths = publishOperations[1]?.args.p_expected_media_paths as string[];
    expect(replacementPaths).toHaveLength(1);
    expect(replacementPaths[0]).not.toBe(firstPaths[0]);
    expect(remote.calls.filter((call) => call.name === "prepare_post_media_cleanup")[0]?.args.p_storage_paths)
      .toEqual(firstPaths);
    expect(remote.calls.filter((call) => call.name === "abandon_media_upload_intents")).toHaveLength(0);
    expect(remote.storageRemove).toHaveBeenCalledWith(firstPaths);
    expect(remote.upload).toHaveBeenCalledTimes(2);
    expect((remote.upload.mock.calls[1]?.[0] as File).name).toBe("replacement.jpg");
  });

  it("inserts post media with the direct upload metadata", async () => {
    remote.upload.mockImplementation(async (_file: File, path: string) => ({
      path,
      url: `https://media.test/${path}`,
      kind: "image",
      mimeType: "image/webp",
      byteSize: 321,
      width: 640,
      height: 480,
    }));
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "publish" }));

    await waitFor(() => expect(remote.calls.some((call) => call.name === "insert:post_media")).toBe(true));
    expect(remote.calls.find((call) => call.name === "insert:post_media")?.args).toEqual(expect.objectContaining({
      kind: "image",
      mime_type: "image/webp",
      byte_size: 321,
      width: 640,
      height: 480,
      duration_seconds: null,
    }));
  });

  it("builds message media input without claiming a scanner approval", async () => {
    remote.upload.mockImplementation(async (_file: File, path: string) => ({
      path,
      url: `https://media.test/${path}`,
      kind: "image",
      mimeType: "image/webp",
      byteSize: 222,
      width: 320,
      height: 240,
    }));
    await renderLoadedProvider();

    fireEvent.click(screen.getByRole("button", { name: "send" }));

    await waitFor(() => expect(remote.calls.some((call) => call.name === "send_message_batch")).toBe(true));
    const items = remote.calls.find((call) => call.name === "send_message_batch")?.args.p_messages as Array<Record<string, unknown>>;
    expect(items).toHaveLength(1);
    expect(items[0]).toEqual(expect.objectContaining({
      kind: "image",
      media_metadata: {
        mime_type: "image/webp",
        byte_size: 222,
        width: 320,
        height: 240,
        duration_seconds: null,
      },
    }));
  });
});
