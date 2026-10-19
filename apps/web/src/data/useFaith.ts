import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useAppData } from "./AppDataProvider";
import { supabase } from "./supabase";
import { parseFaithSnapshot, type FaithSnapshot } from "./faith";
import { parseFaithConsentStatus, verifyFaithConsentText } from "./faithConsent";
import { getFaithSessionEpoch, subscribeFaithSession } from "./faithSession";

export function useFaithScope() {
  const { viewer, mode, consentGateOpen, serviceYear } = useAppData();
  const sessionEpoch = useSyncExternalStore(subscribeFaithSession, getFaithSessionEpoch, getFaithSessionEpoch);
  const organization = viewer?.membership?.status === "active" && consentGateOpen === true ? viewer.membership.organizationId : null;
  return { organization, mode, serviceYear, sessionEpoch, actorID: viewer?.profile.id ?? null, key: organization ? `${mode}:${viewer!.profile.id}:${organization}:${consentGateOpen}:${sessionEpoch}` : null };
}

export function useFaithSnapshot() {
  const scope = useFaithScope();
  const [state, setState] = useState<{ key: string | null; data: FaithSnapshot | null; accepted: boolean | null; error: string | null; loading: boolean }>({ key: null, data: null, accepted: null, error: null, loading: false });
  const [revision, setRevision] = useState(0);
  const currentScope = useRef(scope.key);
  currentScope.current = scope.key;
  useEffect(() => {
    const controller = new AbortController();
    const key = scope.key;
    setState({ key, data: null, accepted: null, error: null, loading: Boolean(key) });
    if (!key || scope.mode === "demo") { setState({ key, data: null, accepted: null, error: null, loading: false }); return; }
    if (!supabase) { setState({ key, data: null, accepted: null, error: "서비스 연결 설정을 확인하지 못했습니다.", loading: false }); return; }
    void (async () => {
      try {
        await verifyFaithConsentText();
        if (controller.signal.aborted || currentScope.current !== key) return;
        const consent = await supabase!.rpc("get_faith_consent_status", { p_organization_id: scope.organization }).abortSignal(controller.signal);
        if (consent.error) throw consent.error;
        const accepted = parseFaithConsentStatus(consent.data);
        if (controller.signal.aborted || currentScope.current !== key) return;
        if (!accepted) { setState({ key, data: null, accepted: false, error: null, loading: false }); return; }
        const { data, error } = await supabase!.rpc("get_faith_snapshot", { p_organization_id: scope.organization }).abortSignal(controller.signal);
        if (error) throw error;
        const snapshot = parseFaithSnapshot(data);
        if (!controller.signal.aborted && currentScope.current === key) setState({ key, data: snapshot, accepted: true, error: null, loading: false });
      } catch {
        if (!controller.signal.aborted && currentScope.current === key) setState({ key, data: null, accepted: null, error: "통독·묵상 기록을 불러오지 못했습니다. 다시 시도해 주세요.", loading: false });
      }
    })();
    return () => controller.abort();
  }, [scope.key, scope.organization, scope.mode, scope.serviceYear, revision]);
  const matches = state.key === scope.key;
  return { ...scope, data: matches ? state.data : null, accepted: matches ? state.accepted : null, error: matches ? state.error : null, loading: matches ? state.loading : Boolean(scope.key), reload: () => setRevision((value) => value + 1), isCurrent: (key: string | null) => key !== null && currentScope.current === key && getFaithSessionEpoch() === scope.sessionEpoch };
}
