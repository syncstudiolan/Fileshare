import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import worker from './worker.js';

test('Guest QR finish pushes exactly one notification to all logged-in listeners',async()=>{
  const token='test-owner-token';
  const cookie='fa9a1b7d-3561-4c1a-b80e-0b100f35be31';
  const hash=createHash('sha256').update(token+':'+cookie).digest('hex');
  let notifications=0,finished=false,dbReads=0;
  const env={
    OWNER_TOKEN:token,
    FILES:{},
    DB:{
      prepare(sql){
        let params=[];
        return {
          bind(...values){params=values;return this;},
          async first(){
            dbReads++;
            if(sql.includes('FROM guest_sessions WHERE id=? AND guest_key=?')){
              assert.equal(params[1],hash);
              return {id:params[0],expires_at:Date.now()+300000};
            }
            if(sql.includes('COUNT(*) AS pending FROM uploads')){
              return {pending:0};
            }
            throw Error('Unexpected query: '+sql);
          },
          async run(){
            assert.match(sql,/UPDATE guest_sessions SET completed=1/);
            if(finished)return {meta:{changes:0}};
            finished=true;
            return {meta:{changes:1}};
          },
        };
      },
    },
    INBOX_EVENTS:{
      getByName(room){
        assert.equal(room,'owner');
        return {async fetch(request,options){
          assert.equal(new URL(request).pathname,'/internal/inbox-notify');
          assert.equal(options.method,'POST');
          notifications++;
          return new Response(null,{status:204});
        }};
      },
    },
  };
  const send=()=>worker.fetch(new Request(
    'https://files.example.workers.dev/v1/guest/finish/guest-session-1',
    {method:'POST',headers:{cookie:'fs_guest='+cookie}}),env);
  const first=await send();
  assert.equal(first.status,200);
  assert.equal(notifications,1,'one event per completed QR upload batch');
  assert.equal(dbReads,2,'no per-device polling or repeated metadata lookup');
  const duplicate=await send();
  assert.equal(duplicate.status,200);
  assert.equal(notifications,1,'duplicate finish must not charge extra notifications');
});
