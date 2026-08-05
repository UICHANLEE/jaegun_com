import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { ConversationPage } from "../pages/ChatPages";

const mocked = vi.hoisted(() => ({
  useAppData: vi.fn(),
}));

vi.mock("../data/AppDataProvider", () => ({
  useAppData: mocked.useAppData,
}));

describe("chat draft preservation", () => {
  it("keeps edits made while a slow message is being sent", async () => {
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: vi.fn(),
    });
    let finishSend!: () => void;
    const pendingSend = new Promise<void>((resolve) => { finishSend = resolve; });
    const sendMessage = vi.fn().mockReturnValue(pendingSend);
    mocked.useAppData.mockReturnValue({
      viewer: { profile: { id: "viewer" } },
      conversations: [{
        id: "conversation-1",
        organizationId: "org-19",
        participant: { id: "other", displayName: "대화 상대", email: "other@example.com", globalRole: "user" },
        lastMessage: "",
        lastMessageAt: "2026-08-05T00:00:00.000Z",
        unreadCount: 0,
      }],
      messagesByConversation: { "conversation-1": [] },
      loadConversationMessages: vi.fn().mockResolvedValue(undefined),
      markConversationRead: vi.fn().mockResolvedValue(undefined),
      sendMessage,
    });

    render(
      <MemoryRouter initialEntries={["/app/chats/conversation-1"]}>
        <Routes>
          <Route path="/app/chats/:conversationId" element={<ConversationPage />} />
        </Routes>
      </MemoryRouter>,
    );

    const composer = screen.getByPlaceholderText("메시지를 입력하세요");
    const fileInput = screen.getByLabelText("사진 또는 영상 첨부");
    const sentFile = new File(["first"], "전송할사진.png", { type: "image/png" });
    fireEvent.change(composer, { target: { value: "먼저 보낼 메시지" } });
    fireEvent.change(fileInput, { target: { files: [sentFile] } });
    fireEvent.click(screen.getByRole("button", { name: "메시지 보내기" }));

    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(
      "conversation-1",
      "먼저 보낼 메시지",
      [sentFile],
    ));

    const nextFile = new File(["next"], "다음초안사진.png", { type: "image/png" });
    fireEvent.change(composer, { target: { value: "전송 중 작성한 다음 초안" } });
    fireEvent.change(fileInput, { target: { files: [nextFile] } });
    expect(composer).toHaveValue("전송 중 작성한 다음 초안");
    expect(screen.getByText("다음초안사진.png")).toBeInTheDocument();

    await act(async () => finishSend());

    expect(composer).toHaveValue("전송 중 작성한 다음 초안");
    expect(screen.getByText("다음초안사진.png")).toBeInTheDocument();
    expect(screen.queryByText("전송할사진.png")).not.toBeInTheDocument();
  });
});
