import { beforeEach, describe, expect, it, vi } from "vitest";
const api=vi.hoisted(() => ({rpc:vi.fn(),abort:vi.fn()}));
vi.mock("../data/supabase",() => ({supabase:{rpc:api.rpc}}));
import { channelCommand, channelError, fetchChannels } from "../data/channels";
beforeEach(() => {vi.resetAllMocks();api.rpc.mockReturnValue({abortSignal:api.abort});api.abort.mockResolvedValue({data:{actorId:"a",channels:[],messages:[],members:[]},error:null});});
describe("channel API boundaries",()=>{
  it("binds a snapshot to the requesting actor",async()=>{
    await expect(fetchChannels("b","org")).rejects.toThrow("channel_access_denied");
  });
  it("sends explicit church and channel scope with a cursor",async()=>{
    await fetchChannels("a","org","channel",50);
    expect(api.rpc).toHaveBeenCalledWith("channel_snapshot",{p_organization_id:"org",p_channel_id:"channel",p_before_seq:50});
  });
  it("overrides any caller-supplied expected actor",async()=>{
    await channelCommand("a","send","channel",{expectedActorId:"b",body:"hello",messageId:"nonce"});
    expect(api.rpc).toHaveBeenCalledWith("channel_command",expect.objectContaining({p_payload:expect.objectContaining({expectedActorId:"a"})}));
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
});
