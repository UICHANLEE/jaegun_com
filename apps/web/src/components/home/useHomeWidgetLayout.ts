import { useCallback, useMemo, useState } from "react";
import { HOME_WIDGET_IDS, type HomeWidgetId } from "./homeWidgetTypes";

const STORAGE_PREFIX = "jaegun-home-widgets-v1";
const STORAGE_VERSION = 1;

function defaultLayout(): HomeWidgetId[] {
  return [...HOME_WIDGET_IDS];
}

function isWidgetLayout(value: unknown): value is HomeWidgetId[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > HOME_WIDGET_IDS.length) return false;
  for (let index = 0; index < value.length; index += 1) {
    const id: unknown = value[index];
    if (!HOME_WIDGET_IDS.some((allowedId) => allowedId === id) || value.indexOf(id) !== index) return false;
  }
  return true;
}

function storageKey(scope: string): string {
  return `${STORAGE_PREFIX}:${encodeURIComponent(scope)}`;
}

function readLayout(scope: string | null): HomeWidgetId[] {
  if (scope === null || typeof window === "undefined") return defaultLayout();

  try {
    const raw = window.localStorage.getItem(storageKey(scope));
    if (raw === null) return defaultLayout();
    const stored: unknown = JSON.parse(raw);
    if (typeof stored !== "object" || stored === null || Array.isArray(stored)) return defaultLayout();
    const preference = stored as Record<string, unknown>;
    if (
      Object.keys(preference).length !== 2
      || preference.version !== STORAGE_VERSION
      || !isWidgetLayout(preference.layout)
    ) return defaultLayout();
    return preference.layout;
  } catch {
    return defaultLayout();
  }
}

export function useHomeWidgetLayout(scope: string | null): {
  layout: HomeWidgetId[];
  saveLayout: (next: HomeWidgetId[]) => boolean;
} {
  const [savedLayouts, setSavedLayouts] = useState(() => new Map<string, HomeWidgetId[]>());
  const storedLayout = useMemo(() => readLayout(scope), [scope]);
  // Derive the current scope during render, not in an effect that could expose the previous actor's layout.
  const layout = scope === null ? storedLayout : savedLayouts.get(scope) ?? storedLayout;

  const saveLayout = useCallback((next: HomeWidgetId[]): boolean => {
    if (scope === null || !isWidgetLayout(next)) return false;
    const savedLayout = [...next];
    let persisted = false;
    try {
      if (typeof window !== "undefined") {
        window.localStorage.setItem(storageKey(scope), JSON.stringify({ version: STORAGE_VERSION, layout: savedLayout }));
        persisted = true;
      }
    } catch {
      // The saved layout still applies in this session when device storage is unavailable.
    }
    setSavedLayouts((previous) => new Map(previous).set(scope, savedLayout));
    return persisted;
  }, [scope]);

  return { layout, saveLayout };
}
