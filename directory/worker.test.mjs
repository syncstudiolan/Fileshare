import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.js';

class FakeD1 {
  accounts = new Map();
  claims = new Map();
  limits = new Map();
  prepare(sql) {
    let args = [];
    const db = this;
    return {
      bind(...values) { args = values; return this; },
      async first() {
        if (sql.includes('FROM limits')) return db.limits.get(args[0]) ?? null;
        if (sql.includes('SELECT email FROM accounts')) {
          return db.accounts.has(args[0]) ? {email:args[0]} : null;
        }
        if (sql.includes('FROM accounts WHERE email')) {
          return db.accounts.get(args[0]) ?? null;
        }
        if (sql.includes('FROM claims WHERE email')) {
          return db.claims.get(args[0]) ?? null;
        }
        throw Error('Unknown D1 first: '+sql);
      },
      async run() {
        if (sql.startsWith('INSERT INTO limits')) {
          const [id, now, boundary] = args;
          const old = db.limits.get(id);
          db.limits.set(id, old && old.starts_at >= boundary ?
            {count:old.count+1,starts_at:old.starts_at} :
            {count:1,starts_at:now});
          return {meta:{changes:1}};
        }
        if (sql.startsWith('INSERT INTO claims')) {
          const [email, worker_url, nonce, otp_hash, expires_at] = args;
          db.claims.set(email,{worker_url,nonce,otp_hash,expires_at,attempts:0});
          return {meta:{changes:1}};
        }
        if (sql.startsWith('DELETE FROM claims')) {
          const [email,nonce] = args;
          const current=db.claims.get(email);
          if (current && (nonce===undefined||current.nonce===nonce))
            db.claims.delete(email);
          return {meta:{changes:1}};
        }
        if (sql.startsWith('UPDATE claims SET attempts')) {
          const record=db.claims.get(args[0]);
          if(record)record.attempts++;
          return {meta:{changes:record?1:0}};
        }
        if (sql.startsWith('INSERT OR IGNORE INTO accounts')) {
          const [email,worker_url,verified_at]=args;
          if(db.accounts.has(email))return {meta:{changes:0}};
          db.accounts.set(email,{email,worker_url,verified_at});
          return {meta:{changes:1}};
        }
        if (sql.startsWith('DELETE FROM limits')) {
          db.limits.clear();return {meta:{changes:1}};
        }
        throw Error('Unknown D1 run: '+sql);
      },
    };
  }
}
const personalOrigin='https://fileshare-own.customer.workers.dev';
const email='user@example.com';
const session='private-session-abcdefghijklmnopqrstuvwxyz';
const env=()=>({
  DB:new FakeD1(), DIRECTORY_OTP_SECRET:'directory-secret-abcdefghijklmnopqrstuvwxyz',
  RESEND_API_KEY:'fake-not-real-token',EMAIL_FROM:'File Share <verify@example.com>',
});
const make=(path,values)=>new Request('https://directory.example.net'+path,{
  method:'POST',
  headers:{'content-type':'application/json',
    'cf-connecting-ip':'203.0.113.77'},
  body:JSON.stringify(values),
});
const originalFetch=globalThis.fetch;
test('email-only discovery requires Worker ownership proof AND email OTP',async()=>{
  const state=env();let lastEmail='';
  globalThis.fetch=async(input,options)=>{
    const url=String(input);
    if(url==='https://api.resend.com/emails'){
      lastEmail=JSON.parse(options.body).text;
      return Response.json({id:'email-1'});
    }
    if(url===personalOrigin+'/v1/auth/me'){
      return Response.json({ok:true,email},{status:
        options.headers.authorization==='Bearer '+session?200:401});
    }
    if(url===personalOrigin+'/v1/auth/login'){
      const payload=JSON.parse(options.body);
      if(payload.password!=='correct-secure-password'){
        return Response.json({ok:false},{status:401});
      }
      return Response.json({ok:true,email,session,
        expiresAt:Date.now()+3600_000});
    }
    throw Error('Unexpected network operation: '+url);
  };
  try {
    const invalid =await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:'http://127.0.0.1:8080/',personalSession:session,
    }),state);
    assert.equal(invalid.status,400);
    const missingProof=await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:personalOrigin,personalSession:'fake',
    }),state);
    assert.equal(missingProof.status,403);
    const started=await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:personalOrigin,personalSession:session,
    }),state);
    assert.equal(started.status,200);
    const code=lastEmail.match(/(\d{8})/)?.[1];
    assert.ok(code);
    assert.equal(state.DB.claims.get(email).otp_hash.includes(code),false);
    const invalidOtp=await worker.fetch(make('/v1/directory/verify',{
      email,code:'00000000',
    }),state);
    assert.equal(invalidOtp.status,403);
    const verified=await worker.fetch(make('/v1/directory/verify',{
      email,code,
    }),state);
    assert.equal(verified.status,200);
    assert.equal(state.DB.accounts.get(email).worker_url,personalOrigin);
    assert.equal(JSON.stringify([...state.DB.accounts.values()]).includes(
      'correct-secure-password'),false);
    const denied=await worker.fetch(make('/v1/directory/login',{
      email,password:'incorrect-password',
    }),state);
    assert.equal(denied.status,401);
    const good=await worker.fetch(make('/v1/directory/login',{
      email,password:'correct-secure-password',
    }),state);
    assert.equal(good.status,200);
    const answer=await good.json();
    assert.equal(answer.workerUrl,personalOrigin);
    assert.equal(answer.session,session);
    assert.equal(answer.email,email);
    assert.equal(JSON.stringify([...state.DB.accounts.values()]).includes(
      'correct-secure-password'),false);
  }finally{globalThis.fetch=originalFetch;}
});
test('unconfigured email sender fails closed',async()=>{
  const state=env();delete state.RESEND_API_KEY;
  const response=await worker.fetch(make('/v1/directory/claim',{
    email,workerUrl:personalOrigin,personalSession:session,
  }),state);
  assert.equal(response.status,503);
});
