import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash,createHmac } from 'node:crypto';
import { receiptR2Config,receiptNotice,signReceiptR2,validReceiptKey,validReceiptMetadata } from './security.ts';
const env={R2_ACCOUNT_ID:'a'.repeat(32),R2_RECEIPTS_BUCKET:'private-receipts',R2_ACCESS_KEY_ID:'b'.repeat(32),R2_SECRET_ACCESS_KEY:'c'.repeat(64),R2_RECEIPTS_POLICY_APPROVED:'finance-private-receipts-v1',R2_RECEIPTS_NOTICE_VERSION:'2026-10-15-review1',R2_RECEIPTS_RECIPIENT:'Reviewed Cloudflare processor',R2_RECEIPTS_COUNTRIES:'Reviewed bucket processing jurisdictions',R2_RECEIPTS_RETENTION:'Reviewed retention period',R2_RECEIPTS_CONTACT:'privacy@example.invalid'};
const key='94000000-0000-4000-8000-000000000001/99000000-0000-4000-8000-000000000001.webp';
test('R2 activation requires credentials AND every factual reviewed notice field',()=>{
 assert.ok(receiptR2Config(env));assert.equal(receiptNotice(env).enabled,true);
 for(const name of Object.keys(env))assert.equal(receiptR2Config({...env,[name]:''}),null,name);
 assert.equal(receiptR2Config({...env,R2_RECEIPTS_POLICY_APPROVED:'true'}),null);
 assert.equal(receiptNotice({}).enabled,false);
 assert.equal(JSON.stringify(receiptNotice(env)).includes(env.R2_SECRET_ACCESS_KEY),false);
 assert.equal(JSON.stringify(receiptNotice(env)).includes(env.R2_ACCESS_KEY_ID),false);
});
test('GET SigV4 agrees with independent node HMAC implementation and TTL is always60',async()=>{
 const config=receiptR2Config(env);const now=new Date('2026-10-15T12:34:56.000Z');const signed=await signReceiptR2(config,'GET',key,now);const url=new URL(signed.url);
 assert.equal(url.hostname,env.R2_ACCOUNT_ID+'.r2.cloudflarestorage.com');assert.equal(url.searchParams.get('X-Amz-Expires'),'60');assert.equal(signed.expiresAt,'2026-10-15T12:35:56.000Z');
 const scope='20261015/auto/s3/aws4_request';const escape=value=>encodeURIComponent(value).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
 const query=[...url.searchParams].filter(([name])=>name!=='X-Amz-Signature').sort(([a],[b])=>a.localeCompare(b)).map(([name,value])=>escape(name)+'='+escape(value)).join('&');
 const canonical=['GET',url.pathname,query,'host:'+url.hostname+'\n','host','UNSIGNED-PAYLOAD'].join('\n');
 const stringToSign=['AWS4-HMAC-SHA256','20261015T123456Z',scope,createHash('sha256').update(canonical).digest('hex')].join('\n');
 let derived=Buffer.from('AWS4'+env.R2_SECRET_ACCESS_KEY);for(const value of ['20261015','auto','s3','aws4_request'])derived=createHmac('sha256',derived).update(value).digest();
 assert.equal(url.searchParams.get('X-Amz-Signature'),createHmac('sha256',derived).update(stringToSign).digest('hex'));
});
test('PUT signs image type and atomic create-once precondition; methods cannot reuse signatures',async()=>{
 const config=receiptR2Config(env);const now=new Date('2026-10-15T00:00:00Z');const signatures=[];
 for(const method of ['PUT','GET','HEAD','DELETE']){const signed=await signReceiptR2(config,method,key,now,102400);signatures.push(new URL(signed.url).searchParams.get('X-Amz-Signature'));if(method==='PUT'){assert.deepEqual(signed.headers,{'content-length':'102400','content-type':'image/webp','if-none-match':'*'});assert.equal(new URL(signed.url).searchParams.get('X-Amz-SignedHeaders'),'content-length;content-type;host;if-none-match');}}
 assert.equal(new Set(signatures).size,4);
});
test('PUT ingestion signs an exact bounded Content-Length and refuses absent or oversized reservations',async()=>{
 const config=receiptR2Config(env);const now=new Date('2026-10-15T00:00:00Z');
 for(const size of [undefined,0,-1,1.5,10485761,Infinity,NaN])await assert.rejects(signReceiptR2(config,'PUT',key,now,size),/invalid_receipt_size/);
 const small=await signReceiptR2(config,'PUT',key,now,100);const larger=await signReceiptR2(config,'PUT',key,now,101);
 assert.equal(small.headers['content-length'],'100');
 assert.notEqual(new URL(small.url).searchParams.get('X-Amz-Signature'),new URL(larger.url).searchParams.get('X-Amz-Signature'));
});
test('signer rejects traversal, unrelated file names and raw arbitrary object paths',async()=>{
 for(const invalid of ['../secret','public/file.webp',key+'?inject=1',key.replace('.webp','.html')]){assert.equal(validReceiptKey(invalid),false);await assert.rejects(signReceiptR2(receiptR2Config(env),'GET',invalid));}
});
test('commit requires bounded image size, real ETag, and exact WebP type',()=>{
 const valid={'content-length':'102400','content-type':'image/webp',etag:'"server-etag"'};
 assert.equal(validReceiptMetadata(new Headers(valid)),true);
 for(const patch of [{'content-length':'0'},{'content-length':'10485761'},{'content-length':'NaN'},{'content-type':'text/html'},{etag:''}])assert.equal(validReceiptMetadata(new Headers({...valid,...patch})),false);
});
