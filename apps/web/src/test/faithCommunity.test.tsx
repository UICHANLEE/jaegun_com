import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { FaithCommunitySection } from "../pages/FaithCommunity";
import { parseFaithCommunity, parseSharedQTFeed } from "../data/faithCommunity";
const mocks = vi.hoisted(() => ({ rpc: vi.fn(), scope: { key: "actor:church", organization: "00000000-0000-4000-8000-000000000001", actorID: "00000000-0000-4000-8000-000000000003", serviceYear: 2026, sessionEpoch: 0, mode: "supabase" } }));
vi.mock("../data/useFaith", () => ({ useFaithScope: () => mocks.scope }));
vi.mock("../data/supabase", () => ({ supabase: { rpc: mocks.rpc } }));
const community = { server_today: "2026-10-15", service_year: 2026, opted_in: false, challenge_department_code: null, revision: 0, notice_version: "2026-10-15", notice: "선택한 올해의 읽은 장 수만 교회·노회 및 선택한 우리 교회 부서별 통독 모임 집계에 포함합니다.", minimum_group: 5, rankings: [] };
const item = { id: "00000000-0000-4000-8000-000000000002", title: "QT · 창세기 1장", body: "명시적으로 공유한 게시판 사본", created_at: "2026-10-15T01:00:00Z", amen_count: 0, reacted_amen: false };
const feed = { server_today: "2026-10-15", day: "2026-10-15", items: [item] };
function response(data: unknown) { const result = Promise.resolve({ data, error: null }); return Object.assign(result, { abortSignal: () => result }); }
beforeEach(() => { mocks.rpc.mockReset(); mocks.scope.mode = "supabase"; mocks.rpc.mockImplementation((name) => response(name === "get_faith_community" ? community : feed)); });
describe("faith community privacy", () => {
  it("rejects smaller groups and malformed aggregate/feed payloads", () => {
    expect(parseFaithCommunity(community).opted_in).toBe(false);
    expect(() => parseFaithCommunity({ ...community, rankings: [{ kind: "church", id: item.id, name: "교회", participants: 4, chapters: 4, average_chapters: 1, rank: 1 }] })).toThrow();
    expect(() => parseFaithCommunity({ ...community, minimum_group: 1 })).toThrow();
    expect(() => parseFaithCommunity({ ...community, opted_in: true, challenge_department_code: "executive" })).toThrow();
    expect(() => parseFaithCommunity({ ...community, challenge_department_code: "teen" })).toThrow();
    expect(() => parseFaithCommunity({ ...community, opted_in: true, challenge_department_code: "adult", rankings: [{ kind: "department", id: item.id, name: "장년부 통독 모임", participants: 4, chapters: 4, average_chapters: 1, rank: 1 }] })).toThrow();
    expect(() => parseSharedQTFeed({ ...feed, items: [{ ...item, amen_count: -1 }] })).toThrow();
  });
  it("never opts in on feature entry or core consent alone", async () => {
    render(<MemoryRouter><FaithCommunitySection optionalAccepted={false} /></MemoryRouter>);
    expect(await screen.findByText(item.body)).toBeVisible();
    expect(screen.getByRole("checkbox")).not.toBeChecked(); expect(screen.getByRole("checkbox")).toBeDisabled();
    expect(screen.getByRole("combobox")).toHaveValue(""); expect(screen.getByRole("combobox")).toBeDisabled();
    expect(screen.getByRole("button", { name: "올해 조직 집계에 참여" })).toBeDisabled();
    expect(mocks.rpc.mock.calls.every(([name]) => ["get_faith_community", "list_shared_qt"].includes(name))).toBe(true);
  });
  it("submits exact server year, independent notice and expected revision only after explicit selection", async () => {
    render(<MemoryRouter><FaithCommunitySection optionalAccepted /></MemoryRouter>);
    await screen.findByText(item.body);
    const button = screen.getByRole("button", { name: "올해 조직 집계에 참여" }); expect(button).toBeDisabled();
    fireEvent.click(screen.getByRole("checkbox")); fireEvent.click(button);
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith("set_faith_ranking_participation", { p_organization_id: mocks.scope.organization, p_service_year: 2026, p_opted_in: true, p_notice_version: "2026-10-15", p_expected_revision: 0, p_expected_actor_id: mocks.scope.actorID, p_challenge_department_code: null }));
  });
  it("uses an explicitly self-selected department, not profile or office inference", async () => {
    render(<MemoryRouter><FaithCommunitySection optionalAccepted /></MemoryRouter>);
    await screen.findByText(item.body);
    expect(screen.getByRole("combobox")).toHaveValue("");
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "teen" } });
    fireEvent.click(screen.getByRole("checkbox")); fireEvent.click(screen.getByRole("button", { name: "올해 조직 집계에 참여" }));
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith("set_faith_ranking_participation", expect.objectContaining({ p_challenge_department_code: "teen", p_opted_in: true })));
    expect(screen.getByText(/실제 소속·나이·직책·권한을 뜻하거나 변경하지 않습니다/)).toBeVisible();
  });
  it("clears department grouping in the explicit optout request", async () => {
    mocks.rpc.mockImplementation((name) => response(name === "get_faith_community" ? { ...community, opted_in: true, challenge_department_code: "adult", revision: 2 } : feed));
    render(<MemoryRouter><FaithCommunitySection optionalAccepted /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: "조직 집계 참여 취소" }));
    await waitFor(() => expect(mocks.rpc).toHaveBeenCalledWith("set_faith_ranking_participation", expect.objectContaining({ p_opted_in: false, p_challenge_department_code: null, p_expected_revision: 2 })));
  });
  it("uses desired-state unique board amen without sending a private note", async () => {
    mocks.rpc.mockImplementation((name) => response(name === "get_faith_community" ? community : name === "set_post_reaction" ? { amen_count: 1, reacted_amen: true } : feed));
    render(<MemoryRouter><FaithCommunitySection optionalAccepted /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: "아멘 0" }));
    expect(await screen.findByRole("button", { name: "아멘 1 · 취소" })).toHaveAttribute("aria-pressed", "true");
    expect(mocks.rpc).toHaveBeenCalledWith("set_post_reaction", { p_post_id: item.id, p_kind: "amen", p_active: true, p_expected_actor_id: mocks.scope.actorID });
  });
  it("does not read or write community records in demo mode", () => {
    mocks.scope.mode = "demo"; render(<MemoryRouter><FaithCommunitySection optionalAccepted /></MemoryRouter>); expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
