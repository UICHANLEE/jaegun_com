import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";

type LiveBannerStatus = { actorId: string; stream: { title: string; expiresAt: string } | null };

/** No conferencing SDK, minutes editor, player or chat is loaded on HOME. */
export function LiveHomeBanner() {
  const { viewer, consentGateOpen, mode } = useAppData();
  const [epoch, setEpoch] = useState(0);
  useEffect(() => {
    const subscription = supabase?.auth.onAuthStateChange((event) => {
      if (event !== "INITIAL_SESSION" && event !== "TOKEN_REFRESHED") setEpoch((value) => value + 1);
    });
    return () => subscription?.data.subscription.unsubscribe();
  }, []);
  const actor = viewer?.profile.id;
  const organization = viewer?.membership?.organizationId;
  if (mode !== "supabase" || consentGateOpen !== true || !actor || !organization) return null;
  return <LiveBannerStatusView key={`${actor}:${organization}:${epoch}`} actor={actor} organization={organization} />;
}

function LiveBannerStatusView({ actor, organization }: { actor: string; organization: string }) {
  const [stream, setStream] = useState<LiveBannerStatus["stream"]>(null);
  useEffect(() => {
    let disposed = false;
    let inFlight = false;
    let timer: number | undefined;
    let controller: AbortController | undefined;
    const load = async () => {
      if (disposed || inFlight || document.visibilityState !== "visible" || !supabase) return;
      window.clearTimeout(timer);
      inFlight = true;
      controller = new AbortController();
      try {
        const { data, error } = await supabase.rpc("church_live_status", { p_organization_id: organization }).abortSignal(controller.signal);
        if (disposed) return;
        const status = data as LiveBannerStatus | null;
        const current = !error && status?.actorId === actor && status.stream && Date.parse(status.stream.expiresAt) > Date.now() ? status.stream : null;
        setStream(current);
        // An absent/paused/expired stream has no periodic HOME polling. A new
        // visible page/focus/online event performs one fresh server check.
        if (current) timer = window.setTimeout(load, Math.min(30_000, Math.max(1000, Date.parse(current.expiresAt) - Date.now())));
      } catch { if (!disposed) setStream(null); }
      finally { inFlight = false; }
    };
    const visibility = () => {
      window.clearTimeout(timer);
      if (document.visibilityState === "visible") void load();
      else { controller?.abort(); setStream(null); }
    };
    const refresh = () => { void load(); };
    document.addEventListener("visibilitychange", visibility);
    window.addEventListener("focus", refresh);
    window.addEventListener("online", refresh);
    void load();
    return () => {
      disposed = true;
      window.clearTimeout(timer);
      controller?.abort();
      document.removeEventListener("visibilitychange", visibility);
      window.removeEventListener("focus", refresh);
      window.removeEventListener("online", refresh);
    };
  }, [actor, organization]);
  return stream && Date.parse(stream.expiresAt) > Date.now()
    ? <Link to="/app/live" className="live-banner" aria-label={`라이브 방송 ${stream.title}`}>LIVE · {stream.title} · 교회 방송 보기</Link>
    : null;
}
