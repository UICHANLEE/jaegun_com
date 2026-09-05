import { FunctionRegion } from "@supabase/supabase-js";
import type { AppMode } from "../types/domain";
import {
  CONSENT_DOCUMENT_KEYS,
  LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION,
  findLegalDocument,
  type ConsentDocumentKey,
} from "./legalDocuments";
import {
  assertAcceptedConsentVersions,
  bundledCurrentConsentDocuments,
  classifyRequiredConsentDocuments,
  legalDocumentUrl,
  type AcceptedConsentVersions,
  type ConsentContract,
  type RequiredConsentDocument,
} from "./legalConsentContract";
import { detachCurrentNativePushDevice, nativePushRegistrationAvailable } from "./nativePush";
import { isSupabaseConfigured, supabase } from "./supabase";

export const ACCOUNT_DELETION_CONFIRMATION = "계정 삭제";

export const REPORT_TARGET_TYPES = ["post", "comment", "message", "profile", "channel_message"] as const;
export type ReportTargetType = (typeof REPORT_TARGET_TYPES)[number];

export const REPORT_REASONS = [
  "harassment",
  "hate",
  "sexual_content",
  "violence",
  "spam",
  "impersonation",
  "privacy",
  "self_harm",
  "other",
] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

export const REPORT_REASON_LABELS: Readonly<Record<ReportReason, string>> = {
  harassment: "괴롭힘·모욕",
  hate: "혐오·차별",
  sexual_content: "성적이거나 부적절한 내용",
  violence: "폭력·위협",
  spam: "스팸·사기",
  impersonation: "사칭",
  privacy: "개인정보 노출",
  self_harm: "자해·극단적 선택 위험",
  other: "기타",
};

export const REPORT_TARGET_LABELS: Readonly<Record<ReportTargetType, string>> = {
  post: "게시글",
  comment: "댓글",
  message: "메시지",
  channel_message: "채널 메시지",
  profile: "사용자",
};

export interface RequiredConsentAcceptance {
  key: ConsentDocumentKey;
  version: string;
  acceptedAt: string | null;
}

export interface DirectoryVisibility {
  avatar: boolean;
  churchTitle: boolean;
  email: boolean;
  bio: boolean;
}

export interface NotificationCategoryPreferences {
  approvals: boolean;
  posts: boolean;
  comments: boolean;
  chats: boolean;
  governance: boolean;
  events: boolean;
}

export interface NotificationPreferences {
  pushEnabled: boolean;
  categories: NotificationCategoryPreferences;
  quietHoursEnabled: boolean;
  quietHoursStart: string;
  quietHoursEnd: string;
  timeZone: "Asia/Seoul";
  lockScreenPreview: "generic" | "hidden";
}

export interface BlockedProfile {
  userId: string;
  displayName: string;
  avatarUrl?: string;
  blockedAt: string;
}

export interface PushDeviceSummary {
  id: string;
  installationId: string;
  platform: "ios" | "android" | "web";
  appVersion?: string;
  lastSeenAt: string;
  disabledAt?: string;
}

export interface AccountDeletionStatus {
  status: "none" | "pending";
  requestedAt: string | null;
  scheduledFor: string | null;
}

export interface SafetyPrivacyState {
  requiredDocuments: RequiredConsentDocument[];
  requiredConsents: RequiredConsentAcceptance[];
  consentContract: ConsentContract;
  consentGateOpen: boolean;
  directoryVisibility: DirectoryVisibility;
  notifications: NotificationPreferences;
  pushDevices: PushDeviceSummary[];
  blockedProfiles: BlockedProfile[];
  mutedConversationIds: string[];
  accountDeletion: AccountDeletionStatus;
}

export interface ContentReportInput {
  targetType: ReportTargetType;
  targetId: string;
  reason: ReportReason;
  details?: string;
}

export interface SecurityActivity {
  id: string;
  action: string;
  actionLabel: string;
  occurredAt: string;
  deviceLabel?: string;
  ipHint?: string;
}

export const MODERATION_REPORT_STATUSES = ["open", "reviewing", "escalated", "resolved", "dismissed"] as const;
export type ModerationReportStatus = (typeof MODERATION_REPORT_STATUSES)[number];
export type ModerationStatusFilter = ModerationReportStatus | "all";
export const MODERATION_ACTIONS = ["no_action", "warning_recorded", "content_hidden", "member_suspended", "escalated_to_platform"] as const;
export type ModerationAction = (typeof MODERATION_ACTIONS)[number];

export interface ModerationReport {
  id: string;
  targetType: ReportTargetType;
  targetId: string;
  reason: ReportReason;
  details?: string;
  evidenceSummary: string;
  targetAuthorName?: string;
  reporterDisplayName?: string;
  organizationName?: string;
  status: ModerationReportStatus;
  createdAt: string;
  resolvedAt?: string;
  resolutionReason?: string;
}

export interface MfaFactorSummary {
  id: string;
  friendlyName: string;
  status: "verified" | "unverified";
  createdAt?: string;
}

export interface MfaStatus {
  currentLevel: "aal1" | "aal2" | null;
  nextLevel: "aal1" | "aal2" | null;
  factors: MfaFactorSummary[];
}

export interface MfaEnrollment {
  factorId: string;
  qrCodeDataUrl?: string;
  secret?: string;
}

export interface SessionSummary {
  signedInAt: string | null;
  expiresAt: string | null;
  email: string | null;
}

interface DemoRecord {
  state: SafetyPrivacyState;
}

const demoRecords = new Map<string, DemoRecord>();
const SAFE_ID_PATTERN = /^[A-Za-z0-9_-]{1,200}$/;
const HH_MM_PATTERN = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function firstRecord(value: unknown): Record<string, unknown> | null {
  if (Array.isArray(value)) return asRecord(value[0]);
  return asRecord(value);
}

function stringOrNull(value: unknown) {
  return typeof value === "string" && value.trim() ? value : null;
}

function booleanOr(value: unknown, fallback: boolean) {
  return typeof value === "boolean" ? value : fallback;
}

function cloneState(state: SafetyPrivacyState): SafetyPrivacyState {
  return {
    requiredDocuments: state.requiredDocuments.map((document) => ({ ...document })),
    requiredConsents: state.requiredConsents.map((consent) => ({ ...consent })),
    consentContract: state.consentContract,
    consentGateOpen: state.consentGateOpen,
    directoryVisibility: { ...state.directoryVisibility },
    notifications: {
      ...state.notifications,
      categories: { ...state.notifications.categories },
    },
    pushDevices: state.pushDevices.map((device) => ({ ...device })),
    blockedProfiles: state.blockedProfiles.map((profile) => ({ ...profile })),
    mutedConversationIds: [...state.mutedConversationIds],
    accountDeletion: { ...state.accountDeletion },
  };
}

function createDefaultState(consented = false): SafetyPrivacyState {
  const acceptedAt = consented ? new Date().toISOString() : null;
  const requiredDocuments = bundledCurrentConsentDocuments();
  return {
    requiredDocuments,
    requiredConsents: requiredDocuments.map((document) => ({
      key: document.key,
      version: document.version,
      acceptedAt,
    })),
    consentContract: "independent-v2",
    consentGateOpen: consented,
    directoryVisibility: {
      avatar: false,
      churchTitle: true,
      email: false,
      bio: false,
    },
    notifications: {
      pushEnabled: true,
      categories: {
        approvals: true,
        posts: true,
        comments: true,
        chats: true,
        governance: true,
        events: true,
      },
      quietHoursEnabled: true,
      quietHoursStart: "21:00",
      quietHoursEnd: "08:00",
      timeZone: "Asia/Seoul",
      lockScreenPreview: "generic",
    },
    pushDevices: [],
    blockedProfiles: [],
    mutedConversationIds: [],
    accountDeletion: {
      status: "none",
      requestedAt: null,
      scheduledFor: null,
    },
  };
}

function demoRecord(userId: string) {
  const current = demoRecords.get(userId);
  if (current) return current;
  const created = { state: createDefaultState(true) };
  demoRecords.set(userId, created);
  return created;
}

export function getDemoSafetyPrivacyState(userId: string) {
  return cloneState(demoRecord(userId).state);
}

function requireMode(mode: AppMode, userId: string) {
  if (!userId.trim()) throw new Error("로그인 정보를 확인하지 못했습니다.");
  if (mode === "demo") {
    if (import.meta.env.PROD) {
      throw new Error("운영 서비스에서는 데모 보안 설정을 사용할 수 없습니다.");
    }
    return null;
  }
  if (!isSupabaseConfigured || !supabase) {
    throw new Error("보안 설정 서비스에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.");
  }
  return supabase;
}

function safeServiceError(error: unknown, fallback: string) {
  const record = asRecord(error);
  const code = typeof record?.code === "string" ? record.code : "";
  if (code === "PGRST202" || code === "42883") {
    return new Error("이 보안 기능을 서버에서 준비하고 있습니다. 운영자에게 문의해 주세요.");
  }
  if (code === "42501" || code === "PGRST301") {
    return new Error("이 작업을 수행할 권한이 없거나 로그인이 만료되었습니다.");
  }
  return new Error(fallback);
}

function normalizeTime(value: unknown, fallback: string) {
  return typeof value === "string" && HH_MM_PATTERN.test(value) ? value : fallback;
}

function isConsentDocumentKey(value: unknown): value is ConsentDocumentKey {
  return typeof value === "string" && CONSENT_DOCUMENT_KEYS.includes(value as ConsentDocumentKey);
}

function normalizeState(data: unknown): SafetyPrivacyState {
  const row = firstRecord(data);
  if (!row) throw new Error("필수 동의 상태 응답이 비어 있습니다.");

  const currentDocuments = asRecord(row.current_documents) ?? asRecord(row.currentDocuments) ?? {};
  const rawDocumentKeys = Object.keys(currentDocuments);
  if (rawDocumentKeys.some((key) => !isConsentDocumentKey(key))) {
    throw new Error("알 수 없는 필수 동의 문서가 반환되었습니다.");
  }
  const requiredDocuments = CONSENT_DOCUMENT_KEYS.flatMap((key): RequiredConsentDocument[] => {
    const document = asRecord(currentDocuments[key]);
    const version = stringOrNull(document?.version);
    if (!document || !version || document.required !== true) return [];
    const bundled = findLegalDocument(key, version);
    if (!bundled) throw new Error("이 앱에서 확인할 수 없는 필수 동의 문서 버전입니다.");
    const title = stringOrNull(document.title);
    const documentUrl = stringOrNull(document.url ?? document.document_url);
    if (title !== LEGAL_DOCUMENT_DATABASE_TITLE_BY_KEY_VERSION[`${key}@${version}`]
      || documentUrl !== legalDocumentUrl(key, version)) {
      throw new Error("필수 동의 문서 메타데이터가 배포된 본문과 일치하지 않습니다.");
    }
    return [{
      key,
      version,
      title: bundled.title,
      documentUrl,
      required: true,
    }];
  });
  if (rawDocumentKeys.length !== requiredDocuments.length) {
    throw new Error("서버의 필수 동의 문서 구성이 안전한 출시 계약과 일치하지 않습니다.");
  }
  const consentContract = classifyRequiredConsentDocuments(requiredDocuments);
  const rawConsentRows = Array.isArray(row.required_consents)
    ? row.required_consents
    : Array.isArray(row.requiredConsents)
      ? row.requiredConsents
      : Array.isArray(row.consents)
        ? row.consents
        : [];
  const consentRows = rawConsentRows.flatMap((value) => {
    const consent = asRecord(value);
    return consent ? [consent] : [];
  });
  const findConsent = (key: ConsentDocumentKey, version: string) => consentRows.find((consent) => (
    (consent.document_key === key || consent.key === key)
    && (consent.document_version === version || consent.version === version)
    && consent.accepted === true
  ));
  const consentRow = asRecord(row.consents) ?? row;
  const sensitiveConsent = asRecord(consentRow.sensitive_affiliation)
    ?? asRecord(consentRow.sensitiveAffiliation);
  const policyConsent = asRecord(consentRow.community_policy)
    ?? asRecord(consentRow.communityPolicy);
  const requiredConsents = requiredDocuments.map((document): RequiredConsentAcceptance => {
    const arrayConsent = findConsent(document.key, document.version);
    const legacyConsent = document.key === "privacy_policy"
      ? sensitiveConsent
      : document.key === "community_guidelines"
        ? policyConsent
        : null;
    const legacyVersion = stringOrNull(legacyConsent?.version);
    return {
      key: document.key,
      version: document.version,
      acceptedAt: stringOrNull(arrayConsent?.recorded_at ?? arrayConsent?.accepted_at)
        ?? (legacyVersion === document.version
          ? stringOrNull(legacyConsent?.accepted_at ?? legacyConsent?.acceptedAt)
          : null),
    };
  });
  const directoryRow = asRecord(row.directory_visibility)
    ?? asRecord(row.directoryVisibility)
    ?? asRecord(row.privacy_preferences)
    ?? {};
  const notificationRow = asRecord(row.notifications)
    ?? asRecord(row.notification_preferences)
    ?? {};
  const categoriesRow = asRecord(notificationRow.categories) ?? notificationRow;
  const deletionRow = asRecord(row.account_deletion)
    ?? asRecord(row.accountDeletion)
    ?? asRecord(row.deletion_request)
    ?? {};
  const blockedRows = Array.isArray(row.blocked_profiles)
    ? row.blocked_profiles
    : Array.isArray(row.blockedProfiles)
      ? row.blockedProfiles
      : Array.isArray(row.blocked_users)
        ? row.blocked_users
      : [];
  const pushDeviceRows = Array.isArray(row.push_devices)
    ? row.push_devices
    : Array.isArray(row.pushDevices)
      ? row.pushDevices
      : [];
  const mutedRows = Array.isArray(row.muted_conversation_ids)
    ? row.muted_conversation_ids
    : Array.isArray(row.mutedConversationIds)
      ? row.mutedConversationIds
      : [];

  return {
    requiredDocuments,
    requiredConsents,
    consentContract,
    consentGateOpen: row.consent_gate_open === true || row.consentGateOpen === true,
    directoryVisibility: {
      avatar: booleanOr(directoryRow.avatar, directoryRow.directory_visibility === "church_profile"),
      churchTitle: booleanOr(directoryRow.church_title ?? directoryRow.churchTitle, directoryRow.directory_visibility === "church_profile"),
      email: booleanOr(directoryRow.email, false),
      bio: booleanOr(directoryRow.bio, directoryRow.directory_visibility === "church_profile"),
    },
    notifications: {
      pushEnabled: booleanOr(notificationRow.push_enabled ?? notificationRow.pushEnabled, true),
      categories: {
        approvals: booleanOr(categoriesRow.approvals ?? categoriesRow.approvals_enabled, true),
        posts: booleanOr(categoriesRow.posts, true),
        comments: booleanOr(categoriesRow.comments ?? categoriesRow.comments_enabled, true),
        chats: booleanOr(categoriesRow.chats ?? categoriesRow.messages_enabled, true),
        governance: booleanOr(categoriesRow.governance, true),
        events: booleanOr(categoriesRow.events, true),
      },
      quietHoursEnabled: booleanOr(
        notificationRow.quiet_hours_enabled ?? notificationRow.quietHoursEnabled,
        Boolean(notificationRow.quiet_hours_start && notificationRow.quiet_hours_end),
      ),
      quietHoursStart: normalizeTime(notificationRow.quiet_hours_start ?? notificationRow.quietHoursStart, "21:00"),
      quietHoursEnd: normalizeTime(notificationRow.quiet_hours_end ?? notificationRow.quietHoursEnd, "08:00"),
      timeZone: "Asia/Seoul",
      lockScreenPreview: (notificationRow.lock_screen_preview ?? notificationRow.lockScreenPreview) === "hidden"
        ? "hidden"
        : "generic",
    },
    pushDevices: pushDeviceRows.flatMap((value) => {
      const device = asRecord(value);
      const id = stringOrNull(device?.id);
      const installationId = stringOrNull(device?.installation_id ?? device?.installationId);
      const platform = device?.platform;
      const lastSeenAt = stringOrNull(device?.last_seen_at ?? device?.lastSeenAt);
      if (
        !device || !id || !installationId || !lastSeenAt ||
        (platform !== "ios" && platform !== "android" && platform !== "web")
      ) return [];
      return [{
        id,
        installationId,
        platform,
        appVersion: stringOrNull(device.app_version ?? device.appVersion) ?? undefined,
        lastSeenAt,
        disabledAt: stringOrNull(device.disabled_at ?? device.disabledAt) ?? undefined,
      }];
    }),
    blockedProfiles: blockedRows.flatMap((value) => {
      const blocked = asRecord(value);
      const userId = stringOrNull(blocked?.user_id ?? blocked?.userId);
      if (!blocked || !userId) return [];
      return [{
        userId,
        displayName: stringOrNull(blocked.display_name ?? blocked.displayName) ?? "차단한 사용자",
        avatarUrl: stringOrNull(blocked.avatar_url ?? blocked.avatarUrl) ?? undefined,
        blockedAt: stringOrNull(blocked.blocked_at ?? blocked.blockedAt ?? blocked.created_at) ?? new Date(0).toISOString(),
      }];
    }),
    mutedConversationIds: mutedRows.filter((value): value is string => typeof value === "string"),
    accountDeletion: {
      status: (["pending", "requested", "processing", "awaiting_identity_deletion"] as unknown[]).includes(deletionRow.status)
        || row.account_deletion_status === "pending" ? "pending" : "none",
      requestedAt: stringOrNull(deletionRow.requested_at ?? deletionRow.requestedAt ?? row.account_deletion_requested_at),
      scheduledFor: stringOrNull(deletionRow.scheduled_for ?? deletionRow.scheduledFor ?? row.account_deletion_scheduled_for),
    },
  };
}

async function callRpc(
  name: string,
  args: Record<string, unknown> | undefined,
  fallback: string,
  signal?: AbortSignal,
) {
  if (!supabase) throw new Error("보안 설정 서비스에 연결하지 못했습니다.");
  const request = supabase.rpc(name, args);
  const { data, error } = signal ? await request.abortSignal(signal) : await request;
  if (error) throw safeServiceError(error, fallback);
  return data;
}

export function isReportTargetType(value: unknown): value is ReportTargetType {
  return typeof value === "string" && REPORT_TARGET_TYPES.includes(value as ReportTargetType);
}

export function validateContentReport(input: ContentReportInput) {
  if (!isReportTargetType(input.targetType) || !SAFE_ID_PATTERN.test(input.targetId)) {
    return "신고할 대상을 확인하지 못했습니다.";
  }
  if (!REPORT_REASONS.includes(input.reason)) return "신고 사유를 선택해 주세요.";
  const details = input.details?.trim() ?? "";
  if (details.length > 1_000) return "상세 내용은 1,000자 이하로 입력해 주세요.";
  if (input.reason === "other" && details.length < 10) return "기타 신고 사유를 10자 이상 입력해 주세요.";
  return null;
}

export async function loadSafetyPrivacyState(mode: AppMode, userId: string, signal?: AbortSignal) {
  const client = requireMode(mode, userId);
  if (!client) return cloneState(demoRecord(userId).state);
  const data = await callRpc(
    "get_my_safety_privacy_state",
    undefined,
    "보안 및 개인정보 설정을 불러오지 못했습니다.",
    signal,
  );
  return normalizeState(data);
}

export function requiredConsentsAreCurrent(state: SafetyPrivacyState | null) {
  if (!state?.consentGateOpen) return false;
  try {
    classifyRequiredConsentDocuments(state.requiredDocuments);
  } catch {
    return false;
  }
  if (state.requiredConsents.length !== state.requiredDocuments.length
    || new Set(state.requiredConsents.map((consent) => consent.key)).size !== state.requiredConsents.length) {
    return false;
  }
  return state.requiredDocuments.every((document) => state.requiredConsents.some((consent) => (
    consent.key === document.key
    && consent.version === document.version
    && Boolean(consent.acceptedAt)
  )));
}

export async function savePrivacyAndConsents(
  mode: AppMode,
  userId: string,
  input: {
    requiredDocuments: RequiredConsentDocument[];
    acceptedConsents: AcceptedConsentVersions;
    directoryVisibility: DirectoryVisibility;
  },
) {
  assertAcceptedConsentVersions(input.requiredDocuments, input.acceptedConsents);
  const contract = classifyRequiredConsentDocuments(input.requiredDocuments);
  const client = requireMode(mode, userId);
  const acceptedAt = new Date().toISOString();
  if (!client) {
    const record = demoRecord(userId);
    record.state.requiredDocuments = input.requiredDocuments.map((document) => ({ ...document }));
    record.state.requiredConsents = input.requiredDocuments.map((document) => ({
      key: document.key,
      version: document.version,
      acceptedAt,
    }));
    record.state.consentContract = contract;
    record.state.consentGateOpen = true;
    record.state.directoryVisibility = { ...input.directoryVisibility };
    return cloneState(record.state);
  }
  const visibilityArgs = {
    p_avatar_visible: input.directoryVisibility.avatar,
    p_church_title_visible: input.directoryVisibility.churchTitle,
    p_email_visible: input.directoryVisibility.email,
    p_bio_visible: input.directoryVisibility.bio,
  };
  if (contract === "legacy-v1") {
    await callRpc("save_my_privacy_preferences", {
      p_sensitive_affiliation_consent_version: input.acceptedConsents.privacy_policy,
      p_community_policy_version: input.acceptedConsents.community_guidelines,
      ...visibilityArgs,
    }, "개인정보 설정을 저장하지 못했습니다.");
  } else {
    await callRpc("save_my_privacy_preferences_v2", {
      p_required_consents: Object.fromEntries(input.requiredDocuments.map((document) => [
        document.key,
        input.acceptedConsents[document.key],
      ])),
      ...visibilityArgs,
    }, "개인정보 설정을 저장하지 못했습니다.");
  }
  return loadSafetyPrivacyState(mode, userId);
}

export async function saveNotificationPreferences(
  mode: AppMode,
  userId: string,
  preferences: NotificationPreferences,
) {
  if (!HH_MM_PATTERN.test(preferences.quietHoursStart) || !HH_MM_PATTERN.test(preferences.quietHoursEnd)) {
    throw new Error("방해금지 시작·종료 시간을 확인해 주세요.");
  }
  const client = requireMode(mode, userId);
  if (!client) {
    const record = demoRecord(userId);
    record.state.notifications = {
      ...preferences,
      categories: { ...preferences.categories },
      timeZone: "Asia/Seoul",
    };
    return cloneState(record.state);
  }
  await callRpc("save_my_notification_preferences", {
    p_push_enabled: preferences.pushEnabled,
    p_approvals: preferences.categories.approvals,
    p_posts: preferences.categories.posts,
    p_comments: preferences.categories.comments,
    p_chats: preferences.categories.chats,
    p_governance: preferences.categories.governance,
    p_events: preferences.categories.events,
    p_quiet_hours_enabled: preferences.quietHoursEnabled,
    p_quiet_hours_start: preferences.quietHoursStart,
    p_quiet_hours_end: preferences.quietHoursEnd,
    p_time_zone: "Asia/Seoul",
    p_lock_screen_preview: preferences.lockScreenPreview,
  }, "알림 설정을 저장하지 못했습니다.");
  return loadSafetyPrivacyState(mode, userId);
}

export async function removePushDevice(mode: AppMode, userId: string, deviceId: string) {
  if (!SAFE_ID_PATTERN.test(deviceId)) throw new Error("해제할 알림 기기를 확인하지 못했습니다.");
  const client = requireMode(mode, userId);
  if (!client) {
    const record = demoRecord(userId);
    record.state.pushDevices = record.state.pushDevices.filter((device) => device.id !== deviceId);
    return cloneState(record.state);
  }
  const removed = await callRpc(
    "remove_my_push_device",
    { p_device_id: deviceId },
    "알림 기기 연결을 해제하지 못했습니다.",
  );
  if (removed !== true) throw new Error("이미 해제되었거나 현재 계정의 기기가 아닙니다.");
  return loadSafetyPrivacyState(mode, userId);
}

export async function submitContentReport(mode: AppMode, userId: string, input: ContentReportInput) {
  const issue = validateContentReport(input);
  if (issue) throw new Error(issue);
  const client = requireMode(mode, userId);
  if (!client) return `demo-report-${crypto.randomUUID()}`;
  const data = await callRpc(input.targetType === "channel_message" ? "report_channel_message" : "create_content_report", {
    ...(input.targetType === "channel_message" ? {} : { p_target_type: input.targetType }),
    p_target_id: input.targetId,
    p_reason_code: input.reason,
    p_details: input.details?.trim() || null,
  }, "신고를 접수하지 못했습니다. 다시 시도해 주세요.");
  return typeof data === "string" ? data : stringOrNull(firstRecord(data)?.id) ?? "submitted";
}

export async function blockUser(mode: AppMode, userId: string, targetUserId: string, displayName: string) {
  if (!SAFE_ID_PATTERN.test(targetUserId) || targetUserId === userId) {
    throw new Error("차단할 사용자를 확인하지 못했습니다.");
  }
  const client = requireMode(mode, userId);
  if (!client) {
    const record = demoRecord(userId);
    if (!record.state.blockedProfiles.some((item) => item.userId === targetUserId)) {
      record.state.blockedProfiles.push({
        userId: targetUserId,
        displayName: displayName.trim() || "차단한 사용자",
        blockedAt: new Date().toISOString(),
      });
    }
    return cloneState(record.state);
  }
  await callRpc("block_user", { p_user_id: targetUserId, p_reason: null }, "사용자를 차단하지 못했습니다.");
  return loadSafetyPrivacyState(mode, userId);
}

export async function unblockUser(mode: AppMode, userId: string, targetUserId: string) {
  if (!SAFE_ID_PATTERN.test(targetUserId)) throw new Error("차단 해제할 사용자를 확인하지 못했습니다.");
  const client = requireMode(mode, userId);
  if (!client) {
    const record = demoRecord(userId);
    record.state.blockedProfiles = record.state.blockedProfiles.filter((item) => item.userId !== targetUserId);
    return cloneState(record.state);
  }
  await callRpc("unblock_user", { p_user_id: targetUserId }, "차단을 해제하지 못했습니다.");
  return loadSafetyPrivacyState(mode, userId);
}

export async function setConversationMuted(
  mode: AppMode,
  userId: string,
  conversationId: string,
  muted: boolean,
) {
  if (!SAFE_ID_PATTERN.test(conversationId)) throw new Error("대화를 확인하지 못했습니다.");
  const client = requireMode(mode, userId);
  if (!client) {
    const record = demoRecord(userId);
    const ids = new Set(record.state.mutedConversationIds);
    if (muted) ids.add(conversationId);
    else ids.delete(conversationId);
    record.state.mutedConversationIds = Array.from(ids);
    return muted;
  }
  await callRpc("set_conversation_muted", {
    p_conversation_id: conversationId,
    p_muted: muted,
  }, "대화 알림 설정을 저장하지 못했습니다.");
  return muted;
}

export async function requestAccountDeletion(
  mode: AppMode,
  userId: string,
  confirmation: string,
  reason?: string,
  password?: string,
) {
  if (confirmation.trim() !== ACCOUNT_DELETION_CONFIRMATION) {
    throw new Error(`확인 문구 '${ACCOUNT_DELETION_CONFIRMATION}'를 정확히 입력해 주세요.`);
  }
  if ((reason?.trim().length ?? 0) > 500) throw new Error("탈퇴 사유는 500자 이하로 입력해 주세요.");
  const client = requireMode(mode, userId);
  if (!client) {
    const requestedAt = new Date();
    const scheduledFor = new Date(requestedAt.getTime() + 14 * 24 * 60 * 60 * 1_000);
    const record = demoRecord(userId);
    record.state.accountDeletion = {
      status: "pending",
      requestedAt: requestedAt.toISOString(),
      scheduledFor: scheduledFor.toISOString(),
    };
    return { ...record.state.accountDeletion };
  }
  if ((password?.length ?? 0) > 512) throw new Error("현재 비밀번호를 확인해 주세요.");
  const { error } = await client.functions.invoke("request-account-deletion", {
    region: FunctionRegion.UsEast1,
    body: {
      confirmation: ACCOUNT_DELETION_CONFIRMATION,
      reason: reason?.trim() || null,
      ...(password ? { password } : {}),
    },
  });
  if (error) {
    throw new Error("계정 본인 확인에 실패했거나 삭제 요청을 처리하지 못했습니다. 비밀번호 또는 MFA 인증 상태를 확인해 주세요.");
  }
  return { status: "pending", requestedAt: null, scheduledFor: null } satisfies AccountDeletionStatus;
}

export async function cancelAccountDeletion(mode: AppMode, userId: string) {
  const client = requireMode(mode, userId);
  if (!client) {
    const record = demoRecord(userId);
    record.state.accountDeletion = { status: "none", requestedAt: null, scheduledFor: null };
    return { ...record.state.accountDeletion };
  }
  await callRpc("cancel_account_deletion", undefined, "계정 삭제 예약을 취소하지 못했습니다.");
  return (await loadSafetyPrivacyState(mode, userId)).accountDeletion;
}

export async function loadSecurityActivity(mode: AppMode, userId: string): Promise<SecurityActivity[]> {
  const client = requireMode(mode, userId);
  if (!client) return [];
  const data = await callRpc(
    "list_my_security_activity",
    { p_limit: 20 },
    "최근 보안 활동을 불러오지 못했습니다.",
  );
  if (!Array.isArray(data)) return [];
  return data.flatMap((value, index) => {
    const row = asRecord(value);
    const occurredAt = stringOrNull(row?.occurred_at ?? row?.occurredAt ?? row?.created_at);
    if (!row || !occurredAt) return [];
    const metadata = asRecord(row.metadata);
    return [{
      id: stringOrNull(row.id) ?? `activity-${index}-${occurredAt}`,
      action: stringOrNull(row.action ?? row.event_type) ?? "security_event",
      actionLabel: stringOrNull(row.action_label ?? row.actionLabel ?? row.summary) ?? "보안 설정 변경",
      occurredAt,
      deviceLabel: stringOrNull(row.device_label ?? row.deviceLabel ?? metadata?.device_label) ?? undefined,
      ipHint: stringOrNull(row.ip_hint ?? row.ipHint ?? metadata?.ip_hint) ?? undefined,
    }];
  });
}

export async function loadModerationReports(
  mode: AppMode,
  userId: string,
  status: ModerationStatusFilter,
): Promise<ModerationReport[]> {
  const client = requireMode(mode, userId);
  if (!client) return [];
  const data = await callRpc("list_moderation_reports", {
    p_status: status === "all" ? null : status,
    p_limit: 100,
  }, "신고 검토 목록을 불러오지 못했습니다.");
  if (!Array.isArray(data)) return [];
  return data.flatMap((value) => {
    const row = asRecord(value);
    const id = stringOrNull(row?.id);
    const targetType = row?.target_type ?? row?.targetType;
    const reason = row?.reason_code ?? row?.reason;
    const statusValue = row?.status;
    const createdAt = stringOrNull(row?.created_at ?? row?.createdAt);
    if (!row || !id || !isReportTargetType(targetType)
      || !REPORT_REASONS.includes(reason as ReportReason)
      || !MODERATION_REPORT_STATUSES.includes(statusValue as ModerationReportStatus)
      || !createdAt) return [];
    const evidence = asRecord(row.evidence_snapshot ?? row.evidenceSnapshot);
    const evidenceSummary = stringOrNull(row.evidence_summary ?? row.evidenceSummary)
      ?? stringOrNull(evidence?.title)
      ?? stringOrNull(evidence?.body_excerpt)
      ?? stringOrNull(evidence?.bio_excerpt)
      ?? (evidence?.has_media === true ? "첨부 미디어가 있는 신고 대상입니다." : null)
      ?? "보존된 증거 요약이 없습니다.";
    return [{
      id,
      targetType,
      targetId: stringOrNull(row.target_id ?? row.targetId) ?? "unknown",
      reason: reason as ReportReason,
      details: stringOrNull(row.details) ?? undefined,
      evidenceSummary: evidenceSummary.slice(0, 500),
      targetAuthorName: stringOrNull(row.target_author_name ?? row.targetAuthorName ?? row.reported_user_name) ?? undefined,
      reporterDisplayName: stringOrNull(row.reporter_display_name ?? row.reporterDisplayName) ?? undefined,
      organizationName: stringOrNull(row.organization_name ?? row.organizationName) ?? undefined,
      status: statusValue as ModerationReportStatus,
      createdAt,
      resolvedAt: stringOrNull(row.resolved_at ?? row.resolvedAt) ?? undefined,
      resolutionReason: stringOrNull(row.resolution_reason ?? row.resolutionReason ?? row.resolution_note) ?? undefined,
    }];
  });
}

export async function resolveModerationReport(
  mode: AppMode,
  userId: string,
  input: { reportId: string; action: ModerationAction; reason: string },
) {
  if (!SAFE_ID_PATTERN.test(input.reportId)) throw new Error("처리할 신고를 확인하지 못했습니다.");
  if (!MODERATION_ACTIONS.includes(input.action)) throw new Error("처리 방법을 선택해 주세요.");
  const reason = input.reason.trim();
  if (reason.length < 10 || reason.length > 500) {
    throw new Error("처리 사유를 10자 이상 500자 이하로 입력해 주세요.");
  }
  const client = requireMode(mode, userId);
  if (!client) throw new Error("로컬 데모에서는 실제 제재를 실행하지 않습니다.");
  await callRpc("resolve_content_report", {
    p_report_id: input.reportId,
    p_action: input.action,
    p_reason: reason,
  }, "신고 처리를 완료하지 못했습니다.");
}

export async function loadSessionSummary(mode: AppMode, userId: string): Promise<SessionSummary> {
  const client = requireMode(mode, userId);
  if (!client) return { signedInAt: new Date().toISOString(), expiresAt: null, email: "demo@jaegun.local" };
  const { data, error } = await client.auth.getSession();
  if (error) throw safeServiceError(error, "현재 로그인 세션을 확인하지 못했습니다.");
  const session = data.session;
  return {
    signedInAt: session?.user.last_sign_in_at ?? null,
    expiresAt: session?.expires_at ? new Date(session.expires_at * 1_000).toISOString() : null,
    email: session?.user.email ?? null,
  };
}

export async function loadMfaStatus(mode: AppMode, userId: string): Promise<MfaStatus> {
  const client = requireMode(mode, userId);
  if (!client) return { currentLevel: "aal1", nextLevel: "aal1", factors: [] };
  const [factorResult, assuranceResult] = await Promise.all([
    client.auth.mfa.listFactors(),
    client.auth.mfa.getAuthenticatorAssuranceLevel(),
  ]);
  if (factorResult.error) throw safeServiceError(factorResult.error, "MFA 등록 상태를 확인하지 못했습니다.");
  if (assuranceResult.error) throw safeServiceError(assuranceResult.error, "인증 보안 수준을 확인하지 못했습니다.");
  const totp = Array.isArray(factorResult.data?.totp) ? factorResult.data.totp : [];
  const normalizeAal = (value: unknown): "aal1" | "aal2" | null => value === "aal1" || value === "aal2" ? value : null;
  return {
    currentLevel: normalizeAal(assuranceResult.data.currentLevel),
    nextLevel: normalizeAal(assuranceResult.data.nextLevel),
    factors: totp.map((factor) => ({
      id: factor.id,
      friendlyName: factor.friendly_name ?? "인증 앱",
      status: factor.status === "verified" ? "verified" : "unverified",
      createdAt: factor.created_at,
    })),
  };
}

export async function enrollTotp(mode: AppMode, userId: string): Promise<MfaEnrollment> {
  const client = requireMode(mode, userId);
  if (!client) throw new Error("로컬 데모에서는 실제 MFA 기기를 등록하지 않습니다.");
  const { data, error } = await client.auth.mfa.enroll({
    factorType: "totp",
    friendlyName: "재건 공동체 인증 앱",
  });
  if (error) throw safeServiceError(error, "MFA 등록을 시작하지 못했습니다.");
  const qrCode = data.totp.qr_code;
  return {
    factorId: data.id,
    qrCodeDataUrl: qrCode.startsWith("data:image/svg+xml") ? qrCode : undefined,
    secret: data.totp.secret,
  };
}

export async function verifyTotpEnrollment(mode: AppMode, userId: string, factorId: string, code: string) {
  const client = requireMode(mode, userId);
  if (!client) throw new Error("로컬 데모에서는 실제 MFA를 확인하지 않습니다.");
  if (!/^\d{6}$/.test(code)) throw new Error("인증 앱의 6자리 코드를 입력해 주세요.");
  const challenge = await client.auth.mfa.challenge({ factorId });
  if (challenge.error) throw safeServiceError(challenge.error, "MFA 확인 요청을 만들지 못했습니다.");
  const verification = await client.auth.mfa.verify({
    factorId,
    challengeId: challenge.data.id,
    code,
  });
  if (verification.error) throw safeServiceError(verification.error, "인증 코드가 맞지 않거나 만료되었습니다.");
}

export async function unenrollTotp(mode: AppMode, userId: string, factorId: string) {
  const client = requireMode(mode, userId);
  if (!client) throw new Error("로컬 데모에서는 실제 MFA를 변경하지 않습니다.");
  const { error } = await client.auth.mfa.unenroll({ factorId });
  if (error) throw safeServiceError(error, "MFA 등록을 해제하지 못했습니다.");
}

export async function signOutEverywhere(mode: AppMode, userId: string) {
  const client = requireMode(mode, userId);
  if (!client) throw new Error("로컬 데모에는 종료할 원격 세션이 없습니다.");
  if (nativePushRegistrationAvailable()) await detachCurrentNativePushDevice();
  const { error } = await client.auth.signOut({ scope: "global" });
  if (error) throw safeServiceError(error, "모든 기기에서 로그아웃하지 못했습니다.");
}

export function __resetSafetyPrivacyDemoForTests() {
  if (import.meta.env.MODE === "test") demoRecords.clear();
}

export function __normalizeSafetyPrivacyStateForTests(value: unknown) {
  if (import.meta.env.MODE !== "test") throw new Error("Test helper is unavailable outside tests.");
  return normalizeState(value);
}
