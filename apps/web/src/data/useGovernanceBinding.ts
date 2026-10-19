import { useEffect, useRef, useState } from "react";
import { useAppData } from "./AppDataProvider";
import { supabase } from "./supabase";

export interface GovernanceBinding { key: string; current: { current: string } }
/** UI lifetime guard only; authority and recent proof remain server-owned. */
export function useGovernanceBinding(): GovernanceBinding {
  const { mode, viewer, consentGateOpen, requiredConsentDocuments } = useAppData();
  const [epoch, setEpoch] = useState(0);
  const counter = useRef(0);
  const base = `${mode}:${viewer?.profile.id ?? ""}:${viewer?.profile.globalRole ?? ""}:${viewer?.membership?.organizationId ?? ""}:${viewer?.membership?.status ?? ""}:${JSON.stringify(viewer?.governanceAccess ?? [])}:${String(consentGateOpen)}:${requiredConsentDocuments.map((document) => `${document.key}:${document.version}:${document.contentSha256}`).join("|")}`;
  const key = `${base}:${epoch}`;
  const current = useRef(key); current.current = key;
  useEffect(() => {
    current.current = `${base}:${counter.current}`;
    if (mode === "demo" || !supabase) return;
    let lastToken = "";
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event !== "SIGNED_IN" && event !== "SIGNED_OUT") return;
      const token = session?.access_token ?? "";
      if (event === "SIGNED_IN" && token === lastToken) return;
      lastToken = token;
      current.current = "invalidated";
      setEpoch(++counter.current);
    });
    return () => { current.current = "invalidated"; data.subscription.unsubscribe(); };
  }, [mode, base]);
  return { key, current };
}
