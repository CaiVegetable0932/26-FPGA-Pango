/* Pure pixel conversion: also exercised by Node tests; no browser state. */
(function(root){
  "use strict";
  function renderPixels(buffer, meta, mode="color", options={}){
    const input=new Uint8Array(buffer), w=meta.width, h=meta.height;
    if(!Number.isInteger(w)||!Number.isInteger(h)||w<1||h<1||input.length>8388608) throw Error("非法图像尺寸");
    const rgb=meta.pixel_format==="RGB888", raw=meta.pixel_format==="RAW8";
    if(!rgb&&!raw) throw Error("不支持的像素格式");
    if(input.length!==w*h*(rgb?3:1)||meta.row_stride!==w*(rgb?3:1)) throw Error("图像字节不完整");
    // Purpose: retain an exact one-sample RAW view at native display size.
    // When the browser must shrink Bayer pixels, prefilter one complete 2x2
    // sensor cell so CSS scaling cannot alias alternating color phases into
    // false dark dots. This changes only the preview, never received bytes.
    // The FPGA display curve is not applied again on the host.
    if(!["color","gray","raw"].includes(mode)) throw Error("不支持的预览模式");
    const color=raw&&mode==="color", exactRaw=raw&&mode==="raw";
    if(color&&(w<2||h<2)) throw Error("Bayer预览至少需要一个2×2色块");
    const displayWidth=options.displayWidth;
    const filteredRaw=exactRaw&&Number.isFinite(displayWidth)&&displayWidth>0&&displayWidth<w&&w>=2&&h>=2;
    const step=filteredRaw?2:exactRaw?Math.max(1,Math.ceil(w/1920)):
      color?Math.max(2,2*Math.ceil(w/1920)):Math.max(1,Math.ceil(w/960));
    const width=Math.floor(w/step), height=Math.max(1,Math.floor(h/step));
    if(!width||!height) throw Error("图像不足以生成预览");
    const output=new Uint8ClampedArray(width*height*4);
    const layout={1:[0,1,2,3],2:[1,0,3,2],3:[2,0,3,1],4:[3,1,2,0]}[meta.bayer_code];
    if(color&&!layout) throw Error("Bayer排列未确认");
    for(let y=0;y<height;y++){
      for(let x=0;x<width;x++){
        const source=y*step*w+x*step, dest=(y*width+x)*4;
        let r,g,b;
        if(color){
          const values=[input[source],input[source+1],input[source+w],input[source+w+1]];
          r=values[layout[0]]; g=(values[layout[1]]+values[layout[2]])>>1; b=values[layout[3]];
        }else if(rgb){
          r=input[source*3];g=input[source*3+1];b=input[source*3+2];
          if(mode==="gray") r=g=b=Math.round((r*77+g*150+b*29)/256);
        }else{
          // Purpose: anti-alias only reduced-size displays; full-size RAW
          // inspection still maps each received byte to one grayscale pixel.
          r=input[source];
          if((filteredRaw||!exactRaw)&&step>=2&&x*step+1<w&&y*step+1<h) r=(r+input[source+1]+input[source+w]+input[source+w+1])>>2;
          g=b=r;
        }
        output[dest]=r;output[dest+1]=g;output[dest+2]=b;output[dest+3]=255;
      }
    }
    return {width,height,pixels:output.buffer};
  }
  root.PangoPixels={renderPixels};
  if(typeof module!=="undefined") module.exports=root.PangoPixels;
})(typeof self!=="undefined"?self:globalThis);
