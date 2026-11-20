import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.js';

const origin='https://owner.example.workers.dev';
const token='test-owner-secret';
function setup(){
  const file={
    id:'9ae98c0a-335e-41a7-9ab4-8a733478f3e0',
    sender_id:'senderDevice12345',
    sender_name:'Windows PC',
    name:'report.pdf',size:123,
    object_key:'device-transfers/file',
    upload_id:null,completed:1,
    received_at:null,received_by:null,
    created_at:Date.now()-500,expires_at:Date.now()+500000,
  };
  let events=0;
  const env={
    OWNER_TOKEN:token,
    FILES:{async get(){return {body:new ReadableStream()};}},
    DB:{
      prepare(sql){
        return {
          bind(...args){this.args=args;return this;},
          async first(){
            if(sql.includes('FROM device_transfers WHERE id=?'))return file;
            return null;
          },
          async all(){
            if(sql.includes('FROM device_transfers'))return {results:[{
              id:file.id,sender_id:file.sender_id,sender_name:file.sender_name,
              size:file.size,name:file.name,created_at:file.created_at,
              expires_at:file.expires_at,received_at:file.received_at,
              received_by:file.received_by,
            }]};
            return {results:[]};
          },
          async run(){
            if(sql.includes('UPDATE device_transfers SET received_at')){
              const [date,receiver,id]=this.args;
              assert.equal(id,file.id);
              if(file.received_at)return {meta:{changes:0}};
              file.received_at=date;file.received_by=receiver;
              return {meta:{changes:1}};
            }
            throw Error('Unexpected DB write: '+sql);
          }
        };
      }
    },
    INBOX_EVENTS:{getByName(){return {async fetch(){events++;return new Response(null,{status:204});}};}}
  };
  return {file,env,events:()=>events};
}
const call=(path,env,opts={})=>worker.fetch(new Request(origin+path,{
  ...opts,headers:{Authorization:'Bearer '+token,...opts.headers},
}),env);

test('upload complete is one tick, different receiver acknowledgement is double',async()=>{
  const {file,env,events}=setup();
  const list1=await (await call('/v1/owner/transfers',env)).json();
  assert.equal(list1.files[0].received_at,null);
  const self=await call('/v1/owner/transfer/'+file.id+'/received',env,{
    method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({deviceId:file.sender_id}),
  });
  assert.equal(self.status,400);
  assert.equal(events(),0);
  const recipient=await call('/v1/owner/transfer/'+file.id+'/received',env,{
    method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({deviceId:'receiverDevice54321'}),
  });
  assert.equal(recipient.status,200);
  const list2=await (await call('/v1/owner/transfers',env)).json();
  assert.ok(list2.files[0].received_at>0);
  assert.equal(list2.files[0].received_by,'receiverDevice54321');
  assert.equal(events(),1);
  const repeat=await call('/v1/owner/transfer/'+file.id+'/received',env,{
    method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({deviceId:'receiverDevice54321'}),
  });
  assert.equal(repeat.status,200);
  assert.equal(events(),1,'duplicate delivery receipt must not emit more signals');
});
