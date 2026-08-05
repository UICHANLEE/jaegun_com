import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import App from "../App";
import { PostCard } from "../components/PostCard";
import { Avatar } from "../components/ui";
import { AppDataProvider } from "../data/AppDataProvider";
import { createDemoState, DEMO_VIEWER } from "../data/seed";
import type { Post } from "../types/domain";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";
const MEDIA_ACCEPT = "image/jpeg,image/png,image/webp,image/avif,image/heic,image/heif,video/mp4,video/quicktime,video/webm";

function storeMemberState(transform?: (state: ReturnType<typeof createDemoState>) => ReturnType<typeof createDemoState>) {
  const base = createDemoState();
  const state = transform?.(base) ?? base;
  window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
    ...state,
    viewer: {
      profile: { ...DEMO_VIEWER, globalRole: "user" },
      membership: {
        id: "resilience-member-membership",
        organizationId: "org-19",
        userId: DEMO_VIEWER.id,
        role: "member",
        churchTitleCode: "deacon",
        executiveOfficeCodes: [],
        status: "active",
      },
    },
  }));
}

function renderApp(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppDataProvider>
        <App />
      </AppDataProvider>
    </MemoryRouter>,
  );
}

describe("media and interaction resilience", () => {
  it("replaces a broken avatar source with the icon-library fallback", () => {
    const { container } = render(<Avatar name="긴이름사용자" src="/missing-avatar.jpg" />);
    fireEvent.error(container.querySelector("img")!);
    expect(container.querySelector(".avatar__fallback")).toBeInTheDocument();
    expect(container.querySelector("img")).not.toBeInTheDocument();
  });

  it("replaces broken post media with a labelled fallback without changing the media count", () => {
    const post: Post = {
      id: "broken-media-post",
      authorId: "author",
      authorName: "작성자",
      category: "photo_video",
      title: "사진 게시글",
      body: "본문",
      createdAt: "2026-08-05T00:00:00.000Z",
      media: [
        { id: "image-1", kind: "image", url: "/missing-post.jpg", alt: "게시글 사진" },
        { id: "image-2", kind: "image", url: "/another.jpg", alt: "두 번째 사진" },
      ],
      comments: [],
      reactionCount: 0,
    };

    render(<MemoryRouter><PostCard post={post} /></MemoryRouter>);
    fireEvent.error(screen.getByRole("img", { name: "게시글 사진" }));

    expect(screen.getByRole("img", { name: "게시글 이미지를 불러오지 못했어요" })).toBeInTheDocument();
    expect(screen.getByText("+1")).toHaveClass("post-card__media-count");
  });

  it("keeps a video card preview non-interactive inside the card link", () => {
    const post: Post = {
      id: "video-preview-post",
      authorId: "author",
      authorName: "작성자",
      category: "photo_video",
      title: "영상 게시글",
      body: "본문",
      createdAt: "2026-08-05T00:00:00.000Z",
      media: [{ id: "video-1", kind: "video", url: "/preview.mp4" }],
      comments: [],
      reactionCount: 0,
    };

    const { container } = render(<MemoryRouter><PostCard post={post} /></MemoryRouter>);
    const preview = container.querySelector("video")!;
    expect(preview).not.toHaveAttribute("controls");
    expect(preview).toHaveProperty("muted", true);
    expect(preview).toHaveAttribute("playsinline");
  });

  it("shows a failed message state, keeps retry content, and exposes only accepted media types", async () => {
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: vi.fn(),
    });
    storeMemberState((state) => ({
      ...state,
      messagesByConversation: {
        ...state.messagesByConversation,
        "conversation-1": [
          ...(state.messagesByConversation["conversation-1"] ?? []),
          {
            id: "failed-message",
            conversationId: "conversation-1",
            senderId: DEMO_VIEWER.id,
            body: "전송에 실패한 본문",
            createdAt: "2026-08-05T01:00:00.000Z",
            status: "failed",
            media: [{ id: "failed-image", kind: "image", url: "/missing-chat.jpg", name: "첨부 사진" }],
          },
        ],
      },
    }));
    renderApp("/app/chats/conversation-1");

    expect(await screen.findByRole("status")).toHaveTextContent("전송 실패, 입력창에서 다시 시도");
    fireEvent.error(screen.getByRole("img", { name: "첨부 사진" }));
    expect(screen.getByRole("img", { name: "첨부 이미지를 불러오지 못했어요" })).toBeInTheDocument();

    const fileInput = screen.getByLabelText("사진 또는 영상 첨부");
    expect(fileInput).toHaveAttribute("accept", MEDIA_ACCEPT);
    const composer = screen.getByPlaceholderText("메시지를 입력하세요");
    fireEvent.change(composer, { target: { value: "입력창에 남아야 하는 재시도 본문" } });
    const invalidFile = new File(["gif"], "지원하지않는파일.gif", { type: "image/gif" });
    fireEvent.change(fileInput, { target: { files: [invalidFile] } });
    fireEvent.click(screen.getByRole("button", { name: "메시지 보내기" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("JPG, PNG, WebP, AVIF, HEIC");
    expect(composer).toHaveValue("입력창에 남아야 하는 재시도 본문");
    expect(screen.getByText("지원하지않는파일.gif")).toBeInTheDocument();
  });

  it("renders the reaction count as read-only information", async () => {
    storeMemberState();
    renderApp("/app/posts/post-retreat");

    expect(await screen.findByLabelText(/공감 \d+개/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /공감/ })).not.toBeInTheDocument();
  });

  it("uses the same exact media contract in the post composer", async () => {
    storeMemberState();
    renderApp("/app/posts/new");

    const upload = await screen.findByLabelText("파일 선택");
    expect(upload).toHaveAttribute("accept", MEDIA_ACCEPT);
  });
});
