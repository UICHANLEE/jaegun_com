import ipaddr from "npm:ipaddr.js@2.2.0";

export interface AuditGatewayConfig {
 upstream: string; anonymousKey: string; signingKey: string; keyID: string;
 rpcAllowlist: Set<string>; trustedProxyCIDRs: string[]; directClients: boolean;
}
export function resolveGatewayClientIP(peer: string, forwarded: string | null, config: Pick<AuditGatewayConfig,"trustedProxyCIDRs"|"directClients">): string | null {
 const trusted=config.trustedProxyCIDRs.map(cidr=>ipaddr.parseCIDR(cidr));
 const parse=(value:string)=>ipaddr.process(value);
 const isTrusted=(value:string)=>{const address=parse(value).toByteArray();return trusted.some(([network,prefix])=>{
  const range=network.toByteArray();if(address.length!==range.length)return false;
  const whole=Math.floor(prefix/8);for(let index=0;index<whole;index++){if(address[index]!==range[index])return false;}
  const remainder=prefix%8;return remainder===0||((address[whole]^range[whole])&(255<<(8-remainder)))===0;
 });};
 try {
  if(config.directClients)return parse(peer).toString();
  if(!isTrusted(peer)||!forwarded)return null;
  const chain=forwarded.split(",").map(value=>value.trim()); if(chain.length>16)return null;
  // Work from the actual socket peer toward the caller; never trust the leftmost client-supplied entry.
  for(let index=chain.length-1;index>=0;index--){const address=parse(chain[index]).toString();if(!isTrusted(address))return address;}
  return null;
 }catch{return null;}
}
export async function signGatewayEnvelope(config: Pick<AuditGatewayConfig,"signingKey"|"keyID">, actor:string,session:string,path:string,ip:string, timestamp=Math.floor(Date.now()/1000), requestID=crypto.randomUUID()): Promise<Record<string,string>> {
 const payload=["jaegun-audit-v1",actor,session,"POST",path,ip,String(timestamp),requestID].join("\n");
 const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(config.signingKey),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 const signed=await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(payload));
 return {"x-jaegun-audit-key":config.keyID,"x-jaegun-audit-ip":ip,"x-jaegun-audit-time":String(timestamp),"x-jaegun-audit-request":requestID,"x-jaegun-audit-signature":Array.from(new Uint8Array(signed),byte=>byte.toString(16).padStart(2,"0")).join("")};
}
export function auditGatewayHandler(config:AuditGatewayConfig,fetcher:typeof fetch=fetch) {
 const upstream=new URL(config.upstream);
 if(upstream.protocol!=="https:"||!upstream.hostname.endsWith(".supabase.co")||upstream.pathname!=="/"||upstream.search||upstream.hash||upstream.username||upstream.password)throw new Error("AUDIT_GATEWAY_UPSTREAM must be one fixed HTTPS project.supabase.co origin");
 if(config.signingKey.length<32||!config.keyID.match(/^[a-zA-Z0-9_-]{1,64}$/)||config.rpcAllowlist.size===0)throw new Error("Signing key, key ID and explicit RPC allowlist required");
 for(const cidr of config.trustedProxyCIDRs){if(ipaddr.parseCIDR(cidr)[1]===0)throw new Error("Trust-all proxy CIDRs are forbidden");}
 if(config.directClients&&config.trustedProxyCIDRs.length)throw new Error("Choose direct socket clients or an explicit proxy chain, never both");
 return async(req:Request,peer:string):Promise<Response>=>{
  const url=new URL(req.url);const match=/^\/rest\/v1\/rpc\/([a-z_][a-z0-9_]*)$/.exec(url.pathname);
  if(req.method!=="POST"||!match||!config.rpcAllowlist.has(match[1])||url.search)return Response.json({error:"gateway_route_not_allowed"},{status:404});
  const authorization=req.headers.get("authorization");if(!authorization?.startsWith("Bearer "))return Response.json({error:"authentication_required"},{status:401});
  const verified=await fetcher(new URL("/auth/v1/user",upstream),{headers:{authorization,apikey:config.anonymousKey},signal:AbortSignal.timeout(10000),redirect:"error"});
  if(!verified.ok)return Response.json({error:"authentication_required"},{status:401});
  const user:unknown=await verified.json();
  const live=await fetcher(new URL("/rest/v1/rpc/audit_gateway_session_context",upstream),{method:"POST",headers:{authorization,apikey:config.anonymousKey,"content-type":"application/json"},body:"{}",signal:AbortSignal.timeout(10000),redirect:"error"});
  if(!live.ok)return Response.json({error:"live_session_required"},{status:401});
  const context:unknown=await live.json();
  if(!user||typeof user!=="object"||!("id" in user)||typeof user.id!=="string"||!context||typeof context!=="object"||!("actor_id" in context)||context.actor_id!==user.id||!("session_id" in context)||typeof context.session_id!=="string"||!context.session_id.match(/^[0-9a-f-]{36}$/))return Response.json({error:"invalid_session"},{status:401});
  // Do not forward arbitrary client envelope, forwarding, service-role, or routing headers.
  const headers=new Headers({authorization,apikey:config.anonymousKey,"content-type":"application/json"});
  const ip=resolveGatewayClientIP(peer,req.headers.get("x-forwarded-for"),config);
  if(ip){const envelope=await signGatewayEnvelope(config,user.id,context.session_id,`/rpc/${match[1]}`,ip);for(const [key,value]of Object.entries(envelope))headers.set(key,value);}
  const reader=req.body?.getReader();let size=0;const chunks:Uint8Array[]=[];
  if(reader){while(true){const next=await reader.read();if(next.done)break;size+=next.value.byteLength;if(size>1048576){await reader.cancel();return Response.json({error:"request_too_large"},{status:413});}chunks.push(next.value);}}
  const body=new Uint8Array(size);let offset=0;for(const chunk of chunks){body.set(chunk,offset);offset+=chunk.byteLength;}
  const result=await fetcher(new URL(url.pathname,upstream),{method:"POST",headers,body,signal:AbortSignal.timeout(30000),redirect:"error"});
  // Never expose the gateway signature or upstream Set-Cookie/security context.
  return new Response(result.body,{status:result.status,headers:{"content-type":result.headers.get("content-type")??"application/json","cache-control":"no-store"}});
 };
}
