"""Compare the same UVC track's latest decoded frames with its native player.

Processor maxBufferSize=1 and immediate frame close avoid application backlog.
Only derivative display is 960x540; native 1920x1080 capture, device ownership,
FPGA/network configuration and source-frame identity remain unchanged.
"""
import argparse
import json
from pathlib import Path
import time
from check_hardware_inputs import linux_hagibis
from open_browser import endpoint,page_key
from playwright.sync_api import sync_playwright


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['latest','native','status','remove'],default='latest')
    args=parser.parse_args()
    device=linux_hagibis()
    with sync_playwright() as p:
        browser=p.chromium.connect_over_cdp(endpoint(),no_defaults=True)
        pages=[pg for c in browser.contexts for pg in c.pages if page_key(pg.url)==page_key('http://127.0.0.1:8765/')]
        if len(pages)!=1:raise RuntimeError('Expected one existing workbench')
        page=pages[0]
        result=page.evaluate('''async ({mode,hostMonoMs,hostEpochMs}) => {
          let trial=window.__pangoHdmiLatestTrial;
          if(mode==='status')return trial?.status()||{installed:false};
          if(mode==='remove'){await trial?.stop();return {removed:true};}
          if(typeof MediaStreamTrackProcessor==='undefined')throw Error('Track processor unavailable');
          const video=document.getElementById('capture-video'),baseline=video.srcObject,track=baseline?.getVideoTracks()[0];
          if(!track||track.label!=='Hagibis')throw Error('Existing Hagibis is not open');
          // Remove only the previous display overlay; preserve the physical stream.
          window.__pangoHdmiCanvasTrial?.stop();
          if(!trial){
            const canvas=document.createElement('canvas');canvas.id='capture-latest-trial';canvas.width=960;canvas.height=540;canvas.style.zIndex='1';
            const ctx=canvas.getContext('2d',{alpha:false});if(!ctx)throw Error('Canvas unavailable');
            document.getElementById('result-surface').append(canvas);
            const button=document.createElement('button');button.id='capture-latest-trial-mode';button.className='button small secondary';
            document.querySelector('.hdmi-panel .panel-heading').append(button);
            const info=document.createElement('p');info.id='capture-latest-trial-info';info.className='capture-health';
            document.getElementById('capture-preview-health').after(info);
            const counter=PangoPreviewRate.createCounter(),monoOrigin=hostMonoMs-(hostEpochMs-performance.timeOrigin);
            let generation=0,reader=null,activeMode='native',frames=0,cost=0,maxCost=0,start=performance.now(),lastTimestamp=null,lastNow=null,
              maxGap=0,age=null,error=null,totalAge=0,ageCount=0;
            function status(){return {installed:true,mode:activeMode,frames,elapsed:(performance.now()-start)/1000,
              updateFps:frames/((performance.now()-start)/1000),meanDrawMs:frames?cost/frames:0,maxDrawMs:maxCost,maxGapMs:maxGap,
              timestamp:lastTimestamp,timestampAgeMs:age,meanTimestampAgeMs:ageCount?totalAge/ageCount:null,
              timestampAgeMeaning:'Conditional host-monotonic reference age, not sensor/HDMI/ToDesk latency',
              sameStream:video.srcObject===baseline,sameTrack:video.srcObject?.getVideoTracks()[0]===track,
              trackId:track.id,trackState:track.readyState,settings:track.getSettings(),error};}
            async function setMode(value){
              const token=++generation,old=reader;reader=null;
              if(old){try{await old.cancel();}catch{}}
              activeMode=value;canvas.style.display=value==='latest'?'block':'none';
              button.textContent=value==='latest'?'显示：最新解码帧（点击切换）':'显示：原生视频（点击切换）';
              counter.reset();
              if(value!=='latest')return;
              const processor=new MediaStreamTrackProcessor({track,maxBufferSize:1}),local=processor.readable.getReader();reader=local;
              async function pump(){
                try{while(token===generation){
                  const {value:frame,done}=await local.read();if(done)break;
                  try{if(token!==generation)continue;
                    // Draw immediately and release native resources. No async
                    // bitmap queue, playback clock, CPU pixel readback or scaling
                    // of the capture itself is involved in this display probe.
                    const now=performance.now();ctx.drawImage(frame,0,0,canvas.width,canvas.height);
                    const dt=performance.now()-now;cost+=dt;maxCost=Math.max(maxCost,dt);
                    if(lastTimestamp!==frame.timestamp){frames++;counter.mark();}
                    if(lastNow!==null)maxGap=Math.max(maxGap,now-lastNow);lastNow=now;lastTimestamp=frame.timestamp;
                    const candidate=monoOrigin+now-frame.timestamp/1000;
                    // Only clocks agreeing within a plausible interval are
                    // compared. A different timestamp origin stays unmeasurable.
                    age=Math.abs(candidate)<10000?candidate:null;
                    if(age!==null){totalAge+=age;ageCount++;}
                  }finally{frame.close();}
                }}catch(e){if(token===generation){error=e.message;info.textContent='最新帧显示失败：'+error;}}
                finally{try{local.releaseLock();}catch{}}
              }
              void pump();
            }
            const timer=setInterval(()=>{const fps=counter.sample();
              info.textContent=activeMode==='latest'?`最新帧对照 ${fps.toFixed(1)} FPS · 平均绘制 ${(frames?cost/frames:0).toFixed(1)} ms · 不使用原生播放器时钟`:'原生视频对照 · 可以点击按钮切回最新解码帧';},1000);
            button.onclick=()=>{void setMode(activeMode==='latest'?'native':'latest');};
            trial=window.__pangoHdmiLatestTrial={setMode,status,async stop(){await setMode('native');clearInterval(timer);canvas.remove();button.remove();info.remove();delete window.__pangoHdmiLatestTrial;}};
          }
          await trial.setMode(mode);return trial.status();
        }''',dict(mode=args.mode,hostMonoMs=time.monotonic()*1000,hostEpochMs=time.time()*1000))
        if args.mode in ('latest','native'):
            page.wait_for_timeout(3500)
            result=page.evaluate('() => window.__pangoHdmiLatestTrial.status()')
        folder=Path(__file__).resolve().parents[1]/'reports/hdmi-latency-20261006';folder.mkdir(parents=True,exist_ok=True)
        (folder/f'direct-{args.mode}.json').write_text(json.dumps(dict(device=device,trial=result),ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
