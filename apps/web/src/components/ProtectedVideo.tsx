import { WarningCircle } from "@phosphor-icons/react";
import {
  type SyntheticEvent,
  type VideoHTMLAttributes,
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
} from "react";

const MAX_AUTOMATIC_REFRESH_ATTEMPTS = 2;

interface PlaybackSnapshot {
  currentTime: number;
  paused: boolean;
  playbackRate: number;
  volume: number;
  muted: boolean;
}

export type ProtectedMediaUrlRefresher = (storagePath: string) => Promise<string | undefined>;

export interface ProtectedVideoProps extends Omit<VideoHTMLAttributes<HTMLVideoElement>, "src"> {
  src: string;
  storagePath?: string;
  refreshUrl?: ProtectedMediaUrlRefresher;
}

function capturePlayback(video: HTMLVideoElement): PlaybackSnapshot {
  return {
    currentTime: Number.isFinite(video.currentTime) ? Math.max(video.currentTime, 0) : 0,
    paused: video.paused,
    playbackRate: video.playbackRate,
    volume: video.volume,
    muted: video.muted,
  };
}

function restorePlayback(video: HTMLVideoElement, snapshot: PlaybackSnapshot) {
  video.playbackRate = snapshot.playbackRate;
  video.volume = snapshot.volume;
  video.muted = snapshot.muted;
  const duration = video.duration;
  const restoredTime = Number.isFinite(duration) && duration > 0
    ? Math.min(snapshot.currentTime, Math.max(duration - 0.01, 0))
    : snapshot.currentTime;
  try {
    video.currentTime = restoredTime;
  } catch {
    // Some engines reject a seek until enough metadata is available.
  }
  if (!snapshot.paused) {
    try {
      void video.play()?.catch(() => undefined);
    } catch {
      // Browser autoplay policy can still require an explicit user gesture.
    }
  }
}

export function ProtectedVideo({
  src,
  storagePath,
  refreshUrl,
  onError,
  onLoadedMetadata,
  onCanPlay,
  ...videoProps
}: ProtectedVideoProps) {
  const [activeSrc, setActiveSrc] = useState(src);
  const [sourceRevision, setSourceRevision] = useState(0);
  const [status, setStatus] = useState<"ready" | "refreshing" | "failed">("ready");
  const videoRef = useRef<HTMLVideoElement>(null);
  const sourceGenerationRef = useRef(0);
  const refreshRequestRef = useRef(0);
  const retryAttemptsRef = useRef(0);
  const refreshingRef = useRef(false);
  const restoreSnapshotRef = useRef<PlaybackSnapshot | null>(null);
  const feedbackId = useId();

  useEffect(() => {
    const generation = sourceGenerationRef.current + 1;
    sourceGenerationRef.current = generation;
    refreshRequestRef.current += 1;
    retryAttemptsRef.current = 0;
    refreshingRef.current = false;
    restoreSnapshotRef.current = null;
    setActiveSrc(src);
    setSourceRevision(0);
    setStatus("ready");
    return () => {
      if (sourceGenerationRef.current === generation) sourceGenerationRef.current += 1;
    };
  }, [src, storagePath]);

  const refreshSource = useCallback(async (snapshot: PlaybackSnapshot, resetAttempts = false) => {
    if (!storagePath || !refreshUrl || refreshingRef.current) return;
    if (resetAttempts) retryAttemptsRef.current = 0;
    if (retryAttemptsRef.current >= MAX_AUTOMATIC_REFRESH_ATTEMPTS) {
      setStatus("failed");
      return;
    }

    retryAttemptsRef.current += 1;
    refreshingRef.current = true;
    restoreSnapshotRef.current = snapshot;
    setStatus("refreshing");
    const sourceGeneration = sourceGenerationRef.current;
    const requestId = refreshRequestRef.current + 1;
    refreshRequestRef.current = requestId;
    let refreshedUrl: string | undefined;
    try {
      refreshedUrl = await refreshUrl(storagePath);
    } catch {
      refreshedUrl = undefined;
    }
    if (sourceGenerationRef.current !== sourceGeneration || refreshRequestRef.current !== requestId) return;
    refreshingRef.current = false;
    if (!refreshedUrl) {
      setStatus("failed");
      return;
    }
    setActiveSrc(refreshedUrl);
    setSourceRevision((current) => current + 1);
  }, [refreshUrl, storagePath]);

  const handleError = useCallback((event: SyntheticEvent<HTMLVideoElement>) => {
    onError?.(event);
    if (!storagePath || !refreshUrl) return;
    const snapshot = capturePlayback(event.currentTarget);
    restoreSnapshotRef.current = snapshot;
    if (retryAttemptsRef.current >= MAX_AUTOMATIC_REFRESH_ATTEMPTS) {
      setStatus("failed");
      return;
    }
    void refreshSource(snapshot);
  }, [onError, refreshSource, refreshUrl, storagePath]);

  const handleLoadedMetadata = useCallback((event: SyntheticEvent<HTMLVideoElement>) => {
    const snapshot = restoreSnapshotRef.current;
    if (snapshot) restorePlayback(event.currentTarget, snapshot);
    onLoadedMetadata?.(event);
  }, [onLoadedMetadata]);

  const handleCanPlay = useCallback((event: SyntheticEvent<HTMLVideoElement>) => {
    retryAttemptsRef.current = 0;
    restoreSnapshotRef.current = null;
    setStatus("ready");
    onCanPlay?.(event);
  }, [onCanPlay]);

  const handleManualRetry = useCallback(() => {
    if (!videoRef.current) return;
    void refreshSource(restoreSnapshotRef.current ?? capturePlayback(videoRef.current), true);
  }, [refreshSource]);

  const feedbackVisible = Boolean(storagePath && refreshUrl && status !== "ready");
  const describedBy = [videoProps["aria-describedby"], feedbackVisible ? feedbackId : undefined]
    .filter(Boolean)
    .join(" ") || undefined;
  const video = (
    <video
      {...videoProps}
      key={`${storagePath ?? src}:${sourceRevision}`}
      ref={videoRef}
      src={activeSrc}
      aria-describedby={describedBy}
      onError={handleError}
      onLoadedMetadata={handleLoadedMetadata}
      onCanPlay={handleCanPlay}
    />
  );

  if (!storagePath || !refreshUrl) return video;
  return (
    <div className="protected-video">
      {video}
      {status === "refreshing" ? (
        <span id={feedbackId} className="sr-only" role="status" aria-live="polite">
          영상 연결을 복구하고 있습니다.
        </span>
      ) : status === "failed" ? (
        <div id={feedbackId} className="error-banner" role="alert">
          <WarningCircle weight="fill" aria-hidden="true" />
          <span>영상을 불러오지 못했습니다.</span>
          <button className="button button--secondary" type="button" onClick={handleManualRetry}>
            다시 시도
          </button>
        </div>
      ) : null}
    </div>
  );
}
