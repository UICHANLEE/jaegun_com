import { useEffect, useRef, useState } from "react";
import { useAppData } from "../data/AppDataProvider";
import { supabase } from "../data/supabase";

export function BoardCommentBlockButton({ commentId }: { commentId: string }) {
  const { viewer, mode, refresh } = useAppData();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const epoch = useRef(0);
  useEffect(() => { epoch.current += 1; setBusy(false); setError(undefined); return () => { epoch.current += 1; }; }, [viewer?.profile.id, viewer?.membership?.organizationId, commentId]);
  async function block() {
    if (busy || !viewer || !supabase || mode !== "supabase" || !window.confirm("댓글 작성자의 글과 메시지를 차단할까요? 익명 작성자의 신원은 공개되지 않습니다.")) return;
    const ticket = epoch.current, actor = viewer.profile.id;
    setBusy(true); setError(undefined);
    try {
      const result = await supabase.rpc("block_community_comment_author", { p_comment_id: commentId, p_expected_actor_id: actor });
      if (result.error) throw result.error;
      if (ticket === epoch.current) await refresh();
    } catch (reason) { if (ticket === epoch.current) setError(reason instanceof Error ? reason.message : "댓글 작성자를 차단하지 못했습니다. 다시 시도해 주세요."); }
    finally { if (ticket === epoch.current) setBusy(false); }
  }
  return <><button className="safety-action-link" type="button" disabled={busy || mode !== "supabase"} onClick={() => void block()}>댓글 작성자 차단</button>{error ? <span role="alert">{error}</span> : null}</>;
}
