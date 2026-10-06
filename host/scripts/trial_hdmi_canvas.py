"""Compare native video and a Canvas mirror of the SAME played HDMI frames.

This reversible display trial does not touch capture constraints, USB, board,
network or power settings. It avoids pixel readback; user-visible remote results
are recorded separately, since local callbacks cannot prove ToDesk delivery.
"""
import argparse
import json
from pathlib import Path
from open_browser import endpoint, page_key
from check_hardware_inputs import linux_hagibis
from playwright.sync_api import sync_playwright


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['canvas','native','remove','status'],default='canvas')
    args=parser.parse_args()
    physical=linux_hagibis()
    with sync_playwright() as p:
        browser=p.chromium.connect_over_cdp(endpoint(),no_defaults=True)
        pages=[pg for c in browser.contexts for pg in c.pages if page_key(pg.url)==page_key('http://127.0.0.1:8765/')]
        if len(pages)!=1:raise RuntimeError(f'Expected one existing workbench; got {len(pages)}')
        page=pages[0]
        result=page.evaluate('''mode => {
          let trial=window.__pangoHdmiCanvasTrial;
          if(mode==='remove'){trial?.stop();return {removed:true};}
          if(mode==='status')return trial?.status()||{installed:false};
          const video=document.getElementById('capture-video');
          if(!video.srcObject?.getVideoTracks()[0])throw Error('Existing capture is closed');
          if(!trial){
            const canvas=document.createElement('canvas');canvas.id='capture-canvas-trial';canvas.width=960;canvas.height=540;
            const ctx=canvas.getContext('2d',{alpha:false});
            if(!ctx)throw Error('Canvas display unavailable');
            canvas.style.zIndex='1';document.getElementById('result-surface').append(canvas);
            const button=document.createElement('button');button.id='capture-canvas-trial-mode';button.className='button small secondary';
            document.querySelector('.hdmi-panel .panel-heading').append(button);
            const baseline=video.srcObject,trackId=baseline.getVideoTracks()[0].id,start=performance.now();
            let callback,ended=false,activeMode,frames=0,cost=0,maxCost=0,last=null,maxGap=0,lastMedia=null;
            function setMode(value){activeMode=value;canvas.style.display=value==='canvas'?'block':'none';
              button.textContent=value==='canvas'?'显示：Canvas（点击切换）':'显示：原生视频（点击切换）';}
            function frame(now,meta){
              if(ended)return;
              // Mirroring the already played video holds source timing constant.
              // No createImageBitmap/getImageData or frame queue is introduced.
              if(video.readyState>=2&&meta.mediaTime!==lastMedia){
                const t=performance.now();ctx.drawImage(video,0,0,canvas.width,canvas.height);
                const dt=performance.now()-t;cost+=dt;maxCost=Math.max(maxCost,dt);frames++;
                if(last!==null)maxGap=Math.max(maxGap,now-last);last=now;lastMedia=meta.mediaTime;
              }
              callback=video.requestVideoFrameCallback(frame);
            }
            button.onclick=()=>setMode(activeMode==='canvas'?'native':'canvas');
            trial=window.__pangoHdmiCanvasTrial={setMode,status(){const elapsed=(performance.now()-start)/1000;
              return {installed:true,mode:activeMode,elapsed,frames,mirrorFps:frames/elapsed,
                meanDrawMs:frames?cost/frames:0,maxDrawMs:maxCost,maxCallbackGapMs:maxGap,
                sameStream:video.srcObject===baseline,sameTrack:video.srcObject?.getVideoTracks()[0]?.id===trackId,
                trackId,settings:video.srcObject?.getVideoTracks()[0]?.getSettings(),
                unverifiedSourceFrame:true,preview:document.getElementById('capture-preview-rate').textContent};},
              stop(){ended=true;video.cancelVideoFrameCallback(callback);canvas.remove();button.remove();delete window.__pangoHdmiCanvasTrial;}};
            callback=video.requestVideoFrameCallback(frame);
          }
          trial.setMode(mode);return trial.status();
        }''',args.mode)
        if args.mode in ('canvas','native'):
            page.wait_for_timeout(3000)
            result=page.evaluate('() => window.__pangoHdmiCanvasTrial.status()')
        folder=Path(__file__).resolve().parents[1]/'reports/hdmi-latency-20261006'
        folder.mkdir(parents=True,exist_ok=True)
        (folder/f'mirror-{args.mode}.json').write_text(json.dumps(dict(device=physical,trial=result),ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
