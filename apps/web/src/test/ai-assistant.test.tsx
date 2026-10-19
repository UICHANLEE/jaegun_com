import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AIAssistantPage } from "../pages/AIAssistantPage";
import { MinutesAIDraft } from "../pages/ScopedRecordsMinutesAI";
import { fetchAITransferNotice, generateAIDraft } from "../data/aiAssistant";
vi.mock("../data/aiAssistant", () => ({ fetchAITransferNotice: vi.fn(), generateAIDraft: vi.fn() }));
describe("reserved Bible tools landing", () => {
  beforeEach(() => vi.clearAllMocks());
  it("keeps both requested destinations visible without fake links or prompt inputs", () => {
    render(<AIAssistantPage />);
    expect(screen.getByRole("heading", { name: "성경 도구" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "성경 지도 보기" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "본문에 나온 이름 분석" })).toBeVisible();
    expect(screen.getAllByText("링크 연결 예정")).toHaveLength(2);
    expect(screen.queryByRole("link")).not.toBeInTheDocument();
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    expect(fetchAITransferNotice).not.toHaveBeenCalled();
    expect(generateAIDraft).not.toHaveBeenCalled();
  });
  it("removes minutes generation and never populates a draft or starts provider requests", () => {
    const reviewed = vi.fn();
    const { container } = render(<MinutesAIDraft onReviewed={reviewed} />);
    expect(container).toBeEmptyDOMElement();
    expect(reviewed).not.toHaveBeenCalled();
    expect(fetchAITransferNotice).not.toHaveBeenCalled();
    expect(generateAIDraft).not.toHaveBeenCalled();
  });
});
