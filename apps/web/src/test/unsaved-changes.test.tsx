import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router-dom";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import { getServiceYear } from "../serviceTime";
import { UNSAVED_CHANGES_MESSAGE, useUnsavedChangesWarning } from "../unsavedChanges";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";
const LAZY_ROUTE_TIMEOUT_MS = 5_000;
const LAZY_ROUTE_TEST_TIMEOUT_MS = 10_000;

function storeViewer(role: "member" | "executive") {
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...createDemoState(),
    viewer: {
      profile: { ...DEMO_VIEWER, globalRole: "user" },
      membership: {
        id: `unsaved-${role}-membership`,
        organizationId: "org-19",
        userId: DEMO_VIEWER.id,
        role,
        churchTitleCode: role === "executive" ? "elder" : "deacon",
        executiveOfficeCodes: role === "executive" ? ["president", "secretary", "treasurer"] : [],
        status: "active",
      },
    },
  }));
}

function renderApp(initialEntries: string[]) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <AppDataProvider>
        <App />
      </AppDataProvider>
    </MemoryRouter>,
  );
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("unsaved form protection", () => {
  it("cancels and reverses a BrowserRouter-style back traversal without adding a history entry", async () => {
    function GuardHarness() {
      useUnsavedChangesWarning(true);
      return <p>작성 중</p>;
    }

    window.history.replaceState({ idx: 40 }, "", "/guard-origin");
    window.history.pushState({ idx: 41 }, "", "/guard-dirty");
    const originalLength = window.history.length;
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    const view = render(<GuardHarness />);

    act(() => window.history.back());
    await waitFor(() => expect(confirm).toHaveBeenCalledWith(UNSAVED_CHANGES_MESSAGE));
    await waitFor(() => expect(window.location.pathname).toBe("/guard-dirty"));
    expect(confirm).toHaveBeenCalledTimes(1);
    expect(window.history.length).toBe(originalLength);

    view.unmount();
    window.history.replaceState(null, "", "/");
  });

  it("blocks post-composer back navigation and page unload only after input changes", async () => {
    storeViewer("member");
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    renderApp(["/app/posts", "/app/posts/new"]);

    const title = await screen.findByPlaceholderText(
      "제목을 입력해 주세요",
      undefined,
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    );
    const pristineUnload = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(pristineUnload);
    expect(pristineUnload.defaultPrevented).toBe(false);

    fireEvent.change(title, { target: { value: "작성 중인 제목" } });
    const dirtyUnload = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(dirtyUnload);
    expect(dirtyUnload.defaultPrevented).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "뒤로" }));
    expect(confirm).toHaveBeenCalledWith(UNSAVED_CHANGES_MESSAGE);
    expect(screen.getByRole("heading", { name: "새 글 작성" })).toBeInTheDocument();

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole("button", { name: "뒤로" }));
    expect(await screen.findByRole("heading", { name: "게시판" })).toBeInTheDocument();
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);

  it("keeps a changed meeting-minutes form open when close is cancelled", async () => {
    storeViewer("executive");
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    renderApp(["/manage/home", "/manage/minutes"]);

    expect(await screen.findByRole(
      "heading",
      { name: "임원 회의 기록" },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "회의록 작성" }));
    fireEvent.change(screen.getByLabelText(/회의 제목/), { target: { value: "작성 중인 회의록" } });
    fireEvent.click(screen.getByRole("button", { name: "작성 폼 닫기" }));

    expect(confirm).toHaveBeenCalledWith(UNSAVED_CHANGES_MESSAGE);
    expect(screen.getByText("새 회의록")).toBeInTheDocument();

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole("button", { name: "작성 폼 닫기" }));
    expect(screen.queryByText("새 회의록")).not.toBeInTheDocument();
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);

  it("blocks ManagerShell navigation links until the dirty meeting form is confirmed", async () => {
    storeViewer("executive");
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    renderApp(["/manage/minutes"]);

    expect(await screen.findByRole(
      "heading",
      { name: "임원 회의 기록" },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "회의록 작성" }));
    fireEvent.change(screen.getByLabelText(/회의 제목/), { target: { value: "이동 전에 지켜야 할 회의록" } });
    fireEvent.click(screen.getAllByRole("link", { name: "운영 홈" })[0]);

    expect(confirm).toHaveBeenCalledWith(UNSAVED_CHANGES_MESSAGE);
    expect(screen.getByRole("heading", { name: "임원 회의 기록" })).toBeInTheDocument();
    expect(screen.getByDisplayValue("이동 전에 지켜야 할 회의록")).toBeInTheDocument();

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getAllByRole("link", { name: "운영 홈" })[0]);
    expect(await screen.findByRole(
      "heading",
      { name: /올해 교회 운영 흐름을 살펴보세요/ },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);

  it("does not switch ledger years when discarding a changed entry is cancelled", async () => {
    storeViewer("executive");
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    const currentYear = getServiceYear();
    renderApp(["/manage/ledger"]);

    expect(await screen.findByRole(
      "heading",
      { name: "교회 재정 기록" },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    fireEvent.click(screen.getAllByRole("button", { name: "항목 등록" }).at(-1)!);
    fireEvent.change(screen.getByLabelText(/적요/), { target: { value: "작성 중인 장부 항목" } });

    const yearSelector = screen.getByRole("combobox", { name: "회계 연도" });
    fireEvent.change(yearSelector, { target: { value: String(currentYear - 1) } });
    expect(confirm).toHaveBeenCalledWith(UNSAVED_CHANGES_MESSAGE);
    expect(yearSelector).toHaveValue(String(currentYear));
    expect(screen.getByText("새 장부 항목")).toBeInTheDocument();

    confirm.mockReturnValue(true);
    fireEvent.change(yearSelector, { target: { value: String(currentYear - 1) } });
    expect(yearSelector).toHaveValue(String(currentYear - 1));
    expect(screen.queryByText("새 장부 항목")).not.toBeInTheDocument();
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);
});

describe("comment length contract", () => {
  it("matches the 5,000-character backend limit and rejects an oversized submitted value", async () => {
    storeViewer("member");
    renderApp(["/app/posts/post-retreat"]);

    const comment = await screen.findByPlaceholderText(
      "따뜻한 댓글을 남겨주세요",
      undefined,
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    );
    expect(comment).toHaveAttribute("maxLength", "5000");
    expect(screen.getByText("0/5,000")).toBeInTheDocument();

    fireEvent.change(comment, { target: { value: "가".repeat(5001) } });
    expect(screen.getByText("5,001/5,000")).toBeInTheDocument();
    expect(comment).toHaveAttribute("aria-invalid", "true");
    fireEvent.submit(comment.closest("form")!);
    expect(await screen.findByRole("alert")).toHaveTextContent("댓글은 5,000자 이하로 입력해 주세요.");
  }, LAZY_ROUTE_TEST_TIMEOUT_MS);
});
