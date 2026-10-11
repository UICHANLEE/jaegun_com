import { beforeEach, describe, expect, it, vi } from "vitest";
const api=vi.hoisted(() => ({rpc:vi.fn(),abort:vi.fn(),signed:vi.fn()}));
vi.mock("../data/supabase",() => ({supabase:{rpc:api.rpc,storage:{from:()=>({createSignedUrl:api.signed})}}}));
import { channelCommand, channelError, channelRichCommand, clearChannelMediaCache, fetchChannels, fetchChannelThread } from "../data/channels";
beforeEach(() => {vi.resetAllMocks();clearChannelMediaCache();api.rpc.mockReturnValue({abortSignal:api.abort});api.abort.mockResolvedValue({data:{actorId:"a",channels:[],messages:[],members:[]},error:null});api.signed.mockResolvedValue({data:{signedUrl:"https://signed.test/channel"},error:null});});
describe("channel API boundaries",()=>{
  it("binds a snapshot to the requesting actor",async()=>{
    await expect(fetchChannels("b","org")).rejects.toThrow("channel_access_denied");
  });
  it("sends explicit church and channel scope with a cursor",async()=>{
    await fetchChannels("a","org","channel",50);
    expect(api.rpc).toHaveBeenCalledWith("channel_snapshot",{p_organization_id:"org",p_channel_id:"channel",p_before_seq:50});
  });
  it("binds thread snapshots to the actor, channel, and root message",async()=>{
    api.abort.mockResolvedValueOnce({data:{actorId:"a",rootId:"root",channelId:"channel",messages:[]},error:null});
    await fetchChannelThread("a","channel","root",25);
    expect(api.rpc).toHaveBeenCalledWith("channel_thread_snapshot",{p_channel_id:"channel",p_root_message_id:"root",p_before_seq:25});
  });
  it("overrides any caller-supplied expected actor",async()=>{
    await channelCommand("a","send","channel",{expectedActorId:"b",body:"hello",messageId:"nonce"});
    expect(api.rpc).toHaveBeenCalledWith("channel_command",expect.objectContaining({p_payload:expect.objectContaining({expectedActorId:"a"})}));
  });
  it("binds rich message operations to the current actor",async()=>{
    api.abort.mockResolvedValueOnce({data:{id:"message"},error:null});
    await channelRichCommand("a","react","channel",{expectedActorId:"b",messageId:"message",emoji:"🙏"});
    expect(api.rpc).toHaveBeenCalledWith("channel_rich_command",expect.objectContaining({p_payload:expect.objectContaining({expectedActorId:"a"})}));
  });
  it("signs only server-returned channel attachment paths for sixty seconds",async()=>{
    api.abort.mockResolvedValueOnce({data:{actorId:"a",channels:[],members:[],messages:[{id:"m",seq:1,body:"",senderId:"a",senderName:"가",createdAt:"now",attachments:[{id:"x",path:"00000000-0000-4000-8000-000000000001/channels/00000000-0000-4000-8000-000000000002/00000000-0000-4000-8000-000000000003.jpg",kind:"image",mimeType:"image/jpeg",byteSize:1,fileName:"a.jpg"}]}]},error:null});
    const result=await fetchChannels("a","org","channel");
    expect(api.signed).toHaveBeenCalledWith("00000000-0000-4000-8000-000000000001/channels/00000000-0000-4000-8000-000000000002/00000000-0000-4000-8000-000000000003.jpg",60);
    expect(result.messages?.[0].attachments[0].url).toBe("https://signed.test/channel");
  });
  it("aborts a pending snapshot after fifteen seconds",async()=>{
    vi.useFakeTimers();
    api.abort.mockImplementation((signal:AbortSignal)=>new Promise(resolve=>signal.addEventListener("abort",()=>resolve({data:null,error:new Error("aborted")}))));
    try {
      const check=expect(fetchChannels("a","org")).rejects.toThrow("aborted");
      await vi.advanceTimersByTimeAsync(15_000); await check;
    } finally {vi.useRealTimers();}
  });
  it("never reflects provider diagnostics in the UI",()=>{
    expect(channelError(new Error("postgres secret-details"))).not.toContain("secret-details");
    expect(channelError(new Error("transfer_owner_first"))).toContain("소유권");
  });
  it("aborts a pending rich command and lets its caller reconcile the operation",async()=>{
    vi.useFakeTimers();
    api.abort.mockImplementation((signal:AbortSignal)=>new Promise(resolve=>signal.addEventListener("abort",()=>resolve({data:null,error:new Error("aborted")}))));
    try {
      const check=expect(channelRichCommand("a","send","channel",{messageId:"nonce"})).rejects.toThrow("aborted");
      await vi.advanceTimersByTimeAsync(15_000); await check;
    } finally {vi.useRealTimers();}
  });
  it("rejects a thread response from another channel",async()=>{
    api.abort.mockResolvedValueOnce({data:{actorId:"a",rootId:"root",channelId:"other",messages:[]},error:null});
    await expect(fetchChannelThread("a","channel","root")).rejects.toThrow("channel_access_denied");
  });
  it("fails closed when the thread channel identity is missing",async()=>{
    api.abort.mockResolvedValueOnce({data:{actorId:"a",rootId:"root",messages:[]},error:null});
    await expect(fetchChannelThread("a","channel","root")).rejects.toThrow("channel_access_denied");
  });
  it("does not restore a signed URL cache after a session or consent transition",async()=>{
    let finish!: (value: unknown) => void;
    api.signed.mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve;}));
    const attachment={id:"x",path:"00000000-0000-4000-8000-000000000001/channels/00000000-0000-4000-8000-000000000002/00000000-0000-4000-8000-000000000004.jpg",kind:"image",mimeType:"image/jpeg",byteSize:1,fileName:"a.jpg"};
    api.abort.mockResolvedValue({data:{actorId:"a",channels:[],members:[],messages:[{id:"m",attachments:[attachment]}]},error:null});
    const pending=fetchChannels("a","org","channel");
    await vi.waitFor(()=>expect(api.signed).toHaveBeenCalledTimes(1));
    clearChannelMediaCache();
    finish({data:{signedUrl:"https://signed.test/previous-session"},error:null});
    expect((await pending).messages?.[0].attachments[0].url).toBeUndefined();
    await fetchChannels("a","org","channel");
    expect(api.signed).toHaveBeenCalledTimes(2);
  });
});
