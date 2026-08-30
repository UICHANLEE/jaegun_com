import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import { canModerateCommunity } from "../components/access";
import {
  BlockUserControl,
  ConversationMuteControl,
  ReportActionLink,
} from "../components/SafetyControls";
import { AppDataProvider } from "../data/AppDataProvider";
import {
  __resetSafetyPrivacyDemoForTests,
  __normalizeSafetyPrivacyStateForTests,
  ACCOUNT_DELETION_CONFIRMATION,
  blockUser,
  loadSafetyPrivacyState,
  setConversationMuted,
  unblockUser,
  validateContentReport,
} from "../data/safetyPrivacy";
import { createDemoState, DEMO_VIEWER } from "../data/seed";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

function renderApp(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppDataProvider><App /></AppDataProvider>
    </MemoryRouter>,
  );
}

function setDemoMember() {
  const state = createDemoState();
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...state,
    viewer: {
      profile: { id: "demo-member", displayName: "이재건", email: "member@jaegun.demo", globalRole: "user" },
      membership: {
        id: "demo-member-membership",
        organizationId: "org-19",
        userId: "demo-member",
        role: "member",
        churchTitleCode: "deacon",
        executiveOfficeCodes: [],
        status: "active",
      },
    },
  }));
}

beforeEach(() => {
  __resetSafetyPrivacyDemoForTests();
});

describe("safety and privacy adapter", () => {
  it("rejects malformed reports and requires useful details for an other report", () => {
    expect(validateContentReport({ targetType: "post", targetId: "bad/id", reason: "spam" })).toBe("신고할 대상을 확인하지 못했습니다.");
    expect(validateContentReport({ targetType: "post", targetId: "post-1", reason: "other", details: "짧음" })).toContain("10자 이상");
    expect(validateContentReport({ targetType: "message", targetId: "message-1", reason: "privacy", details: "" })).toBeNull();
  });

  it("keeps demo blocks and conversation mute preferences scoped to the demo user", async () => {
    await blockUser("demo", "demo-member", "demo-target", "차단 대상");
    await setConversationMuted("demo", "demo-member", "conversation-1", true);
    const state = await loadSafetyPrivacyState("demo", "demo-member");
    expect(state.blockedProfiles).toEqual(expect.arrayContaining([expect.objectContaining({ userId: "demo-target" })]));
    expect(state.mutedConversationIds).toContain("conversation-1");

    await unblockUser("demo", "demo-member", "demo-target");
    expect((await loadSafetyPrivacyState("demo", "demo-member")).blockedProfiles).toHaveLength(0);
  });

  it("normalizes the canonical RPC response without opening consent by default", () => {
    const normalized = __normalizeSafetyPrivacyStateForTests({
      current_documents: {
        privacy_policy: {
          version: "2026-08-27",
          required: true,
          title: "개인정보 처리방침",
          url: "/legal/privacy/2026-08-27",
        },
        community_guidelines: {
          version: "2026-08-27",
          required: true,
          title: "공동체 이용규칙",
          url: "/legal/community/2026-08-27",
        },
      },
      consents: [
        { document_key: "privacy_policy", document_version: "2026-08-27", accepted: true, recorded_at: "2026-08-30T01:00:00.000Z" },
        { document_key: "community_guidelines", document_version: "2026-08-27", accepted: true, recorded_at: "2026-08-30T01:01:00.000Z" },
      ],
      directory_visibility: { avatar: true, church_title: false, email: false, bio: true },
      notifications: {
        push_enabled: true,
        categories: { approvals: true, posts: false, comments: true, chats: true, governance: false, events: true },
        quiet_hours_enabled: true,
        quiet_hours_start: "22:00",
        quiet_hours_end: "07:00",
        lock_screen_preview: "hidden",
      },
      push_devices: [{
        id: "device-1",
        installation_id: "123e4567-e89b-42d3-a456-426614174000",
        platform: "ios",
        app_version: "1.2.3",
        last_seen_at: "2026-08-27T02:10:00.000Z",
        disabled_at: null,
      }],
      blocked_profiles: [{ user_id: "blocked-1", display_name: "차단 사용자", blocked_at: "2026-08-27T02:00:00.000Z" }],
      muted_conversation_ids: ["conversation-1"],
      account_deletion: { status: "none", requested_at: null, scheduled_for: null },
    });
    expect(normalized.requiredConsents).toContainEqual({
      key: "privacy_policy",
      version: "2026-08-27",
      acceptedAt: "2026-08-30T01:00:00.000Z",
    });
    expect(normalized.consentGateOpen).toBe(false);
    expect(normalized.directoryVisibility).toEqual({ avatar: true, churchTitle: false, email: false, bio: true });
    expect(normalized.notifications.lockScreenPreview).toBe("hidden");
    expect(normalized.pushDevices).toEqual([expect.objectContaining({ id: "device-1", platform: "ios" })]);
    expect(normalized.blockedProfiles[0].displayName).toBe("차단 사용자");
    expect(normalized.mutedConversationIds).toEqual(["conversation-1"]);
  });

  it("does not treat a governance-only delegate as a community moderator", () => {
    expect(canModerateCommunity({
      profile: { ...DEMO_VIEWER, id: "delegated-member", globalRole: "user" },
      membership: {
        id: "delegated-membership",
        organizationId: "org-19",
        userId: "delegated-member",
        role: "member",
        executiveOfficeCodes: [],
        status: "active",
      },
      governanceAccess: [{
        scopeId: "demo-scope-church-org-19",
        scopeType: "church",
        scopeName: "재건부평교회",
        authoritySource: "delegation",
        officeCodes: [],
        canManageOfficers: true,
        canManageDelegations: true,
        canViewRoster: true,
        expiresAt: null,
      }],
    })).toBe(false);
  });
});

describe("reusable safety controls", () => {
  it("confirms a user block and reports the resulting state", async () => {
    const onChanged = vi.fn();
    render(<BlockUserControl mode="demo" userId="demo-member" targetUserId="demo-target" targetDisplayName="테스트 사용자" onChanged={onChanged} />);
    const trigger = screen.getByRole("button", { name: "사용자 차단" });
    trigger.focus();
    fireEvent.click(trigger);
    let confirmation = screen.getByRole("dialog", { name: /테스트 사용자님을 차단할까요/ });
    expect(within(confirmation).getByRole("button", { name: "취소" })).toHaveFocus();
    fireEvent.keyDown(confirmation, { key: "Escape" });
    expect(trigger).toHaveFocus();
    fireEvent.click(trigger);
    confirmation = screen.getByRole("dialog", { name: /테스트 사용자님을 차단할까요/ });
    fireEvent.click(within(confirmation).getByRole("button", { name: "차단" }));
    expect(await screen.findByRole("button", { name: "차단 해제" })).toHaveAttribute("aria-pressed", "true");
    expect(onChanged).toHaveBeenCalledWith(true);
  });

  it("toggles a conversation notification preference and rejects an external return URL", async () => {
    const onChanged = vi.fn();
    render(
      <MemoryRouter>
        <ConversationMuteControl mode="demo" userId="demo-member" conversationId="conversation-1" initiallyMuted={false} onChanged={onChanged} />
        <ReportActionLink targetType="post" targetId="post-1" returnTo="//example.com/steal" />
      </MemoryRouter>,
    );
    fireEvent.click(screen.getByRole("button", { name: "대화 알림 끄기" }));
    expect(await screen.findByRole("button", { name: "알림 다시 받기" })).toHaveAttribute("aria-pressed", "true");
    expect(onChanged).toHaveBeenCalledWith(true);
    const reportHref = screen.getByRole("link", { name: "신고" }).getAttribute("href") ?? "";
    expect(reportHref).toContain("/app/report/post/post-1");
    expect(reportHref).not.toContain("example.com");
  });
});

describe("safety and privacy routes", () => {
  it("exposes report, block, and mute actions in the real post and chat flows", async () => {
    setDemoMember();
    const postView = renderApp("/app/posts/post-community");
    expect(await screen.findByRole("heading", { name: "목장 모임에서 함께 나눈 말씀" })).toBeInTheDocument();
    const postReportLinks = screen.getAllByRole("link", { name: "신고" });
    expect(postReportLinks.map((link) => link.getAttribute("href"))).toEqual(expect.arrayContaining([
      expect.stringContaining("/app/report/post/post-community"),
      expect.stringContaining("/app/report/comment/comment-1"),
    ]));
    postView.unmount();

    setDemoMember();
    renderApp("/app/chats/conversation-1");
    expect(await screen.findByRole("heading", { name: "김하늘" })).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "대화 알림 끄기" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "사용자 차단" })).toBeInTheDocument();
    const chatReportHrefs = screen.getAllByRole("link", { name: "신고" })
      .map((link) => link.getAttribute("href") ?? "");
    expect(chatReportHrefs).toEqual(expect.arrayContaining([
      expect.stringContaining("/app/report/profile/demo-haneul"),
      expect.stringContaining("/app/report/message/message-1"),
    ]));
  });

  it("renders the versioned launch processor disclosure before sign-in", async () => {
    renderApp("/legal/overseas/2026-08-30");
    expect(await screen.findByRole("heading", { name: "개인정보 국외 이전 동의" })).toBeInTheDocument();
    expect(screen.getByText(/SUPABASE PTE\. LTD\..*privacy@supabase\.io.*AWS us-east-1/)).toBeInTheDocument();
    expect(screen.getByText(/Vercel Inc\..*privacy@vercel\.com.*Hobby 플랜/)).toBeInTheDocument();
    expect(screen.getByText(/Google LLC.*chaos990562@gmail\.com/)).toBeInTheDocument();
    expect(screen.getByText(/사실 고지이며.*법률 준수를 보증하는 것은 아닙니다/)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "공동체 운영정책" })).toHaveAttribute("href", "/legal/community");
  });

  it("publishes a concrete community-policy appeal window and response target", async () => {
    renderApp("/legal/community/2026-08-30");
    expect(await screen.findByRole("heading", { name: "공동체 운영정책" })).toBeInTheDocument();
    expect(screen.getByText(/조치를 확인한 뒤 가능한 한 14일 안에/)).toBeInTheDocument();
    expect(screen.getByText(/합리적인 기간 안에 검토/)).toBeInTheDocument();
    expect(screen.getByText(/검토가 지연되는 경우 그 사실과 이유를 안내/)).toBeInTheDocument();
  });

  it("does not silently substitute the current copy for an unknown legal version", async () => {
    renderApp("/legal/community/2025-01-01");
    expect(await screen.findByRole("heading", { name: "요청한 운영정책 버전을 찾을 수 없습니다" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "현재 버전 열기" })).toHaveAttribute("href", "/legal/community/2026-08-30");
  });

  it("provides a public store-facing account deletion path before sign-in", async () => {
    renderApp("/account-deletion");
    expect(await screen.findByRole("heading", { name: "계정과 데이터 삭제 요청" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "로그인하여 삭제 요청" })).toHaveAttribute("href", "/auth");
    expect(screen.getByRole("heading", { name: "삭제되는 데이터" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "제한적으로 보존될 수 있는 데이터" })).toBeInTheDocument();
  });

  it("lets a demo member review required consents and save directory visibility", async () => {
    setDemoMember();
    renderApp("/app/privacy");
    expect(await screen.findByRole("heading", { name: "개인정보와 동의" })).toBeInTheDocument();
    expect(screen.getByText("로컬 데모 동작")).toBeInTheDocument();
    const avatarSwitch = screen.getByRole("checkbox", { name: /프로필 사진/ });
    expect(avatarSwitch).not.toBeChecked();
    fireEvent.click(avatarSwitch);
    fireEvent.click(screen.getByRole("button", { name: "동의 및 공개 범위 저장" }));
    expect(await screen.findByRole("status")).toHaveTextContent("개인정보 설정을 저장했습니다");
    expect((await loadSafetyPrivacyState("demo", "demo-member")).directoryVisibility.avatar).toBe(true);
  });

  it("submits a target-scoped report and prevents duplicate interaction while complete", async () => {
    setDemoMember();
    renderApp("/app/report/post/post-123?label=%EC%A4%91%EC%9A%94%20%EA%B3%B5%EC%A7%80&returnTo=/app/posts");
    expect(await screen.findByRole("heading", { name: "신고하기" })).toBeInTheDocument();
    expect(screen.getByText("중요 공지")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("radio", { name: "스팸·사기" }));
    fireEvent.click(screen.getByRole("button", { name: "신고 접수" }));
    expect(await screen.findByRole("heading", { name: "신고가 접수되었습니다" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "원래 화면으로" })).toHaveAttribute("href", "/app/posts");
  });

  it("requires typed confirmation before a demo account deletion reservation", async () => {
    setDemoMember();
    renderApp("/app/account");
    expect(await screen.findByRole("heading", { name: "계정 삭제" })).toBeInTheDocument();
    const requestButton = await screen.findByRole("button", { name: "계정 삭제 요청" });
    expect(requestButton).toBeDisabled();
    fireEvent.change(screen.getByLabelText(/확인 문구/), { target: { value: ACCOUNT_DELETION_CONFIRMATION } });
    expect(requestButton).toBeEnabled();
    fireEvent.click(requestButton);
    const confirmation = screen.getByRole("dialog", { name: /계정 삭제를 예약할까요/ });
    fireEvent.click(within(confirmation).getByRole("button", { name: "삭제 예약" }));
    expect(await screen.findByRole("heading", { name: "계정 삭제가 예약되어 있습니다" })).toBeInTheDocument();
  });

  it("keeps the moderation queue manager-only and explicitly empty in demo mode", async () => {
    const state = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({ ...state, viewer: { profile: DEMO_VIEWER } }));
    renderApp("/manage/moderation");
    expect(await screen.findByRole("heading", { name: "공동체 신고를 안전하게 검토해요" })).toBeInTheDocument();
    expect(await screen.findByRole("heading", { name: "해당 상태의 신고가 없어요" })).toBeInTheDocument();
    expect(screen.getByText(/로컬 데모에서는 실제 신고나 제재 데이터를 만들지 않습니다/)).toBeInTheDocument();
  });
});
