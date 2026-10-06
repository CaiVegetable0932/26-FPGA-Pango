"""Software pixel fixtures on the existing GPU/browser; never hardware FPS proof."""


def verify_renderer(page):
    """Compare known pixels after worker/GPU/bitmap transfer, including rows."""
    result = page.evaluate("""async () => {
      const fixtures=[],results=[];
      function compact(name,width,height,kind,values){
        const channels=kind==='RGB888'?3:1,expected=[];
        for(let i=0;i<width*height;i++)expected.push(...(channels===3?values.slice(i*3,i*3+3):Array(3).fill(values[i])),255);
        fixtures.push({name,values,expected,mode:channels===3?'color':'raw',
          meta:{width:width*2,height:height*2,row_stride:width*2,pixel_format:'RAW8',bayer_code:4,
            preview_derivative:true,preview_width:width,preview_height:height,
            preview_row_stride:width*channels,preview_pixel_format:kind}});
      }
      // Unequal colors across odd-width rows detect channel swaps, alignment,
      // vertical flips and errors when texture geometry/format changes.
      compact('odd RGB rows',3,2,'RGB888',[255,0,0,0,255,0,0,0,255,17,39,81,254,253,252,1,2,3]);
      compact('all gray levels',16,16,'GRAY8',Array.from({length:256},(_,i)=>i));
      compact('all RGB channels',16,16,'RGB888',Array.from({length:256},(_,i)=>[i,255-i,(i*53)&255]).flat());
      compact('repeat RGB texture',16,16,'RGB888',Array.from({length:256},(_,i)=>[255-i,i,(i*17)&255]).flat());
      for(const [code,values] of [[1,[200,40,60,10]],[2,[40,200,10,60]],[3,[40,10,200,60]],[4,[10,40,60,200]]])
        fixtures.push({name:'Bayer CPU fallback '+code,values,expected:[200,50,10,255],mode:'color',
          meta:{width:2,height:2,row_stride:2,pixel_format:'RAW8',bayer_code:code}});
      fixtures.push({name:'native RAW exact samples',values:[0,127,255,23],
        expected:[0,0,0,255,127,127,127,255,255,255,255,255,23,23,23,255],mode:'raw',
        meta:{width:2,height:2,row_stride:2,pixel_format:'RAW8',bayer_code:0}});
      // Invalid bytes must fail before painting, just as on the byte backend.
      fixtures.push({name:'truncated RGB rejected',values:[1,2],error:true,mode:'color',
        meta:{width:2,height:2,row_stride:2,pixel_format:'RAW8',preview_derivative:true,
          preview_width:1,preview_height:1,preview_row_stride:3,preview_pixel_format:'RGB888'}});
      for(const bitmap of [true,false]){
        const worker=new Worker('/preview-worker.js');worker.postMessage({type:'init-live',bitmap});
        try{
          for(const f of fixtures){
            const r=await new Promise((resolve,reject)=>{
              const timer=setTimeout(()=>reject(Error('Renderer fixture timeout')),5000);
              worker.onmessage=e=>{clearTimeout(timer);resolve(e.data);};
              worker.onerror=e=>{clearTimeout(timer);reject(Error(e.message));};
              const buffer=Uint8Array.from(f.values).buffer;
              worker.postMessage({buffer,meta:f.meta,mode:f.mode,target:'live'},[buffer]);
            });
            let pixels=null,passed=false;
            if(f.error)passed=!!r.error;
            else if(!r.error){
              if(r.bitmap){
                const canvas=document.createElement('canvas');canvas.width=r.width;canvas.height=r.height;
                const ctx=canvas.getContext('2d');ctx.drawImage(r.bitmap,0,0);r.bitmap.close();
                pixels=[...ctx.getImageData(0,0,r.width,r.height).data];
              }else pixels=[...new Uint8Array(r.pixels)];
              passed=pixels.length===f.expected.length&&pixels.every((v,i)=>v===f.expected[i]);
            }
            results.push({name:f.name,bitmap,renderer:r.renderer||'byte-conversion',passed,error:r.error,
              mismatch:passed?null:{expected:f.expected?.slice(0,32),actual:pixels?.slice(0,32)}});
          }
        }finally{worker.terminate();}
      }
      return {scope:'software_fixtures_not_hardware_acceptance',passed:results.every(r=>r.passed),results};
    }""")
    if not result["passed"]:
        raise RuntimeError("GPU/bitmap pixel fidelity check failed: " + str(result))
    return result
