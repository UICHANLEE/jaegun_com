import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const remote = vi.hoisted(() => ({
  fetch: vi.fn(), command: vi.fn(), actor: "actor-a",
}));
vi.mock("../data/AppDataProvider", () => ({ useAppData: () => ({
  mode: "supabase", consentGateOpen: true,
  viewer: { profile: { id: remote.actor }, membership: { organizationId: "org-a" } }, members: [],
}) }));
vi.mock("../data/supabase", () => ({supabase: { auth: {onAuthStateChange: () => ({data:{subscription:{unsubscribe:vi.fn()}}})}}}));
vi.mock("../data/channels", async (original) => ({...await original<object>(), fetchChannels:remote.fetch, channelCommand:remote.command}));
vi.mock("../components/SafetyControls", () => ({ReportActionLink: () => <a href="/report">신고</a>, BlockUserControl: () => <button>차단</button>}));
import { ChannelPage } from "../pages/ChannelPages";

const channel = {id:"channel-a",name:"찬양팀",description:"주일 준비",visibility:"private",archived:false,ownerId:"actor-a",status:"active",role:"manager",unreadCount:1};
const snapshot = {actorId:"actor-a",channels:[channel],members:[],messages:[]};
function app(path="/app/chats/channels/channel-a") {
  return <MemoryRouter initialEntries={[path]}><Routes><Route path="/app/chats/channels" element={<ChannelPage/>}/><Route path="/app/chats/channels/:channelId" element={<ChannelPage/>}/></Routes></MemoryRouter>;
}
beforeEach(() => { vi.resetAllMocks(); remote.actor="actor-a"; remote.fetch.mockResolvedValue(snapshot); remote.command.mockResolvedValue({id:"channel-a"}); });

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
    remote.command.mockRejectedValueOnce(new Error("network unavailable"));
    render(app());
    fireEvent.change(await screen.findByLabelText("채널 메시지"),{target:{value:"준비물 확인해 주세요"}});
    fireEvent.click(screen.getByRole("button",{name:"보내기"}));
    await screen.findByRole("alert");
    expect(screen.getByLabelText("채널 메시지")).toHaveValue("준비물 확인해 주세요");
    const first=remote.command.mock.calls[0][3].messageId;
    fireEvent.click(screen.getByRole("button",{name:"보내기"}));
    await waitFor(() => expect(remote.command).toHaveBeenCalledTimes(2));
    expect(remote.command.mock.calls[1][3].messageId).toBe(first);
    await waitFor(() => expect(screen.getByLabelText("채널 메시지")).toHaveValue(""));
  });
  it("blocks duplicate submissions while the first send is pending", async () => {
    let finish!: (value: unknown) => void;
    remote.command.mockImplementation(() => new Promise(resolve => {finish=resolve;}));
    render(app());
    const input=await screen.findByLabelText("채널 메시지");
    fireEvent.change(input,{target:{value:"인사"}});
    fireEvent.submit(input.closest("form")!); fireEvent.submit(input.closest("form")!);
    expect(remote.command).toHaveBeenCalledTimes(1);
    await act(async () => finish({}));
  });
  it("does not erase newer input when a previous send finishes", async () => {
    let finish!: (value: unknown) => void;
    remote.command.mockImplementation(() => new Promise(resolve => {finish=resolve;}));
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
});
