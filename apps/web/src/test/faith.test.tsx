import { webcrypto } from "node:crypto";
import { FAITH_CONSENT, parseFaithConsentStatus, verifyFaithConsentText } from "../data/faithConsent";
import { FaithAcceptance, FaithWithdrawalPage } from "../pages/FaithConsentPages";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { BIBLE_BOOKS, BIBLE_CHAPTERS, chapterID, chapterReference } from "../data/bibleCanon";
import { parseFaithSnapshot, validateQT } from "../data/faith";
import { FaithHomeWidget, FaithPage } from "../pages/FaithPages";
import { faithTodayPlan } from "../data/faithPlan";

const mocks = vi.hoisted(() => ({ rpc: vi.fn(), createPost: vi.fn(), app: { mode: "live", consentGateOpen: true as boolean | null, viewer: { profile: { id: "00000000-0000-0000-0000-000000000001" }, membership: { organizationId: "00000000-0000-0000-0000-000000000002", status: "active" } } } }));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({ ...mocks.app, createPost: mocks.createPost }) }));
vi.mock("../data/supabase", () => ({ supabase: { rpc: mocks.rpc } }));
vi.mock("../pages/FaithBibleReader", () => ({ FaithBibleReader: () => null }));
vi.mock("../pages/FaithCommunity", () => ({ FaithCommunitySection: () => null }));
const snapshot = { server_today: "2026-10-14", service_year: 2026, completed_chapters: [], completed_count: 0, total_chapters: 1189, streak_days: 0, last_read_date: null, latest_private_qt: [] };
function result(data: unknown, error: unknown = null) { const promise = Promise.resolve({ data, error }); return Object.assign(promise, { abortSignal: () => promise }); }
beforeEach(() => { mocks.rpc.mockReset(); mocks.createPost.mockReset(); mocks.app.mode = "live"; mocks.app.consentGateOpen = true; Object.defineProperty(globalThis.crypto, "subtle", { configurable: true, value: webcrypto.subtle }); mocks.rpc.mockImplementation((name) => result(name === "get_faith_consent_status" ? { accepted: true, document: FAITH_CONSENT } : snapshot)); });
describe("faith validation", () => {
  it("maps exactly66books/1189 unique chapter references independently of the text dataset", () => {
    expect(BIBLE_BOOKS).toHaveLength(66); expect(BIBLE_CHAPTERS).toHaveLength(1189);
    expect(chapterID(0, 1)).toBe(1); expect(chapterReference(1189)).toBe("요한계시록 22장");
    expect(chapterID(65, 23)).toBeNull(); expect(chapterReference(0)).toBe(""); expect(chapterReference(1.5)).toBe("");
  });
  it("rejects malformed, duplicate and outofbounds server IDs", () => {
    expect(parseFaithSnapshot(snapshot)).toEqual(snapshot);
    for (const patch of [{ completed_chapters: [1, 1], completed_count: 2 }, { completed_chapters: [1190], completed_count: 1 }, { completed_count: 5 }, { service_year: 2025 }, { server_today: "2026-02-31" }, { last_read_date: "2026-10-15" }, { streak_days: -1 }, { total_chapters: 999 }]) expect(() => parseFaithSnapshot({ ...snapshot, ...patch })).toThrow();
  });
  it("bounds private QT using Unicode code points not UTF16 units", () => {
    expect(validateQT(" 창세기 1장 ", " 기도 ")).toEqual({ reference: "창세기 1장", body: "기도" });
    expect(() => validateQT("창세기 1장", "😀".repeat(500))).not.toThrow();
    expect(() => validateQT("창세기 1장", "가".repeat(501))).toThrow(); expect(() => validateQT("", "기도")).toThrow(); expect(() => validateQT("가".repeat(81), "기도")).toThrow();
  });
});
describe("faith UI", () => {
  it("shows actual empty server progress and Bible rightsboundary", async () => {
    render(<MemoryRouter><FaithPage /></MemoryRouter>);
    expect(await screen.findByText("2026년 내 통독")).toBeVisible();
    expect(screen.getByText(/본문은 사용하시는 성경에서/)).toBeVisible();
    expect(screen.getByText("아직 저장한 묵상이 없습니다.")).toBeVisible();
  });
  it("shows today's deterministic server-date targets with chapter reader links but no automatic completion", async () => {
    render(<MemoryRouter><FaithHomeWidget /></MemoryRouter>);
    await screen.findByText("오늘의 연간 통독 목표");
    for (const target of faithTodayPlan(snapshot.server_today)) expect(screen.getByRole("link", { name: chapterReference(target) })).toHaveAttribute("href", `/bible?chapter=${target}`);
    expect(mocks.rpc.mock.calls.every(([name]) => ["get_faith_consent_status", "get_faith_snapshot"].includes(name))).toBe(true);
  });
  it("checks only the deliberately selected daily target while retaining earlier completed chapters", async () => {
    let stored = { ...snapshot, completed_chapters: [1], completed_count: 1, streak_days: 1, last_read_date: snapshot.server_today };
    const target = faithTodayPlan(snapshot.server_today)[0];
    mocks.rpc.mockImplementation((name, args) => {
      if (name === "get_faith_consent_status") return result({ accepted: true, document: FAITH_CONSENT });
      if (name === "set_my_reading_chapter") { stored = { ...stored, completed_chapters: [1, args.p_chapter_id], completed_count: 2 }; }
      return result(stored);
    });
    render(<MemoryRouter><FaithPage /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: `${chapterReference(target)} · 읽음 표시` }));
    await waitFor(() => expect(screen.getByRole("progressbar", { name: "통독 진도" })).toHaveAttribute("value", "2"));
    expect(mocks.rpc).toHaveBeenCalledWith("set_my_reading_chapter", { p_organization_id: mocks.app.viewer.membership.organizationId, p_service_year: 2026, p_chapter_id: target, p_completed: true });
    expect(stored.completed_chapters).toEqual([1, target]);
  });
  it("shows loadfailure and explicit retry without successstats", async () => {
    mocks.rpc.mockImplementation(() => result(null, { code: "offline" }));
    render(<MemoryRouter><FaithHomeWidget /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("불러오지 못했습니다");
    expect(screen.getByRole("button", { name: "다시 불러오기" })).toBeEnabled(); expect(screen.queryByRole("progressbar")).not.toBeInTheDocument();
  });
  it("does not query backend in demo or before current consent", async () => {
    mocks.app.consentGateOpen = false;
    const { unmount } = render(<MemoryRouter><FaithPage /></MemoryRouter>);
    expect(screen.getByRole("status")).toHaveTextContent("최신 동의가 필요"); expect(mocks.rpc).not.toHaveBeenCalled(); unmount();
    mocks.app.consentGateOpen = true; mocks.app.mode = "demo";
    render(<MemoryRouter><FaithHomeWidget /></MemoryRouter>); expect(screen.getByText(/데모에서는 개인/)).toBeVisible(); expect(mocks.rpc).not.toHaveBeenCalled();
  });
  it("discards an oldactor response after the current actor changes", async () => {
    let resolveOld!: (value: { data: unknown; error: null }) => void;
    const old = new Promise<{ data: unknown; error: null }>((resolve) => { resolveOld = resolve; });
    mocks.rpc.mockImplementationOnce(() => Object.assign(old, { abortSignal: () => old })).mockImplementation((name) => result(name === "get_faith_consent_status" ? { accepted: true, document: FAITH_CONSENT } : snapshot));
    const { rerender } = render(<MemoryRouter><FaithHomeWidget /></MemoryRouter>);
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledTimes(1));
    const originalActor = mocks.app.viewer.profile.id;
    mocks.app.viewer.profile.id = "00000000-0000-0000-0000-000000000004";
    rerender(<MemoryRouter><FaithHomeWidget /></MemoryRouter>);
    await screen.findByRole("progressbar");
    await act(async () => { resolveOld({ data: { ...snapshot, completed_chapters: [1], completed_count: 1 }, error: null }); });
    expect(screen.getByRole("progressbar")).toHaveAttribute("value", "0");
    mocks.app.viewer.profile.id = originalActor;
  });
  it("freezes uncertain QT and retries the same UUID/payload without doubleclick writes", async () => {
    mocks.rpc.mockImplementation((name) => name === "get_faith_consent_status" ? result({ accepted: true, document: FAITH_CONSENT }) : name === "get_faith_snapshot" ? result(snapshot) : result(null, { code: "timeout" }));
    render(<MemoryRouter><FaithPage /></MemoryRouter>); await screen.findByText("2026년 내 통독");
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "오늘 나의 묵상" } });
    const button = screen.getByRole("button", { name: "나만 볼 수 있게 저장" }); fireEvent.click(button); fireEvent.click(button);
    await screen.findByText(/결과를 확인하지 못했습니다/);
    expect(screen.getByRole("textbox")).toBeDisabled();
    const requests = () => mocks.rpc.mock.calls.filter(([name]) => name === "create_my_qt"); expect(requests()).toHaveLength(1);
    fireEvent.click(screen.getByRole("button", { name: "같은 묵상 저장 결과 확인" }));
    await waitFor(() => expect(requests()).toHaveLength(2)); expect(requests()[0][1]).toEqual(requests()[1][1]);
  });
  it("never shares private QT without explicit publicconfirmation", async () => {
    const qt = { id: "00000000-0000-0000-0000-000000000003", reference: "창세기 1장", body: "긴 묵상".repeat(90), created_at: "2026-10-14T01:00:00Z" };
    mocks.rpc.mockImplementation((name) => result(name === "get_faith_consent_status" ? { accepted: true, document: FAITH_CONSENT } : { ...snapshot, latest_private_qt: [qt] }));
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    render(<MemoryRouter><FaithPage /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: "교회 게시판에 공유" }));
    expect(confirm).toHaveBeenCalled(); expect(mocks.createPost).not.toHaveBeenCalled(); confirm.mockRestore();
    expect(mocks.rpc.mock.calls.some(([name]) => name === "share_my_qt")).toBe(false);
  });
  it("shares only the explicitly selected own QT via one stable server copy request", async () => {
    const qt = { id: "00000000-0000-0000-0000-000000000003", reference: "창세기 1장", body: "선택한 묵상", created_at: "2026-10-14T01:00:00Z" };
    mocks.rpc.mockImplementation((name) => name === "get_faith_consent_status" ? result({ accepted: true, document: FAITH_CONSENT }) : name === "share_my_qt" ? result(null, { code: "timeout" }) : result({ ...snapshot, latest_private_qt: [qt] }));
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<MemoryRouter><FaithPage /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: "교회 게시판에 공유" }));
    await screen.findByText(/결과를 확인하지 못했습니다/);
    fireEvent.click(screen.getByRole("button", { name: "보류된 게시판 공유 결과 확인" }));
    await waitFor(() => expect(mocks.rpc.mock.calls.filter(([name]) => name === "share_my_qt")).toHaveLength(2));
    const requests = mocks.rpc.mock.calls.filter(([name]) => name === "share_my_qt");
    expect(requests[0][1]).toEqual(requests[1][1]); expect(requests[0][1].p_qt_id).toBe(qt.id);
    expect(requests[0][1]).not.toHaveProperty("p_body"); expect(mocks.createPost).not.toHaveBeenCalled();
    expect(confirm).toHaveBeenCalledOnce(); confirm.mockRestore();
  });
  it("shows definitive quota refusal without trapping the user in uncertain retry", async () => {
    mocks.rpc.mockImplementation((name) => name === "get_faith_consent_status" ? result({ accepted: true, document: FAITH_CONSENT }) : name === "get_faith_snapshot" ? result(snapshot) : result(null, { message: "qt_daily_creation_limit" }));
    render(<MemoryRouter><FaithPage /></MemoryRouter>); await screen.findByText("2026년 내 통독");
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "나의 기도" } }); fireEvent.click(screen.getByRole("button", { name: "나만 볼 수 있게 저장" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("20개까지"); expect(screen.getByRole("textbox")).toBeEnabled();
    expect(screen.queryByRole("button", { name: "같은 묵상 저장 결과 확인" })).not.toBeInTheDocument();
  });
});
describe("optional private record consent", () => {
  it("validates the actual document bytes and fails closed for unknown manifests", async () => {
    await expect(verifyFaithConsentText()).resolves.toBeUndefined();
    expect(() => parseFaithConsentStatus({ accepted: true, document: { ...FAITH_CONSENT, content_sha256: "0".repeat(64) } })).toThrow();
    expect(() => parseFaithConsentStatus({ accepted: "true", document: FAITH_CONSENT })).toThrow();
  });
  it("does not fetch or write private records before optional consent", async () => {
    mocks.rpc.mockImplementation(() => result({ accepted: false, document: FAITH_CONSENT }));
    render(<MemoryRouter><FaithPage /></MemoryRouter>);
    expect(await screen.findByRole("button", { name: "동의하고 개인 기록 시작" })).toBeDisabled();
    expect(mocks.rpc.mock.calls.every(([name]) => name === "get_faith_consent_status")).toBe(true);
    expect(screen.getByRole("textbox")).toBeDisabled();
  });
  it("requires a read action and unchecked explicit selection before acceptance", async () => {
    const done = vi.fn();
    mocks.rpc.mockImplementation(() => result({ accepted: true, document: FAITH_CONSENT }));
    render(<MemoryRouter><FaithAcceptance organization="00000000-0000-0000-0000-000000000002" onAccepted={done} /></MemoryRouter>);
    const checkbox = screen.getByRole("checkbox"); expect(checkbox).not.toBeChecked(); expect(checkbox).toBeDisabled();
    const details = screen.getByText("개인 기록 안내 전문 읽기").closest("details")!;
    details.open = true; fireEvent(details, new Event("toggle"));
    fireEvent.click(checkbox); fireEvent.click(screen.getByRole("button", { name: "동의하고 개인 기록 시작" }));
    await waitFor(() => expect(done).toHaveBeenCalledOnce());
    expect(mocks.rpc).toHaveBeenCalledWith("accept_faith_consent", expect.objectContaining({ p_version: FAITH_CONSENT.version, p_content_sha256: FAITH_CONSENT.content_sha256 }));
  });
  it("allows explicit self-service withdrawal without reading protected data", async () => {
    mocks.app.consentGateOpen = false; mocks.rpc.mockImplementation(() => result({ accepted: false, deleted: true }));
    render(<MemoryRouter><FaithWithdrawalPage /></MemoryRouter>);
    expect(mocks.rpc).not.toHaveBeenCalled(); fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: "동의 철회 및 개인 기록 삭제" }));
    expect(await screen.findByRole("status")).toHaveTextContent("삭제했습니다");
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("withdraw_faith_consent", { p_organization_id: null, p_confirm_delete: true });
  });
});
