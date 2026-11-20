import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker, {InboxEvents} from './worker.js';

test('live inbox rejects unauthenticated WebSocket upgrades',async()=>{
  let reachedRoom=false;
  const env={
    DB:{},FILES:{},OWNER_TOKEN:'owner-test-secret',
    INBOX_EVENTS:{getByName(){reachedRoom=true;throw Error('must not reach room');}},
  };
  const request=new Request('https://owner.example.workers.dev/v1/owner/events',{
    method:'GET',headers:{Upgrade:'websocket'},
  });
  const response=await worker.fetch(request,env);
  assert.equal(response.status,401);
  assert.equal(reachedRoom,false);
});

test('authenticated WebSocket connects through private Durable Object',async()=>{
  let wasInvoked=false;
  const env={
    DB:{},FILES:{},OWNER_TOKEN:'owner-test-secret',
    INBOX_EVENTS:{
      getByName(name){
        assert.equal(name,'owner');
        return {async fetch(request){
          wasInvoked=true;
          assert.equal(new URL(request.url).pathname,'/internal/inbox-socket');
          assert.equal(request.headers.get('Upgrade'),'websocket');
          return new Response(null,{status:204});
        }};
      },
    },
  };
  const request=new Request('https://owner.example.workers.dev/v1/owner/events',{
    method:'GET',
    headers:{Upgrade:'websocket',Authorization:'Bearer owner-test-secret'},
  });
  const response=await worker.fetch(request,env);
  assert.equal(response.status,204);
  assert.equal(wasInvoked,true);
});

test('hibernated inbox broadcasts only one minimal invalidation signal',async()=>{
  const first={received:[],send(message){this.received.push(message);}};
  const second={received:[],send(message){this.received.push(message);}};
  const events=new InboxEvents({
    getWebSockets(){return [first,second];},
  },{});
  const response=await events.fetch(new Request(
    'https://inbox.internal/internal/inbox-notify',{method:'POST'}));
  assert.equal(response.status,204);
  assert.deepEqual(first.received,['files-changed']);
  assert.deepEqual(second.received,['files-changed']);
});

test('legacy Worker without inbox binding cannot accept live socket',async()=>{
  const env={DB:{},FILES:{},OWNER_TOKEN:'owner-test-secret'};
  const request=new Request('https://owner.example.workers.dev/v1/owner/events',{
    headers:{Upgrade:'websocket',Authorization:'Bearer owner-test-secret'},
  });
  const response=await worker.fetch(request,env);
  assert.equal(response.status,503);
  const data=await response.json();
  assert.match(data.error,/update cloud setup/);
});

test('midnight clears QR R2 and D1 in batches and broadcasts only once',async()=>{
  const now=Date.now();
  const uploads=new Map();
  for(let n=0;n<130;n++){
    const id='qr-file-'+n;
    uploads.set(id,{id,object_key:'uploads/test/'+id,
      upload_id:null,expires_at:now-1000});
  }
  const parts=new Set([...uploads.keys()]);
  const sessions=new Map([['expired-qr-session',{expires_at:now-1000}]]);
  const calls={r2:0,r2Keys:[],events:0,maxBind:0};
  const DB={
    prepare(sql){
      let args=[];
      return {
        bind(...values){
          args=values;
          calls.maxBind=Math.max(calls.maxBind,values.length);
          return this;
        },
        async all(){
          // This fixture has expired Guest QR files but no device transfers.
          if(sql.startsWith('SELECT id,object_key,upload_id,completed FROM device_transfers'))
            return {results:[]};
          if(!sql.startsWith('SELECT id,object_key,upload_id FROM uploads'))
            throw Error('Unexpected SELECT '+sql);
          return {results:[...uploads.values()].filter(
            x=>x.expires_at<=args[0]).slice(0,500)};
        },
        async run(){
          if(sql.startsWith('DELETE FROM upload_parts')){
            for(const id of args)parts.delete(id);
          }else if(sql.startsWith('DELETE FROM uploads WHERE id IN')){
            for(const id of args)uploads.delete(id);
          }else if(sql.startsWith('DELETE FROM guest_sessions')){
            for(const [id,row] of sessions){
              if(row.expires_at<=args[0] && uploads.size===0)sessions.delete(id);
            }
          }else if(!sql.startsWith('DELETE FROM auth_attempts')){
            throw Error('Unexpected DELETE '+sql);
          }
          return {meta:{changes:args.length}};
        },
      };
    },
    async batch(statements){
      for(const statement of statements)await statement.run();
    },
  };
  const env={
    DB,
    FILES:{
      async delete(keys){calls.r2++;calls.r2Keys.push(...keys);},
    },
    INBOX_EVENTS:{
      getByName(name){
        assert.equal(name,'owner');
        return {async fetch(url,options){
          calls.events++;
          assert.equal(options.method,'POST');
          assert.equal(new URL(url).pathname,'/internal/inbox-notify');
          return new Response(null,{status:204});
        }};
      },
    },
  };
  await worker.scheduled({},env);
  assert.equal(uploads.size,0);
  assert.equal(parts.size,0);
  assert.equal(sessions.size,0);
  assert.equal(calls.r2,1);
  assert.equal(calls.r2Keys.length,130);
  assert.equal(calls.events,1);
  assert.ok(calls.maxBind<=100,'Cloudflare D1 allows 100 bound variables');
  await worker.scheduled({},env);
  assert.equal(calls.r2,1,'No new R2 request when already clean');
  assert.equal(calls.events,1,'No duplicate deletion event without changes');
});

test('failed R2 cleanup retains D1 records for the retry cron',async()=>{
  const env={
    DB:{
      prepare(sql){
        assert.match(sql,/SELECT id,object_key,upload_id FROM uploads/);
        return {bind(){return this;},async all(){
          return {results:[{id:'item',object_key:'uploads/item',upload_id:null}]};
        }};
      },
    },
    FILES:{async delete(){throw Error('R2 temporarily unavailable');}},
  };
  await assert.rejects(()=>worker.scheduled({},env),/R2 temporarily unavailable/);
});
