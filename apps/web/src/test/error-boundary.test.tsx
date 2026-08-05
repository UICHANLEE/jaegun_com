import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { AppErrorBoundary } from "../components/ui";

function BrokenScreen(): never {
  throw new Error("render failed");
}

describe("application error boundary", () => {
  it("keeps a render failure recoverable instead of showing a blank screen", () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);

    render(
      <AppErrorBoundary>
        <BrokenScreen />
      </AppErrorBoundary>,
    );

    expect(screen.getByRole("alert")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "화면을 불러오지 못했어요" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /새로고침/ })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /홈으로 이동/ })).toHaveAttribute("href", "/");

    consoleError.mockRestore();
  });
});
