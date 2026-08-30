import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ProtectedVideo } from "./ProtectedVideo";

function setPlaybackState(video: HTMLVideoElement, values: {
  currentTime?: number;
  duration?: number;
  paused?: boolean;
  playbackRate?: number;
  volume?: number;
  muted?: boolean;
  play?: () => Promise<void>;
}) {
  for (const [key, value] of Object.entries(values)) {
    Object.defineProperty(video, key, {
      configurable: true,
      writable: key !== "paused",
      value,
    });
  }
}

describe("ProtectedVideo", () => {
  it("keeps local and demo sources on native video behavior", () => {
    const refreshUrl = vi.fn();
    render(
      <ProtectedVideo
        src="blob:local-preview"
        refreshUrl={refreshUrl}
        controls
        preload="metadata"
        aria-label="로컬 영상"
      />,
    );

    const video = screen.getByLabelText("로컬 영상");
    fireEvent.error(video);

    expect(refreshUrl).not.toHaveBeenCalled();
    expect(video).toHaveAttribute("src", "blob:local-preview");
    expect(video).toHaveAttribute("controls");
    expect(video).toHaveAttribute("preload", "metadata");
    expect(screen.queryByRole("button", { name: "다시 시도" })).not.toBeInTheDocument();
  });

  it("refreshes an expired source and restores playback after metadata loads", async () => {
    const refreshUrl = vi.fn().mockResolvedValue("https://signed.test/refreshed");
    const onError = vi.fn();
    const onLoadedMetadata = vi.fn();
    render(
      <ProtectedVideo
        src="https://signed.test/expired"
        storagePath="org/messages/conversation/video.mp4"
        refreshUrl={refreshUrl}
        controls
        aria-label="보호 영상"
        onError={onError}
        onLoadedMetadata={onLoadedMetadata}
      />,
    );

    const expiredVideo = screen.getByLabelText("보호 영상") as HTMLVideoElement;
    setPlaybackState(expiredVideo, {
      currentTime: 42,
      paused: false,
      playbackRate: 1.5,
      volume: 0.4,
      muted: true,
    });
    fireEvent.error(expiredVideo);

    await waitFor(() => expect(refreshUrl).toHaveBeenCalledWith("org/messages/conversation/video.mp4"));
    await waitFor(() => expect(screen.getByLabelText("보호 영상"))
      .toHaveAttribute("src", "https://signed.test/refreshed"));
    const refreshedVideo = screen.getByLabelText("보호 영상") as HTMLVideoElement;
    const play = vi.fn().mockResolvedValue(undefined);
    setPlaybackState(refreshedVideo, {
      currentTime: 0,
      duration: 120,
      paused: true,
      playbackRate: 1,
      volume: 1,
      muted: false,
      play,
    });
    fireEvent.loadedMetadata(refreshedVideo);

    expect(refreshedVideo.currentTime).toBe(42);
    expect(refreshedVideo.playbackRate).toBe(1.5);
    expect(refreshedVideo.volume).toBe(0.4);
    expect(refreshedVideo.muted).toBe(true);
    expect(play).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onLoadedMetadata).toHaveBeenCalledTimes(1);
  });

  it("caps consecutive automatic refreshes and exposes an accessible manual retry", async () => {
    const refreshUrl = vi.fn()
      .mockResolvedValueOnce("https://signed.test/retry-1")
      .mockResolvedValueOnce("https://signed.test/retry-2")
      .mockResolvedValueOnce("https://signed.test/manual");
    render(
      <ProtectedVideo
        src="https://signed.test/corrupt"
        storagePath="org/posts/post/corrupt.mp4"
        refreshUrl={refreshUrl}
        controls
        aria-label="손상 영상"
      />,
    );

    fireEvent.error(screen.getByLabelText("손상 영상"));
    await waitFor(() => expect(screen.getByLabelText("손상 영상"))
      .toHaveAttribute("src", "https://signed.test/retry-1"));
    fireEvent.error(screen.getByLabelText("손상 영상"));
    await waitFor(() => expect(screen.getByLabelText("손상 영상"))
      .toHaveAttribute("src", "https://signed.test/retry-2"));
    fireEvent.error(screen.getByLabelText("손상 영상"));

    expect(refreshUrl).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("alert")).toHaveTextContent("영상을 불러오지 못했습니다.");
    const retryButton = screen.getByRole("button", { name: "다시 시도" });
    fireEvent.click(retryButton);
    await waitFor(() => expect(refreshUrl).toHaveBeenCalledTimes(3));
    await waitFor(() => expect(screen.getByLabelText("손상 영상"))
      .toHaveAttribute("src", "https://signed.test/manual"));
  });

  it("resets the automatic retry budget after canplay succeeds", async () => {
    const refreshUrl = vi.fn()
      .mockResolvedValueOnce("https://signed.test/recovered")
      .mockResolvedValueOnce("https://signed.test/later-1")
      .mockResolvedValueOnce("https://signed.test/later-2");
    render(
      <ProtectedVideo
        src="https://signed.test/initial"
        storagePath="org/posts/post/long.mp4"
        refreshUrl={refreshUrl}
        aria-label="장시간 영상"
      />,
    );

    fireEvent.error(screen.getByLabelText("장시간 영상"));
    await waitFor(() => expect(screen.getByLabelText("장시간 영상"))
      .toHaveAttribute("src", "https://signed.test/recovered"));
    fireEvent.canPlay(screen.getByLabelText("장시간 영상"));

    fireEvent.error(screen.getByLabelText("장시간 영상"));
    await waitFor(() => expect(screen.getByLabelText("장시간 영상"))
      .toHaveAttribute("src", "https://signed.test/later-1"));
    fireEvent.error(screen.getByLabelText("장시간 영상"));
    await waitFor(() => expect(screen.getByLabelText("장시간 영상"))
      .toHaveAttribute("src", "https://signed.test/later-2"));

    expect(refreshUrl).toHaveBeenCalledTimes(3);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});
