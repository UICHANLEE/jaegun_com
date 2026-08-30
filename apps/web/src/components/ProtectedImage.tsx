import { ImageBroken } from "@phosphor-icons/react";
import {
  type ImgHTMLAttributes,
  type SyntheticEvent,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import type { ProtectedMediaUrlRefresher } from "./ProtectedVideo";
import { ResilientImage } from "./ui";

const MAX_AUTOMATIC_REFRESH_ATTEMPTS = 2;

export interface ProtectedImageProps extends Omit<ImgHTMLAttributes<HTMLImageElement>, "src" | "alt"> {
  src: string;
  storagePath?: string;
  refreshUrl?: ProtectedMediaUrlRefresher;
  alt: string;
  fallbackLabel?: string;
  manualRetry?: boolean;
}

export function ProtectedImage({
  src,
  storagePath,
  refreshUrl,
  alt,
  fallbackLabel = "이미지를 불러오지 못했어요",
  manualRetry = true,
  className,
  onError,
  onLoad,
  ...imageProps
}: ProtectedImageProps) {
  const [activeSrc, setActiveSrc] = useState(src);
  const [sourceRevision, setSourceRevision] = useState(0);
  const [status, setStatus] = useState<"ready" | "refreshing" | "failed">("ready");
  const sourceGenerationRef = useRef(0);
  const refreshRequestRef = useRef(0);
  const retryAttemptsRef = useRef(0);
  const refreshingRef = useRef(false);

  useEffect(() => {
    const generation = sourceGenerationRef.current + 1;
    sourceGenerationRef.current = generation;
    refreshRequestRef.current += 1;
    retryAttemptsRef.current = 0;
    refreshingRef.current = false;
    setActiveSrc(src);
    setSourceRevision(0);
    setStatus("ready");
    return () => {
      if (sourceGenerationRef.current === generation) sourceGenerationRef.current += 1;
    };
  }, [src, storagePath]);

  const refreshSource = useCallback(async (resetAttempts = false) => {
    if (!storagePath || !refreshUrl || refreshingRef.current) return;
    if (resetAttempts) retryAttemptsRef.current = 0;
    if (retryAttemptsRef.current >= MAX_AUTOMATIC_REFRESH_ATTEMPTS) {
      setStatus("failed");
      return;
    }

    retryAttemptsRef.current += 1;
    refreshingRef.current = true;
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
    setStatus("ready");
  }, [refreshUrl, storagePath]);

  const handleError = useCallback((event: SyntheticEvent<HTMLImageElement>) => {
    onError?.(event);
    if (retryAttemptsRef.current >= MAX_AUTOMATIC_REFRESH_ATTEMPTS) {
      setStatus("failed");
      return;
    }
    void refreshSource();
  }, [onError, refreshSource]);

  const handleLoad = useCallback((event: SyntheticEvent<HTMLImageElement>) => {
    retryAttemptsRef.current = 0;
    setStatus("ready");
    onLoad?.(event);
  }, [onLoad]);

  if (!storagePath || !refreshUrl) {
    return (
      <ResilientImage
        {...imageProps}
        className={className}
        src={src}
        alt={alt}
        fallbackLabel={fallbackLabel}
        onError={onError}
        onLoad={onLoad}
      />
    );
  }

  if (status !== "ready") {
    const message = status === "refreshing" ? "이미지를 다시 불러오고 있습니다." : fallbackLabel;
    return (
      <span
        className={["media-fallback", className].filter(Boolean).join(" ")}
        role={status === "refreshing" ? "status" : manualRetry ? "group" : "img"}
        aria-label={message}
        aria-live="polite"
      >
        <ImageBroken weight="duotone" aria-hidden="true" />
        <span aria-hidden="true">{message}</span>
        {status === "failed" && manualRetry ? (
          <button
            className="button button--secondary"
            type="button"
            onClick={() => void refreshSource(true)}
          >
            다시 시도
          </button>
        ) : null}
      </span>
    );
  }

  return (
    <img
      {...imageProps}
      key={`${storagePath}:${sourceRevision}`}
      className={className}
      src={activeSrc}
      alt={alt}
      onError={handleError}
      onLoad={handleLoad}
    />
  );
}
