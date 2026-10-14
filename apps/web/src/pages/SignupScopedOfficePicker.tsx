import { useEffect, useState } from "react";
import { supabase } from "../data/supabase";
import { parseSignupOfficeOptions, SIGNUP_OFFICE_LABELS, signupOfficeKey, type SignupOfficeOptions, type SignupOfficeRequest } from "../data/signupOfficeRequests";

export function SignupScopedOfficePicker({ organizationId, actorId, demo, disabled, value, onChange, onOptions }: {
  organizationId: string; actorId: string; demo: boolean; disabled: boolean; value: SignupOfficeRequest[];
  onChange: (value: SignupOfficeRequest[]) => void; onOptions: (options: SignupOfficeOptions | null) => void;
}) {
  const [loaded, setLoaded] = useState<{ church: string; actor: string; options: SignupOfficeOptions } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);
  const [yearChoice, setYearChoice] = useState<"current" | "next">("current");
  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    setLoaded(null); setError(null); onOptions(null);
    if (!organizationId || demo || !actorId || !supabase) return;
    const client = supabase;
    void (async () => {
      try {
        const { data, error: rpcError } = await client.rpc("list_signup_office_options", { p_organization_id: organizationId }).abortSignal(controller.signal);
        if (rpcError) throw rpcError;
        const options = parseSignupOfficeOptions(data);
        if (cancelled) return;
        setLoaded({ church: organizationId, actor: actorId, options }); onOptions(options);
      } catch { if (!cancelled) { setError("직책 목록을 불러오지 못했습니다. 연결·동의를 확인하고 다시 시도해 주세요."); onOptions(null); } }
    })();
    return () => { cancelled = true; controller.abort(); };
  }, [organizationId, actorId, demo, retry, onOptions]);
  const options = loaded?.church === organizationId && loaded.actor === actorId ? loaded.options : null;
  if (demo) return <fieldset><legend>총회·노회·교회·부서 직책</legend><p className="field-hint">데모에서는 실제 직책을 신청하지 않습니다. 운영 계정으로 로그인하면 소속 교회의 서버 목록을 선택할 수 있습니다.</p></fieldset>;
  const year = yearChoice === "next" ? options?.next_service_year : options?.service_year;
  const groups = options ? [...options.scopes.map((s) => ({ key: s.id, scope: s.id, label: `${({ general_assembly: "총회", presbytery: "노회", church: "교회" })[s.scope_type]} · ${s.display_name}`, codes: options.office_codes, department: undefined as string | undefined })),
    ...options.departments.map((d) => ({ key: d.id, scope: d.scope_id, label: `부서 · ${d.display_name}`, codes: options.department_office_codes, department: d.id }))] : [];
  return <fieldset disabled={disabled}>
    <legend>총회·노회·교회·부서 직책 신청 <small>선택</small></legend>
    <p className="field-hint">직책은 소속·연도별 신청 정보입니다. 가입 승인과 별도 담당자의 직책 승인이 필요하며 선택만으로 관리 권한이 생기지 않습니다.</p>
    {!organizationId ? <p role="status">노회와 교회를 먼저 선택해 주세요.</p> : null}
    {organizationId && !options && !error ? <p role="status">직책 목록을 확인하고 있습니다.</p> : null}
    {error ? <div role="alert"><p>{error}</p><button type="button" className="button button--secondary" onClick={() => setRetry((n) => n + 1)}>직책 목록 다시 불러오기</button></div> : null}
    {options ? <>
      <label className="field"><span>직책 연도</span><select value={yearChoice} onChange={(e) => setYearChoice(e.target.value === "next" ? "next" : "current")}><option value="current">{options.service_year}년</option><option value="next">{options.next_service_year}년</option></select></label>
      {groups.map((g) => <div key={g.key}><h3>{g.label}</h3><div className="executive-office-toggles executive-office-toggles--compact" role="group" aria-label={`${g.label} 직책`}>
        {g.codes.map((code) => {
          const request: SignupOfficeRequest = { scope_id: g.scope, ...(g.department ? { department_id: g.department } : {}), service_year: year!, office_code: code };
          const selected = value.some((v) => signupOfficeKey(v) === signupOfficeKey(request));
          return <label key={code} className={selected ? "is-selected" : ""}><input type="checkbox" checked={selected} disabled={!selected && value.length >= 36} onChange={() => onChange(selected ? value.filter((v) => signupOfficeKey(v) !== signupOfficeKey(request)) : [...value, request])} /><span><strong>{SIGNUP_OFFICE_LABELS[code]}</strong></span></label>;
        })}
      </div></div>)}
      <p className="field-hint" role="status">현재·다음 연도 합계 {value.length}/36개 선택</p>
      {!groups.length ? <p>신청 가능한 직책이 없습니다.</p> : null}
    </> : null}
  </fieldset>;
}
