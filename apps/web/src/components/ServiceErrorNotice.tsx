import { ArrowClockwise, CircleNotch, WarningCircle } from "@phosphor-icons/react";
import { useState } from "react";
import { useAppData } from "../data/AppDataProvider";

export function ServiceErrorNotice() {
  const { error, mode, refresh } = useAppData();
  const [retrying, setRetrying] = useState(false);

  if (mode !== "supabase" || !error) return null;

  async function retry() {
    if (retrying) return;
    setRetrying(true);
    try {
      await refresh();
    } catch {
      // The provider retains a user-safe error message for the next attempt.
    } finally {
      setRetrying(false);
    }
  }

  return (
    <aside className="service-error-notice" role="alert" aria-live="assertive">
      <WarningCircle weight="fill" aria-hidden="true" />
      <p><strong>최신 정보를 불러오지 못했어요</strong><span>{error}</span></p>
      <button type="button" onClick={() => void retry()} disabled={retrying}>
        {retrying ? <CircleNotch className="spin" aria-hidden="true" /> : <ArrowClockwise aria-hidden="true" />}
        {retrying ? "다시 연결 중" : "다시 시도"}
      </button>
    </aside>
  );
}
