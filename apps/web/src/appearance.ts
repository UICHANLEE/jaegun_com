import { useSyncExternalStore } from 'react';

export type Appearance = 'system' | 'light' | 'dark';
const key = 'jaegun-appearance-v1';
const listeners = new Set<() => void>();
export function parseAppearance(value: unknown): Appearance {
 return value === 'light' || value === 'dark' ? value : 'system';
}
function read(): Appearance {
 try { return parseAppearance(window.localStorage.getItem(key)); } catch { return 'system'; }
}
let appearance: Appearance = typeof window === 'undefined' ? 'system' : read();
function apply() {
 if (typeof document === 'undefined') return;
 if (appearance === 'system') document.documentElement.removeAttribute('data-theme');
 else document.documentElement.dataset.theme = appearance;
}
apply();
export function setAppearance(value: Appearance) {
 appearance = parseAppearance(value);
 try {
  if (appearance === 'system') window.localStorage.removeItem(key);
  else window.localStorage.setItem(key, appearance);
 } catch { /* Restricted storage must not prevent an in-memory appearance choice. */ }
 apply(); listeners.forEach(listener => listener());
}
if (typeof window !== 'undefined') window.addEventListener('storage', event => {
 if (event.key !== key && event.key !== null) return;
 appearance = read(); apply(); listeners.forEach(listener => listener());
});
export function useAppearance() {
 return useSyncExternalStore(listener => { listeners.add(listener); return () => { listeners.delete(listener); }; }, () => appearance, () => 'system' as Appearance);
}
