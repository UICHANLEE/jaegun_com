import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AIAssistantPage } from "../pages/AIAssistantPage";
import { AI_ASSISTANT_TEMPLATES, getAIAssistantTemplate } from "../data/aiAssistant";

describe("AIAssistantPage", () => {
  beforeEach(() => {
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: vi.fn().mockResolvedValue(undefined) } });
  });

  it("provides usable templates and places the selected prompt in the editable draft", () => {
    const meeting = getAIAssistantTemplate("meeting-notes");
    expect(AI_ASSISTANT_TEMPLATES).toHaveLength(4);
    expect(meeting?.prompt).toContain("확인 필요");

    render(<AIAssistantPage />);
    fireEvent.click(screen.getByRole("button", { name: /회의 정리/ }));
    expect(screen.getByLabelText("AI에게 건넬 질문 초안")).toHaveValue(meeting?.prompt);
    expect(screen.getByLabelText("AI에게 건넬 질문 초안")).toHaveFocus();
    expect(screen.getByLabelText("AI에게 건넬 질문 초안")).toHaveAttribute("maxLength", "6000");
  });

  it("asks before replacing a non-empty edited draft and preserves it when canceled", () => {
    render(<AIAssistantPage />);
    const input = screen.getByLabelText("AI에게 건넬 질문 초안");
    fireEvent.click(screen.getByRole("button", { name: /모임 준비/ }));
    fireEvent.change(input, { target: { value: "직접 작성한 질문" } });
    fireEvent.click(screen.getByRole("button", { name: /성경 공부 질문/ }));

    expect(input).toHaveValue("직접 작성한 질문");
    expect(screen.getByRole("group", { name: "작성한 질문 초안 교체 확인" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "그대로 두기" }));
    expect(input).toHaveValue("직접 작성한 질문");
    expect(screen.queryByRole("group", { name: "작성한 질문 초안 교체 확인" })).not.toBeInTheDocument();
  });

  it("replaces an edited draft only after explicit confirmation", () => {
    render(<AIAssistantPage />);
    const input = screen.getByLabelText("AI에게 건넬 질문 초안");
    fireEvent.click(screen.getByRole("button", { name: /모임 준비/ }));
    fireEvent.change(input, { target: { value: "직접 작성한 질문" } });
    fireEvent.click(screen.getByRole("button", { name: /성경 공부 질문/ }));
    fireEvent.click(screen.getByRole("button", { name: "초안 바꾸기" }));

    expect(input).toHaveValue(getAIAssistantTemplate("bible-study")?.prompt);
    expect(input).toHaveFocus();
  });

  it("clears a chosen draft without persisting it", () => {
    render(<AIAssistantPage />);
    const input = screen.getByLabelText("AI에게 건넬 질문 초안");
    fireEvent.click(screen.getByRole("button", { name: /공지 초안/ }));
    expect(input).not.toHaveValue("");
    fireEvent.click(screen.getByRole("button", { name: /비우기/ }));
    expect(input).toHaveValue("");
    expect(input).toHaveFocus();
    expect(window.localStorage.length).toBe(0);
  });

  it("shows copy failure accessibly and does not claim success", async () => {
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) } });
    render(<AIAssistantPage />);
    fireEvent.click(screen.getByRole("button", { name: /모임 준비/ }));
    fireEvent.click(screen.getByRole("button", { name: /질문 복사/ }));
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("복사하지 못했어요"));
    expect(screen.getByRole("button", { name: /질문 복사/ })).toBeInTheDocument();
  });

  it("makes the not-connected state clear and never renders a generated answer", () => {
    render(<AIAssistantPage />);
    expect(screen.getByRole("heading", { name: "공동체 AI 생각 도우미" })).toBeInTheDocument();
    expect(screen.getByText(/연결 준비 중/)).toBeInTheDocument();
    expect(screen.getByText(/아직 AI 답변은 없어요/)).toBeInTheDocument();
    expect(screen.queryByText(/답변:/)).not.toBeInTheDocument();
  });
});
