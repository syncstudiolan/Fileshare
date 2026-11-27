import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.js';

const token='owner-test-token';
const origin='https://file-share.example.workers.dev';
const auth={Authorization:'Bearer '+token,'Content-Type':'application/json'};

function uploadEnv() {
  const inserted=[];
  const env={
    OWNER_TOKEN:token,FILES:{},
    DB:{prepare(sql){
      let args=[];
      return {
        bind(...values){args=values;return this;},
        async run(){
          if(sql.includes('INSERT INTO device_transfers')){
            inserted.push(args);
            return {meta:{changes:1}};
          }
          throw Error('Unexpected SQL: '+sql);
        },
        async first(){
          if(sql.includes('SELECT token,created_at FROM qr_codes')){
            return {token:'permanent-guest-qr',created_at:Date.now()-10000};
          }
          throw Error('Unexpected query: '+sql);
        }
      };
    }}
  };
  return {env,inserted};
}

test('logged-in Cloud transfer expires at next midnight IST, not rolling 24h',async()=>{
  const {env,inserted}=uploadEnv();
  const actualNow=Date.now;
  try {
    for(const [instant,expiry] of [
      ['2026-11-20T18:29:00.000Z','2026-11-20T18:30:00.000Z'],
      ['2026-11-20T18:31:00.000Z','2026-11-21T18:30:00.000Z'],
    ]){
      Date.now=()=>Date.parse(instant);
      const response=await worker.fetch(new Request(origin+'/v1/owner/transfer',{
        method:'POST',headers:auth,
        body:JSON.stringify({name:'photo.jpg',size:1024,
          senderId:'desktop12345',senderName:'Laptop'})
      }),env);
      assert.equal(response.status,200,await response.text());
      // The JSON body cannot be read twice. Inspect the actual D1 bound expiry.
      assert.equal(inserted.at(-1).at(-1),Date.parse(expiry));
    }
  }finally{Date.now=actualNow;}
});

test('Guest QR stays active: Auto Cloud setting has no QR revoke endpoint',async()=>{
  const {env}=uploadEnv();
  const qr=await worker.fetch(new Request(origin+'/v1/owner/qr',
    {headers:auth}),env);
  assert.equal(qr.status,200);
  assert.equal((await qr.json()).qr.token,'permanent-guest-qr');
  const revoked=await worker.fetch(new Request(origin+'/v1/owner/qr',
    {method:'DELETE',headers:auth}),env);
  assert.equal(revoked.status,404);
});

test('scheduled midnight cleanup deletes both QR and Cloud R2 objects plus transfer metadata',async()=>{
  let guest=[{id:'qr-id',object_key:'qr/object',upload_id:null}],
      cloud=[{id:'cloud-id',object_key:'device-transfers/object',upload_id:'multipart-1',completed:0}];
  const keys=[],deletes=[],sqlRuns=[];
  const env={
    OWNER_TOKEN:token,
    FILES:{
      async delete(items){keys.push(...(Array.isArray(items)?items:[items]));},
      resumeMultipartUpload(key,id){
        assert.equal(key,'device-transfers/object');
        assert.equal(id,'multipart-1');
        return {async abort(){deletes.push('abort');}};
      }
    },
    DB:{
      prepare(sql){
        return {
          bind(...args){this.args=args;return this;},
          async all(){
            if(sql.includes('FROM uploads'))return {results:guest};
            if(sql.includes('FROM device_transfers'))return {results:cloud};
            throw Error('Unexpected read: '+sql);
          },
          async run(){
            sqlRuns.push(sql);
            return {meta:{changes:1}};
          }
        };
      },
      async batch(queries){
        const queriesText=queries.map(q=>q);
        // Each delete group uses two statements; emulate committed deletion.
        if(guest.length){guest=[];}else{cloud=[];}
        return queriesText.map(()=>({success:true}));
      }
    },
    INBOX_EVENTS:{getByName(){return {async fetch(){return new Response(null,{status:204});}};}}
  };
  await worker.scheduled({},env);
  assert.deepEqual(keys,['qr/object','device-transfers/object']);
  assert.deepEqual(deletes,['abort']);
  assert.ok(sqlRuns.some(s=>s.includes('DELETE FROM guest_sessions')));
});
