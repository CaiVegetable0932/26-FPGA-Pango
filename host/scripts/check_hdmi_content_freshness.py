"""Compare decoded HDMI content with fresh Ethernet bytes, without remote capture.

Use native I420 CPU copies instead of video/GPU readback. Content correlation
estimates lag only when there is enough scene motion; it never assigns an HDMI
source frame ID or creates validated cross-link frame pairing.
"""
import argparse
import base64
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import time
import numpy as np
from check_hardware_inputs import api,linux_hagibis
from open_browser import endpoint,page_key
from playwright.sync_api import sync_playwright

HOST=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=int,default=12,choices=range(5,21))
    parser.add_argument('--label',default='baseline')
    args=parser.parse_args()
    if not args.label.replace('-','').replace('_','').isalnum():parser.error('label must be simple')
    folder=HOST/'reports/hdmi-latency-20261006';folder.mkdir(parents=True,exist_ok=True)
    capture=HOST/'data/hdmi-latency-20261006'/args.label;capture.mkdir(parents=True,exist_ok=True)
    report=dict(utc=datetime.now(timezone.utc).isoformat(),device=linux_hagibis(),board_before=api('/api/board/status'))
    with sync_playwright() as p:
        browser=p.chromium.connect_over_cdp(endpoint(),no_defaults=True)
        pages=[pg for c in browser.contexts for pg in c.pages if page_key(pg.url)==page_key('http://127.0.0.1:8765/')]
        if len(pages)!=1:raise RuntimeError('Expected one existing workbench')
        page=pages[0]
        result=page.evaluate('''async ({seconds,hostMonoMs,hostEpochMs}) => {
          const track=document.getElementById('capture-video').srcObject?.getVideoTracks()[0];
          if(!track||track.label!=='Hagibis')throw Error('Existing Hagibis track unavailable');
          const processor=new MediaStreamTrackProcessor({track,maxBufferSize:1}),reader=processor.readable.getReader();
          const start=performance.now(),origin=hostMonoMs-(hostEpochMs-performance.timeOrigin);
          let reads=0,lastSample=-Infinity,bytes=null,geometry=null,previousHdmi=null,previousNet=null;
          const samples=[];
          function encoded(data){const parts=[];for(let i=0;i<data.length;i+=32768)parts.push(String.fromCharCode(...data.subarray(i,i+32768)));return btoa(parts.join(''));}
          function grid(data,offset,stride,width,height){
            const out=new Uint8Array(64*36);let k=0;
            for(let y=0;y<36;y++)for(let x=0;x<64;x++){
              const sx=Math.min(width-2,Math.floor((x+.5)*width/64)),sy=Math.min(height-2,Math.floor((y+.5)*height/36)),i=offset+sy*stride+sx;
              out[k++]=(data[i]+data[i+1]+data[i+stride]+data[i+stride+1])>>2;
            }return out;
          }
          try{
            while(performance.now()-start<seconds*1000){
              const {value:frame,done}=await reader.read();if(done)break;reads++;
              let sample=null;
              try{
                const now=performance.now();if(now-lastSample<200)continue;lastSample=now;
                if(frame.format!=='I420'||frame.displayWidth!==1920||frame.displayHeight!==1080)throw Error('Unexpected native frame geometry/format');
                if(!bytes)bytes=new Uint8Array(frame.allocationSize());
                const begin=performance.now(),layout=await frame.copyTo(bytes);
                const copyMs=performance.now()-begin;
                const y=bytes.subarray(layout[0].offset,layout[0].offset+layout[0].stride*frame.codedHeight);
                const digest=new Uint8Array(await crypto.subtle.digest('SHA-256',y));
                const hash=Array.from(digest,x=>x.toString(16).padStart(2,'0')).join('');
                geometry={width:frame.displayWidth,height:frame.displayHeight,codedWidth:frame.codedWidth,codedHeight:frame.codedHeight,format:frame.format,layout};
                sample={time:now-start,hdmiTimestamp:frame.timestamp,hostReferenceAgeMs:origin+now-frame.timestamp/1000,
                  copyMs,hashMs:performance.now()-begin-copyMs,hdmiHash:hash,hdmiSameAsPrevious:previousHdmi===hash,
                  hdmiGrid:encoded(grid(bytes,layout[0].offset,layout[0].stride,frame.displayWidth,frame.displayHeight))};
                previousHdmi=hash;
              }finally{frame.close();}
              // Release the native frame before HTTP to keep the capture pool free.
              if(sample){
                const before=performance.now(),response=await fetch('/api/preview?mode=gray&downscale=2',{cache:'no-store'});
                if(!response.ok)throw Error('Ethernet preview HTTP '+response.status);
                const meta=JSON.parse(response.headers.get('X-Frame-Info')),pixels=new Uint8Array(await response.arrayBuffer());
                if(meta.preview_pixel_format!=='GRAY8'||pixels.length!==meta.preview_width*meta.preview_height)throw Error('Unexpected Ethernet derivative');
                const digest=new Uint8Array(await crypto.subtle.digest('SHA-256',pixels));
                const hash=Array.from(digest,x=>x.toString(16).padStart(2,'0')).join('');
                sample.netHash=hash;sample.netSameAsPrevious=previousNet===hash;previousNet=hash;
                sample.netMeta=meta;sample.netTime=performance.now()-start;sample.netFetchMs=performance.now()-before;
                sample.netGrid=encoded(grid(pixels,0,meta.preview_row_stride,meta.preview_width,meta.preview_height));samples.push(sample);
              }
            }
          }finally{await reader.cancel();reader.releaseLock();}
          // Native evidence is serialized after measurement, outside its timing.
          const response=await fetch('/api/frame',{cache:'no-store'});
          if(!response.ok)throw Error('Native RAW HTTP '+response.status);
          const netMeta=JSON.parse(response.headers.get('X-Frame-Info')),netBytes=new Uint8Array(await response.arrayBuffer());
          return {elapsed:(performance.now()-start)/1000,reads,samples,trackId:track.id,trackState:track.readyState,
            hdmiNative:{...geometry,bytes:encoded(bytes)},netNative:{meta:netMeta,bytes:encoded(netBytes)},
            sourceFramePairing:'unverified',hdmiSourceFrameId:null};
        }''',dict(seconds=args.seconds,hostMonoMs=time.monotonic()*1000,hostEpochMs=time.time()*1000))
    # Preserve untouched received RAW and decoded native I420 with explicit metadata.
    for key,name in [('hdmiNative','hdmi-decoded-i420'),('netNative','ethernet-original')]:
        evidence=result.pop(key);payload=base64.b64decode(evidence.pop('bytes'))
        (capture/(name+'.raw')).write_bytes(payload)
        evidence.update(sha256=hashlib.sha256(payload).hexdigest(),byte_length=len(payload),sourceFramePairing='unverified')
        if key=='hdmiNative':evidence.update(source_frame_id=None,source='browser_decoded_hagibis',resized=False)
        (capture/(name+'.json')).write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
    samples=result['samples'];report['measurement']=result
    if len(samples)<10:raise RuntimeError('Insufficient real content samples')
    hdmi=np.array([np.frombuffer(base64.b64decode(s['hdmiGrid']),np.uint8) for s in samples],dtype=np.float64)
    net=np.array([np.frombuffer(base64.b64decode(s['netGrid']),np.uint8) for s in samples],dtype=np.float64)
    intervals=np.diff([s['time'] for s in samples])/1000
    correlations=[]
    for shift in range(-min(15,len(samples)//3),min(15,len(samples)//3)+1):
        # Positive shifts compare earlier Ethernet content with later HDMI content.
        n,h=(net[:-shift],hdmi[shift:]) if shift>0 else (net[-shift:],hdmi[:shift]) if shift<0 else (net,hdmi)
        n=n-n.mean(axis=0);h=h-h.mean(axis=0)
        denom=np.linalg.norm(n)*np.linalg.norm(h)
        correlations.append(dict(shift=shift,seconds=shift*float(np.median(intervals)),correlation=float(np.sum(n*h)/denom) if denom else None))
    best=max(correlations,key=lambda row:row['correlation'] if row['correlation'] is not None else -2)
    report['summary']=dict(samples=len(samples),sample_interval_median=float(np.median(intervals)),decoded_deliveries=result['reads'],
        hdmi_exact_y_repeats=sum(s['hdmiSameAsPrevious'] for s in samples),net_derivative_repeats=sum(s['netSameAsPrevious'] for s in samples),
        hdmi_unique_y_hashes=len({s['hdmiHash'] for s in samples}),net_unique_hashes=len({s['netHash'] for s in samples}),
        hdmi_grid_motion_mean=float(np.abs(np.diff(hdmi,axis=0)).mean()),net_grid_motion_mean=float(np.abs(np.diff(net,axis=0)).mean()),
        copy_ms_median=float(np.median([s['copyMs'] for s in samples])),hash_ms_median=float(np.median([s['hashMs'] for s in samples])),
        net_fetch_ms_median=float(np.median([s['netFetchMs'] for s in samples])),best_content_lag_candidate=best,
        lag_estimate_valid=bool(best['correlation'] is not None and best['correlation']>.7 and np.abs(np.diff(net,axis=0)).mean()>1),
        validity_limit='Scene motion and temporal correlation only; no source-frame pairing, temperature proof or exact source FPS')
    report['correlations']=correlations;report['board_after']=api('/api/board/status')
    target=folder/('content-'+args.label+'.json');target.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(summary=report['summary'],report=str(target)),ensure_ascii=False,indent=2))


if __name__=='__main__':main()
