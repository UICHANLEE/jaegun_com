import { useEffect, useRef, useState } from "react";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";

type AnonymousBlock = { id: string; created_at: string };
export function BoardAnonymousBlocks() {
  const { viewer, mode, consentGateOpen, refresh } = useAppData();
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<AnonymousBlock[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const epoch = useRef(0);
  useEffect(() => { epoch.current += 1; setRows([]); setOpen(false); setBusy(false); setError(undefined); return () => { epoch.current += 1; }; }, [viewer?.profile.id, viewer?.membership?.organizationId, mode, consentGateOpen]);
  async function load(removeId?: string) {
    if (!supabase || mode !== "supabase" || !viewer?.membership || !consentGateOpen || busy) return;
    const ticket = epoch.current; setBusy(true); setError(undefined);
    try {
      if (removeId) {
        const result = await supabase.rpc("remove_my_anonymous_block", { p_block_id: removeId });
        if (result.error) throw result.error;
        if (ticket !== epoch.current) return;
        await refresh();
      }
      if (ticket !== epoch.current) return;
      const result = await supabase.rpc("list_my_anonymous_blocks");
      if (result.error) throw result.error;
      if (ticket !== epoch.current) return;
      setRows(Array.isArray(result.data) ? result.data.filter((row): row is AnonymousBlock => row && typeof row.id === "string" && typeof row.created_at === "string") : []);
    } catch (reason) { if (ticket === epoch.current) setError(reason instanceof Error ? reason.message : "차단 목록을 불러오지 못했습니다."); }
    finally { if (ticket === epoch.current) setBusy(false); }
  }
  return <section aria-label="익명 작성자 차단 관리">
    <button className="button button--secondary" type="button" disabled={busy} aria-expanded={open} onClick={() => { setOpen(!open); if (!open) void load(); }}>익명 작성자 차단 관리</button>
    {open ? <>
      <p>신원 대신 차단한 날짜만 표시합니다. 해제해도 작성자의 신원은 공개되지 않습니다.</p>
      {error ? <p role="alert">{error}</p> : null}
      {busy ? <p role="status">불러오는 중</p> : null}
      {!busy && !rows.length ? <p>차단한 익명 작성자가 없습니다.</p> : null}
      {rows.map((row) => <div key={row.id}>익명 작성자 · {row.created_at.slice(0, 10)} <button type="button" disabled={busy} onClick={() => void load(row.id)}>차단 해제</button></div>)}
    </> : null}
  </section>;
}
