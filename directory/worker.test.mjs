import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.js';

class FakeD1 {
  accounts = new Map();
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
  DB:new FakeD1(), DIRECTORY_RATE_SECRET:'directory-secret-abcdefghijklmnopqrstuvwxyz',
});
const make=(path,values)=>new Request('https://directory.example.net'+path,{
  method:'POST',
  headers:{'content-type':'application/json',
    'cf-connecting-ip':'203.0.113.77'},
  body:JSON.stringify(values),
});
const originalFetch=globalThis.fetch;
test('first personal cloud binding requires session; different Worker cannot take over', async () => {
  const state=env();
  const other='https://other-test.customer.workers.dev';
  globalThis.fetch=async(input,options)=>{
    const url=String(input);
    if(url.endsWith('/v1/auth/me')) {
      const signed=options.headers.authorization==='Bearer '+session;
      return Response.json({ok:signed,email},{status:signed?200:401});
    }
    if(url.endsWith('/v1/auth/login')) {
      const payload=JSON.parse(options.body);
      if(payload.password!=='correct-secure-password')
        return Response.json({ok:false},{status:401});
      return Response.json({ok:true,email,session,expiresAt:Date.now()+3600000});
    }
    throw Error('unexpected '+url);
  };
  try {
    const bad=await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:personalOrigin,personalSession:'invalid'
    }),state);
    assert.equal(bad.status,403);
    const first=await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:personalOrigin,personalSession:session
    }),state);
    assert.equal(first.status,200);
    assert.equal(state.DB.accounts.get(email).worker_url,personalOrigin);
    const same=await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:personalOrigin,personalSession:session
    }),state);
    assert.equal(same.status,200);
    const otherCloud=await worker.fetch(make('/v1/directory/claim',{
      email,workerUrl:other,personalSession:session
    }),state);
    assert.equal(otherCloud.status,409);
    assert.equal(state.DB.accounts.get(email).worker_url,personalOrigin);
    const oldVerify=await worker.fetch(make('/v1/directory/verify',{
      email,code:'1234'
    }),state);
    assert.equal(oldVerify.status,404);
    const rejected=await worker.fetch(make('/v1/directory/login',{
      email,password:'incorrect-password'
    }),state);
    assert.equal(rejected.status,401);
    const success=await worker.fetch(make('/v1/directory/login',{
      email,password:'correct-secure-password'
    }),state);
    assert.equal(success.status,200);
    const result=await success.json();
    assert.equal(result.workerUrl,personalOrigin);
    assert.equal(result.email,email);
    assert.equal(JSON.stringify([...state.DB.accounts.values()]).includes(
      'correct-secure-password'),false);
  }finally{globalThis.fetch=originalFetch;}
});
test('directory health requires no mail service',async()=>{
  const state=env();
  const response=await worker.fetch(
    new Request('https://directory.example.net/health'),state);
  assert.equal(response.status,200);
});
