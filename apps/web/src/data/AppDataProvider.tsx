import {
  createContext,
  type PropsWithChildren,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type {
  AppDataState,
  Comment,
  Conversation,
  MembershipApplication,
  MembershipRequestInput,
  MembershipRole,
  Message,
  Notification,
  Post,
  PostDraft,
  Profile,
  SignUpInput,
  ViewerContext,
} from "../types/domain";
import { createDemoState, DEMO_VIEWER } from "./seed";
import { isSupabaseConfigured, supabase } from "./supabase";
import { uploadCommunityFile, validateMediaFile } from "./mediaUpload";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v3";

interface LoginInput {
  email: string;
  password: string;
}

interface AppDataContextValue extends AppDataState {
  error: string | null;
  hasMorePosts: boolean;
  enterDemo: (persona?: "owner" | "member" | "new") => void;
  signIn: (input: LoginInput) => Promise<void>;
  signUp: (input: SignUpInput) => Promise<void>;
  signOut: () => Promise<void>;
  requestMembership: (input: MembershipRequestInput) => Promise<void>;
  createPost: (draft: PostDraft, onProgress?: (progress: number) => void) => Promise<Post>;
  addComment: (postId: string, body: string) => Promise<void>;
  startConversation: (otherUserId: string) => Promise<string>;
  loadConversationMessages: (conversationId: string) => Promise<void>;
  sendMessage: (conversationId: string, body: string, files?: File[]) => Promise<void>;
  markConversationRead: (conversationId: string, messageId?: string) => Promise<void>;
  reviewApplication: (applicationId: string, decision: "approved" | "rejected", note?: string) => Promise<void>;
  setMembershipStatus: (membershipId: string, status: "active" | "suspended" | "revoked", reason: string) => Promise<void>;
  markNotificationsRead: () => Promise<void>;
  loadMorePosts: () => Promise<void>;
  refresh: () => Promise<void>;
}

const AppDataContext = createContext<AppDataContextValue | null>(null);

function readDemoState(): AppDataState {
  const fresh = createDemoState();
  try {
    const raw = window.localStorage.getItem(DEMO_STORAGE_KEY);
    if (!raw) return fresh;
    const parsed = JSON.parse(raw) as AppDataState;
    return {
      ...fresh,
      ...parsed,
      mode: "demo",
      loading: false,
      organizations: fresh.organizations,
    };
  } catch {
    return fresh;
  }
}

function demoViewer(persona: "owner" | "member" | "new"): ViewerContext {
  if (persona === "new") {
    return {
      profile: {
        id: "demo-new-user",
        displayName: "새 가족",
        email: "new@jaegun.demo",
        globalRole: "user",
      },
    };
  }
  const profile: Profile = persona === "owner" ? DEMO_VIEWER : {
    id: "demo-member",
    displayName: "이재건",
    email: "member@jaegun.demo",
    globalRole: "user",
  };
  return {
    profile,
    membership: {
      organizationId: "org-19",
      userId: profile.id,
      role: persona === "owner" ? "executive" : "member",
      status: "active",
      approvedAt: "2026-07-01T00:00:00.000Z",
    },
  };
}

function mapRole(value: unknown): MembershipRole {
  return value === "minister" || value === "executive" ? value : "member";
}

function mapApplicationStatus(value: unknown): MembershipApplication["status"] {
  if (value === "approved" || value === "rejected") return value;
  if (value === "withdrawn" || value === "cancelled") return "cancelled";
  return "pending";
}

function mapBoardCategory(slug: unknown): Post["category"] {
  if (slug === "prayer") return "prayer";
  if (slug === "media") return "photo_video";
  if (slug === "fellowship") return "sharing";
  return "notice";
}

function rowOf(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}

function rowsOf(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value) ? value.filter((item) => item && typeof item === "object") as Array<Record<string, unknown>> : [];
}

function mapMembershipStatus(value: unknown): "active" | "suspended" | "revoked" {
  if (value === "suspended" || value === "revoked") return value;
  return "active";
}

const signedUrlCache = new Map<string, { url: string; expiresAt: number }>();

async function getCachedSignedUrl(bucket: "avatars" | "community-media", path: string) {
  const key = `${bucket}:${path}`;
  const cached = signedUrlCache.get(key);
  if (cached && cached.expiresAt > Date.now()) return cached.url;
  if (!supabase) return undefined;
  const { data, error: signedUrlError } = await supabase.storage.from(bucket).createSignedUrl(path, 3600);
  if (signedUrlError || !data?.signedUrl) return undefined;
  signedUrlCache.set(key, { url: data.signedUrl, expiresAt: Date.now() + 55 * 60 * 1000 });
  return data.signedUrl;
}

async function mapConversationSummaries(value: unknown, userId: string): Promise<Conversation[]> {
  return Promise.all(rowsOf(value).map(async (row) => {
    const participants = rowsOf(row.participants);
    const other = participants.find((participant) => String(participant.id) !== userId) ?? participants[0] ?? {};
    const lastMessage = rowOf(row.last_message);
    const avatarUrl = other.avatar_path ? await getCachedSignedUrl("avatars", String(other.avatar_path)) : undefined;
    const lastKind = String(lastMessage?.kind ?? "text");
    const lastBody = lastMessage?.body ? String(lastMessage.body) : "";
    return {
      id: String(row.id),
      organizationId: String(row.organization_id),
      participant: {
        id: String(other.id ?? "deleted-user"),
        displayName: String(other.display_name ?? "공동체 회원"),
        email: "",
        avatarUrl,
        globalRole: "user" as const,
      },
      lastMessage: lastBody || (lastKind === "video" ? "영상을 보냈습니다." : lastKind === "image" ? "사진을 보냈습니다." : "대화를 시작해 보세요."),
      lastMessageAt: String(lastMessage?.created_at ?? new Date(0).toISOString()),
      unreadCount: Number(row.unread_count ?? 0),
    };
  }));
}

function mapNotification(row: Record<string, unknown>): Notification {
  const entityType = String(row.entity_type ?? "");
  const entityId = row.entity_id ? String(row.entity_id) : undefined;
  const href = entityType === "conversation" && entityId
    ? `/app/chats/${entityId}`
    : entityType === "post" && entityId
      ? `/app/posts/${entityId}`
      : entityType === "membership_application"
        ? "/manage/approvals"
        : undefined;
  const metadata = rowOf(row.metadata);
  const reason = metadata?.reason ? String(metadata.reason) : undefined;
  return {
    id: String(row.id),
    title: String(row.title),
    body: reason ? `${String(row.body)} 사유: ${reason}` : String(row.body),
    createdAt: String(row.created_at),
    readAt: row.read_at ? String(row.read_at) : undefined,
    href,
  };
}

export function AppDataProvider({ children }: PropsWithChildren) {
  const [state, setState] = useState<AppDataState>(() =>
    isSupabaseConfigured ? { ...createDemoState(), mode: "supabase", loading: true, viewer: null } : readDemoState(),
  );
  const [error, setError] = useState<string | null>(null);
  const [hasMorePosts, setHasMorePosts] = useState(false);
  const postLimitRef = useRef(30);
  const stateRef = useRef(state);

  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  const persistDemo = useCallback((next: AppDataState) => {
    if (next.mode === "demo") window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify(next));
  }, []);

  const updateState = useCallback(
    (updater: (previous: AppDataState) => AppDataState) => {
      setState((previous) => {
        const next = updater(previous);
        persistDemo(next);
        return next;
      });
    },
    [persistDemo],
  );

  const loadRemote = useCallback(async () => {
    if (!supabase) return;
    setError(null);
    const { data: sessionData } = await supabase.auth.getSession();
    const user = sessionData.session?.user;
    if (!user) {
      setHasMorePosts(false);
      setState((previous) => ({ ...previous, mode: "supabase", loading: false, viewer: null }));
      return;
    }
    const postLimit = postLimitRef.current;

    const [contextResult, organizationsResult] = await Promise.all([
      supabase.rpc("get_my_context"),
      supabase
        .from("organizations")
        .select("id, source_name, display_name, slug, presbytery, description, location_text, contact_phone, website_url, worship_schedule, hero_path, status, claimed_at")
        .order("display_name"),
    ]);
    if (contextResult.error) throw contextResult.error;
    if (organizationsResult.error) throw organizationsResult.error;

    const contextRow = rowOf(contextResult.data) ?? {};
    const profileRow = rowOf(contextRow.profile) ?? {};
    const membershipRow = rowOf(contextRow.membership);
    const latestApplicationRow = rowOf(contextRow.latest_application) ?? rowOf(contextRow.pending_application);
    const membershipOrganizationId = membershipRow?.organization_id ? String(membershipRow.organization_id) : null;
    const membersRequest = membershipOrganizationId
      ? supabase
          .from("organization_memberships")
          .select("id, organization_id, user_id, role, status, joined_at")
          .eq("organization_id", membershipOrganizationId)
          .order("joined_at")
      : Promise.resolve({ data: [], error: null });

    const [boardsResult, postsResult, applicationsResult, membersResult, conversationsResult, notificationsResult] = await Promise.all([
      supabase.from("boards").select("id, organization_id, slug, name, staff_only_posting"),
      supabase
        .from("posts")
        .select("id, organization_id, board_id, author_id, author_label, title, body, status, is_system, is_pinned, published_at, created_at")
        .eq("status", "published")
        .order("is_pinned", { ascending: false })
        .order("published_at", { ascending: false })
        .limit(postLimit),
      supabase
        .from("membership_applications")
        .select("id, organization_id, user_id, requested_role, status, applicant_note, review_reason, created_at, reviewed_at")
        .eq("status", "pending")
        .order("created_at", { ascending: false }),
      membersRequest,
      supabase.rpc("get_conversation_summaries"),
      supabase
        .from("notifications")
        .select("id, kind, title, body, entity_type, entity_id, metadata, read_at, created_at")
        .order("created_at", { ascending: false })
        .limit(50),
    ]);

    const firstError = [
      boardsResult.error,
      postsResult.error,
      applicationsResult.error,
      membersResult.error,
      conversationsResult.error,
      notificationsResult.error,
    ].find(Boolean);
    if (firstError) throw firstError;

    const boardRows = rowsOf(boardsResult.data);
    const postRows = rowsOf(postsResult.data);
    const applicationRows = rowsOf(applicationsResult.data);
    const memberRows = rowsOf(membersResult.data);
    const conversationRows = rowsOf(conversationsResult.data);
    const postIds = postRows.map((row) => String(row.id));

    const [postMediaResult, commentsResult] = await Promise.all([
      postIds.length
        ? supabase.from("post_media").select("id, post_id, storage_path, kind, mime_type, byte_size, alt_text, sort_order").in("post_id", postIds).order("sort_order")
        : Promise.resolve({ data: [], error: null }),
      postIds.length
        ? supabase.from("comments").select("id, post_id, author_id, body, status, created_at").in("post_id", postIds).eq("status", "active").order("created_at")
        : Promise.resolve({ data: [], error: null }),
    ]);
    const relatedError = [postMediaResult.error, commentsResult.error].find(Boolean);
    if (relatedError) throw relatedError;

    const commentRows = rowsOf(commentsResult.data);
    const profileIds = new Set<string>([user.id]);
    for (const row of [...applicationRows, ...memberRows, ...postRows, ...commentRows]) {
      const id = row.user_id ?? row.author_id ?? row.sender_id;
      if (id) profileIds.add(String(id));
    }
    const profilesResult = await supabase
      .from("profiles")
      .select("id, display_name, avatar_path, bio")
      .in("id", Array.from(profileIds));
    if (profilesResult.error) throw profilesResult.error;

    const profileRows = rowsOf(profilesResult.data);
    const profileMap = new Map<string, { name: string; avatarUrl?: string; bio?: string }>();
    await Promise.all(profileRows.map(async (row) => {
      const id = String(row.id);
      const avatarUrl = row.avatar_path ? await getCachedSignedUrl("avatars", String(row.avatar_path)) : undefined;
      profileMap.set(id, {
        name: String(row.display_name ?? "공동체 회원"),
        avatarUrl,
        bio: row.bio ? String(row.bio) : undefined,
      });
    }));

    const mediaRows: Array<Record<string, unknown> & { signed_url?: string }> = await Promise.all(rowsOf(postMediaResult.data).map(async (row) => {
      const signedUrl = await getCachedSignedUrl("community-media", String(row.storage_path));
      return { ...row, signed_url: signedUrl };
    }));

    const boardMap = new Map(boardRows.map((row) => [String(row.id), row]));
    const applicationMap = (row: Record<string, unknown>): MembershipApplication => ({
      id: String(row.id),
      organizationId: String(row.organization_id),
      userId: String(row.user_id),
      applicantName: profileMap.get(String(row.user_id))?.name ?? "가입 신청자",
      requestedRole: mapRole(row.requested_role),
      status: mapApplicationStatus(row.status),
      applicantNote: row.applicant_note ? String(row.applicant_note) : undefined,
      reviewNote: row.review_reason ? String(row.review_reason) : undefined,
      createdAt: String(row.created_at),
      reviewedAt: row.reviewed_at ? String(row.reviewed_at) : undefined,
    });
    const applications = applicationRows.map(applicationMap);

    const conversations = await mapConversationSummaries(conversationRows, user.id);
    const messagesByConversation = Object.fromEntries(conversations.map((conversation) => [
      conversation.id,
      stateRef.current.messagesByConversation[conversation.id] ?? [],
    ]));
    const profile: Profile = {
      id: user.id,
      displayName: profileMap.get(user.id)?.name ?? String(profileRow.display_name ?? user.user_metadata.display_name ?? user.email?.split("@")[0] ?? "사용자"),
      email: user.email ?? "",
      avatarUrl: profileMap.get(user.id)?.avatarUrl,
      bio: profileMap.get(user.id)?.bio,
      globalRole: contextRow.is_platform_admin === true ? "platform_admin" : "user",
    };
    const viewerApplication = latestApplicationRow
      ? applications.find((item) => item.id === String(latestApplicationRow.id)) ?? applicationMap(latestApplicationRow)
      : undefined;

    setHasMorePosts(postRows.length === postLimit);

    setState({
      mode: "supabase",
      loading: false,
      viewer: {
        profile,
        membership: membershipRow ? {
          id: String(membershipRow.id),
          organizationId: String(membershipRow.organization_id),
          userId: String(membershipRow.user_id),
          role: mapRole(membershipRow.role),
          status: "active",
          approvedAt: membershipRow.joined_at ? String(membershipRow.joined_at) : undefined,
        } : undefined,
        application: viewerApplication,
      },
      organizations: rowsOf(organizationsResult.data).map((row) => ({
        id: String(row.id),
        sourceName: String(row.source_name),
        name: String(row.display_name),
        slug: String(row.slug),
        presbytery: String(row.presbytery),
        description: row.description ? String(row.description) : undefined,
        address: row.location_text ? String(row.location_text) : undefined,
        contact: row.contact_phone ? String(row.contact_phone) : undefined,
        worshipSchedule: Array.isArray(row.worship_schedule) ? row.worship_schedule.map(String) : undefined,
        status: row.status === "active" ? "active" : row.status === "archived" ? "archived" : "seeded",
        claimStatus: row.claimed_at ? "claimed" : "unclaimed",
      })),
      posts: postRows.map((row) => {
        const board = boardMap.get(String(row.board_id));
        const authorId = row.author_id ? String(row.author_id) : "operations";
        return {
          id: String(row.id),
          organizationId: row.organization_id ? String(row.organization_id) : undefined,
          authorId,
          authorName: row.author_label ? String(row.author_label) : profileMap.get(authorId)?.name ?? "공동체 회원",
          authorAvatarUrl: profileMap.get(authorId)?.avatarUrl,
          category: mapBoardCategory(board?.slug),
          title: String(row.title),
          body: String(row.body),
          isOfficial: row.is_system === true || board?.slug === "notice",
          isPinned: row.is_pinned === true,
          createdAt: String(row.published_at ?? row.created_at),
          media: mediaRows.filter((media) => String(media.post_id) === String(row.id) && media.signed_url).map((media) => ({
            id: String(media.id),
            kind: media.kind === "video" ? "video" as const : "image" as const,
            url: String(media.signed_url),
            alt: media.alt_text ? String(media.alt_text) : String(row.title),
            mimeType: String(media.mime_type),
            byteSize: Number(media.byte_size),
          })),
          comments: commentRows.filter((comment) => String(comment.post_id) === String(row.id)).map((comment) => ({
            id: String(comment.id),
            postId: String(row.id),
            authorId: String(comment.author_id ?? "deleted-user"),
            authorName: profileMap.get(String(comment.author_id))?.name ?? "공동체 회원",
            body: String(comment.body),
            createdAt: String(comment.created_at),
          })),
          reactionCount: 0,
        };
      }),
      applications,
      members: memberRows.map((row) => ({
        membershipId: String(row.id),
        organizationId: String(row.organization_id),
        userId: String(row.user_id),
        displayName: profileMap.get(String(row.user_id))?.name ?? "공동체 회원",
        avatarUrl: profileMap.get(String(row.user_id))?.avatarUrl,
        role: mapRole(row.role),
        status: mapMembershipStatus(row.status),
        joinedAt: String(row.joined_at),
      })),
      conversations,
      messagesByConversation,
      notifications: rowsOf(notificationsResult.data).map(mapNotification),
    });
  }, []);

  useEffect(() => {
    if (!supabase) return;
    void loadRemote().catch((reason: unknown) => {
      setError(reason instanceof Error ? reason.message : "서비스 데이터를 불러오지 못했습니다.");
      setState((previous) => ({ ...previous, loading: false }));
    });
    const { data } = supabase.auth.onAuthStateChange(() => {
      void loadRemote();
    });
    return () => data.subscription.unsubscribe();
  }, [loadRemote]);

  const enterDemo = useCallback((persona: "owner" | "member" | "new" = "owner") => {
    setError(null);
    updateState((previous) => ({ ...previous, mode: "demo", viewer: demoViewer(persona), loading: false }));
  }, [updateState]);

  const signIn = useCallback(async ({ email, password }: LoginInput) => {
    if (!supabase) {
      throw new Error("실서비스 로그인이 아직 연결되지 않았습니다. 아래의 역할별 미리보기를 이용해 주세요.");
    }
    setError(null);
    const { error: authError } = await supabase.auth.signInWithPassword({ email, password });
    if (authError) throw authError;
    await loadRemote();
  }, [loadRemote]);

  const signUp = useCallback(async ({ displayName, email, password }: SignUpInput) => {
    if (!supabase) {
      throw new Error("실서비스 회원가입이 아직 연결되지 않았습니다. 아래에서 신규 가입자 흐름을 미리볼 수 있어요.");
    }
    const { error: authError } = await supabase.auth.signUp({
      email,
      password,
      options: { data: { display_name: displayName } },
    });
    if (authError) throw authError;
    await loadRemote();
  }, [loadRemote]);

  const signOut = useCallback(async () => {
    if (supabase && state.mode === "supabase") await supabase.auth.signOut();
    updateState((previous) => ({ ...previous, viewer: null }));
  }, [state.mode, updateState]);

  const requestMembership = useCallback(async (input: MembershipRequestInput) => {
    if (!state.viewer) throw new Error("로그인이 필요합니다.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("submit_membership_application", {
        p_organization_id: input.organizationId,
        p_requested_role: input.requestedRole,
        p_applicant_note: input.note ?? null,
      });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    const application: MembershipApplication = {
      id: crypto.randomUUID(),
      organizationId: input.organizationId,
      userId: state.viewer.profile.id,
      applicantName: state.viewer.profile.displayName,
      applicantEmail: state.viewer.profile.email,
      requestedRole: input.requestedRole,
      status: "pending",
      applicantNote: input.note,
      createdAt: new Date().toISOString(),
    };
    updateState((previous) => ({
      ...previous,
      viewer: previous.viewer ? { ...previous.viewer, application } : null,
      applications: [application, ...previous.applications],
    }));
  }, [loadRemote, state.mode, state.viewer, updateState]);

  const createPost = useCallback(async (draft: PostDraft, onProgress?: (progress: number) => void) => {
    if (!state.viewer?.membership) throw new Error("승인된 회원만 글을 작성할 수 있습니다.");
    for (const file of draft.files) {
      const validation = validateMediaFile(file);
      if (validation) throw new Error(validation);
    }
    if (supabase && state.mode === "supabase") {
      const boardSlug: Record<Post["category"], string> = {
        notice: "notice",
        sharing: "fellowship",
        prayer: "prayer",
        photo_video: "media",
      };
      const { data: boardRow, error: boardError } = await supabase
        .from("boards")
        .select("id")
        .eq("organization_id", state.viewer.membership.organizationId)
        .eq("slug", boardSlug[draft.category])
        .single();
      if (boardError) throw boardError;
      const { data: postRow, error: postError } = await supabase
        .from("posts")
        .insert({
          organization_id: state.viewer.membership.organizationId,
          board_id: boardRow.id,
          author_id: state.viewer.profile.id,
          title: draft.title,
          body: draft.body,
          status: "draft",
          is_system: false,
        })
        .select("id, created_at")
        .single();
      if (postError) throw postError;
      const media = [];
      for (let index = 0; index < draft.files.length; index += 1) {
        const file = draft.files[index];
        const extension = file.name.split(".").pop()?.toLowerCase() || (file.type.startsWith("video/") ? "mp4" : "jpg");
        const objectPath = `${state.viewer.membership.organizationId}/posts/${postRow.id}/${crypto.randomUUID()}.${extension}`;
        const uploaded = await uploadCommunityFile(
          file,
          objectPath,
          (fileProgress) => onProgress?.((index + fileProgress) / draft.files.length),
        );
        const kind = file.type.startsWith("video/") ? "video" as const : "image" as const;
        const { data: mediaRow, error: mediaError } = await supabase.from("post_media").insert({
          post_id: postRow.id,
          uploader_id: state.viewer.profile.id,
          storage_path: uploaded.path,
          kind,
          mime_type: file.type,
          byte_size: file.size,
          alt_text: file.name,
          sort_order: index,
        }).select("id").single();
        if (mediaError) throw mediaError;
        media.push({
          id: String(mediaRow.id),
          kind: file.type.startsWith("video/") ? "video" as const : "image" as const,
          url: uploaded.url,
          name: file.name,
          mimeType: file.type,
          byteSize: file.size,
        });
      }
      const { data: publishedRow, error: publishError } = await supabase
        .from("posts")
        .update({ status: "published" })
        .eq("id", postRow.id)
        .select("published_at")
        .single();
      if (publishError) throw publishError;
      onProgress?.(1);
      const post: Post = {
        id: String(postRow.id),
        organizationId: state.viewer.membership.organizationId,
        authorId: state.viewer.profile.id,
        authorName: state.viewer.profile.displayName,
        category: draft.category,
        title: draft.title,
        body: draft.body,
        createdAt: String(publishedRow.published_at ?? postRow.created_at),
        media,
        comments: [],
        reactionCount: 0,
      };
      updateState((previous) => ({ ...previous, posts: [post, ...previous.posts] }));
      return post;
    }
    const media = draft.files.map((file) => ({
      id: crypto.randomUUID(),
      kind: file.type.startsWith("video/") ? "video" as const : "image" as const,
      url: URL.createObjectURL(file),
      name: file.name,
      mimeType: file.type,
      byteSize: file.size,
      alt: file.name,
    }));
    onProgress?.(1);
    const post: Post = {
      id: crypto.randomUUID(),
      organizationId: state.viewer.membership.organizationId,
      authorId: state.viewer.profile.id,
      authorName: state.viewer.profile.displayName,
      category: draft.category,
      title: draft.title,
      body: draft.body,
      createdAt: new Date().toISOString(),
      media,
      comments: [],
      reactionCount: 0,
    };
    updateState((previous) => ({ ...previous, posts: [post, ...previous.posts] }));
    return post;
  }, [state.mode, state.viewer, updateState]);

  const addComment = useCallback(async (postId: string, body: string) => {
    if (!state.viewer) throw new Error("로그인이 필요합니다.");
    if (supabase && state.mode === "supabase") {
      const { error: insertError } = await supabase.from("comments").insert({
        post_id: postId,
        author_id: state.viewer.profile.id,
        body,
      });
      if (insertError) throw insertError;
    }
    const comment: Comment = {
      id: crypto.randomUUID(),
      postId,
      authorId: state.viewer.profile.id,
      authorName: state.viewer.profile.displayName,
      body,
      createdAt: new Date().toISOString(),
    };
    updateState((previous) => ({
      ...previous,
      posts: previous.posts.map((post) => post.id === postId ? { ...post, comments: [...post.comments, comment] } : post),
    }));
  }, [state.mode, state.viewer, updateState]);

  const startConversation = useCallback(async (otherUserId: string) => {
    if (!state.viewer?.membership) throw new Error("승인된 회원만 대화를 시작할 수 있습니다.");
    const existing = state.conversations.find((conversation) => conversation.participant.id === otherUserId);
    if (existing) return existing.id;
    if (supabase && state.mode === "supabase") {
      const { data, error: rpcError } = await supabase.rpc("get_or_create_conversation", {
        p_other_user_id: otherUserId,
      });
      if (rpcError) throw rpcError;
      const conversationId = String(data);
      await loadRemote();
      return conversationId;
    }
    const member = state.members.find((item) => item.userId === otherUserId);
    if (!member) throw new Error("같은 교회의 활성 회원만 대화할 수 있습니다.");
    const conversationId = crypto.randomUUID();
    updateState((previous) => ({
      ...previous,
      conversations: [{
        id: conversationId,
        organizationId: member.organizationId,
        participant: {
          id: member.userId,
          displayName: member.displayName,
          email: "",
          avatarUrl: member.avatarUrl,
          globalRole: "user",
        },
        lastMessage: "대화를 시작해 보세요.",
        lastMessageAt: new Date().toISOString(),
        unreadCount: 0,
      }, ...previous.conversations],
      messagesByConversation: { ...previous.messagesByConversation, [conversationId]: [] },
    }));
    return conversationId;
  }, [loadRemote, state.conversations, state.members, state.mode, state.viewer, updateState]);

  const loadConversationMessages = useCallback(async (conversationId: string) => {
    if (!supabase || state.mode !== "supabase") return;
    const { data, error: messagesError } = await supabase
      .from("messages")
      .select("id, conversation_id, sender_id, kind, body, media_path, media_metadata, created_at")
      .eq("conversation_id", conversationId)
      .is("deleted_at", null)
      .order("created_at", { ascending: false })
      .limit(100);
    if (messagesError) throw messagesError;
    const rows = rowsOf(data).reverse();
    const messages = await Promise.all(rows.map(async (row): Promise<Message> => {
      const mediaUrl = row.media_path
        ? await getCachedSignedUrl("community-media", String(row.media_path))
        : undefined;
      return {
        id: String(row.id),
        conversationId,
        senderId: String(row.sender_id ?? "deleted-user"),
        body: row.body ? String(row.body) : "",
        createdAt: String(row.created_at),
        status: "sent",
        media: row.media_path && mediaUrl ? [{
          id: String(row.id),
          kind: row.kind === "video" ? "video" : "image",
          url: mediaUrl,
          name: rowOf(row.media_metadata)?.name ? String(rowOf(row.media_metadata)?.name) : undefined,
        }] : [],
      };
    }));
    const latest = messages[messages.length - 1];
    updateState((previous) => ({
      ...previous,
      messagesByConversation: { ...previous.messagesByConversation, [conversationId]: messages },
      conversations: previous.conversations.map((conversation) => conversation.id === conversationId && latest ? {
        ...conversation,
        lastMessage: latest.body || (latest.media[0]?.kind === "video" ? "영상을 보냈습니다." : "사진을 보냈습니다."),
        lastMessageAt: latest.createdAt,
      } : conversation),
    }));
  }, [state.mode, updateState]);

  const sendMessage = useCallback(async (conversationId: string, body: string, files: File[] = []) => {
    if (!state.viewer) throw new Error("로그인이 필요합니다.");
    for (const file of files) {
      const validation = validateMediaFile(file);
      if (validation) throw new Error(validation);
    }
    const message: Message = {
      id: crypto.randomUUID(),
      conversationId,
      senderId: state.viewer.profile.id,
      body,
      createdAt: new Date().toISOString(),
      status: "sending",
      media: files.map((file) => ({
        id: crypto.randomUUID(),
        kind: file.type.startsWith("video/") ? "video" as const : "image" as const,
        url: URL.createObjectURL(file),
        name: file.name,
      })),
    };
    updateState((previous) => ({
      ...previous,
      messagesByConversation: {
        ...previous.messagesByConversation,
        [conversationId]: [...(previous.messagesByConversation[conversationId] ?? []), message],
      },
    }));
    try {
      if (supabase && state.mode === "supabase") {
        if (body.trim()) {
          const { error: rpcError } = await supabase.rpc("send_message", {
            p_conversation_id: conversationId,
            p_kind: "text",
            p_body: body.trim(),
            p_media_path: null,
            p_media_metadata: {},
            p_client_nonce: message.id,
          });
          if (rpcError) throw rpcError;
        }
        const organizationId = state.conversations.find((item) => item.id === conversationId)?.organizationId
          ?? state.viewer.membership?.organizationId;
        if (!organizationId) throw new Error("대화의 교회 정보를 확인할 수 없습니다.");
        for (const file of files) {
          const extension = file.name.split(".").pop()?.toLowerCase() || (file.type.startsWith("video/") ? "mp4" : "jpg");
          const objectPath = `${organizationId}/messages/${conversationId}/${crypto.randomUUID()}.${extension}`;
          const uploaded = await uploadCommunityFile(file, objectPath, () => undefined);
          const { error: mediaMessageError } = await supabase.rpc("send_message", {
            p_conversation_id: conversationId,
            p_kind: file.type.startsWith("video/") ? "video" : "image",
            p_body: null,
            p_media_path: uploaded.path,
            p_media_metadata: { name: file.name, mime_type: file.type, byte_size: file.size },
            p_client_nonce: crypto.randomUUID(),
          });
          if (mediaMessageError) throw mediaMessageError;
        }
        await loadConversationMessages(conversationId);
        return;
      }
      updateState((previous) => ({
        ...previous,
        messagesByConversation: {
          ...previous.messagesByConversation,
          [conversationId]: (previous.messagesByConversation[conversationId] ?? []).map((item) =>
            item.id === message.id ? { ...item, status: "sent" } : item,
          ),
        },
      }));
    } catch (reason) {
      updateState((previous) => ({
        ...previous,
        messagesByConversation: {
          ...previous.messagesByConversation,
          [conversationId]: (previous.messagesByConversation[conversationId] ?? []).map((item) =>
            item.id === message.id ? { ...item, status: "failed" } : item,
          ),
        },
      }));
      throw reason;
    }
  }, [loadConversationMessages, state.conversations, state.mode, state.viewer, updateState]);

  const markConversationRead = useCallback(async (conversationId: string, messageId?: string) => {
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("mark_conversation_read", {
        p_conversation_id: conversationId,
        p_message_id: messageId ?? null,
      });
      if (rpcError) throw rpcError;
    }
    updateState((previous) => ({
      ...previous,
      conversations: previous.conversations.map((conversation) =>
        conversation.id === conversationId ? { ...conversation, unreadCount: 0 } : conversation,
      ),
    }));
  }, [state.mode, updateState]);

  const refreshConversationSummaries = useCallback(async () => {
    if (!supabase) return;
    const { data: sessionData } = await supabase.auth.getSession();
    const userId = sessionData.session?.user.id;
    if (!userId) return;
    const { data, error: summariesError } = await supabase.rpc("get_conversation_summaries");
    if (summariesError) throw summariesError;
    const conversations = await mapConversationSummaries(data, userId);
    updateState((previous) => ({ ...previous, conversations }));
  }, [updateState]);

  const refreshNotifications = useCallback(async () => {
    if (!supabase) return;
    const { data, error: notificationsError } = await supabase
      .from("notifications")
      .select("id, kind, title, body, entity_type, entity_id, metadata, read_at, created_at")
      .order("created_at", { ascending: false })
      .limit(50);
    if (notificationsError) throw notificationsError;
    updateState((previous) => ({ ...previous, notifications: rowsOf(data).map(mapNotification) }));
  }, [updateState]);

  const realtimeViewerId = state.viewer?.profile.id;
  useEffect(() => {
    if (!supabase || state.mode !== "supabase" || !realtimeViewerId) return;
    const realtimeClient = supabase;
    let aggregateTimer: number | undefined;
    let conversationTimer: number | undefined;
    let notificationTimer: number | undefined;
    const pendingConversationIds = new Set<string>();
    const reportRealtimeError = (reason: unknown) => {
      setError(reason instanceof Error ? reason.message : "실시간 데이터를 새로 고치지 못했습니다.");
    };
    const scheduleAggregateRefresh = () => {
      window.clearTimeout(aggregateTimer);
      aggregateTimer = window.setTimeout(() => {
        void loadRemote().catch(reportRealtimeError);
      }, 350);
    };
    const scheduleNotificationRefresh = () => {
      window.clearTimeout(notificationTimer);
      notificationTimer = window.setTimeout(() => {
        void refreshNotifications().catch(reportRealtimeError);
      }, 150);
    };
    const scheduleConversationRefresh = (conversationId?: string) => {
      if (conversationId) pendingConversationIds.add(conversationId);
      window.clearTimeout(conversationTimer);
      conversationTimer = window.setTimeout(() => {
        const ids = Array.from(pendingConversationIds);
        pendingConversationIds.clear();
        void Promise.all([
          refreshConversationSummaries(),
          ...ids.map((id) => loadConversationMessages(id)),
        ]).catch(reportRealtimeError);
      }, 120);
    };
    const channel = realtimeClient
      .channel(`jaegun-live-${realtimeViewerId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "messages" }, (payload) => {
        const changed = rowOf(payload.new) ?? rowOf(payload.old);
        scheduleConversationRefresh(changed?.conversation_id ? String(changed.conversation_id) : undefined);
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "conversation_reads" }, () => scheduleConversationRefresh())
      .on("postgres_changes", { event: "*", schema: "public", table: "conversations" }, () => scheduleConversationRefresh())
      .on("postgres_changes", { event: "*", schema: "public", table: "notifications" }, scheduleNotificationRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "membership_applications" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "organization_memberships" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "posts" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "comments" }, scheduleAggregateRefresh)
      .subscribe();
    return () => {
      window.clearTimeout(aggregateTimer);
      window.clearTimeout(conversationTimer);
      window.clearTimeout(notificationTimer);
      void realtimeClient.removeChannel(channel);
    };
  }, [loadConversationMessages, loadRemote, realtimeViewerId, refreshConversationSummaries, refreshNotifications, state.mode]);

  const reviewApplication = useCallback(async (
    applicationId: string,
    decision: "approved" | "rejected",
    note?: string,
  ) => {
    if (supabase && state.mode === "supabase") {
      if (decision === "rejected" && !note?.trim()) {
        throw new Error("반려 사유를 입력해 주세요.");
      }
      const { error: rpcError } = await supabase.rpc("review_membership_application", {
        p_application_id: applicationId,
        p_decision: decision === "approved" ? "approve" : "reject",
        p_reason: note ?? null,
      });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    updateState((previous) => ({
      ...previous,
      applications: previous.applications.map((application) =>
        application.id === applicationId
          ? { ...application, status: decision, reviewNote: note, reviewedAt: new Date().toISOString() }
          : application,
      ),
      members: decision === "approved"
        ? [
            ...previous.members,
            ...previous.applications
              .filter((application) => application.id === applicationId)
              .map((application) => ({
                membershipId: `demo-${application.id}`,
                organizationId: application.organizationId,
                userId: application.userId,
                displayName: application.applicantName,
                role: application.requestedRole,
                status: "active" as const,
                joinedAt: new Date().toISOString(),
              })),
          ]
        : previous.members,
    }));
  }, [loadRemote, state.mode, updateState]);

  const setMembershipStatus = useCallback(async (
    membershipId: string,
    status: "active" | "suspended" | "revoked",
    reason: string,
  ) => {
    if (!reason.trim()) throw new Error("상태 변경 사유를 입력해 주세요.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("set_membership_status", {
        p_membership_id: membershipId,
        p_status: status,
        p_reason: reason.trim(),
      });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    updateState((previous) => ({
      ...previous,
      members: previous.members.map((member) =>
        member.membershipId === membershipId ? { ...member, status } : member,
      ),
    }));
  }, [loadRemote, state.mode, updateState]);

  const markNotificationsRead = useCallback(async () => {
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("mark_notifications_read", {
        p_notification_ids: null,
      });
      if (rpcError) throw rpcError;
    }
    updateState((previous) => ({
      ...previous,
      notifications: previous.notifications.map((notification) => ({
        ...notification,
        readAt: notification.readAt ?? new Date().toISOString(),
      })),
    }));
  }, [state.mode, updateState]);

  const loadMorePosts = useCallback(async () => {
    if (!supabase || state.mode !== "supabase" || !hasMorePosts) return;
    postLimitRef.current += 30;
    await loadRemote();
  }, [hasMorePosts, loadRemote, state.mode]);

  const value = useMemo<AppDataContextValue>(() => ({
    ...state,
    error,
    hasMorePosts,
    enterDemo,
    signIn,
    signUp,
    signOut,
    requestMembership,
    createPost,
    addComment,
    startConversation,
    loadConversationMessages,
    sendMessage,
    markConversationRead,
    reviewApplication,
    setMembershipStatus,
    markNotificationsRead,
    loadMorePosts,
    refresh: loadRemote,
  }), [
    addComment,
    createPost,
    enterDemo,
    error,
    hasMorePosts,
    loadRemote,
    loadConversationMessages,
    loadMorePosts,
    markConversationRead,
    markNotificationsRead,
    requestMembership,
    reviewApplication,
    sendMessage,
    setMembershipStatus,
    startConversation,
    signIn,
    signOut,
    signUp,
    state,
  ]);

  return <AppDataContext.Provider value={value}>{children}</AppDataContext.Provider>;
}

export function useAppData() {
  const context = useContext(AppDataContext);
  if (!context) throw new Error("useAppData must be used inside AppDataProvider");
  return context;
}
