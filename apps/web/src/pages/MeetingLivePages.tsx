import { useEffect, useRef, useState } from "react";
import { JitsiMeeting } from "@jitsi/react-sdk";
import { useSearchParams } from "react-router-dom";
import { supabase } from "../data/supabase";
import { useAppData } from "../data/AppDataProvider";
import { MeetingMinutesEditor } from "./ScopedRecordsPages";

type Meeting = { id: string; title: string; channelId: string | null; scopeId: string | null; revision: number; admission: string | null; canManage: boolean; expiresAt: string; waiting: { userId: string; name: string; status: string }[] };
type Meetings = { actorId: string; meetings: Meeting[]; channels: { id: string; name: string }[]; scopes: { id: string; name: string }[] };
type Entry = { host: string; room: string; jwt: string; expiresAt: string; moderator: boolean };
type Stream = { video_id: string; title: string; bulletin: string; state: string; revision: number; expires_at: string };
type Live = { actorId: string; canBroadcast: boolean; stream: Stream | null; messages: { id: string; senderId: string; senderName: string; body: string }[] };

async function rpc<T>(name: string, body: Record<string, unknown>): Promise<T> {
  if (!supabase) throw new Error("서버 연결이 필요합니다.");
  const { data, error } = await supabase.rpc(name, body);
  if (error) throw new Error(error.message.includes("recent_google") ? "민감 작업을 위해 Google 재인증 후 다시 시도하세요." : error.message.includes("conflict") ? "다른 변경이 있습니다. 새로 불러온 상태를 확인하세요." : "권한·동의 또는 연결 상태를 확인하세요.");
  return data as T;
}

function useIdentity() {
  const { viewer, consentGateOpen, mode } = useAppData();
  const [epoch, setEpoch] = useState(0);
  useEffect(() => {
    const subscription = supabase?.auth.onAuthStateChange((event) => { if (event !== "INITIAL_SESSION" && event !== "TOKEN_REFRESHED") setEpoch((n) => n + 1); });
    return () => subscription?.data.subscription.unsubscribe();
  }, []);
  const actor = viewer?.profile.id ?? "";
  const org = viewer?.membership?.organizationId ?? "";
  return { actor, org, key: `${actor}:${org}:${epoch}`, ready: mode === "supabase" && consentGateOpen === true && !!actor && !!org };
}

export function MeetingPage() {
  const identity = useIdentity();
  const [params] = useSearchParams();
  const channelID = params.get("channel") ?? undefined;
  return identity.ready ? <MeetingWorkspace key={`${identity.key}:${channelID ?? ""}`} actor={identity.actor} org={identity.org} channelID={channelID} /> : <p>회의는 현재 동의를 완료한 승인 회원만 이용할 수 있습니다.</p>;
}

function MeetingWorkspace({ actor, org, channelID }: { actor: string; org: string; channelID?: string }) {
  const [snapshot, setSnapshot] = useState<Meetings | null>(null);
  const [active, setActive] = useState<string | null>(null);
  const [entry, setEntry] = useState<Entry | null>(null);
  const [error, setError] = useState("");
  const [title, setTitle] = useState("");
  const [channel, setChannel] = useState(channelID ?? "");
  const [approved, setApproved] = useState(false);
  const [busy, setBusy] = useState(false);
  const api = useRef<{ executeCommand: (command: string, ...args: unknown[]) => void; dispose: () => void } | null>(null);
  const alive = useRef(true);
  const operation = useRef<{ title: string; channel: string; id: string } | null>(null);
  useEffect(() => {
    let timer: number;
    alive.current = true;
    const load = async () => {
      try {
        const result = await rpc<Meetings>("meeting_snapshot", { p_organization_id: org });
        if (!alive.current || result.actorId !== actor) return;
        setSnapshot(result);
        setActive((id) => {
          const meeting = result.meetings.find((item) => item.id === id);
          if (id && (!meeting || meeting.admission !== "admitted")) { api.current?.executeCommand("hangup"); setEntry(null); return null; }
          return id;
        });
      } catch (reason) { if (alive.current) { api.current?.executeCommand("hangup"); setEntry(null); setSnapshot(null); setError((reason as Error).message); } }
      finally { if (alive.current) timer = window.setTimeout(load, 5000); }
    };
    void load();
    return () => { alive.current = false; clearTimeout(timer); api.current?.executeCommand("hangup"); api.current?.dispose(); api.current = null; };
  }, [actor, org]);
  async function command(action: string, id: string, payload: Record<string, unknown> = {}) {
    if (busy) return;
    setBusy(true); setError("");
    try {
      await rpc("meeting_command", { p_action: action, p_meeting_id: id, p_payload: { ...payload, revision: snapshot?.meetings.find((meeting) => meeting.id === id)?.revision, expectedActorId: actor } });
      const result = await rpc<Meetings>("meeting_snapshot", { p_organization_id: org });
      if (alive.current && result.actorId === actor) {
        setSnapshot(result);
        if (action === "create") operation.current = null;
      }
    } catch (reason) { if (alive.current) setError((reason as Error).message); }
    finally { if (alive.current) setBusy(false); }
  }
  async function join(meeting: Meeting) {
    if (!approved || busy || !supabase) return;
    setBusy(true); setError("");
    try {
      // The SDK requests devices on explicit entry, not on page load.
      const devices = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
      devices.getTracks().forEach((track) => track.stop());
      const { data, error: failure } = await supabase.functions.invoke("meeting-access", { body: { meetingId: meeting.id, expectedActorId: actor }, headers: { "x-region": "us-east-1" } });
      if (failure || !data?.jwt) throw new Error("전용 인증 회의 서버가 연결되지 않았거나 입장 권한이 만료되었습니다. 공개 회의로 대신 연결하지 않습니다.");
      if (alive.current) { setActive(meeting.id); setEntry(data as Entry); }
    } catch (reason) { if (alive.current) setError((reason as Error).message); }
    finally { if (alive.current) setBusy(false); }
  }
  const activeScope = snapshot?.meetings.find((meeting) => meeting.id === active)?.scopeId;
  return <div className="page"><h1>인앱 회의</h1><p>회의는 4시간 후 만료됩니다. 대기실 승인과 현재 채널/임원 권한을 확인합니다. 녹화·외부 송출은 제공하지 않습니다. 카메라·마이크는 입장할 때만 요청합니다.</p>
    {error && <p role="alert">{error}</p>}
    <form onSubmit={(event) => { event.preventDefault(); if (!operation.current || operation.current.title !== title || operation.current.channel !== channel) operation.current = { title, channel, id: crypto.randomUUID() }; void command("create", operation.current.id, { organizationId: org, channelId: channel.startsWith("scope:") ? null : channel, scopeId: channel.startsWith("scope:") ? channel.slice(6) : null, title }); }}>
      <label>회의 제목<input required maxLength={200} value={title} onChange={(e) => setTitle(e.target.value)} /></label>
      <label>정확한 참석 범위<select required disabled={!!channelID} value={channel} onChange={(e) => setChannel(e.target.value)}><option value="" disabled>채널 / 정확한 조직 임원 범위 선택</option>{!channelID && snapshot?.scopes.map((s) => <option key={s.id} value={`scope:${s.id}`}>{s.name} · 임원 전용</option>)}{snapshot?.channels.filter((c) => !channelID || c.id === channelID).map((c) => <option key={c.id} value={c.id}>{c.name} · 채널</option>)}</select></label>
      <button disabled={busy || !title.trim() || !channel}>회의 생성</button>
    </form>
    <label><input type="checkbox" checked={approved} onChange={(e) => setApproved(e.target.checked)} /> 전용 Jitsi 호스트에 이름·음성·영상이 전송됩니다. 회의 참여와 장치 사용을 허용합니다. 타인 녹화는 동의 없이 금지합니다.</label>
    <div>{snapshot?.meetings.filter((meeting) => !channelID || meeting.channelId === channelID).map((meeting) => <section key={meeting.id}><h2>{meeting.title}</h2><p>{meeting.channelId ? "채널 회원 전용" : "정확한 조직 임원 전용"} · 만료 {new Date(meeting.expiresAt).toLocaleString()}</p>
      {meeting.admission === "admitted" ? <button disabled={busy || !approved} onClick={() => void join(meeting)}>입장 / 다시 연결</button> : meeting.admission === "revoked" ? <p>입장 권한이 회수되었습니다.</p> : <button disabled={busy || meeting.admission === "waiting"} onClick={() => void command("request", meeting.id)}>{meeting.admission === "waiting" ? "대기실 · 승인 대기" : "대기실 입장 요청"}</button>}
      {meeting.canManage && <><button disabled={busy} onClick={() => void command("end", meeting.id)}>전체 회의 종료</button>{meeting.waiting.filter((a) => a.userId !== actor).map((a) => <div key={a.userId}>{a.name} · {a.status}<button disabled={busy} onClick={() => void command(a.status === "admitted" ? "revoke" : "admit", meeting.id, { userId: a.userId })}>{a.status === "admitted" ? "권한 회수" : "입장 승인"}</button></div>)}</>}
    </section>)}</div>
    {entry && active && <section><button onClick={() => { api.current?.executeCommand("hangup"); setEntry(null); setActive(null); }}>나가기 · 장치 끄기</button>
      <JitsiMeeting key={`${active}:${entry.jwt}`} domain={entry.host} roomName={entry.room} jwt={entry.jwt}
        configOverwrite={{ prejoinConfig: { enabled: true }, startWithAudioMuted: true, startWithVideoMuted: true, localRecording: { disable: true }, disableDeepLinking: true,
          toolbarButtons: ["microphone", "camera", "desktop", "tileview", "settings", "hangup"], fileRecordingsEnabled: false, liveStreamingEnabled: false, transcription: { enabled: false } }}
        onApiReady={(externalApi) => { api.current = externalApi; }} onReadyToClose={() => { setEntry(null); setActive(null); }} getIFrameRef={(element) => { element.style.height = "65vh"; }} />
      {activeScope && <MeetingMinutesEditor scopeId={activeScope} />}
    </section>}
  </div>;
}

export function ChurchLivePage() {
  const identity = useIdentity();
  return identity.ready ? <LiveWorkspace key={identity.key} actor={identity.actor} org={identity.org} /> : <p>교회 가입 승인과 현재 동의 후 라이브를 이용하세요.</p>;
}

function LiveWorkspace({ actor, org }: { actor: string; org: string }) {
  const [snapshot, setSnapshot] = useState<Live | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [playing, setPlaying] = useState(false);
  const [url, setUrl] = useState(""); const [title, setTitle] = useState(""); const [bulletin, setBulletin] = useState("");
  const [rights, setRights] = useState(false); const [body, setBody] = useState("");
  const message = useRef<{ id: string; body: string } | null>(null);
  const alive = useRef(true);
  useEffect(() => {
    let timer: number;
    alive.current = true;
    const load = async () => {
      try { const result = await rpc<Live>("church_live_snapshot", { p_organization_id: org }); if (alive.current && result.actorId === actor) setSnapshot(result); }
      catch (reason) { if (alive.current) { setSnapshot(null); setPlaying(false); setError((reason as Error).message); } }
      finally { if (alive.current) timer = window.setTimeout(load, 5000); }
    };
    void load();
    return () => { alive.current = false; clearTimeout(timer); };
  }, [actor, org]);
  const stream = snapshot?.stream;
  const live = stream?.state === "live" && Date.parse(stream.expires_at) > Date.now();
  async function command(action: string, payload: Record<string, unknown> = {}) {
    if (busy) return; setBusy(true); setError("");
    try {
      await rpc("church_live_command", { p_organization_id: org, p_action: action, p_payload: { ...payload, revision: stream?.revision ?? 0, expectedActorId: actor } });
      const result = await rpc<Live>("church_live_snapshot", { p_organization_id: org });
      if (alive.current && result.actorId === actor) { setSnapshot(result); if (action === "amen") { setBody(""); message.current = null; } }
    } catch (reason) {
      if (alive.current) { setError((reason as Error).message); const current = await rpc<Live>("church_live_snapshot", { p_organization_id: org }).catch(() => null); if (alive.current) setSnapshot(current); }
    } finally { if (alive.current) setBusy(false); }
  }
  return <div className="page"><h1>교회 YouTube 라이브</h1><p>이 화면의 회원 권한은 YouTube 영상 자체를 비공개로 만들지 않습니다. 공개·일부공개 영상은 링크를 가진 외부인도 볼 수 있습니다. 재생하면 YouTube(Google)에 IP·장치 정보가 전달되며 해당 서비스 약관이 적용됩니다.</p>
    {error && <p role="alert">{error}</p>}
    <h2>{stream?.title ?? "등록된 방송이 없습니다"}</h2><p>{live ? "LIVE" : stream?.state === "paused" ? "방송 일시중지" : "방송 종료 / 대기"}</p>
    {live && <>{playing ? <><iframe key={stream.video_id} title="교회 YouTube 라이브" src={`https://www.youtube-nocookie.com/embed/${stream.video_id}?autoplay=1&playsinline=1`} allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowFullScreen style={{ width: "100%", aspectRatio: "16/9", border: 0 }} /><button onClick={() => setPlaying(false)}>내 재생 중지 · YouTube 연결 해제</button></> : <button onClick={() => setPlaying(true)}>외부 서비스 안내 확인 · 재생</button>}</>}
    <section><h2>오늘의 주보</h2><p style={{ whiteSpace: "pre-wrap" }}>{stream?.bulletin || "등록된 주보가 없습니다."}</p></section>
    <section><h2>라이브 아멘 채널</h2>{snapshot?.messages.map((m) => <p key={m.id}><strong>{m.senderName}</strong> {m.body} {snapshot.canBroadcast && <button disabled={busy} onClick={() => void command("hide", { id: m.id })}>숨기기</button>}</p>)}
      <form onSubmit={(e) => { e.preventDefault(); if (!message.current || message.current.body !== body) message.current = { id: crypto.randomUUID(), body }; void command("amen", message.current); }}><label>아멘·메시지<input value={body} maxLength={500} onChange={(e) => setBody(e.target.value)} /></label><button disabled={!live || busy || !body.trim()}>전송</button><button type="button" disabled={!live || busy} onClick={() => void command("amen", { id: crypto.randomUUID(), body: "아멘" })}>아멘</button></form>
    </section>
    {snapshot?.canBroadcast && <section><h2>교회 방송 관리</h2><p>현재 교회 회장·총무만 제어할 수 있습니다. Google 재인증이 필요합니다. 8시간 후 자동으로 앱 노출이 종료됩니다.</p>
      <form onSubmit={(e) => { e.preventDefault(); void command("start", { url, title, bulletin, rightsConfirmed: rights }); }}><label>YouTube URL<input required type="url" value={url} onChange={(e) => setUrl(e.target.value)} /></label><label>방송 제목<input required maxLength={200} value={title} onChange={(e) => setTitle(e.target.value)} /></label><label>주보<textarea maxLength={20000} value={bulletin} onChange={(e) => setBulletin(e.target.value)} /></label><label><input type="checkbox" checked={rights} onChange={(e) => setRights(e.target.checked)} /> 영상·음악 권리와 촬영 대상 동의를 확인했습니다.</label><button disabled={busy || !rights}>방송 시작 / 변경</button></form>
      <button disabled={busy || !live} onClick={() => void command("pause")}>앱 방송 일시중지</button><button disabled={busy || stream?.state !== "paused"} onClick={() => void command("resume")}>다시 노출</button><button disabled={busy || !stream || stream.state === "stopped"} onClick={() => void command("stop")}>앱 방송 중단</button><p>YouTube 원본 송출 중단은 방송자가 YouTube Studio에서도 직접 실행해야 합니다.</p>
    </section>}
  </div>;
}
