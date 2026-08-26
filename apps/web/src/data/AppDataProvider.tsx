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
  Organization,
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
import { normalizeGovernanceAccess } from "./governance";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

interface LoginInput {
  email: string;
  password: string;
}

interface PendingMessageBatch {
  textNonce?: string;
  mediaNonces: string[];
  uploads?: Array<{
    path: string;
    url: string;
    name: string;
    mimeType: string;
    byteSize: number;
    kind: "image" | "video";
  }>;
}

interface PendingPostPublish {
  userId: string;
  post: Post;
  storagePaths: string[];
  sourceFiles: File[];
  fileFingerprints: string[];
}

interface PendingMessageReconciliation {
  userId: string;
  conversationId: string;
  nonces: string[];
  storagePaths: string[];
  createdAt: number;
}

type DemoPersona = "owner" | "member" | "new" | "minister" | "executive";

interface AppDataContextValue extends AppDataState {
  error: string | null;
  hasMorePosts: boolean;
  serviceYear: number;
  getServerNow: () => number;
  passwordRecoveryReady: boolean;
  enterDemo: (persona?: DemoPersona, executiveOfficeCodes?: ExecutiveOfficeCode[]) => void;
  signIn: (input: LoginInput) => Promise<void>;
  signUp: (input: SignUpInput) => Promise<void>;
  requestPasswordReset: (email: string) => Promise<void>;
  updatePassword: (password: string) => Promise<void>;
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
  ensurePost: (postId: string) => Promise<"loaded" | "not_found">;
  refresh: () => Promise<void>;
}

const AppDataContext = createContext<AppDataContextValue | null>(null);

const REMOTE_LOAD_TIMEOUT_MS = 20_000;
const SIGNED_URL_TIMEOUT_MS = 10_000;
const RECOVERY_SESSION_KEY = "jaegun-password-recovery-v1";
const RECOVERY_SESSION_TTL_MS = 30 * 60 * 1000;
const STORAGE_CLEANUP_STORAGE_KEY = "jaegun-storage-cleanup-v1";
const DRAFT_CLEANUP_STORAGE_KEY = "jaegun-draft-cleanup-v1";
const MESSAGE_RECONCILIATION_STORAGE_KEY = "jaegun-message-reconciliation-v1";

function mediaFileFingerprint(file: File) {
  return JSON.stringify([file.name, file.type, file.size, file.lastModified]);
}

function readMessageReconciliations(): PendingMessageReconciliation[] {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(MESSAGE_RECONCILIATION_STORAGE_KEY) ?? "[]") as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const value = item as Partial<PendingMessageReconciliation>;
      if (typeof value.userId !== "string"
        || typeof value.conversationId !== "string"
        || !Array.isArray(value.nonces)
        || !Array.isArray(value.storagePaths)
        || typeof value.createdAt !== "number") return [];
      const nonces = value.nonces.filter((nonce): nonce is string => typeof nonce === "string");
      const storagePaths = value.storagePaths.filter((path): path is string => typeof path === "string");
      return nonces.length ? [{ ...value, nonces, storagePaths } as PendingMessageReconciliation] : [];
    });
  } catch {
    return [];
  }
}

function writeMessageReconciliations(records: PendingMessageReconciliation[]) {
  try {
    window.localStorage.setItem(MESSAGE_RECONCILIATION_STORAGE_KEY, JSON.stringify(records));
  } catch {
    // The in-memory copy remains available for this page lifetime.
  }
}

function readStorageCleanupQueue() {
  const queue = new Map<string, Set<string>>();
  try {
    const parsed = JSON.parse(window.localStorage.getItem(STORAGE_CLEANUP_STORAGE_KEY) ?? "[]") as unknown;
    if (!Array.isArray(parsed)) return queue;
    for (const item of parsed) {
      if (!item || typeof item !== "object") continue;
      const entry = item as { userId?: unknown; paths?: unknown };
      if (typeof entry.userId !== "string" || !Array.isArray(entry.paths)) continue;
      const paths = entry.paths.filter((path): path is string => typeof path === "string" && Boolean(path));
      if (paths.length) queue.set(entry.userId, new Set(paths));
    }
  } catch {
    // Ignore corrupt or unavailable session storage.
  }
  return queue;
}

function writeStorageCleanupQueue(queue: Map<string, Set<string>>) {
  try {
    window.localStorage.setItem(STORAGE_CLEANUP_STORAGE_KEY, JSON.stringify(
      Array.from(queue, ([userId, paths]) => ({ userId, paths: Array.from(paths) })),
    ));
  } catch {
    // The in-memory queue remains available for this page lifetime.
  }
}

function readDraftCleanupQueue() {
  const queue = new Map<string, Set<string>>();
  try {
    const parsed = JSON.parse(window.localStorage.getItem(DRAFT_CLEANUP_STORAGE_KEY) ?? "[]") as unknown;
    if (!Array.isArray(parsed)) return queue;
    for (const item of parsed) {
      if (!item || typeof item !== "object") continue;
      const entry = item as { userId?: unknown; postIds?: unknown };
      if (typeof entry.userId !== "string" || !Array.isArray(entry.postIds)) continue;
      const postIds = entry.postIds.filter((id): id is string => typeof id === "string" && Boolean(id));
      if (postIds.length) queue.set(entry.userId, new Set(postIds));
    }
  } catch {
    // Ignore corrupt or unavailable session storage.
  }
  return queue;
}

function writeDraftCleanupQueue(queue: Map<string, Set<string>>) {
  try {
    window.localStorage.setItem(DRAFT_CLEANUP_STORAGE_KEY, JSON.stringify(
      Array.from(queue, ([userId, postIds]) => ({ userId, postIds: Array.from(postIds) })),
    ));
  } catch {
    // The in-memory queue remains available for this page lifetime.
  }
}

function readRecoverySession(userId: string) {
  try {
    const raw = window.sessionStorage.getItem(RECOVERY_SESSION_KEY);
    if (!raw) return null;
    const value = JSON.parse(raw) as { userId?: unknown; expiresAt?: unknown };
    return value.userId === userId
      && typeof value.expiresAt === "number"
      && value.expiresAt > Date.now()
      ? value.expiresAt
      : null;
  } catch {
    return null;
  }
}

function writeRecoverySession(userId: string) {
  const expiresAt = Date.now() + RECOVERY_SESSION_TTL_MS;
  try {
    window.sessionStorage.setItem(RECOVERY_SESSION_KEY, JSON.stringify({
      userId,
      expiresAt,
    }));
  } catch {
    // The in-memory verified event still works when session storage is blocked.
  }
  return expiresAt;
}

function removeRecoverySession() {
  try {
    window.sessionStorage.removeItem(RECOVERY_SESSION_KEY);
  } catch {
    // Nothing else should fail merely because browser storage is unavailable.
  }
}

function createEmptyState(mode: AppDataState["mode"], loading = false): AppDataState {
  return {
    mode,
    loading,
    viewer: null,
    organizations: [],
    posts: [],
    applications: [],
    members: [],
    conversations: [],
    messagesByConversation: {},
    notifications: [],
    meetingMinutes: [],
    ledgerEntries: [],
  };
}

const ORGANIZATION_DIRECTORY_FIELDS = "id, source_name, display_name, slug, presbytery, description, location_text, contact_phone, website_url, worship_schedule, hero_path, status, claimed_at";

function mapOrganizationDirectory(value: unknown): Organization[] {
  return rowsOf(value).map((row) => ({
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
  }));
}

function createAuthState(previous: AppDataState, mode: AppDataState["mode"], loading = false): AppDataState {
  return {
    ...createEmptyState(mode, loading),
    organizations: previous.organizations,
  };
}

function remoteLoadErrorMessage(reason: unknown) {
  const name = reason instanceof Error ? reason.name.toLowerCase() : "";
  const message = reason instanceof Error ? reason.message.toLowerCase() : "";
  if (name === "remoteloadtimeouterror" || message.includes("timeout") || message.includes("시간 초과")) {
    return "서비스 응답이 지연되고 있습니다. 잠시 후 다시 시도해 주세요.";
  }
  if (message.includes("network") || message.includes("failed to fetch") || message.includes("fetch failed")) {
    return "네트워크 연결을 확인한 뒤 다시 시도해 주세요.";
  }
  if (message.includes("session") || message.includes("jwt") || message.includes("refresh token")) {
    return "로그인 세션을 확인하지 못했습니다. 다시 로그인해 주세요.";
  }
  return "서비스 데이터를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

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

async function fetchAllOrganizationMemberships(organizationId?: string, signal?: AbortSignal) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += MEMBERS_PAGE_SIZE) {
    const request = supabase
      .from("organization_memberships")
      .select("id, organization_id, user_id, role, church_title_code, status, joined_at");
    const scopedRequest = organizationId ? request.eq("organization_id", organizationId) : request;
    const pageRequest = scopedRequest
      .order("joined_at", { ascending: true })
      .order("id", { ascending: true })
      .range(from, from + MEMBERS_PAGE_SIZE - 1);
    const result = await (signal ? pageRequest.abortSignal(signal) : pageRequest);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < MEMBERS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

async function fetchActiveExecutiveOfficeAssignments(serviceYear: number, signal?: AbortSignal) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += MEMBERS_PAGE_SIZE) {
    const pageRequest = supabase
      .from("executive_office_assignments")
      .select("membership_id, service_year, office_code")
      .in("service_year", [serviceYear, serviceYear + 1])
      .is("ended_at", null)
      .order("membership_id", { ascending: true })
      .order("service_year", { ascending: true })
      .order("office_code", { ascending: true })
      .range(from, from + MEMBERS_PAGE_SIZE - 1);
    const result = await (signal ? pageRequest.abortSignal(signal) : pageRequest);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < MEMBERS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

async function fetchProfilesByIds(profileIds: string[], signal?: AbortSignal) {
  const client = supabase;
  if (!client || profileIds.length === 0) {
    return { data: [] as Array<Record<string, unknown>>, error: null };
  }
  const chunks: string[][] = [];
  for (let index = 0; index < profileIds.length; index += PROFILE_ID_CHUNK_SIZE) {
    chunks.push(profileIds.slice(index, index + PROFILE_ID_CHUNK_SIZE));
  }
  const results = await Promise.all(chunks.map((ids) => {
    const request = client
      .from("profiles")
      .select("id, display_name, avatar_path, bio")
      .in("id", ids);
    return signal ? request.abortSignal(signal) : request;
  }));
  const firstError = results.map((result) => result.error).find(Boolean);
  return {
    data: results.flatMap((result) => rowsOf(result.data)),
    error: firstError ?? null,
  };
}

async function fetchAllMeetingMinutes(organizationId: string, signal?: AbortSignal) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += EXECUTIVE_OPERATIONS_PAGE_SIZE) {
    const pageRequest = supabase
      .from("meeting_minutes")
      .select("id, organization_id, meeting_year, meeting_date, title, body, status, author_name, updated_at")
      .eq("organization_id", organizationId)
      .order("meeting_date", { ascending: false })
      .order("id", { ascending: true })
      .range(from, from + EXECUTIVE_OPERATIONS_PAGE_SIZE - 1);
    const result = await (signal ? pageRequest.abortSignal(signal) : pageRequest);
    if (result.error) return { data, error: result.error };
    const page = rowsOf(result.data);
    data.push(...page);
    if (page.length < EXECUTIVE_OPERATIONS_PAGE_SIZE) break;
  }

  return { data, error: null };
}

async function fetchAllLedgerEntries(organizationId: string, signal?: AbortSignal) {
  if (!supabase) return { data: [] as Array<Record<string, unknown>>, error: null };
  const data: Array<Record<string, unknown>> = [];

  for (let from = 0; ; from += EXECUTIVE_OPERATIONS_PAGE_SIZE) {
    const pageRequest = supabase
      .from("ledger_entries")
      .select("id, organization_id, fiscal_year, entry_date, entry_type, category, description, amount, memo, author_name, updated_at")
      .eq("organization_id", organizationId)
      .order("entry_date", { ascending: false })
      .order("id", { ascending: true })
      .range(from, from + EXECUTIVE_OPERATIONS_PAGE_SIZE - 1);
    const result = await (signal ? pageRequest.abortSignal(signal) : pageRequest);
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
const signedUrlRequestCache = new Map<string, Promise<string | undefined>>();

async function getCachedSignedUrl(
  bucket: "avatars" | "community-media",
  path: string,
  isRequestCurrent: () => boolean = () => true,
) {
  const key = `${bucket}:${path}`;
  const cached = signedUrlCache.get(key);
  if (cached && cached.expiresAt > Date.now()) return cached.url;
  if (!supabase) return undefined;
  const client = supabase;
  const existingRequest = signedUrlRequestCache.get(key);
  if (existingRequest) {
    const url = await existingRequest;
    return isRequestCurrent() ? url : undefined;
  }
  const request = (async () => {
    let timeoutId: number | undefined;
    try {
      const storageRequest = client.storage.from(bucket).createSignedUrl(path, 3600)
        .then(({ data, error: signedUrlError }) => signedUrlError ? undefined : data?.signedUrl)
        .catch(() => undefined);
      return await Promise.race([
        storageRequest,
        new Promise<undefined>((resolve) => {
          timeoutId = window.setTimeout(() => resolve(undefined), SIGNED_URL_TIMEOUT_MS);
        }),
      ]);
    } finally {
      window.clearTimeout(timeoutId);
    }
  })();
  signedUrlRequestCache.set(key, request);
  try {
    const url = await request;
    if (!url || !isRequestCurrent()) return undefined;
    signedUrlCache.set(key, { url, expiresAt: Date.now() + 55 * 60 * 1000 });
    return url;
  } finally {
    if (signedUrlRequestCache.get(key) === request) signedUrlRequestCache.delete(key);
  }
}

async function mapConversationSummaries(
  value: unknown,
  userId: string,
  isRequestCurrent: () => boolean = () => true,
): Promise<Conversation[]> {
  return Promise.all(rowsOf(value).map(async (row) => {
    const participants = rowsOf(row.participants);
    const other = participants.find((participant) => String(participant.id) !== userId) ?? participants[0] ?? {};
    const lastMessage = rowOf(row.last_message);
    const avatarUrl = other.avatar_path
      ? await getCachedSignedUrl("avatars", String(other.avatar_path), isRequestCurrent)
      : undefined;
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
    isSupabaseConfigured ? createEmptyState("supabase", true) : readDemoState(),
  );
  const [error, setError] = useState<string | null>(null);
  const [hasMorePosts, setHasMorePosts] = useState(false);
  const [serviceYear, setServiceYear] = useState(currentServiceYear);
  const [serverRolloverDeadline, setServerRolloverDeadline] = useState<number | null>(null);
  const [governanceRefreshDeadline, setGovernanceRefreshDeadline] = useState<number | null>(null);
  const [passwordRecoveryReady, setPasswordRecoveryReady] = useState(false);
  const serverClockRef = useRef({
    unixMs: Date.now(),
    monotonicMs: performance.now(),
  });
  const postLimitRef = useRef(30);
  const stateRef = useRef(state);
  const remoteLoadGenerationRef = useRef(0);
  const remoteSessionEpochRef = useRef(0);
  const activeRemoteUserIdRef = useRef<string | null>(null);
  const remoteLoadsBlockedRef = useRef(false);
  const signOutPromiseRef = useRef<Promise<void> | null>(null);
  const pendingMessageBatchesRef = useRef(new Map<string, PendingMessageBatch>());
  const pendingPostPublishesRef = useRef(new Map<string, PendingPostPublish>());
  const pendingPostCreatesRef = useRef(new Map<string, Promise<Post>>());
  const pendingMessageReconciliationsRef = useRef(readMessageReconciliations());
  const pendingMeetingMinuteIdsRef = useRef(new Map<string, string>());
  const pendingMeetingMinuteSavesRef = useRef(new Map<string, Promise<string>>());
  const pendingLedgerEntryIdsRef = useRef(new Map<string, string>());
  const pendingLedgerEntrySavesRef = useRef(new Map<string, Promise<string>>());
  const recoveryUserIdRef = useRef<string | null>(null);
  const recoveryExpiresAtRef = useRef<number | null>(null);
  const conversationMessageLoadGenerationRef = useRef(new Map<string, number>());
  const conversationStateGenerationRef = useRef(new Map<string, number>());
  const conversationSummaryLoadGenerationRef = useRef(0);
  const storageCleanupQueueRef = useRef(readStorageCleanupQueue());
  const draftCleanupQueueRef = useRef(readDraftCleanupQueue());
  const optimisticMessageMediaRef = useRef(new Map<string, { conversationId: string; urls: string[] }>());
  const remoteLoadAbortControllerRef = useRef<AbortController | null>(null);
  const remoteLoadInFlightRef = useRef<{
    sessionEpoch: number;
    userId: string | null;
    promise: Promise<void>;
  } | null>(null);

  const getServerNow = useCallback(() => {
    const snapshot = serverClockRef.current;
    return snapshot.unixMs + Math.max(performance.now() - snapshot.monotonicMs, 0);
  }, []);
  const remoteRefreshQueuedRef = useRef(false);
  const loadRemoteRef = useRef<() => Promise<void>>(async () => undefined);

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
        stateRef.current = next;
        persistDemo(next);
        return next;
      });
    },
    [persistDemo],
  );

  const replaceState = useCallback((next: AppDataState) => {
    stateRef.current = next;
    persistDemo(next);
    setState(next);
  }, [persistDemo]);

  const clearPasswordRecovery = useCallback(() => {
    recoveryUserIdRef.current = null;
    recoveryExpiresAtRef.current = null;
    removeRecoverySession();
    setPasswordRecoveryReady(false);
  }, []);

  const queueStorageCleanup = useCallback((userId: string, paths: string[]) => {
    const pending = storageCleanupQueueRef.current.get(userId) ?? new Set<string>();
    for (const path of paths.filter(Boolean)) pending.add(path);
    storageCleanupQueueRef.current.set(userId, pending);
    writeStorageCleanupQueue(storageCleanupQueueRef.current);
  }, []);

  const removeOrQueueStoragePaths = useCallback(async (
    userId: string,
    paths: string[],
    sessionEpoch = remoteSessionEpochRef.current,
  ) => {
    const uniquePaths = Array.from(new Set(paths.filter(Boolean)));
    if (!supabase || uniquePaths.length === 0) return true;
    const isCleanupActorCurrent = () =>
      remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === userId
      && !remoteLoadsBlockedRef.current;
    if (!isCleanupActorCurrent()) {
      queueStorageCleanup(userId, uniquePaths);
      return false;
    }
    try {
      const result = await supabase.storage.from("community-media").remove(uniquePaths);
      if (result.error) throw result.error;
      if (!isCleanupActorCurrent()) {
        queueStorageCleanup(userId, uniquePaths);
        return false;
      }
      const pending = storageCleanupQueueRef.current.get(userId);
      if (pending) {
        for (const path of uniquePaths) pending.delete(path);
        if (pending.size === 0) storageCleanupQueueRef.current.delete(userId);
        writeStorageCleanupQueue(storageCleanupQueueRef.current);
      }
      return true;
    } catch {
      queueStorageCleanup(userId, uniquePaths);
      return false;
    }
  }, [queueStorageCleanup]);

  const queueDraftCleanup = useCallback((userId: string, postId: string) => {
    const pending = draftCleanupQueueRef.current.get(userId) ?? new Set<string>();
    pending.add(postId);
    draftCleanupQueueRef.current.set(userId, pending);
    writeDraftCleanupQueue(draftCleanupQueueRef.current);
  }, []);

  const clearStorageCleanupPaths = useCallback((userId: string, paths: string[]) => {
    const pending = storageCleanupQueueRef.current.get(userId);
    if (!pending) return;
    for (const path of paths) pending.delete(path);
    if (pending.size === 0) storageCleanupQueueRef.current.delete(userId);
    writeStorageCleanupQueue(storageCleanupQueueRef.current);
  }, []);

  const clearDraftCleanup = useCallback((userId: string, postId: string) => {
    const pending = draftCleanupQueueRef.current.get(userId);
    if (!pending) return;
    pending.delete(postId);
    if (pending.size === 0) draftCleanupQueueRef.current.delete(userId);
    writeDraftCleanupQueue(draftCleanupQueueRef.current);
  }, []);

  const clearPublishedPostCleanup = useCallback((userId: string, postId: string, livePaths: string[]) => {
    // A response-loss retry may have queued the now-live paths. They must never
    // be removed by a later cleanup flush after publication succeeds.
    const postPathMarker = `/posts/${postId}/`;
    const queuedPostPaths = Array.from(storageCleanupQueueRef.current.get(userId) ?? [])
      .filter((path) => path.includes(postPathMarker));
    clearStorageCleanupPaths(userId, livePaths);
    const livePathSet = new Set(livePaths);
    const orphanCandidates = queuedPostPaths.filter((path) => !livePathSet.has(path));
    if (orphanCandidates.length) queueDraftCleanup(userId, postId);
    else clearDraftCleanup(userId, postId);
  }, [clearDraftCleanup, clearStorageCleanupPaths, queueDraftCleanup]);

  const cleanupOrQueueDraftPost = useCallback(async (
    userId: string,
    postId: string,
    paths: string[],
    sessionEpoch = remoteSessionEpochRef.current,
  ) => {
    const uniquePaths = Array.from(new Set(paths.filter(Boolean)));
    if (!supabase || uniquePaths.length === 0) {
      clearDraftCleanup(userId, postId);
      return true;
    }
    const isCleanupActorCurrent = () =>
      remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === userId
      && !remoteLoadsBlockedRef.current;
    if (!isCleanupActorCurrent()) {
      queueStorageCleanup(userId, uniquePaths);
      queueDraftCleanup(userId, postId);
      return false;
    }
    try {
      const result = await supabase.rpc("prepare_post_media_cleanup", {
        p_post_id: postId,
        p_expected_author_id: userId,
        p_storage_paths: uniquePaths,
      });
      if (result.error || !isCleanupActorCurrent()) throw result.error ?? new Error("cleanup_actor_changed");
      const payload = rowOf(result.data) ?? {};
      const removablePaths = Array.isArray(payload.removable_paths)
        ? payload.removable_paths.filter((path): path is string => typeof path === "string")
        : [];
      const protectedPaths = Array.isArray(payload.protected_paths)
        ? payload.protected_paths.filter((path): path is string => typeof path === "string")
        : [];
      if (protectedPaths.length) clearStorageCleanupPaths(userId, protectedPaths);
      if (payload.status === "not_found") {
        clearStorageCleanupPaths(userId, uniquePaths);
        clearDraftCleanup(userId, postId);
        return true;
      }
      const removed = removablePaths.length
        ? await removeOrQueueStoragePaths(userId, removablePaths, sessionEpoch)
        : true;
      if (removed) clearDraftCleanup(userId, postId);
      else queueDraftCleanup(userId, postId);
      return removed;
    } catch {
      queueStorageCleanup(userId, uniquePaths);
      queueDraftCleanup(userId, postId);
      return false;
    }
  }, [clearDraftCleanup, clearStorageCleanupPaths, queueDraftCleanup, queueStorageCleanup, removeOrQueueStoragePaths]);

  const flushPostCleanupQueues = useCallback(async (userId: string) => {
    const sessionEpoch = remoteSessionEpochRef.current;
    const postIds = Array.from(draftCleanupQueueRef.current.get(userId) ?? []);
    for (const postId of postIds) {
      const postPathMarker = `/posts/${postId}/`;
      const postPaths = Array.from(storageCleanupQueueRef.current.get(userId) ?? [])
        .filter((path) => path.includes(postPathMarker));
      await cleanupOrQueueDraftPost(userId, postId, postPaths, sessionEpoch);
    }
    const remainingPaths = Array.from(storageCleanupQueueRef.current.get(userId) ?? []);
    for (const path of remainingPaths) {
      if (path.includes("/posts/")) continue;
      await removeOrQueueStoragePaths(userId, [path], sessionEpoch);
    }
  }, [cleanupOrQueueDraftPost, removeOrQueueStoragePaths]);

  const messageReconciliationKey = useCallback((record: Pick<PendingMessageReconciliation, "userId" | "conversationId" | "nonces">) =>
    `${record.userId}:${record.conversationId}:${[...record.nonces].sort().join(",")}`,
  []);

  const saveMessageReconciliation = useCallback((record: PendingMessageReconciliation) => {
    const key = messageReconciliationKey(record);
    pendingMessageReconciliationsRef.current = [
      ...pendingMessageReconciliationsRef.current.filter((item) => messageReconciliationKey(item) !== key),
      record,
    ];
    writeMessageReconciliations(pendingMessageReconciliationsRef.current);
  }, [messageReconciliationKey]);

  const clearMessageReconciliation = useCallback((record: Pick<PendingMessageReconciliation, "userId" | "conversationId" | "nonces">) => {
    const key = messageReconciliationKey(record);
    pendingMessageReconciliationsRef.current = pendingMessageReconciliationsRef.current
      .filter((item) => messageReconciliationKey(item) !== key);
    writeMessageReconciliations(pendingMessageReconciliationsRef.current);
  }, [messageReconciliationKey]);

  const flushMessageReconciliations = useCallback(async (userId: string) => {
    if (!supabase) return;
    const sessionEpoch = remoteSessionEpochRef.current;
    const isActorCurrent = () => remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === userId
      && !remoteLoadsBlockedRef.current;
    for (const record of pendingMessageReconciliationsRef.current.filter((item) => item.userId === userId)) {
      if (!isActorCurrent()) return;
      const result = await supabase.rpc("reconcile_message_batch", {
        p_conversation_id: record.conversationId,
        p_expected_sender_id: userId,
        p_client_nonces: record.nonces,
      });
      if (!isActorCurrent()) return;
      if (result.error) continue;
      const found = new Set(rowsOf(result.data).map((row) => String(row.client_nonce)));
      if (record.nonces.every((nonce) => found.has(nonce))) {
        clearMessageReconciliation(record);
      } else if (found.size === 0) {
        if (record.storagePaths.length) {
          await removeOrQueueStoragePaths(userId, record.storagePaths, sessionEpoch);
        }
        clearMessageReconciliation(record);
      }
    }
  }, [clearMessageReconciliation, removeOrQueueStoragePaths]);

  const revokeOptimisticMessageMedia = useCallback((messageId?: string, conversationId?: string) => {
    for (const [id, entry] of optimisticMessageMediaRef.current) {
      if ((messageId && id === messageId) || (conversationId && entry.conversationId === conversationId)) {
        for (const url of entry.urls) URL.revokeObjectURL(url);
        optimisticMessageMediaRef.current.delete(id);
      }
    }
  }, []);

  useEffect(() => () => {
    for (const entry of optimisticMessageMediaRef.current.values()) {
      for (const url of entry.urls) URL.revokeObjectURL(url);
    }
    optimisticMessageMediaRef.current.clear();
    remoteLoadAbortControllerRef.current?.abort();
    remoteLoadAbortControllerRef.current = null;
  }, []);

  const invalidateRemoteWork = useCallback((nextUserId: string | null, preserveActiveLoad = false) => {
    if (!preserveActiveLoad) {
      remoteLoadAbortControllerRef.current?.abort();
      remoteLoadAbortControllerRef.current = null;
      remoteRefreshQueuedRef.current = false;
    }
    remoteLoadGenerationRef.current += 1;
    remoteSessionEpochRef.current += 1;
    activeRemoteUserIdRef.current = nextUserId;
    postLimitRef.current = 30;
    pendingMessageBatchesRef.current.clear();
    for (const entry of optimisticMessageMediaRef.current.values()) {
      for (const url of entry.urls) URL.revokeObjectURL(url);
    }
    optimisticMessageMediaRef.current.clear();
    conversationMessageLoadGenerationRef.current.clear();
    conversationStateGenerationRef.current.clear();
    conversationSummaryLoadGenerationRef.current += 1;
    signedUrlCache.clear();
    signedUrlRequestCache.clear();
    setHasMorePosts(false);
    setServerRolloverDeadline(null);
    return {
      generation: remoteLoadGenerationRef.current,
      sessionEpoch: remoteSessionEpochRef.current,
    };
  }, []);

  const isRemoteActorCurrent = useCallback((sessionEpoch: number, userId: string) =>
    remoteSessionEpochRef.current === sessionEpoch
    && activeRemoteUserIdRef.current === userId
    && !remoteLoadsBlockedRef.current
    && stateRef.current.mode === "supabase"
    && stateRef.current.viewer?.profile.id === userId,
  []);

  const loadRemote = useCallback(async () => {
    if (!supabase || remoteLoadsBlockedRef.current || stateRef.current.mode !== "supabase") return;
    const existingLoad = remoteLoadInFlightRef.current;
    if (existingLoad
      && existingLoad.sessionEpoch === remoteSessionEpochRef.current
      && existingLoad.userId === activeRemoteUserIdRef.current) {
      remoteRefreshQueuedRef.current = true;
      return existingLoad.promise;
    }
    remoteLoadAbortControllerRef.current?.abort();
    const abortController = new AbortController();
    remoteLoadAbortControllerRef.current = abortController;
    let settleSharedLoad: () => void = () => undefined;
    const sharedLoad = new Promise<void>((resolve) => {
      settleSharedLoad = resolve;
    });
    const inFlightEntry = {
      sessionEpoch: remoteSessionEpochRef.current,
      userId: activeRemoteUserIdRef.current,
      promise: sharedLoad,
    };
    remoteLoadInFlightRef.current = inFlightEntry;
    let generation = ++remoteLoadGenerationRef.current;
    let sessionEpoch = remoteSessionEpochRef.current;
    let requestUserId = activeRemoteUserIdRef.current;
    const conversationStateGenerationsAtStart = new Map(conversationStateGenerationRef.current);
    let watchdogTimer: number | undefined;
    const isRequestCurrent = () =>
      remoteLoadGenerationRef.current === generation
      && remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === requestUserId
      && !remoteLoadsBlockedRef.current
      && stateRef.current.mode === "supabase";

    setError(null);
    if (!stateRef.current.viewer) {
      updateState((previous) => previous.mode === "supabase" ? { ...previous, loading: true } : previous);
    }

    const task = (async () => {
      const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
      if (sessionError) throw sessionError;
      if (remoteLoadGenerationRef.current !== generation || remoteSessionEpochRef.current !== sessionEpoch) return;

      const user = sessionData.session?.user;
      const nextUserId = user?.id ?? null;
      if (nextUserId !== activeRemoteUserIdRef.current) {
        const tokens = invalidateRemoteWork(nextUserId, true);
        generation = tokens.generation;
        sessionEpoch = tokens.sessionEpoch;
        requestUserId = nextUserId;
        inFlightEntry.sessionEpoch = sessionEpoch;
        inFlightEntry.userId = requestUserId;
        replaceState(createAuthState(stateRef.current, "supabase", Boolean(user)));
      }
      if (!user) {
        const organizationsResult = await supabase
          .from("organizations")
          .select(ORGANIZATION_DIRECTORY_FIELDS)
          .order("display_name")
          .abortSignal(abortController.signal);
        if (organizationsResult.error) throw organizationsResult.error;
        if (!isRequestCurrent()) return;
        replaceState({
          ...createEmptyState("supabase", false),
          organizations: mapOrganizationDirectory(organizationsResult.data),
        });
        setGovernanceRefreshDeadline(null);
        setError(null);
        return;
      }
      if (!isRequestCurrent()) return;
      const postLimit = postLimitRef.current;
      void flushPostCleanupQueues(user.id);
      void flushMessageReconciliations(user.id);

    const [contextResult, organizationsResult, serviceClockResult] = await Promise.all([
      supabase.rpc("get_my_context").abortSignal(abortController.signal),
      supabase
        .from("organizations")
        .select(ORGANIZATION_DIRECTORY_FIELDS)
        .order("display_name")
        .abortSignal(abortController.signal),
      supabase.rpc("get_service_clock").abortSignal(abortController.signal),
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
    const contextRow = rowOf(contextResult.data) ?? {};
    const profileRow = rowOf(contextRow.profile) ?? {};
    const membershipRow = rowOf(contextRow.membership);
    const latestApplicationRow = rowOf(contextRow.latest_application) ?? rowOf(contextRow.pending_application);
    const membershipOrganizationId = membershipRow?.organization_id ? String(membershipRow.organization_id) : null;
    const isPlatformAdmin = contextRow.is_platform_admin === true;
    const membersRequest = isPlatformAdmin
      ? fetchAllOrganizationMemberships(undefined, abortController.signal)
      : membershipOrganizationId
        ? fetchAllOrganizationMemberships(membershipOrganizationId, abortController.signal)
        : Promise.resolve({ data: [], error: null });
    const meetingMinutesRequest = membershipOrganizationId
      ? fetchAllMeetingMinutes(membershipOrganizationId, abortController.signal)
      : Promise.resolve({ data: [], error: null });
    const ledgerEntriesRequest = membershipOrganizationId
      ? fetchAllLedgerEntries(membershipOrganizationId, abortController.signal)
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
      supabase
        .from("boards")
        .select("id, organization_id, slug, name, staff_only_posting")
        .abortSignal(abortController.signal),
      supabase
        .from("posts")
        .select("id, organization_id, board_id, author_id, author_label, title, body, status, is_system, is_pinned, published_at, created_at")
        .eq("status", "published")
        .order("is_pinned", { ascending: false })
        .order("published_at", { ascending: false })
        .limit(postLimit)
        .abortSignal(abortController.signal),
      supabase
        .from("membership_applications")
        .select("id, organization_id, user_id, requested_role, requested_church_title_code, requested_executive_office_codes, requested_service_year, status, applicant_note, review_reason, created_at, reviewed_at")
        .eq("status", "pending")
        .order("created_at", { ascending: false })
        .abortSignal(abortController.signal),
      membersRequest,
      supabase.rpc("get_conversation_summaries").abortSignal(abortController.signal),
      supabase
        .from("notifications")
        .select("id, kind, title, body, entity_type, entity_id, metadata, read_at, created_at")
        .order("created_at", { ascending: false })
        .limit(50)
        .abortSignal(abortController.signal),
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
        ? supabase.from("post_media").select("id, post_id, storage_path, kind, mime_type, byte_size, alt_text, sort_order").in("post_id", postIds).order("sort_order").abortSignal(abortController.signal)
        : Promise.resolve({ data: [], error: null }),
      postIds.length
        ? supabase.from("comments").select("id, post_id, author_id, body, status, created_at").in("post_id", postIds).eq("status", "active").order("created_at").abortSignal(abortController.signal)
        : Promise.resolve({ data: [], error: null }),
      fetchActiveExecutiveOfficeAssignments(serverServiceYear, abortController.signal),
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
    const profilesResult = await fetchProfilesByIds(Array.from(profileIds), abortController.signal);
    if (profilesResult.error) throw profilesResult.error;

    const profileRows = rowsOf(profilesResult.data);
    const profileMap = new Map<string, { name: string; avatarUrl?: string; bio?: string }>();
    await Promise.all(profileRows.map(async (row) => {
      const id = String(row.id);
      const avatarUrl = row.avatar_path
        ? await getCachedSignedUrl("avatars", String(row.avatar_path), isRequestCurrent)
        : undefined;
      profileMap.set(id, {
        name: String(row.display_name ?? "공동체 회원"),
        avatarUrl,
        bio: row.bio ? String(row.bio) : undefined,
      });
    }));

    const mediaRows: Array<Record<string, unknown> & { signed_url?: string }> = await Promise.all(rowsOf(postMediaResult.data).map(async (row) => {
      const signedUrl = await getCachedSignedUrl("community-media", String(row.storage_path), isRequestCurrent);
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

    const conversations = await mapConversationSummaries(conversationRows, user.id, isRequestCurrent);
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
    const governanceAccess = normalizeGovernanceAccess(contextRow.governance_access);
    const organizationDirectory = mapOrganizationDirectory(organizationsResult.data);
    // Auth metadata is user-controlled: use it only to prefill onboarding, never as membership authority.
    const requestedOrganizationId = typeof user.user_metadata.signup_organization_id === "string"
      ? user.user_metadata.signup_organization_id
      : undefined;

    const nextState: AppDataState = {
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
        governanceAccess,
        signupOrganizationId: requestedOrganizationId
          && organizationDirectory.some((organization) => organization.id === requestedOrganizationId)
          ? requestedOrganizationId
          : undefined,
      },
      organizations: organizationDirectory,
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
    };
    if (!isRequestCurrent()) return;
    const currentMessages = stateRef.current.messagesByConversation;
    nextState.messagesByConversation = Object.fromEntries(nextState.conversations.map((conversation) => [
      conversation.id,
      currentMessages[conversation.id] ?? nextState.messagesByConversation[conversation.id] ?? [],
    ]));
    const currentConversationMap = new Map(stateRef.current.conversations.map((conversation) => [conversation.id, conversation]));
    nextState.conversations = nextState.conversations.map((conversation) => {
      const generationAtStart = conversationStateGenerationsAtStart.get(conversation.id) ?? 0;
      const currentGeneration = conversationStateGenerationRef.current.get(conversation.id) ?? 0;
      const currentConversation = currentConversationMap.get(conversation.id);
      return currentConversation && currentGeneration > generationAtStart
        ? {
            ...conversation,
            lastMessage: currentConversation.lastMessage,
            lastMessageAt: currentConversation.lastMessageAt,
            unreadCount: currentConversation.unreadCount,
          }
        : conversation;
    });
    const serverClockCapturedAt = performance.now();
    const serverNow = Date.UTC(serverServiceYear, 11, 31, 15, 0, 0, 0) - millisecondsUntilServerRollover;
    serverClockRef.current = {
      unixMs: serverNow,
      monotonicMs: serverClockCapturedAt,
    };
    setServerRolloverDeadline(serverClockCapturedAt + millisecondsUntilServerRollover);
    const nearestGovernanceExpiry = governanceAccess.reduce<number | null>((nearest, access) => {
      if (!access.expiresAt) return nearest;
      const expiry = Date.parse(access.expiresAt);
      if (!Number.isFinite(expiry)) return nearest;
      return nearest === null ? expiry : Math.min(nearest, expiry);
    }, null);
    setGovernanceRefreshDeadline(nearestGovernanceExpiry === null
      ? null
      : serverClockCapturedAt + Math.max(nearestGovernanceExpiry - serverNow, 1));
    setServiceYear(serverServiceYear);
    setHasMorePosts(postRows.length === postLimit);
    setError(null);
    replaceState(nextState);
    })();

    try {
      await Promise.race([
        task,
        new Promise<never>((_resolve, reject) => {
          watchdogTimer = window.setTimeout(() => {
            const timeoutError = new Error("서비스 응답이 지연되고 있습니다. 잠시 후 다시 시도해 주세요.");
            timeoutError.name = "RemoteLoadTimeoutError";
            reject(timeoutError);
            abortController.abort();
          }, REMOTE_LOAD_TIMEOUT_MS);
        }),
      ]);
    } catch (reason) {
      if (!isRequestCurrent()) return;
      remoteLoadGenerationRef.current += 1;
      setServerRolloverDeadline(performance.now() + 60_000);
      setError(remoteLoadErrorMessage(reason));
      updateState((previous) => previous.mode === "supabase" ? { ...previous, loading: false } : previous);
      throw reason;
    } finally {
      window.clearTimeout(watchdogTimer);
      settleSharedLoad();
      const shouldRunTrailingRefresh = remoteLoadInFlightRef.current === inFlightEntry
        && remoteRefreshQueuedRef.current;
      if (remoteLoadInFlightRef.current === inFlightEntry) {
        remoteLoadInFlightRef.current = null;
        remoteRefreshQueuedRef.current = false;
      }
      if (remoteLoadAbortControllerRef.current === abortController) {
        remoteLoadAbortControllerRef.current = null;
      }
      if (shouldRunTrailingRefresh
        && remoteSessionEpochRef.current === inFlightEntry.sessionEpoch
        && activeRemoteUserIdRef.current === inFlightEntry.userId
        && !remoteLoadsBlockedRef.current) {
        window.setTimeout(() => void loadRemoteRef.current().catch(() => undefined), 0);
      }
    }
  }, [flushMessageReconciliations, flushPostCleanupQueues, invalidateRemoteWork, replaceState, updateState]);

  useEffect(() => {
    loadRemoteRef.current = loadRemote;
  }, [loadRemote]);

  const scheduleRemoteRefresh = useCallback(() => {
    void loadRemote().catch(() => undefined);
  }, [loadRemote]);

  useEffect(() => {
    if (!supabase) return;
    let authLoadTimer: number | undefined;
    const scheduleRemoteLoad = () => {
      window.clearTimeout(authLoadTimer);
      authLoadTimer = window.setTimeout(() => {
        void loadRemote().catch(() => undefined);
      }, 0);
    };
    void loadRemote().catch(() => undefined);
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      const nextUserId = session?.user.id ?? null;
      if (event === "PASSWORD_RECOVERY" && nextUserId) {
        remoteLoadsBlockedRef.current = false;
        recoveryUserIdRef.current = nextUserId;
        recoveryExpiresAtRef.current = writeRecoverySession(nextUserId);
        setPasswordRecoveryReady(true);
      } else if (event === "INITIAL_SESSION" && nextUserId) {
        const recoveryExpiresAt = readRecoverySession(nextUserId);
        if (recoveryExpiresAt) {
          recoveryUserIdRef.current = nextUserId;
          recoveryExpiresAtRef.current = recoveryExpiresAt;
          setPasswordRecoveryReady(true);
        } else {
          clearPasswordRecovery();
        }
      } else if (!nextUserId || (recoveryUserIdRef.current && recoveryUserIdRef.current !== nextUserId)) {
        clearPasswordRecovery();
      }
      if (remoteLoadsBlockedRef.current || stateRef.current.mode === "demo") return;
      if (nextUserId !== activeRemoteUserIdRef.current) {
        invalidateRemoteWork(nextUserId);
        replaceState(createAuthState(stateRef.current, "supabase", Boolean(nextUserId)));
      }
      scheduleRemoteLoad();
    });
    return () => {
      window.clearTimeout(authLoadTimer);
      remoteLoadGenerationRef.current += 1;
      remoteSessionEpochRef.current += 1;
      signedUrlCache.clear();
      signedUrlRequestCache.clear();
      data.subscription.unsubscribe();
    };
  }, [clearPasswordRecovery, invalidateRemoteWork, loadRemote, replaceState]);

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
          setError(remoteLoadErrorMessage(reason));
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
      const governanceDelay = governanceRefreshDeadline === null
        ? sixHours
        : Math.max(governanceRefreshDeadline - performance.now(), 1);
      const delay = stateRef.current.mode === "supabase"
        ? Math.min(serverDelay, governanceDelay, sixHours)
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
  }, [governanceRefreshDeadline, loadRemote, serverRolloverDeadline, updateState]);

  const enterDemo = useCallback((
    persona: DemoPersona = "owner",
    executiveOfficeCodes?: ExecutiveOfficeCode[],
  ) => {
    const demoYear = currentServiceYear();
    const fresh = withDemoDefaults(createDemoState());
    const viewer = demoViewer(persona, executiveOfficeCodes);
    const selectedOffices = normalizeExecutiveOfficeCodes(executiveOfficeCodes);
    const shouldApplySelectedOffices = viewer.membership?.role === "executive"
      && executiveOfficeCodes !== undefined;
    const members = shouldApplySelectedOffices && viewer.membership
      ? fresh.members.map((member) => {
          if (member.userId !== viewer.membership?.userId
            || member.organizationId !== viewer.membership.organizationId) return member;
          return {
            ...member,
            executiveOfficeCodes: selectedOffices,
            executiveOfficesByYear: {
              ...normalizeExecutiveOfficesByYear(member.executiveOfficesByYear),
              [demoYear]: selectedOffices,
            },
          };
        })
      : fresh.members;
    clearPasswordRecovery();
    remoteLoadsBlockedRef.current = true;
    invalidateRemoteWork(null);
    setError(null);
    setServiceYear(demoYear);
    replaceState(withDemoDefaults({
      ...fresh,
      mode: "demo",
      viewer,
      members,
      loading: false,
    }));
  }, [clearPasswordRecovery, invalidateRemoteWork, replaceState]);

  const signIn = useCallback(async ({ email, password }: LoginInput) => {
    if (!supabase) {
      throw new Error("실서비스 로그인이 아직 연결되지 않았습니다. 아래의 역할별 미리보기를 이용해 주세요.");
    }
    if (signOutPromiseRef.current) await signOutPromiseRef.current;
    clearPasswordRecovery();
    remoteLoadsBlockedRef.current = false;
    invalidateRemoteWork(null);
    // Keep signed-out routes mounted while Supabase validates credentials.
    // The auth page owns its submitting state; toggling the global loader here
    // unmounts the form and drops the provider error returned to its caller.
    replaceState(createAuthState(stateRef.current, "supabase", false));
    setError(null);
    const { error: authError } = await supabase.auth.signInWithPassword({ email, password });
    if (authError) {
      replaceState(createAuthState(stateRef.current, "supabase", false));
      throw authError;
    }
    // onAuthStateChange owns the remote refresh so a successful login is not
    // reported as failed merely because the following data refresh is slow.
  }, [clearPasswordRecovery, invalidateRemoteWork, replaceState]);

  const signUp = useCallback(async ({ displayName, email, password, organizationId }: SignUpInput) => {
    if (!supabase) {
      throw new Error("실서비스 회원가입이 아직 연결되지 않았습니다. 아래에서 신규 가입자 흐름을 미리볼 수 있어요.");
    }
    if (signOutPromiseRef.current) await signOutPromiseRef.current;
    const selectedOrganization = stateRef.current.organizations.find((organization) => (
      organization.id === organizationId && organization.status !== "archived"
    ));
    if (!selectedOrganization) {
      throw new Error("선택한 교회를 확인하지 못했습니다. 노회와 교회를 다시 선택해 주세요.");
    }
    clearPasswordRecovery();
    remoteLoadsBlockedRef.current = false;
    invalidateRemoteWork(null);
    // Keep the signup form mounted so delivery/provider failures remain visible.
    // A session-bearing signup is moved into the global loading state by the
    // onAuthStateChange handler below.
    replaceState(createAuthState(stateRef.current, "supabase", false));
    setError(null);
    const { data, error: authError } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          display_name: displayName,
          signup_organization_id: selectedOrganization.id,
        },
      },
    });
    if (authError) {
      replaceState(createAuthState(stateRef.current, "supabase", false));
      throw authError;
    }
    if (!data.session) replaceState(createAuthState(stateRef.current, "supabase", false));
    // A session-bearing signup is refreshed by onAuthStateChange.
  }, [clearPasswordRecovery, invalidateRemoteWork, replaceState]);

  const requestPasswordReset = useCallback(async (email: string) => {
    if (!supabase) throw new Error("비밀번호 재설정 서비스가 아직 연결되지 않았습니다.");
    const normalizedEmail = email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail)) {
      throw new Error("올바른 이메일 주소를 입력해 주세요.");
    }
    const { error: resetError } = await supabase.auth.resetPasswordForEmail(normalizedEmail, {
      redirectTo: `${window.location.origin}/reset-password`,
    });
    if (resetError) throw resetError;
  }, []);

  const updatePassword = useCallback(async (password: string) => {
    if (!supabase) throw new Error("비밀번호 변경 서비스가 아직 연결되지 않았습니다.");
    if (password.length < 8) throw new Error("비밀번호는 8자 이상 입력해 주세요.");
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) throw sessionError;
    if (!sessionData.session?.user) throw new Error("비밀번호 재설정 링크가 만료되었습니다. 다시 요청해 주세요.");
    if (recoveryUserIdRef.current !== sessionData.session.user.id
      || (recoveryExpiresAtRef.current ?? 0) <= Date.now()) {
      clearPasswordRecovery();
      throw new Error("비밀번호 재설정 링크로 확인된 세션이 아닙니다. 새 링크를 요청해 주세요.");
    }
    remoteLoadsBlockedRef.current = true;
    const { error: updateError } = await supabase.auth.updateUser({ password });
    if (updateError) {
      remoteLoadsBlockedRef.current = false;
      throw updateError;
    }

    clearPasswordRecovery();
    invalidateRemoteWork(null);
    replaceState(createAuthState(stateRef.current, "supabase", false));
    setError(null);
    const { error: signOutError } = await supabase.auth.signOut();
    if (signOutError) {
      const { error: localSignOutError } = await supabase.auth.signOut({ scope: "local" });
      if (localSignOutError) {
        setError("비밀번호는 변경되었지만 세션 종료에 실패했습니다. 브라우저를 닫고 다시 로그인해 주세요.");
      }
    }
  }, [clearPasswordRecovery, invalidateRemoteWork, replaceState]);

  const signOut = useCallback((): Promise<void> => {
    if (signOutPromiseRef.current) return signOutPromiseRef.current;
    clearPasswordRecovery();
    remoteLoadsBlockedRef.current = true;
    invalidateRemoteWork(null);
    replaceState(createAuthState(
      stateRef.current,
      isSupabaseConfigured ? "supabase" : "demo",
      false,
    ));
    setError(null);
    const operation = (async () => {
      if (!supabase) return;
      const { error: signOutError } = await supabase.auth.signOut();
      if (signOutError) {
        const { error: localSignOutError } = await supabase.auth.signOut({ scope: "local" });
        if (localSignOutError) {
          const logoutError = new Error("로그아웃 상태를 저장하지 못했습니다. 안전을 위해 브라우저를 닫아 주세요.");
          setError(logoutError.message);
          throw logoutError;
        }
      }
    })();
    const trackedOperation = operation.finally(() => {
      if (signOutPromiseRef.current === trackedOperation) signOutPromiseRef.current = null;
    });
    signOutPromiseRef.current = trackedOperation;
    return trackedOperation;
  }, [clearPasswordRecovery, invalidateRemoteWork, replaceState]);

  const requestMembership = useCallback(async (input: MembershipRequestInput) => {
    if (!state.viewer) throw new Error("로그인이 필요합니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer.profile.id;
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
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      const application: MembershipApplication = {
        id: `pending-${crypto.randomUUID()}`,
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
      scheduleRemoteRefresh();
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
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.mode, state.viewer, updateState]);

  const createPost = useCallback(async (draft: PostDraft, onProgress?: (progress: number) => void) => {
    const viewer = state.viewer;
    const membership = viewer?.membership;
    if (!viewer || !membership) throw new Error("승인된 회원만 글을 작성할 수 있습니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = viewer.profile.id;
    for (const file of draft.files) {
      const validation = validateMediaFile(file);
      if (validation) throw new Error(validation);
    }
    if (supabase && state.mode === "supabase") {
      const remoteOperationKey = draft.clientOperationId
        ? `${requestUserId}:${draft.clientOperationId}`
        : JSON.stringify([
        requestUserId,
        membership.organizationId,
        draft.category,
        draft.title,
        draft.body,
        ...draft.files.map((file) => [file.name, file.type, file.size, file.lastModified]),
        ]);
      const existingCreate = pendingPostCreatesRef.current.get(remoteOperationKey);
      if (existingCreate) return existingCreate;
      const remoteCreate = (async () => {
      const client = supabase;
      const postOperationId = draft.clientOperationId ?? crypto.randomUUID();
      const publishKey = draft.clientOperationId
        ? `${requestUserId}:${draft.clientOperationId}`
        : JSON.stringify([
        requestUserId,
        membership.organizationId,
        draft.category,
        draft.title,
        draft.body,
        ...draft.files.map((file) => [file.name, file.type, file.size, file.lastModified]),
        ]);
      const finishPublishedPost = (post: Post) => {
        const liveStoragePaths = pendingPostPublishesRef.current.get(publishKey)?.storagePaths ?? [];
        pendingPostPublishesRef.current.delete(publishKey);
        clearPublishedPostCleanup(requestUserId, post.id, liveStoragePaths);
        onProgress?.(1);
        if (isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
          updateState((previous) => ({
            ...previous,
            posts: [post, ...previous.posts.filter((item) => item.id !== post.id)],
          }));
        }
        return post;
      };
      const readPostStatus = async (postId: string) => client.rpc("reconcile_post_operation", {
        p_post_id: postId,
        p_expected_author_id: requestUserId,
      });
      const publishOwnedPost = async (postId: string, storagePaths: string[]) => client.rpc("publish_owned_post", {
        p_post_id: postId,
        p_expected_author_id: requestUserId,
        p_expected_media_paths: storagePaths,
      });
      const boardSlug: Record<Post["category"], string> = {
        notice: "notice",
        sharing: "fellowship",
        prayer: "prayer",
        photo_video: "media",
      };
      const { data: boardRow, error: boardError } = await supabase
        .from("boards")
        .select("id")
        .eq("organization_id", membership.organizationId)
        .eq("slug", boardSlug[draft.category])
        .single();
      if (boardError) throw boardError;
      const saveOwnedDraft = async () => client.rpc("save_owned_post_draft", {
        p_post_id: postOperationId,
        p_expected_author_id: requestUserId,
        p_organization_id: membership.organizationId,
        p_board_id: boardRow.id,
        p_title: draft.title,
        p_body: draft.body,
      });
      const verifySavedDraft = (row: Record<string, unknown>) => {
        if (String(row.board_id) !== String(boardRow.id)
          || String(row.title) !== draft.title
          || String(row.body) !== draft.body) {
          throw new Error("게시글 초안에 최신 입력 내용이 반영되지 않았습니다. 다시 시도해 주세요.");
        }
      };
      const alreadyLoadedPost = stateRef.current.posts.find((post) => post.id === postOperationId);
      if (alreadyLoadedPost) return alreadyLoadedPost;
      const retryPending = pendingPostPublishesRef.current.get(publishKey);
      let retryRequiresFreshMedia = false;
      if (retryPending?.userId === requestUserId) {
        const statusResult = await saveOwnedDraft();
        if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
          throw new Error("계정이 변경되어 게시글 저장 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
        }
        if (statusResult.error) {
          throw new Error("게시글 저장 결과를 확인하지 못했습니다. 같은 내용으로 다시 시도해 주세요.");
        }
        const statusRow = rowOf(statusResult.data);
        if (statusRow?.status === "published") {
          return finishPublishedPost({
            ...retryPending.post,
            createdAt: String(statusRow.published_at ?? statusRow.created_at ?? retryPending.post.createdAt),
          });
        }
        if (statusRow?.status === "draft") {
          verifySavedDraft(statusRow);
          const currentFileFingerprints = draft.files.map(mediaFileFingerprint);
          const sameSourceFiles = retryPending.sourceFiles.length === draft.files.length
            && draft.files.every((file, index) => file === retryPending.sourceFiles[index]);
          const sameFingerprints = retryPending.fileFingerprints.length === currentFileFingerprints.length
            && currentFileFingerprints.every((fingerprint, index) => fingerprint === retryPending.fileFingerprints[index]);
          retryRequiresFreshMedia = statusRow.scope_recreated === true
            || !sameSourceFiles
            || !sameFingerprints;
          if (retryRequiresFreshMedia) {
            pendingPostPublishesRef.current.delete(publishKey);
            const cleaned = await cleanupOrQueueDraftPost(
              requestUserId,
              retryPending.post.id,
              retryPending.storagePaths,
              requestSessionEpoch,
            );
            if (!cleaned) {
              throw new Error("이전 첨부 파일을 안전하게 정리하지 못했습니다. 잠시 후 다시 시도해 주세요.");
            }
          } else {
            retryPending.post = {
              ...retryPending.post,
              category: draft.category,
              title: draft.title,
              body: draft.body,
            };
            const retryPublish = await publishOwnedPost(retryPending.post.id, retryPending.storagePaths);
            if (!retryPublish.error) {
              const retryPublishedRow = rowOf(retryPublish.data);
              return finishPublishedPost({
                ...retryPending.post,
                createdAt: String(retryPublishedRow?.published_at ?? retryPending.post.createdAt),
              });
            }
            if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
              throw new Error("계정이 변경되어 게시글 저장 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
            }
            const confirmation = await readPostStatus(retryPending.post.id);
            if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
              throw new Error("계정이 변경되어 게시글 저장 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
            }
            if (confirmation.error) {
              throw new Error("게시글 저장 결과를 확인하지 못했습니다. 같은 내용으로 다시 시도해 주세요.");
            }
            const confirmationRow = rowOf(confirmation.data);
            if (confirmationRow?.status === "published") {
              return finishPublishedPost({
                ...retryPending.post,
                createdAt: String(confirmationRow.published_at ?? confirmationRow.created_at ?? retryPending.post.createdAt),
              });
            }
            throw retryPublish.error;
          }
        }
        if (!retryRequiresFreshMedia) {
          pendingPostPublishesRef.current.delete(publishKey);
          await cleanupOrQueueDraftPost(
            requestUserId,
            retryPending.post.id,
            retryPending.storagePaths,
            requestSessionEpoch,
          );
        }
      }
      const saveResult = await saveOwnedDraft();
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
        throw new Error("계정이 변경되어 게시글 초안 저장을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
      }
      if (saveResult.error || !saveResult.data) throw saveResult.error ?? new Error("게시글 초안을 만들지 못했습니다.");
      const savedDraft = rowOf(saveResult.data) ?? {};
      if (savedDraft.status === "published") {
        const loaded = stateRef.current.posts.find((post) => post.id === postOperationId);
        if (loaded) return loaded;
        return finishPublishedPost({
          id: postOperationId,
          organizationId: membership.organizationId,
          authorId: viewer.profile.id,
          authorName: viewer.profile.displayName,
          category: draft.category,
          title: draft.title,
          body: draft.body,
          createdAt: String(savedDraft.published_at ?? savedDraft.created_at ?? new Date().toISOString()),
          media: [],
          comments: [],
          reactionCount: 0,
        });
      }
      if (savedDraft.status !== "draft") throw new Error("게시글 초안 상태를 확인하지 못했습니다.");
      verifySavedDraft(savedDraft);
      const postRow = {
        id: postOperationId,
        created_at: String(savedDraft.created_at ?? new Date().toISOString()),
      };
      const recoveredMediaPaths = Array.isArray(savedDraft.media_paths)
        ? savedDraft.media_paths.filter((path): path is string => typeof path === "string")
        : [];
      if (recoveredMediaPaths.length) {
        const recovered = await cleanupOrQueueDraftPost(
          requestUserId,
          postOperationId,
          recoveredMediaPaths,
          requestSessionEpoch,
        );
        if (!recovered) {
          throw new Error("이전 첨부 파일을 안전하게 정리하지 못했습니다. 잠시 후 같은 내용으로 다시 시도해 주세요.");
        }
      }
      const attemptedObjectPaths: string[] = [];
      try {
        const media = [];
        for (let index = 0; index < draft.files.length; index += 1) {
          const file = draft.files[index];
          const extension = file.name.split(".").pop()?.toLowerCase() || (file.type.startsWith("video/") ? "mp4" : "jpg");
          const objectPath = `${membership.organizationId}/posts/${postRow.id}/${crypto.randomUUID()}.${extension}`;
          // Record the intended path before upload: the object can exist even if
          // signing its URL fails after the bytes have already been stored.
          attemptedObjectPaths.push(objectPath);
          const uploaded = await uploadCommunityFile(
            file,
            objectPath,
            (fileProgress) => onProgress?.((index + fileProgress) / draft.files.length),
          );
          const kind = file.type.startsWith("video/") ? "video" as const : "image" as const;
          const { data: mediaRow, error: mediaError } = await supabase.from("post_media").insert({
            post_id: postRow.id,
            uploader_id: viewer.profile.id,
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
        const pendingPost: PendingPostPublish = {
          userId: requestUserId,
          storagePaths: [...attemptedObjectPaths],
          sourceFiles: [...draft.files],
          fileFingerprints: draft.files.map(mediaFileFingerprint),
          post: {
            id: String(postRow.id),
            organizationId: membership.organizationId,
            authorId: viewer.profile.id,
            authorName: viewer.profile.displayName,
            category: draft.category,
            title: draft.title,
            body: draft.body,
            createdAt: String(postRow.created_at),
            media,
            comments: [],
            reactionCount: 0,
          },
        };
        pendingPostPublishesRef.current.set(publishKey, pendingPost);
        if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
          attemptedObjectPaths.length = 0;
          throw new Error("계정이 변경되어 게시글 게시를 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
        }
        const { data: publishData, error: publishError } = await publishOwnedPost(
          String(postRow.id),
          pendingPost.storagePaths,
        );
        if (publishError) {
          if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
            attemptedObjectPaths.length = 0;
            throw new Error("계정이 변경되어 게시글 저장 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
          }
          const confirmation = await readPostStatus(String(postRow.id));
          if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
            attemptedObjectPaths.length = 0;
            throw new Error("계정이 변경되어 게시글 저장 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
          }
          if (confirmation.error) {
            attemptedObjectPaths.length = 0;
            throw new Error("게시글 저장 결과를 확인하지 못했습니다. 같은 내용으로 다시 시도해 주세요.");
          }
          const confirmationRow = rowOf(confirmation.data);
          if (confirmationRow?.status === "published") {
            return finishPublishedPost({
              ...pendingPost.post,
              createdAt: String(confirmationRow.published_at ?? confirmationRow.created_at ?? postRow.created_at),
            });
          }
          if (confirmationRow?.status === "draft") {
            attemptedObjectPaths.length = 0;
            throw publishError;
          }
          pendingPostPublishesRef.current.delete(publishKey);
          throw publishError;
        }
        const publishedRow = rowOf(publishData);
        return finishPublishedPost({
          ...pendingPost.post,
          createdAt: String(publishedRow?.published_at ?? postRow.created_at),
        });
      } catch (originalError) {
        if (pendingPostPublishesRef.current.has(publishKey)) throw originalError;
        if (attemptedObjectPaths.length) {
          await cleanupOrQueueDraftPost(
            requestUserId,
            String(postRow.id),
            attemptedObjectPaths,
            requestSessionEpoch,
          );
        }
        throw originalError;
      }
      })();
      pendingPostCreatesRef.current.set(remoteOperationKey, remoteCreate);
      try {
        return await remoteCreate;
      } finally {
        if (pendingPostCreatesRef.current.get(remoteOperationKey) === remoteCreate) {
          pendingPostCreatesRef.current.delete(remoteOperationKey);
        }
      }
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
      id: draft.clientOperationId ?? crypto.randomUUID(),
      organizationId: membership.organizationId,
      authorId: viewer.profile.id,
      authorName: viewer.profile.displayName,
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
  }, [cleanupOrQueueDraftPost, clearPublishedPostCleanup, isRemoteActorCurrent, state.mode, state.viewer, updateState]);

  const ensurePost = useCallback(async (postId: string): Promise<"loaded" | "not_found"> => {
    const normalizedPostId = postId.trim();
    if (!normalizedPostId) return "not_found";
    if (stateRef.current.posts.some((post) => post.id === normalizedPostId)) return "loaded";
    if (!supabase || stateRef.current.mode !== "supabase") return "not_found";

    const sessionEpoch = remoteSessionEpochRef.current;
    const userId = activeRemoteUserIdRef.current;
    if (!userId) throw new Error("로그인이 필요합니다.");
    const isRequestCurrent = () =>
      remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === userId
      && stateRef.current.mode === "supabase"
      && stateRef.current.viewer?.profile.id === userId;
    const assertRequestCurrent = () => {
      if (isRequestCurrent()) return;
      const cancelledError = new Error("사용자 변경으로 게시글 요청이 취소되었습니다.");
      cancelledError.name = "AbortError";
      throw cancelledError;
    };

    const { data: postData, error: postError } = await supabase
      .from("posts")
      .select("id, organization_id, board_id, author_id, author_label, title, body, status, is_system, is_pinned, published_at, created_at")
      .eq("id", normalizedPostId)
      .eq("status", "published")
      .maybeSingle();
    if (postError) throw postError;
    assertRequestCurrent();
    const postRow = rowOf(postData);
    if (!postRow) return "not_found";

    const [boardResult, mediaResult, commentsResult] = await Promise.all([
      supabase
        .from("boards")
        .select("id, slug")
        .eq("id", String(postRow.board_id))
        .maybeSingle(),
      supabase
        .from("post_media")
        .select("id, post_id, storage_path, kind, mime_type, byte_size, alt_text, sort_order")
        .eq("post_id", normalizedPostId)
        .order("sort_order"),
      supabase
        .from("comments")
        .select("id, post_id, author_id, body, status, created_at")
        .eq("post_id", normalizedPostId)
        .eq("status", "active")
        .order("created_at"),
    ]);
    const relatedError = [boardResult.error, mediaResult.error, commentsResult.error].find(Boolean);
    if (relatedError) throw relatedError;
    assertRequestCurrent();

    const commentRows = rowsOf(commentsResult.data);
    const authorId = postRow.author_id ? String(postRow.author_id) : "operations";
    const profileIds = Array.from(new Set([
      authorId,
      ...commentRows.map((comment) => comment.author_id ? String(comment.author_id) : "").filter(Boolean),
    ]));
    const profilesResult = await fetchProfilesByIds(profileIds);
    if (profilesResult.error) throw profilesResult.error;
    assertRequestCurrent();

    const profileMap = new Map<string, { name: string; avatarUrl?: string }>();
    await Promise.all(rowsOf(profilesResult.data).map(async (row) => {
      const avatarUrl = row.avatar_path
        ? await getCachedSignedUrl("avatars", String(row.avatar_path), isRequestCurrent)
        : undefined;
      profileMap.set(String(row.id), {
        name: String(row.display_name ?? "공동체 회원"),
        avatarUrl,
      });
    }));
    const media = await Promise.all(rowsOf(mediaResult.data).map(async (row) => ({
      row,
      url: await getCachedSignedUrl("community-media", String(row.storage_path), isRequestCurrent),
    })));
    assertRequestCurrent();

    const boardRow = rowOf(boardResult.data);
    const post: Post = {
      id: String(postRow.id),
      organizationId: postRow.organization_id ? String(postRow.organization_id) : undefined,
      authorId,
      authorName: postRow.author_label
        ? String(postRow.author_label)
        : profileMap.get(authorId)?.name ?? "공동체 회원",
      authorAvatarUrl: profileMap.get(authorId)?.avatarUrl,
      category: mapBoardCategory(boardRow?.slug),
      title: String(postRow.title),
      body: String(postRow.body),
      isOfficial: postRow.is_system === true || boardRow?.slug === "notice",
      isPinned: postRow.is_pinned === true,
      createdAt: String(postRow.published_at ?? postRow.created_at),
      media: media.flatMap(({ row, url }) => url ? [{
        id: String(row.id),
        kind: row.kind === "video" ? "video" as const : "image" as const,
        url,
        alt: row.alt_text ? String(row.alt_text) : String(postRow.title),
        mimeType: String(row.mime_type),
        byteSize: Number(row.byte_size),
      }] : []),
      comments: commentRows.map((comment) => ({
        id: String(comment.id),
        postId: normalizedPostId,
        authorId: String(comment.author_id ?? "deleted-user"),
        authorName: profileMap.get(String(comment.author_id))?.name ?? "공동체 회원",
        body: String(comment.body),
        createdAt: String(comment.created_at),
      })),
      reactionCount: 0,
    };
    assertRequestCurrent();
    updateState((previous) => {
      if (!isRequestCurrent()) return previous;
      return {
        ...previous,
        posts: previous.posts.some((item) => item.id === post.id)
          ? previous.posts.map((item) => item.id === post.id ? post : item)
          : [post, ...previous.posts],
      };
    });
    return "loaded";
  }, [updateState]);

  const addComment = useCallback(async (postId: string, body: string) => {
    if (!state.viewer) throw new Error("로그인이 필요합니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer.profile.id;
    if (supabase && state.mode === "supabase") {
      const { error: insertError } = await supabase.from("comments").insert({
        post_id: postId,
        author_id: state.viewer.profile.id,
        body,
      });
      if (insertError) throw insertError;
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
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
  }, [isRemoteActorCurrent, state.mode, state.viewer, updateState]);

  const startConversation = useCallback(async (otherUserId: string) => {
    if (!state.viewer?.membership) throw new Error("승인된 회원만 대화를 시작할 수 있습니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer.profile.id;
    const existing = state.conversations.find((conversation) => conversation.participant.id === otherUserId);
    if (existing) return existing.id;
    if (supabase && state.mode === "supabase") {
      const { data, error: rpcError } = await supabase.rpc("get_or_create_conversation", {
        p_other_user_id: otherUserId,
      });
      if (rpcError) throw rpcError;
      const conversationId = String(data);
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return conversationId;
      const member = state.members.find((item) => item.userId === otherUserId);
      if (member) {
        updateState((previous) => previous.conversations.some((item) => item.id === conversationId)
          ? previous
          : {
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
            });
      }
      scheduleRemoteRefresh();
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
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, state.conversations, state.members, state.mode, state.viewer, updateState]);

  const loadConversationMessages = useCallback(async (conversationId: string) => {
    if (!supabase || state.mode !== "supabase") return;
    const sessionEpoch = remoteSessionEpochRef.current;
    const userId = activeRemoteUserIdRef.current;
    const loadGeneration = (conversationMessageLoadGenerationRef.current.get(conversationId) ?? 0) + 1;
    conversationMessageLoadGenerationRef.current.set(conversationId, loadGeneration);
    conversationStateGenerationRef.current.set(
      conversationId,
      (conversationStateGenerationRef.current.get(conversationId) ?? 0) + 1,
    );
    const isRequestCurrent = () =>
      remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === userId
      && conversationMessageLoadGenerationRef.current.get(conversationId) === loadGeneration
      && stateRef.current.mode === "supabase"
      && stateRef.current.viewer?.profile.id === userId;
    const { data, error: messagesError } = await supabase
      .from("messages")
      .select("id, conversation_id, sender_id, kind, body, media_path, media_metadata, client_nonce, created_at")
      .eq("conversation_id", conversationId)
      .is("deleted_at", null)
      .order("created_at", { ascending: false })
      .limit(100);
    if (messagesError) throw messagesError;
    const rows = rowsOf(data).reverse();
    const messages = await Promise.all(rows.map(async (row): Promise<Message> => {
      const mediaUrl = row.media_path
        ? await getCachedSignedUrl("community-media", String(row.media_path), isRequestCurrent)
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
    if (!isRequestCurrent()) return;
    const serverNonces = new Set(rows
      .map((row) => row.client_nonce ? String(row.client_nonce) : "")
      .filter(Boolean));
    updateState((previous) => {
      const pending = (previous.messagesByConversation[conversationId] ?? []).filter((message) =>
        (message.status === "sending" || message.status === "failed")
        && !serverNonces.has(message.id),
      );
      const mergedMessages = [...messages, ...pending]
        .sort((left, right) => left.createdAt.localeCompare(right.createdAt));
      const latest = mergedMessages[mergedMessages.length - 1];
      return {
        ...previous,
        messagesByConversation: { ...previous.messagesByConversation, [conversationId]: mergedMessages },
        conversations: previous.conversations.map((conversation) => conversation.id === conversationId && latest ? {
          ...conversation,
          lastMessage: latest.body || (latest.media[0]?.kind === "video" ? "영상을 보냈습니다." : "사진을 보냈습니다."),
          lastMessageAt: latest.createdAt,
        } : conversation),
      };
    });
    for (const nonce of serverNonces) revokeOptimisticMessageMedia(nonce);
  }, [revokeOptimisticMessageMedia, state.mode, updateState]);

  const sendMessage = useCallback(async (conversationId: string, body: string, files: File[] = []) => {
    if (!state.viewer) throw new Error("로그인이 필요합니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer.profile.id;
    const normalizedBody = body.trim();
    if (!normalizedBody && files.length === 0) throw new Error("메시지 또는 첨부 파일을 입력해 주세요.");
    if (normalizedBody.length > 10_000) throw new Error("메시지는 10,000자 이하로 입력해 주세요.");
    if (files.length > 3) throw new Error("사진과 영상은 한 번에 최대 3개까지 보낼 수 있습니다.");
    for (const file of files) {
      const validation = validateMediaFile(file);
      if (validation) throw new Error(validation);
    }
    const batchKey = JSON.stringify([
      conversationId,
      normalizedBody,
      ...files.map((file) => [file.name, file.type, file.size, file.lastModified]),
    ]);
    const pendingBatch = pendingMessageBatchesRef.current.get(batchKey) ?? {
      textNonce: normalizedBody ? crypto.randomUUID() : undefined,
      mediaNonces: files.map(() => crypto.randomUUID()),
    };
    pendingMessageBatchesRef.current.set(batchKey, pendingBatch);
    conversationStateGenerationRef.current.set(
      conversationId,
      (conversationStateGenerationRef.current.get(conversationId) ?? 0) + 1,
    );
    const optimisticMessageId = pendingBatch.textNonce ?? pendingBatch.mediaNonces[0];
    revokeOptimisticMessageMedia(optimisticMessageId);
    const optimisticUrls = files.map((file) => URL.createObjectURL(file));
    if (optimisticUrls.length) {
      optimisticMessageMediaRef.current.set(optimisticMessageId, {
        conversationId,
        urls: optimisticUrls,
      });
    }
    const message: Message = {
      id: optimisticMessageId,
      conversationId,
      senderId: state.viewer.profile.id,
      body: normalizedBody,
      createdAt: new Date().toISOString(),
      status: "sending",
      media: files.map((file, index) => ({
        id: pendingBatch.mediaNonces[index],
        kind: file.type.startsWith("video/") ? "video" as const : "image" as const,
        url: optimisticUrls[index],
        name: file.name,
      })),
    };
    updateState((previous) => ({
      ...previous,
      messagesByConversation: {
        ...previous.messagesByConversation,
        [conversationId]: (previous.messagesByConversation[conversationId] ?? []).some((item) => item.id === message.id)
          ? (previous.messagesByConversation[conversationId] ?? []).map((item) => item.id === message.id ? message : item)
          : [...(previous.messagesByConversation[conversationId] ?? []), message],
      },
    }));
    const attemptedObjectPaths: string[] = [];
    try {
      if (supabase && state.mode === "supabase") {
        const organizationId = state.conversations.find((item) => item.id === conversationId)?.organizationId
          ?? state.viewer.membership?.organizationId;
        if (files.length && !organizationId) throw new Error("대화의 교회 정보를 확인할 수 없습니다.");
        let uploadedFiles = pendingBatch.uploads?.map((upload, index) => ({
          file: files[index],
          uploaded: { path: upload.path, url: upload.url },
          nonce: pendingBatch.mediaNonces[index],
        })) ?? [];
        if (uploadedFiles.length !== files.length) {
          uploadedFiles = [];
          for (let index = 0; index < files.length; index += 1) {
            const file = files[index];
            const extension = file.name.split(".").pop()?.toLowerCase() || (file.type.startsWith("video/") ? "mp4" : "jpg");
            const objectPath = `${organizationId}/messages/${conversationId}/${crypto.randomUUID()}.${extension}`;
            attemptedObjectPaths.push(objectPath);
            const uploaded = await uploadCommunityFile(file, objectPath, () => undefined);
            uploadedFiles.push({ file, uploaded, nonce: pendingBatch.mediaNonces[index] });
          }
          pendingBatch.uploads = uploadedFiles.map(({ file, uploaded }) => ({
            path: uploaded.path,
            url: uploaded.url,
            name: file.name,
            mimeType: file.type,
            byteSize: file.size,
            kind: file.type.startsWith("video/") ? "video" : "image",
          }));
        } else {
          attemptedObjectPaths.push(...uploadedFiles.map(({ uploaded }) => uploaded.path));
        }
        const items = [
          ...(normalizedBody ? [{
            kind: "text",
            body: normalizedBody,
            media_path: null,
            media_metadata: {},
            client_nonce: pendingBatch.textNonce,
          }] : []),
          ...uploadedFiles.map(({ file, uploaded, nonce }) => ({
            kind: file.type.startsWith("video/") ? "video" : "image",
            body: null,
            media_path: uploaded.path,
            media_metadata: { name: file.name, mime_type: file.type, byte_size: file.size },
            client_nonce: nonce,
          })),
        ];
        const expectedNonces = [
          ...(pendingBatch.textNonce ? [pendingBatch.textNonce] : []),
          ...pendingBatch.mediaNonces,
        ];
        const reconciliationRecord = (): PendingMessageReconciliation => ({
          userId: requestUserId,
          conversationId,
          nonces: expectedNonces,
          storagePaths: pendingBatch.uploads?.map((upload) => upload.path) ?? [...attemptedObjectPaths],
          createdAt: Date.now(),
        });
        if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
          await removeOrQueueStoragePaths(requestUserId, attemptedObjectPaths, requestSessionEpoch);
          pendingBatch.uploads = undefined;
          attemptedObjectPaths.length = 0;
          throw new Error("계정이 변경되어 메시지 전송을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
        }
        const { error: batchError } = await supabase.rpc("send_message_batch", {
          p_conversation_id: conversationId,
          p_expected_sender_id: requestUserId,
          p_messages: items,
        });
        if (batchError) {
          const record = reconciliationRecord();
          if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
            saveMessageReconciliation(record);
            attemptedObjectPaths.length = 0;
            throw new Error("계정이 변경되어 메시지 전송 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
          }
          const reconciliation = await supabase.rpc("reconcile_message_batch", {
            p_conversation_id: conversationId,
            p_expected_sender_id: requestUserId,
            p_client_nonces: expectedNonces,
          });
          if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
            saveMessageReconciliation(record);
            attemptedObjectPaths.length = 0;
            throw new Error("계정이 변경되어 메시지 전송 결과 확인을 중단했습니다. 원래 계정으로 다시 로그인해 주세요.");
          }
          if (reconciliation.error) {
            saveMessageReconciliation(record);
            attemptedObjectPaths.length = 0;
            throw new Error("메시지 전송 결과를 확인하지 못했습니다. 같은 내용으로 다시 시도해 주세요.");
          }
          const foundNonces = new Set(rowsOf(reconciliation.data).map((row) => String(row.client_nonce)));
          if (expectedNonces.every((nonce) => foundNonces.has(nonce))) {
            // The transaction committed and only the response was lost.
            clearMessageReconciliation(record);
          } else if (foundNonces.size === 0) {
            await removeOrQueueStoragePaths(requestUserId, attemptedObjectPaths, requestSessionEpoch);
            clearMessageReconciliation(record);
            pendingBatch.uploads = undefined;
            attemptedObjectPaths.length = 0;
            throw batchError;
          } else {
            saveMessageReconciliation(record);
            attemptedObjectPaths.length = 0;
            throw new Error("메시지 전송 상태를 확인 중입니다. 같은 내용으로 다시 시도해 주세요.");
          }
        }
        clearMessageReconciliation(reconciliationRecord());
        pendingMessageBatchesRef.current.delete(batchKey);
        if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
        updateState((previous) => ({
          ...previous,
          messagesByConversation: {
            ...previous.messagesByConversation,
            [conversationId]: (previous.messagesByConversation[conversationId] ?? []).map((item) =>
              item.id === message.id ? { ...item, status: "sent" } : item,
            ),
          },
        }));
        void loadConversationMessages(conversationId).catch(() => {
          setError("메시지는 전송되었지만 최신 대화를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.");
        });
        return;
      }
      pendingMessageBatchesRef.current.delete(batchKey);
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
      if (supabase && attemptedObjectPaths.length) {
        await removeOrQueueStoragePaths(requestUserId, attemptedObjectPaths);
        pendingBatch.uploads = undefined;
      }
      if (state.mode === "supabase" && !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) {
        throw reason;
      }
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
  }, [clearMessageReconciliation, isRemoteActorCurrent, loadConversationMessages, removeOrQueueStoragePaths, revokeOptimisticMessageMedia, saveMessageReconciliation, state.conversations, state.mode, state.viewer, updateState]);

  const markConversationRead = useCallback(async (conversationId: string, messageId?: string) => {
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer?.profile.id;
    conversationStateGenerationRef.current.set(
      conversationId,
      (conversationStateGenerationRef.current.get(conversationId) ?? 0) + 1,
    );
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("mark_conversation_read", {
        p_conversation_id: conversationId,
        p_message_id: messageId ?? null,
      });
      if (rpcError) throw rpcError;
      if (!requestUserId || !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
    }
    updateState((previous) => ({
      ...previous,
      conversations: previous.conversations.map((conversation) =>
        conversation.id === conversationId ? { ...conversation, unreadCount: 0 } : conversation,
      ),
    }));
  }, [isRemoteActorCurrent, state.mode, state.viewer?.profile.id, updateState]);

  const refreshConversationSummaries = useCallback(async () => {
    if (!supabase) return;
    const sessionEpoch = remoteSessionEpochRef.current;
    const expectedUserId = activeRemoteUserIdRef.current;
    const loadGeneration = ++conversationSummaryLoadGenerationRef.current;
    const stateGenerationsAtStart = new Map(conversationStateGenerationRef.current);
    const isRequestCurrent = () =>
      remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === expectedUserId
      && conversationSummaryLoadGenerationRef.current === loadGeneration
      && stateRef.current.mode === "supabase"
      && stateRef.current.viewer?.profile.id === expectedUserId;
    const { data: sessionData } = await supabase.auth.getSession();
    const userId = sessionData.session?.user.id;
    if (!userId || userId !== expectedUserId || !isRequestCurrent()) return;
    const { data, error: summariesError } = await supabase.rpc("get_conversation_summaries");
    if (summariesError) throw summariesError;
    const conversations = await mapConversationSummaries(data, userId, isRequestCurrent);
    if (!isRequestCurrent()) return;
    updateState((previous) => ({
      ...previous,
      conversations: conversations.map((conversation) => {
        const current = previous.conversations.find((item) => item.id === conversation.id);
        const changedSinceStart = (conversationStateGenerationRef.current.get(conversation.id) ?? 0)
          > (stateGenerationsAtStart.get(conversation.id) ?? 0);
        return current && changedSinceStart
          ? {
              ...conversation,
              lastMessage: current.lastMessage,
              lastMessageAt: current.lastMessageAt,
              unreadCount: current.unreadCount,
            }
          : conversation;
      }),
    }));
  }, [updateState]);

  const refreshNotifications = useCallback(async () => {
    if (!supabase) return;
    const sessionEpoch = remoteSessionEpochRef.current;
    const userId = activeRemoteUserIdRef.current;
    const isRequestCurrent = () =>
      remoteSessionEpochRef.current === sessionEpoch
      && activeRemoteUserIdRef.current === userId
      && stateRef.current.mode === "supabase"
      && stateRef.current.viewer?.profile.id === userId;
    const { data, error: notificationsError } = await supabase
      .from("notifications")
      .select("id, kind, title, body, entity_type, entity_id, metadata, read_at, created_at")
      .order("created_at", { ascending: false })
      .limit(50);
    if (notificationsError) throw notificationsError;
    if (!isRequestCurrent()) return;
    updateState((previous) => ({ ...previous, notifications: rowsOf(data).map(mapNotification) }));
  }, [updateState]);

  const realtimeViewerId = state.viewer?.profile.id;
  useEffect(() => {
    if (!supabase || state.mode !== "supabase" || !realtimeViewerId) return;
    const realtimeClient = supabase;
    const realtimeSessionEpoch = remoteSessionEpochRef.current;
    let cancelled = false;
    let aggregateTimer: number | undefined;
    let conversationTimer: number | undefined;
    let notificationTimer: number | undefined;
    const pendingConversationIds = new Set<string>();
    const reportRealtimeError = () => {
      if (cancelled
        || remoteSessionEpochRef.current !== realtimeSessionEpoch
        || activeRemoteUserIdRef.current !== realtimeViewerId
        || stateRef.current.viewer?.profile.id !== realtimeViewerId) return;
      setError("실시간 데이터를 새로 고치지 못했습니다. 잠시 후 다시 시도해 주세요.");
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
      .on("postgres_changes", { event: "*", schema: "public", table: "notifications" }, (payload) => {
        scheduleNotificationRefresh();
        const changed = rowOf(payload.new) ?? rowOf(payload.old);
        if (changed?.entity_type === "governance_scope" || changed?.entity_type === "governance_delegation") {
          scheduleAggregateRefresh();
        }
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "membership_applications" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "organization_memberships" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "executive_office_assignments" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "meeting_minutes" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "ledger_entries" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "posts" }, scheduleAggregateRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "comments" }, scheduleAggregateRefresh)
      .subscribe();
    return () => {
      cancelled = true;
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
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer?.profile.id;
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
      if (!requestUserId || !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      updateState((previous) => ({
        ...previous,
        applications: previous.applications.map((application) =>
          application.id === applicationId
            ? { ...application, status: decision, reviewNote: note, reviewedAt: new Date().toISOString() }
            : application,
        ),
      }));
      scheduleRemoteRefresh();
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
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.mode, state.viewer?.profile.id, updateState]);

  const setMembershipStatus = useCallback(async (
    membershipId: string,
    status: "active" | "suspended" | "revoked",
    reason: string,
  ) => {
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer?.profile.id;
    if (!reason.trim()) throw new Error("상태 변경 사유를 입력해 주세요.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("set_membership_status", {
        p_membership_id: membershipId,
        p_status: status,
        p_reason: reason.trim(),
      });
      if (rpcError) throw rpcError;
      if (!requestUserId || !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      scheduleRemoteRefresh();
    }
    updateState((previous) => ({
      ...previous,
      members: previous.members.map((member) =>
        member.membershipId === membershipId ? { ...member, status } : member,
      ),
    }));
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, state.mode, state.viewer?.profile.id, updateState]);

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
      const requestSessionEpoch = remoteSessionEpochRef.current;
      const requestUserId = viewer.profile.id;
      const { error: rpcError } = await supabase.rpc("set_executive_offices", {
        p_membership_id: membershipId,
        p_service_year: assignmentYear,
        p_office_codes: normalizedOfficeCodes,
      });
      if (rpcError) throw rpcError;
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      scheduleRemoteRefresh();
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
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.members, state.mode, state.viewer, updateState]);

  const saveMeetingMinute = useCallback(async (input: MeetingMinuteInput) => {
    const viewer = state.viewer;
    if (!viewer) throw new Error("로그인이 필요합니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = viewer.profile.id;
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
    let savedId = input.id ?? input.clientOperationId;
    if (supabase && state.mode === "supabase") {
      const saveKey = JSON.stringify([
        requestUserId,
        organizationId,
        input.id ?? input.clientOperationId ?? null,
        input.meetingYear,
        input.meetingDate,
        title,
        body,
        input.status,
      ]);
      const existingSave = pendingMeetingMinuteSavesRef.current.get(saveKey);
      if (existingSave) {
        await existingSave;
        return;
      }
      const stableId = input.id
        ?? input.clientOperationId
        ?? pendingMeetingMinuteIdsRef.current.get(saveKey)
        ?? crypto.randomUUID();
      if (!input.id) pendingMeetingMinuteIdsRef.current.set(saveKey, stableId);
      const saveRequest = (async () => {
        const { data, error: rpcError } = await supabase.rpc("save_meeting_minute", {
          p_id: stableId,
          p_create: !input.id,
          p_organization_id: organizationId,
          p_meeting_year: input.meetingYear,
          p_meeting_date: input.meetingDate,
          p_title: title,
          p_body: body,
          p_status: input.status,
        });
        if (rpcError) throw rpcError;
        return data ? String(data) : stableId;
      })();
      pendingMeetingMinuteSavesRef.current.set(saveKey, saveRequest);
      try {
        savedId = await saveRequest;
        pendingMeetingMinuteIdsRef.current.delete(saveKey);
      } finally {
        if (pendingMeetingMinuteSavesRef.current.get(saveKey) === saveRequest) {
          pendingMeetingMinuteSavesRef.current.delete(saveKey);
        }
      }
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      scheduleRemoteRefresh();
    }
    const minute: MeetingMinute = {
      id: savedId ?? crypto.randomUUID(),
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
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.mode, state.viewer, updateState]);

  const deleteMeetingMinute = useCallback(async (id: string) => {
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer?.profile.id;
    if (!canWriteMeetingMinutes(state.viewer)) throw new Error("현재 직책에는 회의록 삭제 권한이 없습니다.");
    const target = state.meetingMinutes.find((item) => item.id === id);
    if (!target) throw new Error("삭제할 회의록을 찾을 수 없습니다.");
    if (target.meetingYear !== serviceYear) throw new Error("지난 연도 회의록은 삭제할 수 없습니다.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("delete_meeting_minute", { p_id: id });
      if (rpcError) throw rpcError;
      if (!requestUserId || !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      scheduleRemoteRefresh();
    }
    updateState((previous) => ({
      ...previous,
      meetingMinutes: previous.meetingMinutes.filter((item) => item.id !== id),
    }));
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.meetingMinutes, state.mode, state.viewer, updateState]);

  const saveLedgerEntry = useCallback(async (input: LedgerEntryInput) => {
    const viewer = state.viewer;
    if (!viewer) throw new Error("로그인이 필요합니다.");
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = viewer.profile.id;
    const organizationId = viewer.membership?.organizationId;
    if (!organizationId) throw new Error("승인된 교회 소속이 필요합니다.");
    if (!canWriteLedger(viewer)) throw new Error("현재 직책에는 회계장부 작성 권한이 없습니다.");
    if (input.fiscalYear !== serviceYear) throw new Error("지난 연도 회계장부는 열람만 할 수 있습니다.");
    const category = input.category.trim();
    const description = input.description.trim();
    const memo = input.memo?.trim() || undefined;
    if (!category || !description) throw new Error("회계 분류와 설명을 입력해 주세요.");
    if (!Number.isFinite(input.amount) || input.amount <= 0 || input.amount > 9_999_999_999_999.99) {
      throw new Error("금액은 0보다 크고 9조 9,999억 9,999만 9,999.99원 이하여야 합니다.");
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(input.entryDate) || Number(input.entryDate.slice(0, 4)) !== input.fiscalYear) {
      throw new Error("회계연도와 거래 날짜를 확인해 주세요.");
    }
    let savedId = input.id ?? input.clientOperationId;
    if (supabase && state.mode === "supabase") {
      const saveKey = JSON.stringify([
        requestUserId,
        organizationId,
        input.id ?? input.clientOperationId ?? null,
        input.fiscalYear,
        input.entryDate,
        input.entryType,
        category,
        description,
        input.amount,
        memo ?? null,
      ]);
      const existingSave = pendingLedgerEntrySavesRef.current.get(saveKey);
      if (existingSave) {
        await existingSave;
        return;
      }
      const stableId = input.id
        ?? input.clientOperationId
        ?? pendingLedgerEntryIdsRef.current.get(saveKey)
        ?? crypto.randomUUID();
      if (!input.id) pendingLedgerEntryIdsRef.current.set(saveKey, stableId);
      const saveRequest = (async () => {
        const { data, error: rpcError } = await supabase.rpc("save_ledger_entry", {
          p_id: stableId,
          p_create: !input.id,
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
        return data ? String(data) : stableId;
      })();
      pendingLedgerEntrySavesRef.current.set(saveKey, saveRequest);
      try {
        savedId = await saveRequest;
        pendingLedgerEntryIdsRef.current.delete(saveKey);
      } finally {
        if (pendingLedgerEntrySavesRef.current.get(saveKey) === saveRequest) {
          pendingLedgerEntrySavesRef.current.delete(saveKey);
        }
      }
      if (!isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      scheduleRemoteRefresh();
    }
    const entry: LedgerEntry = {
      id: savedId ?? crypto.randomUUID(),
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
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.mode, state.viewer, updateState]);

  const deleteLedgerEntry = useCallback(async (id: string) => {
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer?.profile.id;
    if (!canWriteLedger(state.viewer)) throw new Error("현재 직책에는 회계장부 삭제 권한이 없습니다.");
    const target = state.ledgerEntries.find((item) => item.id === id);
    if (!target) throw new Error("삭제할 장부 항목을 찾을 수 없습니다.");
    if (target.fiscalYear !== serviceYear) throw new Error("지난 연도 회계장부는 삭제할 수 없습니다.");
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("delete_ledger_entry", { p_id: id });
      if (rpcError) throw rpcError;
      if (!requestUserId || !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
      scheduleRemoteRefresh();
    }
    updateState((previous) => ({
      ...previous,
      ledgerEntries: previous.ledgerEntries.filter((item) => item.id !== id),
    }));
  }, [isRemoteActorCurrent, scheduleRemoteRefresh, serviceYear, state.ledgerEntries, state.mode, state.viewer, updateState]);

  const markNotificationsRead = useCallback(async () => {
    const requestSessionEpoch = remoteSessionEpochRef.current;
    const requestUserId = state.viewer?.profile.id;
    if (supabase && state.mode === "supabase") {
      const { error: rpcError } = await supabase.rpc("mark_notifications_read", {
        p_notification_ids: null,
      });
      if (rpcError) throw rpcError;
      if (!requestUserId || !isRemoteActorCurrent(requestSessionEpoch, requestUserId)) return;
    }
    updateState((previous) => ({
      ...previous,
      notifications: previous.notifications.map((notification) => ({
        ...notification,
        readAt: notification.readAt ?? new Date().toISOString(),
      })),
    }));
  }, [isRemoteActorCurrent, state.mode, state.viewer?.profile.id, updateState]);

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
    getServerNow,
    passwordRecoveryReady,
    enterDemo,
    signIn,
    signUp,
    requestPasswordReset,
    updatePassword,
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
    ensurePost,
    refresh: loadRemote,
  }), [
    addComment,
    createPost,
    deleteLedgerEntry,
    deleteMeetingMinute,
    enterDemo,
    ensurePost,
    error,
    getServerNow,
    hasMorePosts,
    loadRemote,
    loadConversationMessages,
    loadMorePosts,
    markConversationRead,
    markNotificationsRead,
    passwordRecoveryReady,
    requestPasswordReset,
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
    updatePassword,
  ]);

  return <AppDataContext.Provider value={value}>{children}</AppDataContext.Provider>;
}

export function useAppData() {
  const context = useContext(AppDataContext);
  if (!context) throw new Error("useAppData must be used inside AppDataProvider");
  return context;
}
