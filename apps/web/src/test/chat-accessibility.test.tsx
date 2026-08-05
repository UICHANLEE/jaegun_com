import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import App from "../App";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

function renderMemberChatList() {
  const base = createDemoState();
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...base,
    viewer: {
      profile: { ...DEMO_VIEWER, globalRole: "user" },
      membership: {
        id: "member-accessibility-membership",
        organizationId: "org-19",
        userId: DEMO_VIEWER.id,
        role: "member",
        churchTitleCode: "deacon",
        executiveOfficeCodes: [],
        status: "active",
      },
    },
  }));

  return render(
    <MemoryRouter initialEntries={["/app/chats"]}>
      <AppDataProvider>
        <App />
      </AppDataProvider>
    </MemoryRouter>,
  );
}

describe("chat dialog accessibility", () => {
  it("traps keyboard focus, closes with Escape, and restores the trigger", async () => {
    renderMemberChatList();

    const trigger = await screen.findByRole("button", { name: "새 대화" });
    fireEvent.click(trigger);

    const dialog = await screen.findByRole("dialog", { name: "새 대화 시작" });
    const search = within(dialog).getByRole("textbox", { name: "대화할 회원 검색" });
    const closeButton = within(dialog).getByRole("button", { name: "닫기" });
    const dialogButtons = within(dialog).getAllByRole("button");
    const lastButton = dialogButtons[dialogButtons.length - 1];

    expect(search).toHaveFocus();
    expect(trigger.closest(".chat-list-page__content")).toHaveAttribute("inert");
    expect(document.body).toHaveStyle({ overflow: "hidden" });

    lastButton.focus();
    fireEvent.keyDown(document, { key: "Tab" });
    expect(closeButton).toHaveFocus();

    fireEvent.keyDown(document, { key: "Escape" });
    expect(screen.queryByRole("dialog", { name: "새 대화 시작" })).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
    expect(document.body.style.overflow).toBe("");
  });
});
