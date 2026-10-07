// Purpose: reproduce default fisheye fixed-point mapping offline, then replay
// the SAME full raster through alternative cache indices. This is a transaction
// locality model, not a DDR timing simulator, hardware result, or uploaded map.
// LUT arithmetic mirrors geometry_lens_lut; exact baseline board counters are
// checked before accepting optimization results. All outputs stay in fpga/build.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
const fpga=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2);
const out=path.resolve(args[0]??path.join(fpga,'build','geometry_cache_trace_'+new Date().toISOString().replace(/[:.]/g,'_')));
if(!out.startsWith(path.join(fpga,'build')+path.sep))throw Error('Output must be inside fpga/build');
fs.mkdirSync(out,{recursive:true});
const wordsPath=path.join(fpga,'build/geometry_board_20261006_203737_977/fisheye_words.hex');
const words=fs.readFileSync(wordsPath,'utf8').trim().split(/\s+/).map(s=>BigInt.asIntN(32,BigInt('0x'+s)));
const WIDTH=1920,HEIGHT=1080,ONE=1n<<26n,BASE=0x3000000;
const atan=[52707179,31114864,16440240,8345322,4188854,2096470,1048491,524277,262143,131072,65536,32768,16384,8192,4096,2048,1024,512,256,128,64,32,16,8].map(BigInt);
// Purpose: exact integer root and 24 vectoring CORDIC steps, followed by the
// same fixed-point Horner truncations and restoring-division quotient as RTL.
function isqrt(n){if(n<2n)return n;let x=1n<<BigInt(Math.ceil(n.toString(2).length/2));for(;;){const y=(x+n/x)>>1n;if(y>=x)return x;x=y;}}
const lut=[];
for(let i=0;i<=1024;i++){
 if(i===0){lut.push(ONE);continue;}
 const r=isqrt(BigInt(i)<<47n);let x=ONE,y=r,z=0n;
 for(let k=0;k<24;k++){const sh=BigInt(k),oldx=x;if(y>=0n){x+=y>>sh;y-=oldx>>sh;z+=atan[k];}else{x-=y>>sh;y+=oldx>>sh;z-=atan[k];}}
 const u=(z*z)>>26n,scale=(z<<26n)/r;
 let p=words[9];for(const c of [words[8],words[7],words[6],ONE])p=BigInt.asIntN(40,((p*u)>>26n)+c);
 lut.push(BigInt.asIntN(32,(p*scale)>>26n));
}
const trace=new Uint32Array(WIDTH*HEIGHT);trace.fill(0xffffffff);let valid=0;
for(let oy=0;oy<HEIGHT;oy++)for(let ox=0;ox<WIDTH;ox++){
 const nx=words[0]*BigInt(ox)+words[1]*BigInt(oy)+words[2],ny=words[3]*BigInt(ox)+words[4]*BigInt(oy)+words[5];
 if(nx < -4n*ONE || nx > 4n*ONE || ny < -4n*ONE || ny > 4n*ONE)continue;
 const r2=((nx*nx)>>26n)+((ny*ny)>>26n);if(r2<0n || r2>=32n*ONE)continue;
 const li=Number(r2>>21n),frac=r2&((1n<<21n)-1n),sc=lut[li]+(((lut[li+1]-lut[li])*frac)>>21n);
 const sx=BigInt.asIntN(36,(nx*sc)>>26n),sy=BigInt.asIntN(36,(ny*sc)>>26n);
 const uq=((words[10]*sx)>>30n)+(words[12]>>4n),vq=((words[11]*sy)>>30n)+(words[13]>>4n);
 if(uq<0n || vq<0n || uq>BigInt(WIDTH-1)*4096n || vq>BigInt(HEIGHT-1)*4096n)continue;
 trace[oy*WIDTH+ox]=(Number(uq>>12n)<<12)|Number(vq>>12n);valid++;
}
fs.writeFileSync(path.join(out,'coordinates.u32le'),Buffer.from(trace.buffer));
fs.writeFileSync(path.join(out,'lut.hex'),lut.map(x=>BigInt.asUintN(32,x).toString(16).padStart(8,'0')).join('\n')+'\n');
console.log(JSON.stringify({event:'trace_ready',valid,invalid:trace.length-valid,out}));
// Purpose: collect all hits against a single cache snapshot before any fill,
// exactly matching the window's saved-hit behavior. Repeated words/rows fill
// once; conflicts cannot create extra misses within an already captured window.
function replay(wordsCount,colBits,hash){
 const rowBits=Math.log2(wordsCount)-colBits,cm=(1<<colBits)-1,rm=(1<<rowBits)-1,mask=wordsCount-1;
 const cache=new Int32Array(wordsCount);cache.fill(-1);const needed=new Int32Array(6),slots=new Int32Array(6),missing=new Int32Array(6);
 let hits=0,misses=0,conflictWindows=0;
 for(let p=0;p<trace.length;p++){
  const xy=trace[p];if(xy===0xffffffff)continue;
  const x=xy>>>12,y=xy&4095,l=Math.max(0,x-1)>>>5,r=Math.min(WIDTH-1,x+1)>>>5;
  let count=0,nmiss=0;
  for(let ry=0;ry<3;ry++){
   const sy=ry===0?Math.max(0,y-1):ry===1?y:Math.min(HEIGHT-1,y+1);
   if(ry===1 && y===0 || ry===2 && y===HEIGHT-1)continue;
   for(let cx=0;cx<(l===r?1:2);cx++){
    const wx=cx===0?l:r,tag=(BASE>>>5)+(sy<<6)+wx;
    let slot=((sy&rm)<<colBits)|(wx&cm);
    if(hash==='fold')slot^=((sy>>>rowBits)*13+(wx>>>colBits)*7)&mask;
    if(hash==='rowfold')slot=((sy&rm)<<colBits)|((wx^(sy>>>rowBits))&cm);
    needed[count]=tag;slots[count]=slot;
    if(cache[slot]!==tag)missing[nmiss++]=count;
    count++;
   }
  }
  if(nmiss===0)hits++;
  else{
   let conflicts=false;for(let i=0;i<count;i++)for(let j=0;j<i;j++)if(slots[i]===slots[j])conflicts=true;
   if(conflicts)conflictWindows++;
   misses+=nmiss;for(let i=0;i<nmiss;i++){const j=missing[i];cache[slots[j]]=needed[j];}
  }
 }
 return {words:wordsCount,rows:1<<rowBits,columns:1<<colBits,col_bits:colBits,hash,hits,misses,conflict_windows:conflictWindows};
}
const baseline=replay(256,6,'none');
if(baseline.misses!==375981 || baseline.hits!==1150441)throw Error('Fixed-point/transaction model does not match board baseline: '+JSON.stringify(baseline));
console.log(JSON.stringify({event:'baseline_exact',...baseline}));
const results=[];
for(const wordsCount of [256,512,1024])for(let c=0;c<=6;c++)for(const hash of ['none','rowfold','fold']){
 const result=replay(wordsCount,c,hash);results.push(result);console.log(JSON.stringify(result));
}
results.sort((a,b)=>a.misses-b.misses);
const sources=[wordsPath,path.join(fpga,'rtl/geometry/geometry_map_stream.v'),path.join(fpga,'rtl/geometry/geometry_lens_lut.v'),fileURLToPath(import.meta.url)].map(p=>({path:p,sha256:crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')}));
fs.writeFileSync(path.join(out,'result.json'),JSON.stringify({baseline_exact:true,width:WIDTH,height:HEIGHT,valid,invalid:trace.length-valid,baseline,results,sources,hardware_tested:false,timing_model:false},null,2)+'\n');
console.log('CACHE_TRACE_PASS '+out);
