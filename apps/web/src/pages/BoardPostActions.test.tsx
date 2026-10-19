import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Post } from "../types/domain";

const adapter = vi.hoisted(() => ({
  setPostReaction: vi.fn(async () => undefined), updatePost: vi.fn(async () => undefined),
  deletePost: vi.fn(async () => undefined), blockPostAuthor: vi.fn(async () => undefined),
  upload: vi.fn(async () => ({ path: "org/posts/post/upload.jpg", kind: "image", mimeType: "image/jpeg", byteSize: 4 })),
}));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({
  viewer: { profile: { id: "viewer" }, membership: { organizationId: "org" } }, mode: "supabase",
  setPostReaction: adapter.setPostReaction, updatePost: adapter.updatePost,
  deletePost: adapter.deletePost, blockPostAuthor: adapter.blockPostAuthor,
}) }));
vi.mock("../data/mediaUpload", () => ({ uploadCommunityFile: adapter.upload }));
vi.mock("../data/supabase", () => ({ supabase: { rpc: vi.fn(async () => ({ data: { cleanup_queued: true }, error: null })) } }));
import { BoardPostActions } from "./BoardPostActions";

const post: Post = { id: "post", organizationId: "org", authorId: "author", authorName: "회원", category: "prayer", title: "기도", body: "함께 기도해 주세요", createdAt: "2026-10-15T00:00:00Z", media: [], comments: [], reactionCount: 0, revision: 7 };
function show(value: Post) { return render(<MemoryRouter><BoardPostActions post={value} /></MemoryRouter>); }

describe("server-authoritative community board actions", () => {
  beforeEach(() => { vi.clearAllMocks(); });
  it("sends desired unique prayer state rather than a client counter", async () => {
    show({ ...post, prayerCount: 12 });
    fireEvent.click(screen.getByRole("button", { name: "함께 기도 12" }));
    await waitFor(() => expect(adapter.setPostReaction).toHaveBeenCalledWith("post", "prayer", true));
    expect(adapter.setPostReaction.mock.calls[0]).toHaveLength(3);
  });
  it("removes the actor's existing amen without decrementing an arbitrary counter", async () => {
    show({ ...post, reactedAmen: true, amenCount: 8 });
    fireEvent.click(screen.getByRole("button", { name: "아멘 8" }));
    await waitFor(() => expect(adapter.setPostReaction).toHaveBeenCalledWith("post", "amen", false));
  });
  it("acknowledges official documents explicitly and never offers undo", async () => {
    const view = show({ ...post, category: "official_document", receiptCount: 3 });
    fireEvent.click(screen.getByRole("button", { name: "공문 수신 확인 · 3명" }));
    await waitFor(() => expect(adapter.setPostReaction).toHaveBeenCalledWith("post", "receipt", true));
    view.rerender(<MemoryRouter><BoardPostActions post={{ ...post, category: "official_document", receiptCount: 4, acknowledged: true }} /></MemoryRouter>);
    expect(screen.getByRole("button", { name: "수신 확인 완료 · 4명" })).toBeDisabled();
  });
  it("uses an anonymous owner capability and preserves edit revision and media removal IDs", async () => {
    show({ ...post, category: "anonymous_qa", authorId: "", authorName: "익명", isOwner: true, media: [{ id: "media", kind: "image", url: "https://example.test/signed", alt: "사진" }] });
    fireEvent.click(screen.getByRole("button", { name: "수정" }));
    fireEvent.change(screen.getByLabelText("제목"), { target: { value: "수정 질문" } });
    fireEvent.click(screen.getByRole("checkbox", { name: "사진 삭제" }));
    fireEvent.click(screen.getByRole("button", { name: "수정 저장" }));
    await waitFor(() => expect(adapter.updatePost).toHaveBeenCalledWith("post", 7, "수정 질문", "함께 기도해 주세요", ["media"], []));
  });
  it("adds uploaded bytes through the atomic edit contract", async () => {
    show({ ...post, isOwner: true });
    fireEvent.click(screen.getByRole("button", { name: "수정" }));
    const file = new File(["jpeg"], "photo.jpg", { type: "image/jpeg" });
    fireEvent.change(screen.getByLabelText("사진·영상 추가"), { target: { files: [file] } });
    fireEvent.click(screen.getByRole("button", { name: "수정 저장" }));
    await waitFor(() => expect(adapter.updatePost).toHaveBeenCalledWith("post", 7, "기도", "함께 기도해 주세요", [], [{ storage_path: "org/posts/post/upload.jpg", kind: "image", mime_type: "image/jpeg", byte_size: 4, file_name: "photo.jpg" }]));
    expect(adapter.upload).toHaveBeenCalledWith(file, expect.objectContaining({ purpose: "post", targetId: "post", organizationId: "org" }), expect.any(Function));
  });
});
