import { useCallback, useEffect, useRef } from "react";

export const UNSAVED_CHANGES_MESSAGE = "작성 중인 내용이 저장되지 않았습니다. 이동하면 입력한 내용이 사라집니다. 계속할까요?";

export function confirmDiscardChanges(isDirty: boolean) {
  return !isDirty || window.confirm(UNSAVED_CHANGES_MESSAGE);
}

export function useUnsavedChangesWarning(isDirty: boolean) {
  const approvedHistoryNavigationRef = useRef(false);
  const approvalResetTimerRef = useRef<number | null>(null);

  const confirmHistoryNavigation = useCallback(() => {
    if (!isDirty) return true;
    if (!window.confirm(UNSAVED_CHANGES_MESSAGE)) return false;

    approvedHistoryNavigationRef.current = true;
    if (approvalResetTimerRef.current !== null) window.clearTimeout(approvalResetTimerRef.current);
    approvalResetTimerRef.current = window.setTimeout(() => {
      approvedHistoryNavigationRef.current = false;
      approvalResetTimerRef.current = null;
    }, 2_000);
    return true;
  }, [isDirty]);

  useEffect(() => {
    if (!isDirty) return undefined;
    const initialIndex = window.history.state?.idx;
    let currentHistoryIndex = typeof initialIndex === "number" ? initialIndex : null;
    let restoringCancelledTraversal = false;
    let indexUpdateTimer: number | null = null;

    function handleBeforeUnload(event: BeforeUnloadEvent) {
      event.preventDefault();
      event.returnValue = "";
    }

    function handleDocumentClick(event: MouseEvent) {
      if (
        event.defaultPrevented
        || event.button !== 0
        || event.metaKey
        || event.ctrlKey
        || event.shiftKey
        || event.altKey
        || !(event.target instanceof Element)
      ) return;

      const anchor = event.target.closest<HTMLAnchorElement>("a[href]");
      if (!anchor || anchor.hasAttribute("download")) return;
      const target = anchor.getAttribute("target");
      if (target && target.toLowerCase() !== "_self") return;

      let destination: URL;
      try {
        destination = new URL(anchor.href, window.location.href);
      } catch {
        return;
      }
      if (destination.origin !== window.location.origin) return;
      const currentRoute = `${window.location.pathname}${window.location.search}`;
      const destinationRoute = `${destination.pathname}${destination.search}`;
      if (destinationRoute === currentRoute) return;

      if (!window.confirm(UNSAVED_CHANGES_MESSAGE)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        return;
      }

      indexUpdateTimer = window.setTimeout(() => {
        const nextIndex = window.history.state?.idx;
        currentHistoryIndex = typeof nextIndex === "number" ? nextIndex : currentHistoryIndex;
      }, 0);
    }

    function handlePopState(event: PopStateEvent) {
      const nextIndexValue = event.state?.idx;
      const nextHistoryIndex = typeof nextIndexValue === "number" ? nextIndexValue : null;

      if (approvedHistoryNavigationRef.current) {
        approvedHistoryNavigationRef.current = false;
        if (approvalResetTimerRef.current !== null) {
          window.clearTimeout(approvalResetTimerRef.current);
          approvalResetTimerRef.current = null;
        }
        currentHistoryIndex = nextHistoryIndex;
        return;
      }

      if (restoringCancelledTraversal) {
        restoringCancelledTraversal = false;
        currentHistoryIndex = nextHistoryIndex;
        return;
      }

      if (currentHistoryIndex === null || nextHistoryIndex === null || currentHistoryIndex === nextHistoryIndex) {
        currentHistoryIndex = nextHistoryIndex;
        return;
      }

      if (window.confirm(UNSAVED_CHANGES_MESSAGE)) {
        currentHistoryIndex = nextHistoryIndex;
        return;
      }

      event.preventDefault();
      event.stopImmediatePropagation();
      restoringCancelledTraversal = true;
      window.history.go(currentHistoryIndex - nextHistoryIndex);
    }

    window.addEventListener("beforeunload", handleBeforeUnload);
    document.addEventListener("click", handleDocumentClick, true);
    window.addEventListener("popstate", handlePopState, true);
    return () => {
      window.removeEventListener("beforeunload", handleBeforeUnload);
      document.removeEventListener("click", handleDocumentClick, true);
      window.removeEventListener("popstate", handlePopState, true);
      if (indexUpdateTimer !== null) window.clearTimeout(indexUpdateTimer);
      if (approvalResetTimerRef.current !== null) {
        window.clearTimeout(approvalResetTimerRef.current);
        approvalResetTimerRef.current = null;
      }
      approvedHistoryNavigationRef.current = false;
    };
  }, [isDirty]);

  return confirmHistoryNavigation;
}
