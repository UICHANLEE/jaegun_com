import { useEffect } from "react";
import { Capacitor, type PluginListenerHandle } from "@capacitor/core";
import { Keyboard } from "@capacitor/keyboard";

/** Keep fixed app surfaces inside the keyboard-visible viewport, including Safari. */
export function useMobileViewport() {
  useEffect(() => {
    const viewport = window.visualViewport;
    if (!viewport) return;
    const root = document.documentElement;
    let frame = 0;
    let nativeKeyboardHeight = 0;
    let fullHeight = viewport.height;
    let disposed = false;
    const listeners: PluginListenerHandle[] = [];
    function update() {
      if (!viewport || viewport.scale !== 1) return;
      const focused = document.activeElement;
      const editing = focused instanceof HTMLElement && (focused.matches("input:not([type=checkbox]):not([type=radio]), textarea") || focused.isContentEditable);
      const browserKeyboard = editing && window.innerHeight - viewport.height > 100;
      if (!nativeKeyboardHeight && !browserKeyboard) fullHeight = viewport.height;
      // Native resize already excludes IME space on iOS. min() also handles
      // Android edge-to-edge without subtracting keyboard space twice.
      const height = nativeKeyboardHeight
        ? Math.min(viewport.height, Math.max(1, fullHeight - nativeKeyboardHeight))
        : viewport.height;
      root.style.setProperty("--mobile-viewport-height", `${height}px`);
      root.style.setProperty("--mobile-viewport-top", `${viewport.offsetTop}px`);
      root.dataset.mobileKeyboard = String(nativeKeyboardHeight > 0 || browserKeyboard);
    }
    function schedule() {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(update);
    }
    update();
    viewport.addEventListener("resize", schedule);
    viewport.addEventListener("scroll", schedule);
    document.addEventListener("focusin", schedule);
    document.addEventListener("focusout", schedule);
    if (Capacitor.isNativePlatform()) {
      const retain = (handle: PluginListenerHandle) => {
        if (disposed) void handle.remove();
        else listeners.push(handle);
      };
      void Keyboard.addListener("keyboardWillShow", ({ keyboardHeight }) => {
        nativeKeyboardHeight = keyboardHeight;
        schedule();
      }).then(retain);
      void Keyboard.addListener("keyboardDidHide", () => {
        nativeKeyboardHeight = 0;
        schedule();
      }).then(retain);
    }
    return () => {
      disposed = true;
      for (const listener of listeners) void listener.remove();
      cancelAnimationFrame(frame);
      viewport.removeEventListener("resize", schedule);
      viewport.removeEventListener("scroll", schedule);
      document.removeEventListener("focusin", schedule);
      document.removeEventListener("focusout", schedule);
      root.style.removeProperty("--mobile-viewport-height");
      root.style.removeProperty("--mobile-viewport-top");
      delete root.dataset.mobileKeyboard;
    };
  }, []);
}
