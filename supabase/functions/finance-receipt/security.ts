export interface R2Config { accountId:string; bucket:string; accessKeyId:string; secretAccessKey:string }
export interface ReceiptNotice { enabled:boolean; provider:'r2'; version:string; recipient:string; countries:string; purpose:string; items:string; retention:string; refusal:string; contact:string; processingRegion:'us-east-1' }
export function receiptR2Config(env:Record<string,string|undefined>):R2Config|null {
 if(!/^[a-f0-9]{32}$/i.test(env.R2_ACCOUNT_ID??'')||!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(env.R2_RECEIPTS_BUCKET??'')||!/^[A-Za-z0-9]{16,128}$/.test(env.R2_ACCESS_KEY_ID??'')||(env.R2_SECRET_ACCESS_KEY??'').length<32||env.R2_RECEIPTS_POLICY_APPROVED!=='finance-private-receipts-v1')return null;
 if(['R2_RECEIPTS_NOTICE_VERSION','R2_RECEIPTS_RECIPIENT','R2_RECEIPTS_COUNTRIES','R2_RECEIPTS_RETENTION','R2_RECEIPTS_CONTACT'].some(key=>!env[key]?.trim()))return null;
 return {accountId:env.R2_ACCOUNT_ID!,bucket:env.R2_RECEIPTS_BUCKET!,accessKeyId:env.R2_ACCESS_KEY_ID!,secretAccessKey:env.R2_SECRET_ACCESS_KEY!};
}
export function receiptNotice(env:Record<string,string|undefined>):ReceiptNotice {
 return {enabled:receiptR2Config(env)!==null,provider:'r2',version:env.R2_RECEIPTS_NOTICE_VERSION??'',recipient:env.R2_RECEIPTS_RECIPIENT??'',countries:env.R2_RECEIPTS_COUNTRIES??'',purpose:'승인된 조직·행사의 비공개 회계 영수증 보관·조회',items:'사용자가 직접 선택하고 판독 확인한 영수증 이미지, 임의 UUID 객체 식별자',retention:env.R2_RECEIPTS_RETENTION??'',refusal:'R2 전송을 거부할 수 있으며 기존 Supabase 비공개 Storage 옵션을 선택할 수 있습니다.',contact:env.R2_RECEIPTS_CONTACT??'',processingRegion:'us-east-1'};
}
export function validReceiptKey(value:string) { return /^[a-f0-9-]{36}\/[a-f0-9-]{36}\.webp$/i.test(value) && value.split('/').every(part=>part!=='.'&&part!=='..'); }
const encoder=new TextEncoder();
function hex(data:ArrayBuffer) { return [...new Uint8Array(data)].map(byte=>byte.toString(16).padStart(2,'0')).join(''); }
async function hmac(key:Uint8Array<ArrayBuffer>,data:string) { const imported=await crypto.subtle.importKey('raw',key,{name:'HMAC',hash:'SHA-256'},false,['sign']);return new Uint8Array(await crypto.subtle.sign('HMAC',imported,encoder.encode(data))); }
function awsEscape(value:string) { return encodeURIComponent(value).replace(/[!'()*]/g,char=>'%'+char.charCodeAt(0).toString(16).toUpperCase()); }
/** Cloudflare's S3 endpoint requires auto/s3 SigV4. PUT is create-once with atomic If-None-Match. */
export async function signReceiptR2(config:R2Config,method:'GET'|'PUT'|'HEAD'|'DELETE',key:string,now=new Date(),byteLength?:number) {
 if(!validReceiptKey(key))throw new Error('invalid_receipt_key');
 if(method==='PUT'&&(!Number.isInteger(byteLength)||!byteLength||byteLength<1||byteLength>10485760))throw new Error('invalid_receipt_size');
 const date=now.toISOString().replace(/[:-]|\.\d{3}/g,'');const day=date.slice(0,8);const credentialScope=`${day}/auto/s3/aws4_request`;
 const host=`${config.accountId}.r2.cloudflarestorage.com`;const path='/'+[config.bucket,...key.split('/')].map(awsEscape).join('/');
 const headers:Record<string,string>=method==='PUT'?{'content-type':'image/webp','content-length':String(byteLength),'if-none-match':'*'}:{};
 const signedHeaders=Object.keys({...headers,host}).sort().join(';');
 const query:Record<string,string>={'X-Amz-Algorithm':'AWS4-HMAC-SHA256','X-Amz-Credential':config.accessKeyId+'/'+credentialScope,'X-Amz-Date':date,'X-Amz-Expires':'60','X-Amz-SignedHeaders':signedHeaders};
 const canonicalQuery=Object.keys(query).sort().map(key=>awsEscape(key)+'='+awsEscape(query[key])).join('&');
 const canonicalHeaders=Object.entries({...headers,host}).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([key,value])=>key+':'+value.trim()+'\n').join('');
 const canonicalRequest=[method,path,canonicalQuery,canonicalHeaders,signedHeaders,'UNSIGNED-PAYLOAD'].join('\n');
 const digest=hex(await crypto.subtle.digest('SHA-256',encoder.encode(canonicalRequest)));
 const stringToSign=['AWS4-HMAC-SHA256',date,credentialScope,digest].join('\n');
 const keyDate=await hmac(encoder.encode('AWS4'+config.secretAccessKey),day);const keyRegion=await hmac(keyDate,'auto');const keyService=await hmac(keyRegion,'s3');const keySigning=await hmac(keyService,'aws4_request');
 const signature=hex((await hmac(keySigning,stringToSign)).buffer);
 return {url:`https://${host}${path}?${canonicalQuery}&X-Amz-Signature=${signature}`,headers,expiresAt:new Date(now.getTime()+60000).toISOString()};
}
export function validReceiptMetadata(headers:Headers) {
 const size=Number(headers.get('content-length'));return Number.isInteger(size)&&size>0&&size<=10485760&&headers.get('content-type')==='image/webp'&&!!headers.get('etag');
}
