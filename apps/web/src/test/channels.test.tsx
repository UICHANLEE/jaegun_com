import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => ({
  fetch: vi.fn(), command: vi.fn(), rich: vi.fn(), upload: vi.fn(), actor: "actor-a",
}));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({
  mode: "supabase", consentGateOpen: true,
  viewer: { profile: { id: remote.actor }, membership: { organizationId: "org-a" } }, members: [],
}) }));
vi.mock("../data/supabase", () => ({supabase: { auth: {onAuthStateChange: () => ({data:{subscription:{unsubscribe:vi.fn()}}})}}}));
vi.mock("../data/channels", async (original) => ({...await original<object>(), fetchChannels:remote.fetch, channelCommand:remote.command, channelRichCommand:remote.rich}));
vi.mock("../data/mediaUpload", () => ({uploadCommunityFile:remote.upload}));
vi.mock("../components/SafetyControls", () => ({ReportActionLink: () => <a href="/report">신고</a>, BlockUserControl: () => <button>차단</button>}));
import { ChannelPage } from "../pages/ChannelPages";

const channel = {id:"channel-a",name:"찬양팀",description:"주일 준비",visibility:"private",archived:false,ownerId:"actor-a",status:"active",role:"manager",unreadCount:1};
const snapshot = {actorId:"actor-a",channels:[channel],members:[],messages:[]};
function app(path="/app/chats/channels/channel-a") {
  return <MemoryRouter initialEntries={[path]}><Routes><Route path="/app/chats/channels" element={<ChannelPage/>}/><Route path="/app/chats/channels/:channelId" element={<ChannelPage/>}/></Routes></MemoryRouter>;
}
beforeEach(() => { vi.resetAllMocks(); remote.actor="actor-a"; remote.fetch.mockResolvedValue(snapshot); remote.command.mockResolvedValue({id:"channel-a"}); remote.rich.mockResolvedValue({id:"message-a"}); });

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
    fireEvent.click(screen.getByRole("button",{name:"보내기"}));
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
    await waitFor(()=>expect(remote.rich).toHaveBeenCalledWith("actor-a","react","channel-a",{messageId:"message-a",emoji:"🙏"}));
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
});
