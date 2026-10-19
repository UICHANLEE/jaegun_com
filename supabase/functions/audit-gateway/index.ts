import { auditGatewayHandler } from "./gateway.ts";
// Standalone: deno run --allow-env --allow-net index.ts
// Deployment must review region, DNS/TLS and proxy ownership before client routing changes.
const required=(name:string)=>{const value=Deno.env.get(name);if(!value)throw new Error(`${name} required`);return value;};
const split=(name:string)=>(Deno.env.get(name)??"").split(",").map(value=>value.trim()).filter(Boolean);
const handler=auditGatewayHandler({
 upstream:required("AUDIT_GATEWAY_UPSTREAM"),anonymousKey:required("SUPABASE_ANON_KEY"),signingKey:required("AUDIT_GATEWAY_SIGNING_KEY"),keyID:required("AUDIT_GATEWAY_KEY_ID"),
 rpcAllowlist:new Set(split("AUDIT_GATEWAY_RPC_ALLOWLIST")),trustedProxyCIDRs:split("AUDIT_GATEWAY_TRUSTED_PROXY_CIDRS"),directClients:Deno.env.get("AUDIT_GATEWAY_DIRECT_CLIENTS")==="true",
});
const origins=new Set(split("AUDIT_GATEWAY_ALLOWED_ORIGINS"));
Deno.serve({hostname:Deno.env.get("AUDIT_GATEWAY_HOST")??"127.0.0.1",port:Number(Deno.env.get("PORT")??8787)},async(req,info)=>{
 const origin=req.headers.get("origin");
 if(origin&&!origins.has(origin))return Response.json({error:"origin_not_allowed"},{status:403});
 const cors:Record<string,string>=origin?{"access-control-allow-origin":origin,"vary":"Origin","access-control-allow-methods":"POST, OPTIONS","access-control-allow-headers":"authorization, apikey, content-type, x-client-info, x-region","access-control-max-age":"300"}:{};
 if(req.method==="OPTIONS")return new Response(null,{headers:cors});
 try{const result=await handler(req,info.remoteAddr.hostname);for(const [key,value]of Object.entries(cors))result.headers.set(key,value);return result;}
 catch{return Response.json({error:"gateway_upstream_unavailable"},{status:503,headers:cors});}
});
