/* Minimal existing-tab CDP probe. Never enable Network: RAW WebSocket payload
   tracing can add large base64 traffic and distort the performance being measured. */
"use strict";
const fs=require('node:fs'),path=require('node:path'),readline=require('node:readline');
const profile=path.resolve(__dirname,'../build/environment/browser-profile/DevToolsActivePort');
async function main(){
  const [port,nonce]=fs.readFileSync(profile,'utf8').trim().split(/\r?\n/);
  if(!/^\d+$/.test(port)||Number(port)<1||Number(port)>65535||!nonce.startsWith('/devtools/browser/'))throw Error('Invalid project browser endpoint');
  const version=await (await fetch('http://127.0.0.1:'+port+'/json/version',{signal:AbortSignal.timeout(5000)})).json();
  const address='ws://127.0.0.1:'+port+nonce;
  if(version.webSocketDebuggerUrl!==address)throw Error('Browser nonce mismatch');
  const ws=new WebSocket(address),pending=new Map();let sequence=0,ready=false;
  ws.addEventListener('message',event=>{
    const value=JSON.parse(event.data);
    if(ready&&value.method==='Runtime.exceptionThrown'){
      const detail=value.params.exceptionDetails;
      process.stdout.write(JSON.stringify({event:'pageerror',message:detail.exception?.description||detail.text})+'\n');return;
    }
    const entry=pending.get(value.id);if(!entry)return;
    pending.delete(value.id);clearTimeout(entry.timer);
    if(value.error)entry.reject(Error(value.error.message));else entry.resolve(value.result);
  });
  await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
  function rpc(method,params={},sessionId){
    return new Promise((resolve,reject)=>{
      const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout: '+method));},6000);
      pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));
    });
  }
  const {targetInfos}=await rpc('Target.getTargets');
  const target=targetInfos.find(t=>t.type==='page'&&/^http:\/\/127\.0\.0\.1:8765\/(?:index\.html)?(?:#.*)?$/.test(t.url));
  if(!target)throw Error('Existing workbench page is required');
  const {sessionId}=await rpc('Target.attachToTarget',{targetId:target.targetId,flatten:true});
  // Runtime exceptions are small. Network tracing remains deliberately off.
  await rpc('Runtime.enable',{},sessionId);ready=true;
  process.stdout.write(JSON.stringify({ready:true,network_monitoring:false})+'\n');
  // Serialize stdin commands. Responses contain only explicitly requested UI
  // state; no browser launch, defaults, recording or tab closing is performed.
  const input=readline.createInterface({input:process.stdin});
  for await(const line of input){
    let command;
    try{
      command=JSON.parse(line);
      if(command.method==='SystemInfo.getInfo'){
        const value=await rpc(command.method);process.stdout.write(JSON.stringify({id:command.id,value})+'\n');continue;
      }
      if(['Page.reload','Page.captureScreenshot'].includes(command.method)){
        const value=await rpc(command.method,command.params||{},sessionId);
        process.stdout.write(JSON.stringify({id:command.id,value})+'\n');continue;
      }
      const result=await rpc('Runtime.evaluate',{expression:command.expression,
        returnByValue:true,awaitPromise:true,timeout:3000},sessionId);
      if(result.exceptionDetails)throw Error(result.exceptionDetails.exception?.description||result.exceptionDetails.text);
      process.stdout.write(JSON.stringify({id:command.id,value:result.result.value})+'\n');
    }catch(error){process.stdout.write(JSON.stringify({id:command?.id,error:String(error.message||error)})+'\n');}
  }
  await rpc('Target.detachFromTarget',{sessionId});ws.close();
}
main().catch(error=>{console.error(error.message);process.exit(1);});
