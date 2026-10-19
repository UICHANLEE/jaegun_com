import { auditGatewayHandler, resolveGatewayClientIP, signGatewayEnvelope, type AuditGatewayConfig } from "./gateway.ts";
const assert=(condition:unknown,message:string)=>{if(!condition)throw new Error(message);};
const config:AuditGatewayConfig={upstream:"https://fixture.supabase.co",anonymousKey:"test-anon-key",signingKey:"fixture-only-key-at-least-32-bytes-long",keyID:"fixture",rpcAllowlist:new Set(["admin_operations_action"]),trustedProxyCIDRs:["10.0.0.0/8"],directClients:false};
Deno.test("forged forwarding headers have no authority from an untrusted socket peer",()=>{
 assert(resolveGatewayClientIP("203.0.113.9","1.2.3.4",config)===null,"untrusted socket must produce unavailable");
 assert(resolveGatewayClientIP("10.1.1.1","1.2.3.4, 203.0.113.9",config)==="203.0.113.9","walk proxy chain from actual trusted peer; discard forged leftmost entry");
 assert(resolveGatewayClientIP("10.1.1.1","bad-ip",config)===null,"invalid IP is unavailable");
 assert(resolveGatewayClientIP("10.1.1.1",null,config)===null,"no inferred client IP without forwarding contract");
});
Deno.test("signature binds actor session method path address timestamp and nonce",async()=>{
 const envelope=await signGatewayEnvelope(config,"actor","session","/rpc/admin_operations_action","203.0.113.9",1234567890,"00000000-0000-4000-8000-000000000001");
 const payload="jaegun-audit-v1\nactor\nsession\nPOST\n/rpc/admin_operations_action\n203.0.113.9\n1234567890\n00000000-0000-4000-8000-000000000001";
 const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(config.signingKey),{name:"HMAC",hash:"SHA-256"},false,["verify"]);
 const bytes=Uint8Array.from(envelope["x-jaegun-audit-signature"].match(/../g)!.map(value=>parseInt(value,16)));
 assert(await crypto.subtle.verify("HMAC",key,bytes,new TextEncoder().encode(payload)),"exact wire payload must verify");
 assert(!await crypto.subtle.verify("HMAC",key,bytes,new TextEncoder().encode(payload.replace("actor","different-actor"))),"changed actor fails");
});
Deno.test("gateway verifies live user and replaces all client-submitted provenance",async()=>{
 const actor="00000000-0000-4000-8000-000000000001",session="00000000-0000-4000-8000-000000000002";
 const token=`e30.${btoa(JSON.stringify({sub:actor,session_id:session}))}.signature`;
 const captured:{headers?:Headers}={};
 const mock:typeof fetch=async(input,init)=>{if(String(input).endsWith("/auth/v1/user"))return Response.json({id:actor});if(String(input).endsWith("/rpc/audit_gateway_session_context"))return Response.json({actor_id:actor,session_id:session});captured.headers=new Headers(init?.headers);return Response.json({ok:true});};
 const handler=auditGatewayHandler(config,mock);
 const response=await handler(new Request("https://gateway.invalid/rest/v1/rpc/admin_operations_action",{method:"POST",headers:{authorization:`Bearer ${token}`,"x-forwarded-for":"1.2.3.4, 203.0.113.9","x-jaegun-audit-ip":"8.8.8.8","x-jaegun-audit-signature":"forged"},body:"{}"}),"10.1.1.1");
 assert(response.status===200,"allowlisted authenticated request forwarded");
 if(!captured.headers)throw new Error("forwarded headers missing");
 const sent=captured.headers;
 assert(sent.get("x-jaegun-audit-ip")==="203.0.113.9","forged IP discarded");
 assert(sent.get("x-jaegun-audit-signature")!=="forged","server envelope replaces client envelope");
 assert(!sent.has("x-forwarded-for"),"untrusted chain not forwarded to database");
 assert((await handler(new Request("https://gateway.invalid/rest/v1/rpc/arbitrary",{method:"POST"}),"10.1.1.1")).status===404,"fixed RPC allowlist enforced");
});
Deno.test("gateway refuses invalid live authentication before proxying",async()=>{
 const handler=auditGatewayHandler(config,async()=>new Response(null,{status:401}));
 const response=await handler(new Request("https://gateway.invalid/rest/v1/rpc/admin_operations_action",{method:"POST",headers:{authorization:"Bearer invalid"},body:"{}"}),"10.1.1.1");
 assert(response.status===401,"invalid live JWT cannot get a signed envelope");
});
Deno.test("revoked live session does not receive a signed proxy request",async()=>{
 const handler=auditGatewayHandler(config,async(input)=>String(input).endsWith("/auth/v1/user")?Response.json({id:"00000000-0000-4000-8000-000000000001"}):new Response(null,{status:401}));
 const response=await handler(new Request("https://gateway.invalid/rest/v1/rpc/admin_operations_action",{method:"POST",headers:{authorization:"Bearer expired-session"},body:"{}"}),"10.1.1.1");
 assert(response.status===401,"server-owned live session required beyond user lookup");
});
