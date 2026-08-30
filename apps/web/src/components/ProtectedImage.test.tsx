import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ProtectedImage } from "./ProtectedImage";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => { resolve = next; });
  return { promise, resolve };
}

describe("ProtectedImage", () => {
  it("refreshes a lazy image whose initial signed URL expired", async () => {
    const refreshUrl = vi.fn().mockResolvedValue("https://signed.test/refreshed-image");
    const onError = vi.fn();
    const onLoad = vi.fn();
    render(
      <ProtectedImage
        src="https://signed.test/expired-image"
        storagePath="org/posts/post/photo.jpg"
        refreshUrl={refreshUrl}
        alt="게시글 사진"
        fallbackLabel="게시글 이미지를 불러오지 못했어요"
        loading="lazy"
        decoding="async"
        onError={onError}
        onLoad={onLoad}
      />,
    );

    fireEvent.error(screen.getByRole("img", { name: "게시글 사진" }));
    expect(screen.getByRole("status", { name: "이미지를 다시 불러오고 있습니다." })).toBeInTheDocument();
    await waitFor(() => expect(refreshUrl).toHaveBeenCalledWith("org/posts/post/photo.jpg"));
    const refreshed = await screen.findByRole("img", { name: "게시글 사진" });
    expect(refreshed).toHaveAttribute("src", "https://signed.test/refreshed-image");
    expect(refreshed).toHaveAttribute("loading", "lazy");
    expect(refreshed).toHaveAttribute("decoding", "async");
    fireEvent.load(refreshed);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onLoad).toHaveBeenCalledTimes(1);
  });

  it("caps consecutive automatic refreshes and offers a manual retry", async () => {
    const refreshUrl = vi.fn()
      .mockResolvedValueOnce("https://signed.test/retry-image-1")
      .mockResolvedValueOnce("https://signed.test/retry-image-2")
      .mockResolvedValueOnce("https://signed.test/manual-image");
    render(
      <ProtectedImage
        src="https://signed.test/corrupt-image"
        storagePath="org/messages/conversation/corrupt.jpg"
        refreshUrl={refreshUrl}
        alt="손상된 첨부 사진"
        fallbackLabel="첨부 이미지를 불러오지 못했어요"
      />,
    );

    fireEvent.error(screen.getByRole("img", { name: "손상된 첨부 사진" }));
    await waitFor(() => expect(screen.getByRole("img", { name: "손상된 첨부 사진" }))
      .toHaveAttribute("src", "https://signed.test/retry-image-1"));
    fireEvent.error(screen.getByRole("img", { name: "손상된 첨부 사진" }));
    await waitFor(() => expect(screen.getByRole("img", { name: "손상된 첨부 사진" }))
      .toHaveAttribute("src", "https://signed.test/retry-image-2"));
    fireEvent.error(screen.getByRole("img", { name: "손상된 첨부 사진" }));

    expect(refreshUrl).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("group", { name: "첨부 이미지를 불러오지 못했어요" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "다시 시도" }));
    await waitFor(() => expect(refreshUrl).toHaveBeenCalledTimes(3));
    await waitFor(() => expect(screen.getByRole("img", { name: "손상된 첨부 사진" }))
      .toHaveAttribute("src", "https://signed.test/manual-image"));
  });

  it("ignores a late refresh response after the source changes", async () => {
    const pending = deferred<string | undefined>();
    const refreshUrl = vi.fn().mockReturnValueOnce(pending.promise);
    const { rerender } = render(
      <ProtectedImage
        src="https://signed.test/old-image"
        storagePath="org/posts/old/photo.jpg"
        refreshUrl={refreshUrl}
        alt="변경되는 사진"
      />,
    );

    fireEvent.error(screen.getByRole("img", { name: "변경되는 사진" }));
    await waitFor(() => expect(refreshUrl).toHaveBeenCalledTimes(1));
    rerender(
      <ProtectedImage
        src="https://signed.test/new-image"
        storagePath="org/posts/new/photo.jpg"
        refreshUrl={refreshUrl}
        alt="변경되는 사진"
      />,
    );
    await waitFor(() => expect(screen.getByRole("img", { name: "변경되는 사진" }))
      .toHaveAttribute("src", "https://signed.test/new-image"));

    await act(async () => {
      pending.resolve("https://signed.test/stale-refresh");
      await pending.promise;
    });
    expect(screen.getByRole("img", { name: "변경되는 사진" }))
      .toHaveAttribute("src", "https://signed.test/new-image");
  });

  it("preserves the existing resilient fallback for local images", () => {
    const refreshUrl = vi.fn();
    render(
      <ProtectedImage
        src="blob:local-image"
        refreshUrl={refreshUrl}
        alt="로컬 사진"
        fallbackLabel="로컬 이미지를 불러오지 못했어요"
        loading="lazy"
      />,
    );

    fireEvent.error(screen.getByRole("img", { name: "로컬 사진" }));
    expect(refreshUrl).not.toHaveBeenCalled();
    expect(screen.getByRole("img", { name: "로컬 이미지를 불러오지 못했어요" })).toBeInTheDocument();
  });

  it("can omit the manual retry control when rendered inside a link", async () => {
    const refreshUrl = vi.fn()
      .mockResolvedValueOnce("https://signed.test/retry-image-1")
      .mockResolvedValueOnce("https://signed.test/retry-image-2");
    render(
      <ProtectedImage
        src="https://signed.test/expired-image"
        storagePath="org/posts/post/photo.jpg"
        refreshUrl={refreshUrl}
        alt="최근 게시글 사진"
        fallbackLabel="게시글 이미지 없음"
        manualRetry={false}
      />,
    );

    fireEvent.error(screen.getByRole("img", { name: "최근 게시글 사진" }));
    await waitFor(() => expect(screen.getByRole("img", { name: "최근 게시글 사진" }))
      .toHaveAttribute("src", "https://signed.test/retry-image-1"));
    fireEvent.error(screen.getByRole("img", { name: "최근 게시글 사진" }));
    await waitFor(() => expect(screen.getByRole("img", { name: "최근 게시글 사진" }))
      .toHaveAttribute("src", "https://signed.test/retry-image-2"));
    fireEvent.error(screen.getByRole("img", { name: "최근 게시글 사진" }));

    expect(screen.getByRole("img", { name: "게시글 이미지 없음" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "다시 시도" })).not.toBeInTheDocument();
  });
});
