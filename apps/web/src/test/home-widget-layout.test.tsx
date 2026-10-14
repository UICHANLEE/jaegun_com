import { useState } from "react";
import { act, fireEvent, render, renderHook, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { HomeWidgetEditor } from "../components/home/HomeWidgetEditor";
import { HOME_WIDGET_IDS } from "../components/home/homeWidgetTypes";
import { useHomeWidgetLayout } from "../components/home/useHomeWidgetLayout";

const LIVE_SCOPE = "live:church/a:actor/a";
const LIVE_KEY = "jaegun-home-widgets-v1:live%3Achurch%2Fa%3Aactor%2Fa";
const DEMO_SCOPE = "demo:church/a:actor/a";
const DEMO_KEY = "jaegun-home-widgets-v1:demo%3Achurch%2Fa%3Aactor%2Fa";

afterEach(() => {
  vi.restoreAllMocks();
});

function EditorHarness() {
  const { layout, saveLayout } = useHomeWidgetLayout(LIVE_SCOPE);
  const [draft, setDraft] = useState(layout);
  return (
    <HomeWidgetEditor
      layout={draft}
      onChange={setDraft}
      onSave={() => { saveLayout(draft); }}
      onCancel={() => setDraft(layout)}
      onReset={() => setDraft([...HOME_WIDGET_IDS])}
    />
  );
}

describe("home widget preferences", () => {
  it.each([
    ["malformed JSON", "{"],
    ["unknown version", JSON.stringify({ version: 9, layout: ["notice"] })],
    ["non-numeric version", JSON.stringify({ version: "1", layout: ["notice"] })],
    ["duplicate widgets", JSON.stringify({ version: 1, layout: ["feed", "feed"] })],
    ["unknown widgets", JSON.stringify({ version: 1, layout: ["notice", "management"] })],
    ["empty layout", JSON.stringify({ version: 1, layout: [] })],
    ["oversized layout", JSON.stringify({ version: 1, layout: ["notice", "feed", "groups", "schedule", "notice"] })],
    ["missing layout", JSON.stringify({ version: 1 })],
    ["unknown fields", JSON.stringify({ version: 1, layout: ["notice"], content: "not a preference" })],
  ])("uses defaults for %s without rewriting storage", (_description, raw) => {
    window.localStorage.setItem(LIVE_KEY, raw);
    const setItem = vi.spyOn(window.localStorage, "setItem");
    const { result } = renderHook(() => useHomeWidgetLayout(LIVE_SCOPE));

    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    expect(window.localStorage.getItem(LIVE_KEY)).toBe(raw);
    expect(setItem).not.toHaveBeenCalled();
  });

  it("isolates live, demo, account, and church layouts immediately on scope changes", () => {
    const otherActorScope = "live:church/a:actor/b";
    const otherChurchScope = "live:church/b:actor/a";
    window.localStorage.setItem(LIVE_KEY, JSON.stringify({ version: 1, layout: ["notice", "feed"] }));
    window.localStorage.setItem(DEMO_KEY, JSON.stringify({ version: 1, layout: ["schedule", "groups"] }));
    const { result, rerender } = renderHook(({ scope }: { scope: string | null }) => useHomeWidgetLayout(scope), {
      initialProps: { scope: LIVE_SCOPE as string | null },
    });
    const saveLiveLayout = result.current.saveLayout;

    rerender({ scope: DEMO_SCOPE });
    expect(result.current.layout).toEqual(["schedule", "groups"]);
    act(() => {
      expect(saveLiveLayout(["feed", "notice"])).toBe(true);
    });
    expect(result.current.layout).toEqual(["schedule", "groups"]);
    expect(JSON.parse(window.localStorage.getItem(DEMO_KEY)!)).toEqual({ version: 1, layout: ["schedule", "groups"] });

    rerender({ scope: otherActorScope });
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    rerender({ scope: otherChurchScope });
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    rerender({ scope: LIVE_SCOPE });
    expect(result.current.layout).toEqual(["feed", "notice"]);
    rerender({ scope: null });
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    act(() => {
      expect(result.current.saveLayout(["schedule"])).toBe(false);
    });
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    expect(window.localStorage.length).toBe(2);
  });

  it("keeps a failed save in memory only for its scope and reports it as unpersisted", () => {
    const setItem = vi.spyOn(window.localStorage, "setItem").mockImplementation(() => {
      throw new DOMException("Storage is full", "QuotaExceededError");
    });
    const { result, rerender } = renderHook(({ scope }) => useHomeWidgetLayout(scope), {
      initialProps: { scope: LIVE_SCOPE },
    });

    act(() => {
      expect(result.current.saveLayout(["groups", "feed"])).toBe(false);
    });
    expect(result.current.layout).toEqual(["groups", "feed"]);
    expect(window.localStorage.getItem(LIVE_KEY)).toBeNull();
    rerender({ scope: DEMO_SCOPE });
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    rerender({ scope: LIVE_SCOPE });
    expect(result.current.layout).toEqual(["groups", "feed"]);
    expect(setItem).toHaveBeenCalledTimes(1);
  });

  it("loads defaults when storage cannot be read", () => {
    vi.spyOn(window.localStorage, "getItem").mockImplementation(() => {
      throw new DOMException("Storage is blocked", "SecurityError");
    });
    const { result } = renderHook(() => useHomeWidgetLayout(LIVE_SCOPE));
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
  });

  it("rejects invalid saves without changing the current layout or storage", () => {
    const setItem = vi.spyOn(window.localStorage, "setItem");
    const { result } = renderHook(() => useHomeWidgetLayout(LIVE_SCOPE));
    act(() => {
      expect(result.current.saveLayout([])).toBe(false);
      expect(result.current.saveLayout(["feed", "feed"])).toBe(false);
    });
    expect(result.current.layout).toEqual(HOME_WIDGET_IDS);
    expect(setItem).not.toHaveBeenCalled();
  });
});

describe("home widget editor", () => {
  it("prevents hiding the final visible widget, including after adding and hiding another", () => {
    window.localStorage.setItem(LIVE_KEY, JSON.stringify({ version: 1, layout: ["feed"] }));
    render(<EditorHarness />);
    const visibleList = screen.getByRole("list", { name: "표시 항목" });

    expect(screen.getByRole("button", { name: "게시글 피드 숨기기" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "게시글 피드 숨기기" }));
    expect(within(visibleList).getAllByRole("listitem")).toHaveLength(1);
    fireEvent.click(screen.getByRole("button", { name: "교회 공지 추가" }));
    expect(screen.getByRole("button", { name: "게시글 피드 숨기기" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "게시글 피드 숨기기" }));
    expect(within(visibleList).getAllByRole("listitem")).toHaveLength(1);
    expect(screen.getByRole("button", { name: "교회 공지 숨기기" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "교회 공지 위로 이동" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "교회 공지 아래로 이동" })).toBeDisabled();
  });

  it("previews order and visibility without persistence until explicit save, and cancel restores the saved layout", () => {
    const original = JSON.stringify({ version: 1, layout: ["notice", "feed"] });
    window.localStorage.setItem(LIVE_KEY, original);
    const setItem = vi.spyOn(window.localStorage, "setItem");
    render(<EditorHarness />);
    const visibleList = screen.getByRole("list", { name: "표시 항목" });

    fireEvent.click(screen.getByRole("button", { name: "게시글 피드 위로 이동" }));
    expect(within(visibleList).getAllByRole("listitem")[0]).toHaveTextContent("게시글 피드");
    fireEvent.click(screen.getByRole("button", { name: "교회 공지 숨기기" }));
    expect(within(visibleList).getAllByRole("listitem")).toHaveLength(1);
    expect(window.localStorage.getItem(LIVE_KEY)).toBe(original);
    expect(setItem).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "취소" }));
    expect(within(visibleList).getAllByRole("listitem")).toHaveLength(2);
    expect(within(visibleList).getAllByRole("listitem")[0]).toHaveTextContent("교회 공지");
    expect(setItem).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "기본 구성" }));
    expect(within(visibleList).getAllByRole("listitem")).toHaveLength(5);
    expect(setItem).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "저장" }));
    expect(JSON.parse(window.localStorage.getItem(LIVE_KEY)!)).toEqual({ version: 2, layout: HOME_WIDGET_IDS });
    expect(setItem).toHaveBeenCalledTimes(1);
  });
});
