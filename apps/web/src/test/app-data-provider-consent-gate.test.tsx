import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => {
  type Result = { data: unknown; error: Error | null };
  type AuthCallback = (event: string, session: { user: Record<string, unknown> } | null) => void;
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
  const safetyState = {
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
      accepted: false,
      recorded_at: null,
    })),
    consent_gate_open: false,
    directory_visibility: {},
  };
  const fromCalls: string[] = [];
  const rpcCalls: string[] = [];
  const channelNames: string[] = [];
  let authCallback: AuthCallback | null = null;
  let signedIn = true;
  const user = {
    id: "existing-member",
    email: "member@example.com",
    user_metadata: { display_name: "기존 회원" },
  };
  const builder = (result: Result) => {
    const request: Record<string, unknown> = {};
    for (const method of ["select", "eq", "is", "order", "limit", "range"]) {
      request[method] = vi.fn(() => request);
    }
    request.abortSignal = vi.fn(async () => result);
    request.then = (resolve: (value: Result) => unknown, reject?: (reason: unknown) => unknown) => (
      Promise.resolve(result).then(resolve, reject)
    );
    return request;
  };
  const signOut = vi.fn(async () => {
    signedIn = false;
    authCallback?.("SIGNED_OUT", null);
    return { error: null };
  });
  return {
    consentDocuments,
    safetyState,
    fromCalls,
    rpcCalls,
    channelNames,
    user,
    builder,
    signOut,
    reset() {
      fromCalls.length = 0;
      rpcCalls.length = 0;
      channelNames.length = 0;
      authCallback = null;
      signedIn = true;
      signOut.mockClear();
    },
    getSession: vi.fn(async () => ({
      data: { session: signedIn ? { user } : null },
      error: null,
    })),
    onAuthStateChange(callback: AuthCallback) {
      authCallback = callback;
      return { data: { subscription: { unsubscribe: vi.fn() } } };
    },
  };
});

vi.mock("../data/supabase", () => ({
  canPersistSensitiveClientState: () => true,
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: remote.getSession,
      signOut: remote.signOut,
      onAuthStateChange: vi.fn((callback) => remote.onAuthStateChange(callback)),
      mfa: {
        listFactors: vi.fn(async () => ({ data: { totp: [] }, error: null })),
        getAuthenticatorAssuranceLevel: vi.fn(async () => ({
          data: { currentLevel: "aal1", nextLevel: "aal1" },
          error: null,
        })),
      },
    },
    from: vi.fn((table: string) => {
      remote.fromCalls.push(table);
      return remote.builder({
        data: table === "consent_documents" ? remote.consentDocuments : [],
        error: null,
      });
    }),
    rpc: vi.fn((name: string) => {
      remote.rpcCalls.push(name);
      return remote.builder({
        data: name === "get_my_safety_privacy_state" ? remote.safetyState : [],
        error: null,
      });
    }),
    channel: vi.fn((name: string) => {
      remote.channelNames.push(name);
      const channel = { on: vi.fn(() => channel), subscribe: vi.fn(() => channel) };
      return channel;
    }),
    removeChannel: vi.fn(async () => undefined),
    storage: { from: vi.fn() },
  },
}));

import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";

beforeEach(() => remote.reset());

describe("signed-in required-consent gate", () => {
  it("opens the reconsent page before every protected query and preserves the refusal choices on direct load", async () => {
    render(
      <MemoryRouter initialEntries={["/app/home"]}>
        <AppDataProvider><App /></AppDataProvider>
      </MemoryRouter>,
    );

    expect(await screen.findByRole("heading", { name: "개인정보와 동의" })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("필수 동의 확인이 필요합니다");
    expect(screen.getByRole("button", { name: "로그아웃" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "계정 삭제" })).toHaveAttribute("href", "/app/account");
    expect(screen.getAllByRole("link", { name: /전문 보기/ })).toHaveLength(5);
    for (const link of screen.getAllByRole("link", { name: /전문 보기/ })) {
      expect(link).toHaveAttribute("target", "_blank");
      expect(link).toHaveAttribute("rel", expect.stringContaining("noopener"));
    }

    expect(remote.fromCalls.filter((table) => table !== "consent_documents")).toEqual([]);
    expect(remote.rpcCalls.filter((name) => name !== "get_my_safety_privacy_state")).toEqual([]);
    expect(remote.channelNames).toEqual([]);

    fireEvent.click(screen.getByRole("button", { name: "로그아웃" }));
    expect(await screen.findByRole("heading", { name: "다시 만나 반가워요" })).toBeInTheDocument();
    await waitFor(() => expect(remote.signOut).toHaveBeenCalledTimes(1));
  });
});
