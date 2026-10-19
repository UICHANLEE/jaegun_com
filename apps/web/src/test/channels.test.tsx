import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => ({
  fetch: vi.fn(), thread: vi.fn(), command: vi.fn(), rich: vi.fn(), update: vi.fn(), upload: vi.fn(), remove: vi.fn(), actor: "actor-a",
  realtimeHandler: undefined as undefined | (()=>void),
}));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({
  mode: "supabase", consentGateOpen: true,
  viewer: { profile: { id: remote.actor }, membership: { organizationId: "org-a" } }, members: [],
}) }));
vi.mock("../data/supabase", () => ({supabase: {
  auth: {onAuthStateChange: () => ({data:{subscription:{unsubscribe:vi.fn()}}})},
  channel:()=>({on:(_event:string,_filter:unknown,handler:()=>void)=>{remote.realtimeHandler=handler;return {subscribe:(callback:(status:string)=>void)=>{callback("SUBSCRIBED");return {};}};}}),
  removeChannel:vi.fn(), storage:{from:()=>({remove:remote.remove})},
}}));
vi.mock("../data/channels", async (original) => ({...await original<object>(), fetchChannels:remote.fetch, fetchChannelThread:remote.thread, channelCommand:remote.command, channelRichCommand:remote.rich, updateCommunityChannel:remote.update}));
vi.mock("../data/mediaUpload", () => ({uploadCommunityFile:remote.upload}));
vi.mock("../components/SafetyControls", () => ({ReportActionLink: () => <a href="/report">신고</a>, BlockUserControl: () => <button>차단</button>}));
import { ChannelPage } from "../pages/ChannelPages";

const channel = {id:"channel-a",name:"찬양팀",description:"주일 준비",visibility:"private",archived:false,ownerId:"actor-a",status:"active",role:"manager",unreadCount:1,lastReadSeq:0,notificationMode:"mentions"};
const snapshot = {actorId:"actor-a",channels:[channel],members:[],messages:[]};
function app(path="/app/chats/channels/channel-a") {
  return <MemoryRouter initialEntries={[path]}><Routes><Route path="/app/chats/channels" element={<ChannelPage/>}/><Route path="/app/chats/channels/:channelId" element={<ChannelPage/>}/></Routes></MemoryRouter>;
}
beforeEach(() => { vi.resetAllMocks(); remote.actor="actor-a"; remote.realtimeHandler=undefined; remote.fetch.mockResolvedValue(snapshot); remote.thread.mockResolvedValue({actorId:"actor-a",rootId:"message-a",messages:[]}); remote.command.mockResolvedValue({id:"channel-a"}); remote.rich.mockResolvedValue({id:"message-a"}); remote.update.mockResolvedValue({id:"channel-a"}); remote.remove.mockResolvedValue({error:null}); });

describe("member-created channels", () => {
  it("lets ordinary approved members create private-by-default channels", async () => {
    render(app("/app/chats/channels"));
    fireEvent.click(await screen.findByRole("button",{name:"채널 만들기"}));
    expect(screen.getByLabelText("공개 범위")).toHaveValue("private");
    fireEvent.change(screen.getByLabelText("채널 이름"),{target:{value:"청년 봉사"}});
    fireEvent.click(screen.getByRole("button",{name:"만들고 입장하기"}));
    await waitFor(() => expect(remote.command).toHaveBeenCalledWith("actor-a","create",expect.any(String),expect.objectContaining({name:"청년 봉사",visibility:"private",organizationId:"org-a"})));
  });
  it("preserves failed message and reuses its operation id on retry", async () => {
    remote.rich.mockRejectedValueOnce(new Error("network unavailable"));
    render(app());
    fireEvent.change(await screen.findByLabelText("채널 메시지"),{target:{value:"준비물 확인해 주세요"}});
    fireEvent.click(screen.getByRole("button",{name:"보내기"}));
    await screen.findByRole("alert");
    expect(screen.getByLabelText("채널 메시지")).toHaveValue("준비물 확인해 주세요");
    const first=remote.rich.mock.calls[0][3].messageId;
    fireEvent.click(screen.getByRole("button",{name:"전송 확인·다시 시도"}));
    await waitFor(() => expect(remote.rich).toHaveBeenCalledTimes(2));
    expect(remote.rich.mock.calls[1][3].messageId).toBe(first);
    await waitFor(() => expect(screen.getByLabelText("채널 메시지")).toHaveValue(""));
  });
  it("blocks duplicate submissions while the first send is pending", async () => {
    let finish!: (value: unknown) => void;
    remote.rich.mockImplementation(() => new Promise(resolve => {finish=resolve;}));
    render(app());
    const input=await screen.findByLabelText("채널 메시지");
    fireEvent.change(input,{target:{value:"인사"}});
    fireEvent.submit(input.closest("form")!); fireEvent.submit(input.closest("form")!);
    expect(remote.rich).toHaveBeenCalledTimes(1);
    await act(async () => finish({}));
  });
  it("does not erase newer input when a previous send finishes", async () => {
    let finish!: (value: unknown) => void;
    remote.rich.mockImplementation(() => new Promise(resolve => {finish=resolve;}));
    render(app());
    const input=await screen.findByLabelText("채널 메시지");
    fireEvent.change(input,{target:{value:"첫 메시지"}});
    fireEvent.submit(input.closest("form")!);
    fireEvent.change(input,{target:{value:"다음 메시지 초안"}});
    await act(async () => finish({}));
    expect(input).toHaveValue("다음 메시지 초안");
  });
  it("shows no ownership or invite controls to a regular participant", async () => {
    remote.fetch.mockResolvedValue({...snapshot,channels:[{...channel,ownerId:"someone",role:"member"}]});
    render(app()); await screen.findByLabelText("채널 메시지");
    expect(screen.queryByRole("button",{name:"채널 보관"})).not.toBeInTheDocument();
    expect(screen.queryByRole("button",{name:"초대 보내기"})).not.toBeInTheDocument();
  });
  it("edits metadata against the displayed revision without changing visibility",async()=>{
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"이름·소개 수정"}));
    fireEvent.change(screen.getByLabelText("채널 이름"),{target:{value:"새 찬양팀"}});
    fireEvent.click(screen.getByRole("button",{name:"이름·소개 저장"}));
    await waitFor(()=>expect(remote.update).toHaveBeenCalledWith("actor-a","channel-a",{name:"새 찬양팀",description:"주일 준비",expectedName:"찬양팀",expectedDescription:"주일 준비"}));
  });
  it("freezes uncertain metadata and retries the exact CAS request",async()=>{
    remote.update.mockRejectedValueOnce(new Error("network"));
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"이름·소개 수정"}));
    fireEvent.change(screen.getByLabelText("채널 이름"),{target:{value:"새 모임"}});
    fireEvent.click(screen.getByRole("button",{name:"이름·소개 저장"}));
    await screen.findByRole("alert");
    expect(screen.getByLabelText("채널 이름")).toHaveAttribute("readonly");
    fireEvent.click(screen.getByRole("button",{name:"같은 변경 결과 확인"}));
    await waitFor(()=>expect(remote.update).toHaveBeenCalledTimes(2));
    expect(remote.update.mock.calls[1]).toEqual(remote.update.mock.calls[0]);
  });
  it("clears old private data immediately when the actor changes", async () => {
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"message-a",seq:1,body:"이전 계정 비공개",senderId:"actor-a",senderName:"가",createdAt:"2026-09-01T00:00:00Z"}]});
    const view=render(app()); await screen.findByText("이전 계정 비공개");
    remote.actor="actor-b"; remote.fetch.mockImplementation(() => new Promise(()=>{}));
    view.rerender(app());
    expect(screen.queryByText("이전 계정 비공개")).not.toBeInTheDocument();
  });
  it("shows generic failure without raw server details", async () => {
    remote.fetch.mockRejectedValue(new Error("postgres secret-internal-detail"));
    render(app()); await screen.findByRole("alert");
    expect(screen.queryByText(/secret-internal-detail/)).not.toBeInTheDocument();
    expect(screen.queryByLabelText("채널 메시지")).not.toBeInTheDocument();
  });
  it("adds a bounded emoji reaction and forwards text only to an active channel", async () => {
    remote.fetch.mockResolvedValue({...snapshot,channels:[channel,{...channel,id:"channel-b",name:"봉사팀"}],messages:[{id:"message-a",seq:1,body:"함께 준비해요",senderId:"actor-b",senderName:"다른 회원",createdAt:"2026-09-01T00:00:00Z",mentionUserIds:[],reactions:[],attachments:[]}]});
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"🙏 반응"}));
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","react","channel-a",{messageId:"message-a",emoji:"🙏",active:true}));
    fireEvent.click(screen.getByRole("button",{name:"전달"}));
    fireEvent.change(screen.getByLabelText("전달할 채널"),{target:{value:"channel-b"}});
    expect(screen.getByText(/첨부와 태그 알림은 복사하지 않습니다/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button",{name:"전달하기"}));
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","forward","channel-a",expect.objectContaining({messageId:"message-a",targetChannelId:"channel-b"})));
  });
  it("inserts a participant tag and sends validated media metadata", async () => {
    remote.fetch.mockResolvedValue({...snapshot,members:[{userId:"actor-b",name:"김집사",role:"member",status:"active"}]});
    remote.upload.mockResolvedValue({bucket:"community-media",path:"org-a/channels/channel-a/object.jpg",url:"signed",kind:"image",mimeType:"image/jpeg",byteSize:4});
    render(app());
    fireEvent.change(await screen.findByLabelText("참여자 태그"),{target:{value:"actor-b"}});
    expect(screen.getByLabelText("채널 메시지")).toHaveValue("@김집사 ");
    const file=new File([new Uint8Array([0xff,0xd8,0xff,0])],"사진.jpg",{type:"image/jpeg"});
    fireEvent.change(screen.getByLabelText("사진·영상 첨부"),{target:{files:[file]}});
    fireEvent.submit(screen.getByLabelText("채널 메시지").closest("form")!);
    await waitFor(()=>expect(remote.upload).toHaveBeenCalled());
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","send","channel-a",expect.objectContaining({mentionUserIds:["actor-b"],attachments:[expect.objectContaining({path:"org-a/channels/channel-a/object.jpg",fileName:"사진.jpg"})]})));
  });
  it("refreshes secure snapshots after an opaque realtime change event", async () => {
    render(app()); await screen.findByText(/실시간 연결됨/);
    expect(remote.realtimeHandler).toBeTypeOf("function");
    act(()=>remote.realtimeHandler?.());
    await waitFor(()=>expect(remote.fetch.mock.calls.length).toBeGreaterThan(1));
  });
  it("edits and soft-deletes only through actor-bound commands", async () => {
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"message-a",seq:1,body:"원문",senderId:"actor-a",senderName:"나",createdAt:"2026-09-01T00:00:00Z",mentionUserIds:[],reactions:[],attachments:[],editedAt:null,deleted:false,replyCount:0}]});
    remote.rich.mockResolvedValueOnce({id:"message-a"}).mockResolvedValueOnce({id:"message-a",deletedPaths:["org-a/channels/channel-a/photo.jpg"]});
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"수정"}));
    fireEvent.change(screen.getByLabelText("메시지 수정"),{target:{value:"수정한 내용"}});
    fireEvent.click(screen.getByRole("button",{name:"저장"}));
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","edit","channel-a",{messageId:"message-a",body:"수정한 내용"}));
    fireEvent.click(screen.getByRole("button",{name:"삭제"}));
    fireEvent.click(screen.getAllByRole("button",{name:"삭제"}).at(-1)!);
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","delete","channel-a",{messageId:"message-a"}));
    expect(remote.remove).toHaveBeenCalledWith(["org-a/channels/channel-a/photo.jpg"]);
  });
  it("opens a reply thread and sends a one-level reply", async () => {
    remote.fetch.mockResolvedValue({...snapshot,members:[{userId:"actor-b",name:"김집사",role:"member",status:"active"}],messages:[{id:"message-a",seq:1,body:"원문",senderId:"actor-b",senderName:"김집사",createdAt:"2026-09-01T00:00:00Z",mentionUserIds:[],reactions:[],attachments:[],deleted:false,replyCount:2}]});
    render(app()); fireEvent.click(await screen.findByRole("button",{name:"답글 2"}));
    await screen.findByText("아직 답글이 없어요.");
    fireEvent.change(screen.getByLabelText("답글 작성"),{target:{value:"확인했습니다"}});
    fireEvent.click(screen.getByRole("button",{name:"답글 보내기"}));
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","send","channel-a",expect.objectContaining({body:"확인했습니다",parentMessageId:"message-a",attachments:[]})));
  });
  it("saves a per-channel notification preference", async () => {
    render(app()); fireEvent.change(await screen.findByLabelText("채널 알림"),{target:{value:"none"}});
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","preference","channel-a",{mode:"none"}));
  });
  it("opens a private small-group starter from the home shortcut", async () => {
    render(app("/app/chats/channels?create=1"));
    expect(await screen.findByLabelText("공개 범위")).toHaveValue("private");
    fireEvent.click(screen.getByRole("button",{name:"봉사 모임"}));
    expect(screen.getByLabelText("채널 이름")).toHaveValue("봉사 모임");
  });
  it("reconciles a lost send response without re-uploading or deleting attached media", async () => {
    remote.upload.mockImplementation(async (_file, options) => {
      options.onObjectPathCreated("org-a/channels/channel-a/photo.jpg");
      return {path:"org-a/channels/channel-a/photo.jpg",kind:"image",mimeType:"image/jpeg",byteSize:4};
    });
    remote.rich.mockRejectedValueOnce(new Error("response lost"));
    render(app());
    fireEvent.change(await screen.findByLabelText("사진·영상 첨부"),{target:{files:[new File(["test"],"사진.jpg",{type:"image/jpeg"})]}});
    fireEvent.click(screen.getByRole("button",{name:"보내기"}));
    fireEvent.click(await screen.findByRole("button",{name:"전송 확인·다시 시도"}));
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledTimes(2));
    expect(remote.rich.mock.calls[1][3]).toEqual(remote.rich.mock.calls[0][3]);
    expect(remote.upload).toHaveBeenCalledTimes(1);
    expect(remote.remove).not.toHaveBeenCalled();
    await waitFor(()=>expect(screen.getByRole("button",{name:"보내기"})).toBeDisabled());
  });
  it("cleans an uploaded object only when message submission has not begun", async () => {
    remote.upload.mockImplementation(async (_file, options) => {
      options.onObjectPathCreated("org-a/channels/channel-a/failed.jpg");
      throw new Error("upload interrupted");
    });
    render(app());
    fireEvent.change(await screen.findByLabelText("사진·영상 첨부"),{target:{files:[new File(["test"],"사진.jpg",{type:"image/jpeg"})]}});
    fireEvent.click(screen.getByRole("button",{name:"보내기"}));
    await waitFor(()=>expect(remote.remove).toHaveBeenCalledWith(["org-a/channels/channel-a/failed.jpg"]));
    expect(remote.rich).not.toHaveBeenCalled();
  });
  it("keeps an unsent reply after closing and reopening its thread", async () => {
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"message-a",seq:1,body:"원문",senderId:"actor-b",senderName:"회원",createdAt:"2026-09-01T00:00:00Z",replyCount:2}]});
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"답글 2"}));
    fireEvent.change(await screen.findByLabelText("답글 작성"),{target:{value:"작성 중인 답글"}});
    fireEvent.click(screen.getByRole("button",{name:"답글 닫기"}));
    fireEvent.click(screen.getByRole("button",{name:"답글 2"}));
    expect(await screen.findByLabelText("답글 작성")).toHaveValue("작성 중인 답글");
  });
  it("marks only the opened thread replies as read and preserves deleted-root history", async () => {
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"message-a",seq:1,body:"",senderId:"actor-b",senderName:"회원",createdAt:"2026-09-01T00:00:00Z",deleted:true,replyCount:1,unreadReplyCount:1}]});
    remote.thread.mockResolvedValue({actorId:"actor-a",rootId:"message-a",channelId:"channel-a",lastReadSeq:0,rootDeleted:true,messages:[{id:"reply-a",seq:5,body:"기존 답글",senderId:"actor-b",senderName:"회원",createdAt:"2026-09-01T00:01:00Z"}]});
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"답글 1 · 새 답글 1"}));
    await screen.findByText("기존 답글");
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","read_thread","channel-a",{messageId:"message-a",seq:5}));
    expect(screen.queryByLabelText("답글 작성")).not.toBeInTheDocument();
    expect(screen.getByText("원문이 삭제되어 기존 답글만 볼 수 있어요.")).toBeInTheDocument();
  });
  it("offers a retry instead of an endless thread loading state", async () => {
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"message-a",seq:1,body:"원문",senderId:"actor-b",senderName:"회원",createdAt:"2026-09-01T00:00:00Z",replyCount:2}]});
    remote.thread.mockRejectedValueOnce(new Error("connection lost"));
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"답글 2"}));
    fireEvent.click(await screen.findByRole("button",{name:"답글 다시 불러오기"}));
    await screen.findByText("아직 답글이 없어요.");
  });
  it("does not label later acknowledged messages as unread on entry", async () => {
    render(app()); await screen.findByLabelText("채널 메시지");
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"later",seq:8,body:"나중에 도착한 메시지",senderId:"actor-b",senderName:"회원",createdAt:"2026-09-01T00:00:00Z"}]});
    act(()=>remote.realtimeHandler?.());
    await screen.findByText("나중에 도착한 메시지");
    await waitFor(()=>expect(remote.command).toHaveBeenCalledWith("actor-a","read","channel-a",{seq:8}));
    expect(screen.queryByLabelText("입장할 때 읽지 않은 메시지")).not.toBeInTheDocument();
  });
  it("sends the desired reaction state on retry instead of blindly toggling", async () => {
    remote.fetch.mockResolvedValue({...snapshot,messages:[{id:"message-a",seq:1,body:"원문",senderId:"actor-b",senderName:"회원",createdAt:"2026-09-01T00:00:00Z",reactions:[]}]});
    remote.rich.mockRejectedValueOnce(new Error("response lost"));
    render(app());
    fireEvent.click(await screen.findByRole("button",{name:"🙏 반응"}));
    await waitFor(()=>expect(remote.fetch.mock.calls.length).toBeGreaterThan(1));
    fireEvent.click(screen.getByRole("button",{name:"🙏 반응"}));
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledTimes(2));
    expect(remote.rich.mock.calls[0][3]).toEqual({messageId:"message-a",emoji:"🙏",active:true});
    expect(remote.rich.mock.calls[1][3]).toEqual(remote.rich.mock.calls[0][3]);
  });
});
