import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { PostDetailPage } from "../pages/FeedPages";

const mocked = vi.hoisted(() => ({
  useAppData: vi.fn(),
}));

vi.mock("../data/AppDataProvider", () => ({
  useAppData: mocked.useAppData,
}));

function renderPostDetail() {
  return render(
    <MemoryRouter initialEntries={["/app/posts/older-post-id"]}>
      <Routes>
        <Route path="/app/posts/:postId" element={<PostDetailPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

describe("post detail deep-link recovery", () => {
  it("loads an absent post once before deciding it is actually not found", async () => {
    const ensurePost = vi.fn().mockResolvedValue("not_found");
    mocked.useAppData.mockReturnValue({
      posts: [],
      addComment: vi.fn(),
      ensurePost,
      viewer: { profile: { id: "viewer-a" } },
    });

    renderPostDetail();

    expect(screen.getByRole("status")).toHaveTextContent("게시글을 불러오고 있어요");
    expect(await screen.findByRole("heading", { name: "게시글을 찾을 수 없어요" })).toBeInTheDocument();
    expect(ensurePost).toHaveBeenCalledTimes(1);
    expect(ensurePost).toHaveBeenCalledWith("older-post-id");
  });

  it("hides raw lookup failures and retries only when the user asks", async () => {
    const ensurePost = vi
      .fn()
      .mockRejectedValueOnce(new Error("JWT secret and internal table details"))
      .mockResolvedValueOnce("not_found");
    mocked.useAppData.mockReturnValue({
      posts: [],
      addComment: vi.fn(),
      ensurePost,
      viewer: { profile: { id: "viewer-a" } },
    });

    renderPostDetail();

    expect(await screen.findByRole("heading", { name: "게시글을 불러오지 못했어요" })).toBeInTheDocument();
    expect(screen.queryByText(/JWT secret/)).not.toBeInTheDocument();
    expect(ensurePost).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole("button", { name: "다시 시도" }));
    expect(await screen.findByRole("heading", { name: "게시글을 찾을 수 없어요" })).toBeInTheDocument();
    expect(ensurePost).toHaveBeenCalledTimes(2);
  });

  it("ignores an older account lookup after the active account changes", async () => {
    let resolveFirst!: (result: "not_found") => void;
    let resolveSecond!: (result: "not_found") => void;
    const firstLookup = new Promise<"not_found">((resolve) => { resolveFirst = resolve; });
    const secondLookup = new Promise<"not_found">((resolve) => { resolveSecond = resolve; });
    const ensurePost = vi.fn()
      .mockReturnValueOnce(firstLookup)
      .mockReturnValueOnce(secondLookup);
    let viewerId = "viewer-a";
    mocked.useAppData.mockImplementation(() => ({
      posts: [],
      addComment: vi.fn(),
      ensurePost,
      viewer: { profile: { id: viewerId } },
    }));

    const view = renderPostDetail();
    await waitFor(() => expect(ensurePost).toHaveBeenCalledTimes(1));
    viewerId = "viewer-b";
    view.rerender(
      <MemoryRouter initialEntries={["/app/posts/older-post-id"]}>
        <Routes>
          <Route path="/app/posts/:postId" element={<PostDetailPage />} />
        </Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(ensurePost).toHaveBeenCalledTimes(2));

    await act(async () => resolveFirst("not_found"));
    expect(screen.getByRole("status")).toHaveTextContent("게시글을 불러오고 있어요");
    expect(screen.queryByRole("heading", { name: "게시글을 찾을 수 없어요" })).not.toBeInTheDocument();

    await act(async () => resolveSecond("not_found"));
    expect(await screen.findByRole("heading", { name: "게시글을 찾을 수 없어요" })).toBeInTheDocument();
  });
});
