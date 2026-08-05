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
import {
  EXECUTIVE_OFFICE_CODES,
  isChurchTitleCode,
  isExecutiveOfficeCode,
} from "../types/domain";
import type {
  AppDataState,
  ChurchTitleCode,
  Comment,
  Conversation,
  ExecutiveOfficeCode,
  ExecutiveOfficesByYear,
  LedgerEntry,
  LedgerEntryInput,
  MeetingMinute,
  MeetingMinuteInput,
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
import { getServiceYear, millisecondsUntilNextServiceYear } from "../serviceTime";
import { executiveApprovalErrorMessage, getExecutiveApprovalIssue } from "../executiveApprovalPolicy";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

interface LoginInput {
  email: string;
  password: string;
}

type DemoPersona = "owner" | "member" | "new" | "minister" | "executive";

interface AppDataContextValue extends AppDataState {
  error: string | null;
  hasMorePosts: boolean;
  serviceYear: number;
  enterDemo: (persona?: DemoPersona, executiveOfficeCodes?: ExecutiveOfficeCode[]) => void;
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
  setExecutiveOffices: (
    membershipId: string,
    serviceYear: number,
    officeCodes: ExecutiveOfficeCode[],
  ) => Promise<void>;
  saveMeetingMinute: (input: MeetingMinuteInput) => Promise<void>;
  deleteMeetingMinute: (id: string) => Promise<void>;
  saveLedgerEntry: (input: LedgerEntryInput) => Promise<void>;
  deleteLedgerEntry: (id: string) => Promise<void>;
  markNotificationsRead: () => Promise<void>;
  loadMorePosts: () => Promise<void>;
  refresh: () => Promise<void>;
}

const AppDataContext = createContext<AppDataContextValue | null>(null);

function currentServiceYear() {
  return getServiceYear();
}

function normalizeExecutiveOfficeCodes(value: unknown): ExecutiveOfficeCode[] {
  const requested = Array.isArray(value) ? value.filter(isExecutiveOfficeCode) : [];
  return EXECUTIVE_OFFICE_CODES.filter((code) => requested.includes(code));
}

function normalizeExecutiveOfficesByYear(
  value: unknown,
  currentOfficeCodes: ExecutiveOfficeCode[] = [],
): ExecutiveOfficesByYear {
  const normalized: ExecutiveOfficesByYear = {};
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const [yearKey, officeCodes] of Object.entries(value)) {
      const year = Number(yearKey);
      const normalizedOfficeCodes = normalizeExecutiveOfficeCodes(officeCodes);
      if (Number.isInteger(year) && year >= 2000 && year <= 2100 && normalizedOfficeCodes.length) {
        normalized[year] = normalizedOfficeCodes;
      }
    }
  }
  if (currentOfficeCodes.length) normalized[currentServiceYear()] = currentOfficeCodes;
  return normalized;
}

function demoExecutiveOffices(role: MembershipRole, userId: string): ExecutiveOfficeCode[] {
  if (role !== "executive") return [];
  if (userId === "demo-owner") return ["president", "treasurer"];
  if (userId === "demo-executive") return ["general_secretary", "secretary"];
  return ["vice_president"];
}

function demoChurchTitle(role: MembershipRole, userId: string): ChurchTitleCode {
  if (role === "minister") return "pastor";
  if (role === "executive") return "elder";
  if (userId === "demo-haneul") return "kwonsa";
  if (userId === "demo-eunchan" || userId === "demo-member") return "deacon";
  return "congregant";
}

function withDemoDefaults(value: AppDataState): AppDataState {
  const serviceYear = currentServiceYear();
  const members = value.members.map((member) => {
    const storedByYear = normalizeExecutiveOfficesByYear(member.executiveOfficesByYear);
    const hasStoredYearAssignments = Object.keys(storedByYear).length > 0;
    const storedCurrentOffices = normalizeExecutiveOfficeCodes(member.executiveOfficeCodes);
    const currentOfficeCodes = member.role === "executive"
      ? hasStoredYearAssignments
        ? storedByYear[serviceYear] ?? []
        : storedCurrentOffices.length
          ? storedCurrentOffices
          : demoExecutiveOffices(member.role, member.userId)
      : [];
    return {
      ...member,
      churchTitleCode: member.churchTitleCode ?? demoChurchTitle(member.role, member.userId),
      executiveOfficeCodes: currentOfficeCodes,
      executiveOfficesByYear: member.role === "executive"
        ? normalizeExecutiveOfficesByYear(storedByYear, currentOfficeCodes)
        : {},
    };
  });
  const viewerMembership = value.viewer?.membership;
  const viewerMember = viewerMembership
    ? members.find((member) => member.membershipId === viewerMembership.id)
      ?? members.find((member) => member.userId === viewerMembership.userId
        && member.organizationId === viewerMembership.organizationId)
    : undefined;

  return {
    ...value,
    viewer: value.viewer ? {
      ...value.viewer,
      membership: viewerMembership ? {
        ...viewerMembership,
        churchTitleCode: viewerMembership.churchTitleCode
          ?? demoChurchTitle(viewerMembership.role, viewerMembership.userId),
        executiveOfficeCodes: viewerMembership.role === "executive"
          ? viewerMember?.executiveOfficeCodes
            ?? normalizeExecutiveOfficeCodes(viewerMembership.executiveOfficeCodes)
          : [],
      } : undefined,
      application: value.viewer.application ? {
        ...value.viewer.application,
        churchTitleCode: value.viewer.application.churchTitleCode
          ?? demoChurchTitle(value.viewer.application.requestedRole, value.viewer.application.userId),
        requestedExecutiveOfficeCodes: value.viewer.application.requestedRole === "executive"
          ? normalizeExecutiveOfficeCodes(value.viewer.application.requestedExecutiveOfficeCodes)
          : [],
        requestedServiceYear: value.viewer.application.requestedRole === "executive"
          ? value.viewer.application.requestedServiceYear
          : undefined,
      } : undefined,
    } : null,
    members,
    applications: value.applications.map((application) => ({
      ...application,
      churchTitleCode: application.churchTitleCode
        ?? demoChurchTitle(application.requestedRole, application.userId),
      requestedExecutiveOfficeCodes: application.requestedRole === "executive"
        ? normalizeExecutiveOfficeCodes(application.requestedExecutiveOfficeCodes)
        : [],
      requestedServiceYear: application.requestedRole === "executive"
        ? application.requestedServiceYear
        : undefined,
    })),
    meetingMinutes: Array.isArray(value.meetingMinutes) ? value.meetingMinutes : [],
    ledgerEntries: Array.isArray(value.ledgerEntries) ? value.ledgerEntries : [],
  };
}

function readDemoState(): AppDataState {
  const fresh = withDemoDefaults(createDemoState());
  try {
    const raw = window.localStorage.getItem(DEMO_STORAGE_KEY);
    if (!raw) return fresh;
    const parsed = JSON.parse(raw) as AppDataState;
    return withDemoDefaults({
      ...fresh,
      ...parsed,
      mode: "demo",
      loading: false,
      organizations: fresh.organizations,
    });
  } catch {
    return fresh;
  }
}

function demoViewer(persona: DemoPersona, executiveOfficeCodes?: ExecutiveOfficeCode[]): ViewerContext {
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
  const profile: Profile = persona === "owner"
    ? DEMO_VIEWER
    : persona === "minister"
      ? { id: "demo-minister", displayName: "한주원", email: "minister@jaegun.demo", globalRole: "user" }
      : persona === "executive"
        ? { id: "demo-executive", displayName: "최다니엘", email: "executive@jaegun.demo", globalRole: "user" }
        : { id: "demo-member", displayName: "이재건", email: "member@jaegun.demo", globalRole: "user" };
  const role: MembershipRole = persona === "owner" || persona === "executive"
    ? "executive"
    : persona === "minister"
      ? "minister"
      : "member";
  const selectedOffices = role === "executive"
    ? executiveOfficeCodes === undefined
      ? demoExecutiveOffices(role, profile.id)
      : normalizeExecutiveOfficeCodes(executiveOfficeCodes)
    : [];
  return {
    profile,
    membership: {
      organizationId: "org-19",
      userId: profile.id,
      role,
      churchTitleCode: role === "minister" ? "pastor" : role === "executive" ? "elder" : "deacon",
      executiveOfficeCodes: selectedOffices,
      status: "active",
      approvedAt: "2026-07-01T00:00:00.000Z",
    },
  };
}

function mapRole(value: unknown): MembershipRole {
  return value === "minister" || value === "executive" ? value : "member";
}

function mapChurchTitleCode(value: unknown): ChurchTitleCode | undefined {
  return isChurchTitleCode(value) ? value : undefined;
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

const EXECUTIVE_OPERATIONS_PAGE_SIZE = 500;
const MEMBERS_PAGE_SIZE = 500;
const PROFILE_ID_CHUNK_SIZE = 100;

async function fetchAllOrganizationMemberships(organizationId?: string) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += MEMBERS_PAGE_SIZE) {
    const request = supabase
      .from("organization_memberships")
      .select("id, organization_id, user_id, role, church_title_code, status, joined_at");
    const scopedRequest = organizationId ? request.eq("organization_id", organizationId) : request;
    const result = await scopedRequest
      .order("joined_at", { ascending: true })
      .order("id", { ascending: true })
      .range(from, from + MEMBERS_PAGE_SIZE - 1);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < MEMBERS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

async function fetchActiveExecutiveOfficeAssignments(serviceYear: number) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += MEMBERS_PAGE_SIZE) {
    const result = await supabase
      .from("executive_office_assignments")
      .select("membership_id, service_year, office_code")
      .in("service_year", [serviceYear, serviceYear + 1])
      .is("ended_at", null)
      .order("membership_id", { ascending: true })
      .order("service_year", { ascending: true })
      .order("office_code", { ascending: true })
      .range(from, from + MEMBERS_PAGE_SIZE - 1);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < MEMBERS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

async function fetchProfilesByIds(profileIds: string[]) {
  const client = supabase;
  if (!client || profileIds.length === 0) {
    return { data: [] as Array<Record<string, unknown>>, error: null };
  }
  const chunks: string[][] = [];
  for (let index = 0; index < profileIds.length; index += PROFILE_ID_CHUNK_SIZE) {
    chunks.push(profileIds.slice(index, index + PROFILE_ID_CHUNK_SIZE));
  }
  const results = await Promise.all(chunks.map((ids) =>
    client
      .from("profiles")
      .select("id, display_name, avatar_path, bio")
      .in("id", ids),
  ));
  const firstError = results.map((result) => result.error).find(Boolean);
  return {
    data: results.flatMap((result) => rowsOf(result.data)),
    error: firstError ?? null,
  };
}

async function fetchAllMeetingMinutes(organizationId: string) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += EXECUTIVE_OPERATIONS_PAGE_SIZE) {
    const result = await supabase
      .from("meeting_minutes")
      .select("id, organization_id, meeting_year, meeting_date, title, body, status, author_name, updated_at")
      .eq("organization_id", organizationId)
      .order("meeting_date", { ascending: false })
      .order("id", { ascending: true })
      .range(from, from + EXECUTIVE_OPERATIONS_PAGE_SIZE - 1);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < EXECUTIVE_OPERATIONS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

async function fetchAllLedgerEntries(organizationId: string) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += EXECUTIVE_OPERATIONS_PAGE_SIZE) {
    const result = await supabase
      .from("ledger_entries")
      .select("id, organization_id, fiscal_year, entry_date, entry_type, category, description, amount, memo, author_name, updated_at")
      .eq("organization_id", organizationId)
      .order("entry_date", { ascending: false })
      .order("id", { ascending: true })
      .range(from, from + EXECUTIVE_OPERATIONS_PAGE_SIZE - 1);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < EXECUTIVE_OPERATIONS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

function mapMembershipStatus(value: unknown): "active" | "suspended" | "revoked" {
  if (value === "suspended" || value === "revoked") return value;
  return "active";
}

function canWriteMeetingMinutes(viewer: ViewerContext | null): boolean {
  if (viewer?.membership?.role !== "executive") return false;
  return viewer.membership.executiveOfficeCodes.some((code) =>
    code === "president"
      || code === "vice_president"
      || code === "general_secretary"
      || code === "secretary",
  );
}

function canWriteLedger(viewer: ViewerContext | null): boolean {
  if (viewer?.membership?.role !== "executive") return false;
  return viewer.membership.executiveOfficeCodes.some((code) => code === "president" || code === "treasurer");
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
  const [serviceYear, setServiceYear] = useState(currentServiceYear);
  const [serverRolloverDeadline, setServerRolloverDeadline] = useState<number | null>(null);
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
      setServerRolloverDeadline(null);
      setHasMorePosts(false);
      setState((previous) => ({ ...previous, mode: "supabase", loading: false, viewer: null }));
      return;
    }
    const postLimit = postLimitRef.current;

    const [contextResult, organizationsResult, serviceClockResult] = await Promise.all([
      supabase.rpc("get_my_context"),
      supabase
        .from("organizations")
        .select("id, source_name, display_name, slug, presbytery, description, location_text, contact_phone, website_url, worship_schedule, hero_path, status, claimed_at")
        .order("display_name"),
      supabase.rpc("get_service_clock"),
    ]);
    if (contextResult.error) throw contextResult.error;
    if (organizationsResult.error) throw organizationsResult.error;
    if (serviceClockResult.error) throw serviceClockResult.error;

    const serviceClock = rowOf(serviceClockResult.data) ?? {};
    const serverServiceYear = Number(serviceClock.service_year);
    const millisecondsUntilServerRollover = Number(serviceClock.milliseconds_until_rollover);
    if (!Number.isInteger(serverServiceYear) || serverServiceYear < 2000 || serverServiceYear > 2100) {
      throw new Error("서버 운영 연도를 확인하지 못했습니다.");
    }
    if (!Number.isFinite(millisecondsUntilServerRollover) || millisecondsUntilServerRollover < 1) {
      throw new Error("서버 운영 연도 전환 시각을 확인하지 못했습니다.");
    }
    setServerRolloverDeadline(performance.now() + millisecondsUntilServerRollover);
    setServiceYear(serverServiceYear);

    const contextRow = rowOf(contextResult.data) ?? {};
    const profileRow = rowOf(contextRow.profile) ?? {};
    const membershipRow = rowOf(contextRow.membership);
    const latestApplicationRow = rowOf(contextRow.latest_application) ?? rowOf(contextRow.pending_application);
    const membershipOrganizationId = membershipRow?.organization_id ? String(membershipRow.organization_id) : null;
    const isPlatformAdmin = contextRow.is_platform_admin === true;
    const membersRequest = isPlatformAdmin
      ? fetchAllOrganizationMemberships()
      : membershipOrganizationId
        ? fetchAllOrganizationMemberships(membershipOrganizationId)
        : Promise.resolve({ data: [], error: null });
    const meetingMinutesRequest = membershipOrganizationId
      ? fetchAllMeetingMinutes(membershipOrganizationId)
      : Promise.resolve({ data: [], error: null });
    const ledgerEntriesRequest = membershipOrganizationId
      ? fetchAllLedgerEntries(membershipOrganizationId)
      : Promise.resolve({ data: [], error: null });

    const [
      boardsResult,
      postsResult,
      applicationsResult,
      membersResult,
      conversationsResult,
      notificationsResult,
      meetingMinutesResult,
      ledgerEntriesResult,
    ] = await Promise.all([
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
        .select("id, organization_id, user_id, requested_role, requested_church_title_code, requested_executive_office_codes, requested_service_year, status, applicant_note, review_reason, created_at, reviewed_at")
        .eq("status", "pending")
        .order("created_at", { ascending: false }),
      membersRequest,
      supabase.rpc("get_conversation_summaries"),
      supabase
        .from("notifications")
        .select("id, kind, title, body, entity_type, entity_id, metadata, read_at, created_at")
        .order("created_at", { ascending: false })
        .limit(50),
      meetingMinutesRequest,
      ledgerEntriesRequest,
    ]);

    const firstError = [
      boardsResult.error,
      postsResult.error,
      applicationsResult.error,
      membersResult.error,
      conversationsResult.error,
      notificationsResult.error,
      meetingMinutesResult.error,
      ledgerEntriesResult.error,
    ].find(Boolean);
    if (firstError) throw firstError;

    const boardRows = rowsOf(boardsResult.data);
    const postRows = rowsOf(postsResult.data);
    const applicationRows = rowsOf(applicationsResult.data);
    const memberRows = rowsOf(membersResult.data);
    const conversationRows = rowsOf(conversationsResult.data);
    const meetingMinuteRows = rowsOf(meetingMinutesResult.data);
    const ledgerEntryRows = rowsOf(ledgerEntriesResult.data);
    const postIds = postRows.map((row) => String(row.id));

    const [postMediaResult, commentsResult, executiveAssignmentsResult] = await Promise.all([
      postIds.length
        ? supabase.from("post_media").select("id, post_id, storage_path, kind, mime_type, byte_size, alt_text, sort_order").in("post_id", postIds).order("sort_order")
        : Promise.resolve({ data: [], error: null }),
      postIds.length
        ? supabase.from("comments").select("id, post_id, author_id, body, status, created_at").in("post_id", postIds).eq("status", "active").order("created_at")
        : Promise.resolve({ data: [], error: null }),
      fetchActiveExecutiveOfficeAssignments(serverServiceYear),
    ]);
    const relatedError = [postMediaResult.error, commentsResult.error, executiveAssignmentsResult.error].find(Boolean);
    if (relatedError) throw relatedError;

    const commentRows = rowsOf(commentsResult.data);
    const executiveOfficesByYearMap = new Map<string, ExecutiveOfficesByYear>();
    for (const row of rowsOf(executiveAssignmentsResult.data)) {
      const membershipId = String(row.membership_id);
      const officeCode = row.office_code;
      const serviceYear = Number(row.service_year);
      if (!isExecutiveOfficeCode(officeCode)
        || (serviceYear !== serverServiceYear && serviceYear !== serverServiceYear + 1)) continue;
      const officesByYear = executiveOfficesByYearMap.get(membershipId) ?? {};
      const current = officesByYear[serviceYear] ?? [];
      executiveOfficesByYearMap.set(membershipId, {
        ...officesByYear,
        [serviceYear]: normalizeExecutiveOfficeCodes([...current, officeCode]),
      });
    }
    const profileIds = new Set<string>([user.id]);
    for (const row of [...applicationRows, ...memberRows, ...postRows, ...commentRows]) {
      const id = row.user_id ?? row.author_id ?? row.sender_id;
      if (id) profileIds.add(String(id));
    }
    const profilesResult = await fetchProfilesByIds(Array.from(profileIds));
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
      churchTitleCode: mapChurchTitleCode(row.requested_church_title_code),
      requestedExecutiveOfficeCodes: normalizeExecutiveOfficeCodes(row.requested_executive_office_codes),
      requestedServiceYear: row.requested_service_year ? Number(row.requested_service_year) : undefined,
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
          churchTitleCode: mapChurchTitleCode(membershipRow.church_title_code),
          executiveOfficeCodes: executiveOfficesByYearMap.get(String(membershipRow.id))?.[serverServiceYear] ?? [],
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
      members: memberRows.map((row) => {
        const executiveOfficesByYear = executiveOfficesByYearMap.get(String(row.id)) ?? {};
        return {
          membershipId: String(row.id),
          organizationId: String(row.organization_id),
          userId: String(row.user_id),
          displayName: profileMap.get(String(row.user_id))?.name ?? "공동체 회원",
          avatarUrl: profileMap.get(String(row.user_id))?.avatarUrl,
          role: mapRole(row.role),
          churchTitleCode: mapChurchTitleCode(row.church_title_code),
          executiveOfficeCodes: executiveOfficesByYear[serverServiceYear] ?? [],
          executiveOfficesByYear,
          status: mapMembershipStatus(row.status),
          joinedAt: String(row.joined_at),
        };
      }),
      conversations,
      messagesByConversation,
      notifications: rowsOf(notificationsResult.data).map(mapNotification),
      meetingMinutes: meetingMinuteRows.map((row): MeetingMinute => ({
        id: String(row.id),
        organizationId: String(row.organization_id),
        meetingYear: Number(row.meeting_year),
        meetingDate: String(row.meeting_date),
        title: String(row.title),
        body: String(row.body),
        status: row.status === "published" ? "published" : "draft",
        authorName: String(row.author_name),
        updatedAt: String(row.updated_at),
      })),
      ledgerEntries: ledgerEntryRows.map((row): LedgerEntry => ({
        id: String(row.id),
        organizationId: String(row.organization_id),
        fiscalYear: Number(row.fiscal_year),
        entryDate: String(row.entry_date),
        entryType: row.entry_type === "income" ? "income" : "expense",
        category: String(row.category),
        description: String(row.description),
        amount: Number(row.amount),
        memo: row.memo ? String(row.memo) : undefined,
        authorName: String(row.author_name),
        updatedAt: String(row.updated_at),
      })),
    });
  }, []);

  useEffect(() => {
    if (!supabase) return;
    const handleRemoteLoadError = (reason: unknown) => {
      setServerRolloverDeadline(performance.now() + 60_000);
      setError(reason instanceof Error ? reason.message : "서비스 데이터를 불러오지 못했습니다.");
      setState((previous) => ({ ...previous, loading: false }));
    };
    void loadRemote().catch(handleRemoteLoadError);
    const { data } = supabase.auth.onAuthStateChange(() => {
      void loadRemote().catch(handleRemoteLoadError);
    });
    return () => data.subscription.unsubscribe();
  }, [loadRemote]);

  useEffect(() => {
    let observedServiceYear = currentServiceYear();
    let timer = 0;
    let cancelled = false;

    const refreshServiceYear = async () => {
      if (supabase && stateRef.current.mode === "supabase") {
        try {
          await loadRemote();
        } catch (reason) {
          setServerRolloverDeadline(performance.now() + 60_000);
          setError(reason instanceof Error ? reason.message : "새 연도 권한을 갱신하지 못했습니다.");
        }
        return;
      }

      const nextServiceYear = currentServiceYear();
      if (nextServiceYear === observedServiceYear) return;
      observedServiceYear = nextServiceYear;

      setServiceYear(nextServiceYear);
      updateState((previous) => {
        const members = previous.members.map((member) => ({
          ...member,
          executiveOfficeCodes: member.role === "executive"
            ? normalizeExecutiveOfficesByYear(member.executiveOfficesByYear)[nextServiceYear] ?? []
            : [],
        }));
        const viewerMembership = previous.viewer?.membership;
        const viewerMember = viewerMembership
          ? members.find((member) => member.membershipId === viewerMembership.id)
            ?? members.find((member) => member.userId === viewerMembership.userId
              && member.organizationId === viewerMembership.organizationId)
          : undefined;
        return {
          ...previous,
          members,
          viewer: previous.viewer && viewerMembership
            ? {
                ...previous.viewer,
                membership: {
                  ...viewerMembership,
                  executiveOfficeCodes: viewerMembership.role === "executive"
                    ? viewerMember?.executiveOfficeCodes ?? []
                    : [],
                },
              }
            : previous.viewer,
        };
      });

    };

    const scheduleServiceYearCheck = () => {
      if (cancelled) return;
      window.clearTimeout(timer);
      const sixHours = 6 * 60 * 60 * 1000;
      const serverDelay = serverRolloverDeadline === null
        ? sixHours
        : Math.max(serverRolloverDeadline - performance.now(), 1);
      const delay = stateRef.current.mode === "supabase"
        ? Math.min(serverDelay, sixHours)
        : Math.min(millisecondsUntilNextServiceYear(), sixHours);
      timer = window.setTimeout(() => {
        void refreshServiceYear().finally(() => {
          if (!cancelled) scheduleServiceYearCheck();
        });
      }, Math.max(delay, 1));
    };
    const refreshAfterResume = () => {
      if (document.visibilityState === "hidden") return;
      window.clearTimeout(timer);
      void refreshServiceYear().finally(() => {
        if (!cancelled) scheduleServiceYearCheck();
      });
    };

    scheduleServiceYearCheck();
    window.addEventListener("focus", refreshAfterResume);
    document.addEventListener("visibilitychange", refreshAfterResume);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      window.removeEventListener("focus", refreshAfterResume);
      document.removeEventListener("visibilitychange", refreshAfterResume);
    };
  }, [loadRemote, serverRolloverDeadline, updateState]);

  const enterDemo = useCallback((
    persona: DemoPersona = "owner",
    executiveOfficeCodes?: ExecutiveOfficeCode[],
  ) => {
    setError(null);
    updateState((previous) => {
      const viewer = demoViewer(persona, executiveOfficeCodes);
      const selectedOffices = normalizeExecutiveOfficeCodes(executiveOfficeCodes);
      const shouldApplySelectedOffices = persona === "executive" && executiveOfficeCodes !== undefined;
      const members = shouldApplySelectedOffices && viewer.membership
        ? previous.members.map((member) => {
            if (member.userId !== viewer.membership?.userId
              || member.organizationId !== viewer.membership.organizationId) return member;
            const executiveOfficesByYear = normalizeExecutiveOfficesByYear(member.executiveOfficesByYear);
            return {
              ...member,
              executiveOfficeCodes: selectedOffices,
              executiveOfficesByYear: {
                ...executiveOfficesByYear,
                [serviceYear]: selectedOffices,
              },
            };
          })
        : previous.members;
      return withDemoDefaults({
        ...previous,
        mode: "demo",
        viewer,
        members,
        loading: false,
      });
    });
  }, [serviceYear, updateState]);

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
    const requestedExecutiveOfficeCodes = normalizeExecutiveOfficeCodes(input.executiveOfficeCodes);
    if (input.requestedRole !== "executive" && (requestedExecutiveOfficeCodes.length || input.serviceYear !== undefined)) {
      throw new Error("임원 직책과 임기는 임원 역할을 신청할 때만 선택할 수 있습니다.");
    }
    if (input.requestedRole === "executive" && requestedExecutiveOfficeCodes.length === 0) {
      throw new Error("임원 직책을 한 개 이상 선택해 주세요.");
    }
    const requestedServiceYear = input.requestedRole === "executive"
      ? input.serviceYear ?? serviceYear
      : undefined;
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("submit_membership_application", {
        p_organization_id: input.organizationId,
        p_requested_role: input.requestedRole,
        p_applicant_note: input.note ?? null,
        p_requested_church_title_code: input.churchTitleCode ?? null,
        p_requested_executive_office_codes: requestedExecutiveOfficeCodes,
        p_requested_service_year: requestedServiceYear ?? null,
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
      churchTitleCode: input.churchTitleCode,
      requestedExecutiveOfficeCodes,
      requestedServiceYear,
      status: "pending",
      applicantNote: input.note,
      createdAt: new Date().toISOString(),
    };
    updateState((previous) => ({
      ...previous,
      viewer: previous.viewer ? { ...previous.viewer, application } : null,
      applications: [application, ...previous.applications],
    }));
  }, [loadRemote, serviceYear, state.mode, state.viewer, updateState]);

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
      .on("postgres_changes", { event: "*", schema: "public", table: "executive_office_assignments" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "meeting_minutes" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "ledger_entries" }, scheduleAggregateRefresh)
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
    const applicationToReview = stateRef.current.applications.find((application) => application.id === applicationId);
    if (decision === "approved" && applicationToReview) {
      const executiveIssue = getExecutiveApprovalIssue(applicationToReview, serviceYear);
      if (executiveIssue) throw new Error(executiveApprovalErrorMessage(executiveIssue));
    }
    if (supabase && state.mode === "supabase") {
      if (decision === "rejected" && !note?.trim()) {
        throw new Error("반려 사유를 입력해 주세요.");
      }
      const { error: rpcError } = await supabase.rpc("review_membership_application", {
        p_application_id: applicationId,
        p_decision: decision === "approved" ? "approve" : "reject",
        p_reason: note ?? null,
      });
      if (rpcError) {
        if (rpcError.message.includes("invalid_executive_service_year")) {
          throw new Error(executiveApprovalErrorMessage("invalid_service_year"));
        }
        if (rpcError.message.includes("executive_office_required")) {
          throw new Error(executiveApprovalErrorMessage("missing_offices"));
        }
        throw rpcError;
      }
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
              .map((application) => {
                const applicationServiceYear = application.requestedServiceYear ?? serviceYear;
                const isExecutive = application.requestedRole === "executive";
                return {
                  membershipId: `demo-${application.id}`,
                  organizationId: application.organizationId,
                  userId: application.userId,
                  displayName: application.applicantName,
                  role: application.requestedRole,
                  churchTitleCode: application.churchTitleCode,
                  executiveOfficeCodes: isExecutive && applicationServiceYear === serviceYear
                    ? application.requestedExecutiveOfficeCodes
                    : [],
                  executiveOfficesByYear: isExecutive
                    ? { [applicationServiceYear]: application.requestedExecutiveOfficeCodes }
                    : {},
                  status: "active" as const,
                  joinedAt: new Date().toISOString(),
                };
              }),
          ]
        : previous.members,
    }));
  }, [loadRemote, serviceYear, state.mode, updateState]);

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

  const setExecutiveOffices = useCallback(async (
    membershipId: string,
    assignmentYear: number,
    officeCodes: ExecutiveOfficeCode[],
  ) => {
    const viewer = state.viewer;
    if (viewer?.profile.globalRole !== "platform_admin") {
      throw new Error("플랫폼 관리자만 임원 직책을 지정할 수 있습니다.");
    }
    if (!Number.isInteger(assignmentYear)
      || (assignmentYear !== serviceYear && assignmentYear !== serviceYear + 1)) {
      throw new Error("임원 직책은 올해 또는 다음 연도에만 지정할 수 있습니다.");
    }
    if (officeCodes.some((code) => !isExecutiveOfficeCode(code))) {
      throw new Error("올바르지 않은 임원 직책이 포함되어 있습니다.");
    }
    const normalizedOfficeCodes = normalizeExecutiveOfficeCodes(officeCodes);
    if (normalizedOfficeCodes.length === 0) {
      throw new Error("임원 직책을 한 개 이상 선택해 주세요.");
    }
    const target = state.members.find((member) => member.membershipId === membershipId);
    if (!target || target.role !== "executive" || target.status !== "active") {
      throw new Error("활성 상태의 임원에게만 직책을 지정할 수 있습니다.");
    }

    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("set_executive_offices", {
        p_membership_id: membershipId,
        p_service_year: assignmentYear,
        p_office_codes: normalizedOfficeCodes,
      });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }

    updateState((previous) => ({
      ...previous,
      members: previous.members.map((member) => {
        if (member.membershipId !== membershipId) return member;
        const executiveOfficesByYear = normalizeExecutiveOfficesByYear(
          member.executiveOfficesByYear,
          member.executiveOfficeCodes,
        );
        return {
          ...member,
          executiveOfficeCodes: assignmentYear === serviceYear
            ? normalizedOfficeCodes
            : member.executiveOfficeCodes,
          executiveOfficesByYear: {
            ...executiveOfficesByYear,
            [assignmentYear]: normalizedOfficeCodes,
          },
        };
      }),
      viewer: previous.viewer?.membership?.userId === target.userId
        ? {
            ...previous.viewer,
            membership: {
              ...previous.viewer.membership,
              executiveOfficeCodes: assignmentYear === serviceYear
                ? normalizedOfficeCodes
                : previous.viewer.membership.executiveOfficeCodes,
            },
          }
        : previous.viewer,
    }));
  }, [loadRemote, serviceYear, state.members, state.mode, state.viewer, updateState]);

  const saveMeetingMinute = useCallback(async (input: MeetingMinuteInput) => {
    const viewer = state.viewer;
    if (!viewer) throw new Error("로그인이 필요합니다.");
    const organizationId = viewer.membership?.organizationId;
    if (!organizationId) throw new Error("승인된 교회 소속이 필요합니다.");
    if (!canWriteMeetingMinutes(viewer)) throw new Error("현재 직책에는 회의록 작성 권한이 없습니다.");
    if (input.meetingYear !== serviceYear) throw new Error("지난 연도 회의록은 열람만 할 수 있습니다.");
    const title = input.title.trim();
    const body = input.body.trim();
    if (!title || !body) throw new Error("회의록 제목과 내용을 입력해 주세요.");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(input.meetingDate) || Number(input.meetingDate.slice(0, 4)) !== input.meetingYear) {
      throw new Error("회의 연도와 회의 날짜를 확인해 주세요.");
    }
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("save_meeting_minute", {
        p_id: input.id ?? null,
        p_organization_id: organizationId,
        p_meeting_year: input.meetingYear,
        p_meeting_date: input.meetingDate,
        p_title: title,
        p_body: body,
        p_status: input.status,
      });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    const minute: MeetingMinute = {
      id: input.id ?? crypto.randomUUID(),
      organizationId,
      meetingYear: input.meetingYear,
      meetingDate: input.meetingDate,
      title,
      body,
      status: input.status,
      authorName: viewer.profile.displayName,
      updatedAt: new Date().toISOString(),
    };
    updateState((previous) => ({
      ...previous,
      meetingMinutes: [minute, ...previous.meetingMinutes.filter((item) => item.id !== minute.id)]
        .sort((left, right) => right.meetingDate.localeCompare(left.meetingDate)),
    }));
  }, [loadRemote, serviceYear, state.mode, state.viewer, updateState]);

  const deleteMeetingMinute = useCallback(async (id: string) => {
    if (!canWriteMeetingMinutes(state.viewer)) throw new Error("현재 직책에는 회의록 삭제 권한이 없습니다.");
    const target = state.meetingMinutes.find((item) => item.id === id);
    if (!target) throw new Error("삭제할 회의록을 찾을 수 없습니다.");
    if (target.meetingYear !== serviceYear) throw new Error("지난 연도 회의록은 삭제할 수 없습니다.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("delete_meeting_minute", { p_id: id });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    updateState((previous) => ({
      ...previous,
      meetingMinutes: previous.meetingMinutes.filter((item) => item.id !== id),
    }));
  }, [loadRemote, serviceYear, state.meetingMinutes, state.mode, state.viewer, updateState]);

  const saveLedgerEntry = useCallback(async (input: LedgerEntryInput) => {
    const viewer = state.viewer;
    if (!viewer) throw new Error("로그인이 필요합니다.");
    const organizationId = viewer.membership?.organizationId;
    if (!organizationId) throw new Error("승인된 교회 소속이 필요합니다.");
    if (!canWriteLedger(viewer)) throw new Error("현재 직책에는 회계장부 작성 권한이 없습니다.");
    if (input.fiscalYear !== serviceYear) throw new Error("지난 연도 회계장부는 열람만 할 수 있습니다.");
    const category = input.category.trim();
    const description = input.description.trim();
    const memo = input.memo?.trim() || undefined;
    if (!category || !description) throw new Error("회계 분류와 설명을 입력해 주세요.");
    if (!Number.isFinite(input.amount) || input.amount <= 0) throw new Error("금액은 0보다 큰 숫자로 입력해 주세요.");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(input.entryDate) || Number(input.entryDate.slice(0, 4)) !== input.fiscalYear) {
      throw new Error("회계연도와 거래 날짜를 확인해 주세요.");
    }
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("save_ledger_entry", {
        p_id: input.id ?? null,
        p_organization_id: organizationId,
        p_fiscal_year: input.fiscalYear,
        p_entry_date: input.entryDate,
        p_entry_type: input.entryType,
        p_category: category,
        p_description: description,
        p_amount: input.amount,
        p_memo: memo ?? null,
      });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    const entry: LedgerEntry = {
      id: input.id ?? crypto.randomUUID(),
      organizationId,
      fiscalYear: input.fiscalYear,
      entryDate: input.entryDate,
      entryType: input.entryType,
      category,
      description,
      amount: input.amount,
      memo,
      authorName: viewer.profile.displayName,
      updatedAt: new Date().toISOString(),
    };
    updateState((previous) => ({
      ...previous,
      ledgerEntries: [entry, ...previous.ledgerEntries.filter((item) => item.id !== entry.id)]
        .sort((left, right) => right.entryDate.localeCompare(left.entryDate)),
    }));
  }, [loadRemote, serviceYear, state.mode, state.viewer, updateState]);

  const deleteLedgerEntry = useCallback(async (id: string) => {
    if (!canWriteLedger(state.viewer)) throw new Error("현재 직책에는 회계장부 삭제 권한이 없습니다.");
    const target = state.ledgerEntries.find((item) => item.id === id);
    if (!target) throw new Error("삭제할 장부 항목을 찾을 수 없습니다.");
    if (target.fiscalYear !== serviceYear) throw new Error("지난 연도 회계장부는 삭제할 수 없습니다.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("delete_ledger_entry", { p_id: id });
      if (rpcError) throw rpcError;
      await loadRemote();
      return;
    }
    updateState((previous) => ({
      ...previous,
      ledgerEntries: previous.ledgerEntries.filter((item) => item.id !== id),
    }));
  }, [loadRemote, serviceYear, state.ledgerEntries, state.mode, state.viewer, updateState]);

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
    serviceYear,
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
    setExecutiveOffices,
    saveMeetingMinute,
    deleteMeetingMinute,
    saveLedgerEntry,
    deleteLedgerEntry,
    markNotificationsRead,
    loadMorePosts,
    refresh: loadRemote,
  }), [
    addComment,
    createPost,
    deleteLedgerEntry,
    deleteMeetingMinute,
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
    saveLedgerEntry,
    saveMeetingMinute,
    serviceYear,
    sendMessage,
    setMembershipStatus,
    setExecutiveOffices,
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
