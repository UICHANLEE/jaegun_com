import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import { UNSAVED_CHANGES_MESSAGE } from "../unsavedChanges";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";
const LAZY_ROUTE_TIMEOUT_MS = 5_000;

function storeExecutive() {
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...createDemoState(),
    viewer: {
      profile: { ...DEMO_VIEWER, globalRole: "user" },
      membership: {
        id: "browser-guard-executive",
        organizationId: "org-19",
        userId: DEMO_VIEWER.id,
        role: "executive",
        churchTitleCode: "elder",
        executiveOfficeCodes: ["president", "secretary", "treasurer"],
        status: "active",
      },
    },
  }));
}

afterEach(() => {
  vi.restoreAllMocks();
  window.history.replaceState(null, "", "/");
});

describe("BrowserRouter unsaved traversal integration", () => {
  it("keeps the dirty form and value mounted after a cancelled browser back", async () => {
    storeExecutive();
    window.history.replaceState(null, "", "/manage/home");
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    const view = render(
      <BrowserRouter>
        <AppDataProvider>
          <App />
        </AppDataProvider>
      </BrowserRouter>,
    );

    expect(await screen.findByRole(
      "heading",
      { name: /올해 교회 운영 흐름을 살펴보세요/ },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    fireEvent.click(screen.getAllByRole("link", { name: "회의록" })[0]);
    expect(await screen.findByRole("heading", { name: "임원 회의 기록" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "회의록 작성" }));
    const title = await screen.findByLabelText(/회의 제목/);
    fireEvent.change(title, { target: { value: "브라우저 뒤로 가기에도 남아야 할 초안" } });
    const historyLength = window.history.length;

    act(() => window.history.back());

    await waitFor(() => expect(confirm).toHaveBeenCalledWith(UNSAVED_CHANGES_MESSAGE));
    await waitFor(() => expect(window.location.pathname).toBe("/manage/minutes"));
    expect(screen.getByRole("heading", { name: "임원 회의 기록" })).toBeInTheDocument();
    expect(screen.getByDisplayValue("브라우저 뒤로 가기에도 남아야 할 초안")).toBeInTheDocument();
    expect(confirm).toHaveBeenCalledTimes(1);
    expect(window.history.length).toBe(historyLength);

    confirm.mockReturnValue(true);
    act(() => window.history.back());
    expect(await screen.findByRole(
      "heading",
      { name: /올해 교회 운영 흐름을 살펴보세요/ },
      { timeout: LAZY_ROUTE_TIMEOUT_MS },
    )).toBeInTheDocument();
    expect(confirm).toHaveBeenCalledTimes(2);
    expect(window.history.length).toBe(historyLength);

    view.unmount();
  }, 10_000);
});
