"""Inspect existing UVC/desktop display without changing device or board state."""
import json
from pathlib import Path
from open_browser import endpoint, page_key
from check_hardware_inputs import api, linux_hagibis
from playwright.sync_api import sync_playwright

folder=Path(__file__).resolve().parents[1]/'reports/hdmi-latency-20261006'
folder.mkdir(parents=True,exist_ok=True)
with sync_playwright() as p:
    browser=p.chromium.connect_over_cdp(endpoint(),no_defaults=True)
    pages=[pg for c in browser.contexts for pg in c.pages if page_key(pg.url)==page_key('http://127.0.0.1:8765/')]
    if len(pages)!=1:
        raise RuntimeError(f'Expected exactly one existing workbench; got {len(pages)}')
    page=pages[0]
    system=browser.new_browser_cdp_session().send('SystemInfo.getInfo')
    result=dict(device=linux_hagibis(),board=api('/api/board/status'),gpu=system['gpu'])
    result['page']=page.evaluate('''async () => {
      const v=document.getElementById('capture-video'),t=v.srcObject?.getVideoTracks()[0];
      if(!t)throw Error('Existing HDMI stream is closed');
      const processorAvailable=typeof MediaStreamTrackProcessor!=='undefined';
      let processorProbe=null;
      if(processorAvailable){
        const processor=new MediaStreamTrackProcessor({track:t,maxBufferSize:1}),reader=processor.readable.getReader();
        const times=[],start=performance.now();let previous=null;
        try {
          for(let i=0;i<30;i++){
            const {value,done}=await reader.read();if(done)break;
            const now=performance.now();times.push({received:now-start,timestamp:value.timestamp,format:value.format,width:value.displayWidth,height:value.displayHeight});
            value.close();
          }
        }finally{await reader.cancel();reader.releaseLock();}
        processorProbe={elapsed:performance.now()-start,frames:times};
      }
      return {track:{id:t.id,label:t.label,settings:t.getSettings(),capabilities:t.getCapabilities(),constraints:t.getConstraints()},
        processorAvailable,processorProbe,offscreen:typeof OffscreenCanvas,videoFrame:typeof VideoFrame,
        video:{currentTime:v.currentTime,readyState:v.readyState,paused:v.paused,quality:v.getVideoPlaybackQuality().toJSON?.()||{total:v.getVideoPlaybackQuality().totalVideoFrames,dropped:v.getVideoPlaybackQuality().droppedVideoFrames}},
        preview:document.getElementById('capture-preview-rate').dataset.measurement,visibility:document.visibilityState};
    }''')
(folder/'browser-probe.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(dict(page=result['page'],gpu=result['gpu'].get('featureStatus'),report=str(folder/'browser-probe.json')),ensure_ascii=False,indent=2))
