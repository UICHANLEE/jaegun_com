import { supabase } from "./supabase";
// In-memory epoch only: no tokens, records, or consent are persisted here.
let epoch = 0;
let installed = false;
const listeners = new Set<() => void>();
export function getFaithSessionEpoch() { return epoch; }
export function subscribeFaithSession(listener: () => void) {
  listeners.add(listener);
  if (!installed && supabase?.auth?.onAuthStateChange) {
    installed = true;
    supabase.auth.onAuthStateChange((event) => {
      if (event !== "SIGNED_IN" && event !== "SIGNED_OUT") return;
      epoch += 1;
      for (const notify of listeners) notify();
    });
  }
  return () => { listeners.delete(listener); };
}
