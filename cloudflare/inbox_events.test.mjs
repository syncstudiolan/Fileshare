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
