import { createClient } from '@supabase/supabase-js';
import { corsHeaders,isOriginAllowed,parseAllowedOrigins } from '../request-account-deletion/security.ts';
import { receiptNotice,receiptR2Config,signReceiptR2,validReceiptKey,validReceiptMetadata } from './security.ts';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
Deno.serve(async request=>{
 const allowed=parseAllowedOrigins(Deno.env.get('ALLOWED_ORIGINS'));const headers=corsHeaders(request.headers.get('origin'),allowed);
 headers.set('Content-Type','application/json');headers.set('Cache-Control','no-store');headers.set('Access-Control-Allow-Headers','authorization, x-client-info, apikey, content-type, x-region');
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(!isOriginAllowed(request.headers.get('origin'),allowed))return reply({error:'origin_not_allowed'},403);
 if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(request.method!=='POST')return reply({error:'method_not_allowed'},405);
 try {
  const reader=request.body?.getReader();if(!reader)return reply({error:'invalid_request'},400);
  const chunks:Uint8Array[]=[];let count=0;
  while(true){const {value,done}=await reader.read();if(done)break;count+=value.byteLength;if(count>4096){await reader.cancel();return reply({error:'request_too_large'},413);}chunks.push(value);}
  const bytes=new Uint8Array(count);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
  const input=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if(!input||typeof input!=='object'||Array.isArray(input))return reply({error:'invalid_request'},400);
  const url=Deno.env.get('SUPABASE_URL')??'';const anon=Deno.env.get('SUPABASE_ANON_KEY')??'';const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')??'';
  if(!url||!anon||!serviceKey)return reply({error:'receipt_service_unavailable'},503);
  const client=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:request.headers.get('authorization')??''}}});
  const {data:identity,error:authError}=await client.auth.getUser();const actor=identity.user;
  if(authError||!actor||actor.is_anonymous)return reply({error:'authentication_required'},401);
  if(input.expectedActorId!==actor.id)return reply({error:'actor_changed'},403);
  const env=Deno.env.toObject();const notice=receiptNotice(env);const r2=receiptR2Config(env);
  if(input.action==='notice')return reply(notice);
  if(!uuid.test(input.receiptId??''))return reply({error:'invalid_receipt_id'},400);
  const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const cleanupUnattached = async () => {
   const {data:latest,error:accessError}=await client.rpc('abandon_unattached_finance_receipt',{p_receipt_id:input.receiptId,p_expected_actor_id:actor.id});
   if(accessError||!latest||!latest.abandoned||!validReceiptKey(latest.path))return;
   if(latest.provider==='r2'&&r2){const signed=await signReceiptR2(r2,'DELETE',latest.path);const removed=await fetch(signed.url,{method:'DELETE',redirect:'error'});if(!removed.ok&&removed.status!==404)throw new Error('cleanup_pending');}
   if(latest.provider==='supabase'){const {error}=await admin.storage.from('finance-receipts').remove([latest.path]);if(error)throw new Error('cleanup_pending');}
  };
  if(input.action==='prepare') {
   if(!uuid.test(input.recordId??'')||!['r2','supabase'].includes(input.provider)||!Number.isInteger(input.byteLength)||input.byteLength<1||input.byteLength>10485760)return reply({error:'invalid_receipt_size'},400);
   if(input.provider==='r2'&&(!r2||!notice.enabled||input.noticeVersion!==notice.version))return reply({error:'r2_reviewed_configuration_required'},503);
   const {data:staged,error}=await client.rpc('prepare_finance_receipt',{p_record_id:input.recordId,p_receipt_id:input.receiptId,p_provider:input.provider,p_expected_size:input.byteLength,p_notice_version:input.provider==='r2'?notice.version:null});
   if(error||!staged)return reply({error:error?.message==='finance_period_closed'?'finance_period_closed':'receipt_access_denied'},error?.message==='finance_period_closed'?409:403);
   const {data:access,error:accessError}=await client.rpc('get_finance_receipt_access',{p_receipt_id:input.receiptId,p_expected_actor_id:actor.id,p_write:true});
   if(accessError||!access||access.uploader_id!==actor.id||access.deleted_at||!validReceiptKey(access.path))return reply({error:'receipt_access_denied'},403);
   if(access.attached_at)return reply({id:input.receiptId,attached:true,provider:access.provider});
   return reply(input.provider==='r2'?{...staged,...await signReceiptR2(r2!,'PUT',access.path,new Date(),Number(access.expected_size)),method:'PUT'}:{...staged,method:'POST'});
  }
  if(!['commit','sign','delete'].includes(input.action))return reply({error:'invalid_action'},400);
  const {data:access,error}=await client.rpc('get_finance_receipt_access',{p_receipt_id:input.receiptId,p_expected_actor_id:actor.id,p_write:input.action!=='sign'});
  if(error||!access||!validReceiptKey(access.path))return reply({error:'receipt_access_denied'},403);
  if(access.provider==='r2'&&!r2)return reply({error:'r2_reviewed_configuration_required'},503);
  if(input.action==='sign') {
   if(access.provider==='r2'){const signed=await signReceiptR2(r2!,'GET',access.path);return reply({url:signed.url,expiresAt:signed.expiresAt,provider:'r2'});}
   const {data:signed,error:signError}=await admin.storage.from('finance-receipts').createSignedUrl(access.path,60);
   if(signError||!signed)return reply({error:'receipt_sign_failed'},503);
   return reply({url:signed.signedUrl,expiresAt:new Date(Date.now()+60000).toISOString(),provider:'supabase'});
  }
  if(input.action==='commit') {
   if(!Number.isInteger(input.expectedRevision)||input.expectedRevision<1||access.uploader_id!==actor.id||access.deleted_at)return reply({error:'invalid_revision'},409);
   if(access.provider==='r2') {
    if(input.noticeVersion!==notice.version||access.notice_version!==notice.version)return reply({error:'receipt_notice_changed'},409);
    const signed=await signReceiptR2(r2!,'HEAD',access.path);const metadata=await fetch(signed.url,{method:'HEAD',redirect:'error'});
    if(!metadata.ok)return reply({error:'receipt_upload_unconfirmed'},409);
    if(!validReceiptMetadata(metadata.headers)||Number(metadata.headers.get('content-length'))!==Number(access.expected_size)){await cleanupUnattached();return reply({error:'receipt_upload_rejected'},409);}
    const {error:confirmError}=await admin.rpc('service_confirm_r2_receipt',{p_receipt_id:input.receiptId,p_actor_id:actor.id,p_size:Number(metadata.headers.get('content-length')),p_content_type:metadata.headers.get('content-type'),p_etag:metadata.headers.get('etag')});
    if(confirmError){await cleanupUnattached();return reply({error:'receipt_access_denied'},403);}
   }
   const {data:attached,error:attachError}=await client.rpc('attach_finance_receipt',{p_receipt_id:input.receiptId,p_expected_revision:input.expectedRevision});
   if(attachError){await cleanupUnattached();return reply({error:'receipt_revision_or_access_changed'},409);}return reply({attached:true,id:attached.id});
  }
  if(typeof input.reason!=='string'||input.reason.trim().length<2||input.reason.length>500)return reply({error:'reason_required'},400);
  const {data:revoked,error:revokeError}=await client.rpc('delete_finance_receipt',{p_receipt_id:input.receiptId,p_reason:input.reason});
  if(revokeError||!revoked)return reply({error:'receipt_access_denied'},403);
  if(access.provider==='r2'){const signed=await signReceiptR2(r2!,'DELETE',access.path);const deleted=await fetch(signed.url,{method:'DELETE',redirect:'error'});if(!deleted.ok&&deleted.status!==404)return reply({error:'receipt_revoked_cleanup_pending'},503);}
  else {const {error:deleteError}=await admin.storage.from('finance-receipts').remove([access.path]);if(deleteError)return reply({error:'receipt_revoked_cleanup_pending'},503);}
  return reply({deleted:true,id:input.receiptId});
 }catch{return reply({error:'receipt_service_unavailable'},503);}
});
