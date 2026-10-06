/* Manual fish-eye preview: PC software reference, independent of FPGA output
 * and immutable calibration records. Pixel centers follow OpenCV conventions. */
(function(root){
  "use strict";
  const RAD=Math.PI/180,STORAGE_KEY="pango.fisheye-preview.v1",MARKER_COUNT=20;

  // Purpose: keep the operator-reviewed 2026-10-02 screenshot as the default
  // manual preset; these values are not a fitted or FPGA-compatible calibration.
  function preset(name="user-reviewed200",width=1920,height=1080){
    if(name==="user-reviewed200"){
      const sx=width/1920,sy=height/1080;
      return {model:"fisheye_equidistant",reference_width:width,reference_height:height,
        fx:770*sx,fy:752*sy,cx:(945+0.5)*sx-0.5,cy:(553+0.5)*sy-0.5,
        k1:0.121,k2:-0.118,k3:0,k4:0.036,output_fov_deg:139};
    }
    // Generic alternatives retain explicit optical assumptions: 200 degrees
    // is diagonal, and equal-solid-angle is represented by its Taylor series.
    if(!["equidistant200","equidistant180","equisolid200"].includes(name))throw Error("请选择一种预置参数组合");
    const angle=name==="equidistant180"?180:200;
    const solid=name==="equisolid200",half=angle*RAD/2;
    const focal=Math.hypot(width,height)/2/(solid?2*Math.sin(half/2):half);
    return {model:"fisheye_equidistant",reference_width:width,reference_height:height,
      fx:focal,fy:focal,cx:(width-1)/2,cy:(height-1)/2,
      k1:solid?-1/24:0,k2:solid?1/1920:0,k3:solid?-1/322560:0,k4:solid?1/92897280:0,
      output_fov_deg:110};
  }

  // Purpose: reject incomplete/unstable settings before updating either renderer.
  // A positive radial derivative avoids folded sampling inside the output view.
  function normalize(value){
    if(!value||value.model!=="fisheye_equidistant")throw Error("请选择鱼眼 k1～k4 参数，不能导入针孔模型系数");
    const keys=["reference_width","reference_height","fx","fy","cx","cy","k1","k2","k3","k4","output_fov_deg"];
    const p={model:value.model};
    for(const key of keys){
      if(typeof value[key]!=="number"||!Number.isFinite(value[key]))throw Error(key+" 需要完整的有限数值");
      p[key]=value[key];
    }
    for(const key of ["reference_width","reference_height"])
      if(!Number.isInteger(p[key])||p[key]<16||p[key]>8192)throw Error("参数参考尺寸应为 16～8192 的整数");
    if(p.fx<=0||p.fy<=0||Math.max(p.fx,p.fy)>8*Math.max(p.reference_width,p.reference_height))throw Error("fx、fy 必须为正且在可调范围内");
    if(p.cx < -p.reference_width||p.cx>2*p.reference_width||p.cy < -p.reference_height||p.cy>2*p.reference_height)throw Error("主点超出可调范围");
    if([p.k1,p.k2,p.k3,p.k4].some(k=>Math.abs(k)>2))throw Error("畸变系数应在 -2～2 内");
    if(p.output_fov_deg<30||p.output_fov_deg>160)throw Error("输出水平视场应在 30°～160° 内");
    checkDomain(p,p.reference_width,p.reference_height);
    return p;
  }

  // Purpose: check the actual output aspect as well as the reference size;
  // a tall capture can reach rays beyond those tested in the reference format.
  function checkDomain(p,width,height){
    const thetaMax=Math.atan(Math.tan(p.output_fov_deg*RAD/2)*Math.hypot(1,height/width));
    for(let i=0;i<=128;i++){
      const t2=(thetaMax*i/128)**2;
      const derivative=1+t2*(3*p.k1+t2*(5*p.k2+t2*(7*p.k3+t2*9*p.k4)));
      if(derivative<=0)throw Error("当前畸变曲线会折叠；请降低系数幅度或输出视场");
    }
  }

  // Purpose: scale intrinsics only for this explicitly displayed software view.
  // Half-pixel scaling preserves centers; it does not certify capture-card geometry.
  function scaledIntrinsics(p,width,height){
    const sx=width/p.reference_width,sy=height/p.reference_height;
    return {fx:p.fx*sx,fy:p.fy*sy,cx:(p.cx+0.5)*sx-0.5,cy:(p.cy+0.5)*sy-0.5};
  }

  // Purpose: inverse-map an output perspective pixel into source fish-eye pixels.
  // The zero-coefficient fish-eye case remains an equidistant optical projection.
  function sourcePoint(p,width,height,u,v,outWidth=width,outHeight=height){
    const k=scaledIntrinsics(p,width,height),f=outWidth/(2*Math.tan(p.output_fov_deg*RAD/2));
    const x=(u-(outWidth-1)/2)/f,y=(v-(outHeight-1)/2)/f,r=Math.hypot(x,y),theta=Math.atan(r),t2=theta*theta;
    const td=theta*(1+t2*(p.k1+t2*(p.k2+t2*(p.k3+t2*p.k4))));
    const scale=r>1e-12?td/r:1;
    return [k.fx*x*scale+k.cx,k.fy*y*scale+k.cy];
  }

  // Purpose: move an actual source pixel into the perspective output, reversing
  // sourcePoint's radial polynomial over the renderer's monotone ray domain.
  // Cropped rays remain outside: never clamp them into a false correspondence.
  function destinationPoint(p,width,height,u,v,outWidth=width,outHeight=height){
    checkDomain(p,outWidth,outHeight);
    const k=scaledIntrinsics(p,width,height),x=(u-k.cx)/k.fx,y=(v-k.cy)/k.fy,rd=Math.hypot(x,y);
    const thetaMax=Math.atan(Math.tan(p.output_fov_deg*RAD/2)*Math.hypot(1,outHeight/outWidth));
    const distorted=theta=>{const t2=theta*theta;return theta*(1+t2*(p.k1+t2*(p.k2+t2*(p.k3+t2*p.k4))));};
    if(rd>distorted(thetaMax)+1e-12)return {point:null,visible:false,reason:"outside_view"};
    let lo=0,hi=thetaMax;
    for(let i=0;i<64;i++){const mid=(lo+hi)/2;if(distorted(mid)<rd)lo=mid;else hi=mid;}
    const scale=rd>1e-12?Math.tan((lo+hi)/2)/rd:1,f=outWidth/(2*Math.tan(p.output_fov_deg*RAD/2));
    const point=[(outWidth-1)/2+f*x*scale,(outHeight-1)/2+f*y*scale];
    const visible=point[0]>=-1e-8&&point[1]>=-1e-8&&point[0]<=outWidth-1+1e-8&&point[1]<=outHeight-1+1e-8;
    return {point,visible,reason:visible?"":"outside_view"};
  }

  // Purpose: sample integer source pixels on corners, central axes and both
  // diagonals. Keep the first thirteen anchors stable, then add four inner
  // cross-axis pixels and three inner diagonal pixels for twenty references.
  // Each link retains its own geometry, without claiming source-frame pairing.
  function markerPixels(width,height){
    if(!Number.isInteger(width)||!Number.isInteger(height)||width<16||height<16)throw Error("像素标记需要有效的原图尺寸");
    const right=width-1,bottom=height-1,cx=Math.round(right/2),cy=Math.round(bottom/2);
    const qx=Math.round(right/4),qy=Math.round(bottom/4),tx=Math.round(right/3),ty=Math.round(bottom/3);
    const points=[[0,0],[right,0],[right,bottom],[0,bottom],
      [cx,0],[right,cy],[cx,bottom],[0,cy],[cx,cy],
      [qx,qy],[right-qx,bottom-qy],[right-qx,qy],[qx,bottom-qy],
      [qx,cy],[right-qx,cy],[cx,qy],[cx,bottom-qy],
      [tx,ty],[right-tx,bottom-ty],[right-tx,ty]];
    const colors=["#ff3864","#00e5ff","#ffe600","#58ff42","#ff52ef","#ff8b18","#7d9cff",
      "#00ffb3","#ffffff","#ff4040","#22dfff","#eeff00","#ff65ed",
      "#ffb000","#00ff74","#bf80ff","#ff734d","#00ffff","#dfff00","#ff70c8"];
    return points.map((point,index)=>({id:index+1,point,color:colors[index]}));
  }

  // Purpose: layer screen-sized markers above pixels without drawing into any
  // image/capture buffer. Resize geometry is cached; unchanged frame geometry
  // does no layout or DOM work, and letterboxing shares object-fit:contain.
  function createPixelOverlay({element,container=element.parentElement,environment=root,onChange=()=>{}}){
    const doc=environment.document;
    let enabled=false,view=null,key="",points=[],bounds={width:0,height:0},disposed=false;
    function state(){return {enabled,ready:!!view,corrected:!!view?.parameters,total:points.length,
      visible:points.filter(p=>p.visible).length,outside:points.filter(p=>!p.visible).map(p=>p.id),points};}
    function draw(){
      if(disposed)return;
      element.hidden=!enabled||!view||bounds.width<=0||bounds.height<=0;
      // SVGElement does not reflect an assigned .hidden property like HTML
      // elements do. Update the attribute used by CSS, or markers stay hidden.
      element.toggleAttribute?.("hidden",element.hidden);
      if(element.hidden){element.replaceChildren();onChange(state());return;}
      const {width,height}=view,scale=Math.min(bounds.width/width,bounds.height/height);
      const ox=(bounds.width-width*scale)/2,oy=(bounds.height-height*scale)/2;
      element.setAttribute("viewBox",`0 0 ${bounds.width} ${bounds.height}`);
      const nodes=[];
      for(const p of points){
        if(!p.visible)continue;
        const x=ox+(p.output[0]+.5)*scale,y=oy+(p.output[1]+.5)*scale;
        const group=doc.createElementNS("http://www.w3.org/2000/svg","g");
        group.dataset.pixelId=String(p.id);group.dataset.source=JSON.stringify(p.point);group.dataset.output=JSON.stringify(p.output);
        const circle=doc.createElementNS("http://www.w3.org/2000/svg","circle");
        for(const [name,value] of Object.entries({cx:x,cy:y,r:5,fill:p.color,stroke:"#101010","stroke-width":2}))circle.setAttribute(name,String(value));
        const label=doc.createElementNS("http://www.w3.org/2000/svg","text");
        const end=x>bounds.width/2;
        for(const [name,value] of Object.entries({x:x+(end?-9:9),y:y<20?y+16:y-9,fill:p.color,"text-anchor":end?"end":"start"}))label.setAttribute(name,String(value));
        label.textContent=String(p.id);group.append(circle,label);nodes.push(group);
      }
      element.replaceChildren(...nodes);element.dataset.coordinates=JSON.stringify(points);onChange(state());
    }
    function resize(rect){if(rect.width===bounds.width&&rect.height===bounds.height)return;
      bounds={width:rect.width,height:rect.height};draw();}
    function measure(){resize(container.getBoundingClientRect?.()||{width:0,height:0});}
    const observer=typeof environment.ResizeObserver==="function"?new environment.ResizeObserver(entries=>resize(entries[0].contentRect)):null;
    observer?.observe(container);if(!observer)environment.addEventListener?.("resize",measure);measure();
    return {getState:state,
      setEnabled(value){if(enabled===!!value)return;enabled=!!value;draw();},
      setView(value){
        const next=JSON.stringify(value);if(disposed||next===key)return;key=next;view=value;points=[];
        if(view){
          const sourceWidth=view.sourceWidth||view.width,sourceHeight=view.sourceHeight||view.height;
          points=markerPixels(sourceWidth,sourceHeight).map(p=>{
            const mapped=view.parameters?destinationPoint(view.parameters,sourceWidth,sourceHeight,...p.point,view.width,view.height):
              {point:[(p.point[0]+.5)*view.width/sourceWidth-.5,(p.point[1]+.5)*view.height/sourceHeight-.5],visible:true};
            return {...p,output:mapped.point,visible:mapped.visible};
          });
        }
        draw();
      },
      destroy(){disposed=true;observer?.disconnect();if(!observer)environment.removeEventListener?.("resize",measure);element.replaceChildren();element.hidden=true;element.toggleAttribute?.("hidden",true);}
    };
  }

  // Purpose: one visible control toggles all reference overlays; the preference
  // also follows same-origin calibration tabs, without opening media devices.
  function createMarkerToggle({button,info,overlays,storage=null,environment=root}){
    const key="pango.pixel-markers.visible.v1";
    let enabled=false;try{enabled=storage?.getItem(key)==="1";}catch{}
    function updateInfo(){
      const corrected=overlays.map(o=>o.getState()).find(s=>s.ready&&s.corrected);
      info.textContent=!enabled?"标记已隐藏 · 可观察原图像素的矫正映射":
        `${MARKER_COUNT} 个代表像素 · 编号与颜色对应`+(corrected?` · 矫正视野内 ${corrected.visible}/${MARKER_COUNT}`+
          (corrected.outside.length?` · 视野外：${corrected.outside.join("、")}`:""):"");
    }
    function apply(){button.textContent=enabled?"隐藏像素标记":"显示像素标记";button.setAttribute("aria-pressed",String(enabled));
      for(const overlay of overlays)overlay.setEnabled(enabled);updateInfo();}
    function click(){enabled=!enabled;try{storage?.setItem(key,enabled?"1":"0");}catch{}apply();}
    function changed(event){if(event.key!==key&&event.key!==null)return;
      try{enabled=storage?.getItem(key)==="1";}catch{enabled=false;}apply();}
    button.addEventListener("click",click);environment.addEventListener?.("storage",changed);apply();
    return {updateInfo,destroy(){button.removeEventListener("click",click);environment.removeEventListener?.("storage",changed);}};
  }

  // Purpose: calibration and the HDMI display restore exactly the same manual
  // parameters. An absent/unreadable setting uses the reviewed default in both;
  // callers can disclose fallback instead of claiming a fitted calibration.
  function loadSettings(storage){
    try{
      const saved=JSON.parse(storage?.getItem(STORAGE_KEY)||"null");
      if(saved?.schema===STORAGE_KEY)return {parameters:normalize(saved.parameters),origin:"calibration",error:""};
      if(saved)throw Error("已保存的矫正参数格式不兼容");
    }catch(error){return {parameters:normalize(preset()),origin:"default",error:error.message};}
    return {parameters:normalize(preset()),origin:"default",error:""};
  }

  // Purpose: upload existing video directly and correct with a GPU fragment
  // shader. Live views discard the drawing buffer after composition; static
  // calibration/frozen views preserve it for subsequent exports/readback.
  function createRenderer(canvas,{live=false}={}){
    const gl=canvas.getContext("webgl",{alpha:false,antialias:false,depth:false,stencil:false,
      powerPreference:"high-performance",preserveDrawingBuffer:!live});
    if(!gl)return createCpuRenderer(canvas);
    const vertex="attribute vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}";
    const fragment=`precision highp float;
      uniform sampler2D source; uniform vec2 inputSize; uniform vec2 outputSize;
      uniform vec4 intrinsics; uniform vec4 distortion; uniform float focal;
      void main(){
        vec2 pixel=vec2(gl_FragCoord.x,outputSize.y-gl_FragCoord.y)-0.5;
        vec2 q=(pixel-(outputSize-1.0)*0.5)/focal;
        float radius=length(q); float theta=atan(radius); float t2=theta*theta;
        float td=theta*(1.0+t2*(distortion.x+t2*(distortion.y+t2*(distortion.z+t2*distortion.w))));
        float scale=radius>0.0000001?td/radius:1.0;
        vec2 src=intrinsics.xy*q*scale+intrinsics.zw;
        if(any(lessThan(src,vec2(0.0)))||any(greaterThan(src,inputSize-1.0)))gl_FragColor=vec4(0.0,0.0,0.0,1.0);
        else gl_FragColor=vec4(texture2D(source,(src+0.5)/inputSize).rgb,1.0);
      }`;
    function compile(type,text){
      const shader=gl.createShader(type);gl.shaderSource(shader,text);gl.compileShader(shader);
      if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS)){const error=gl.getShaderInfoLog(shader);gl.deleteShader(shader);throw Error("预览着色器编译失败："+error);}
      return shader;
    }
    const program=gl.createProgram(),vs=compile(gl.VERTEX_SHADER,vertex),fs=compile(gl.FRAGMENT_SHADER,fragment);
    gl.attachShader(program,vs);gl.attachShader(program,fs);gl.linkProgram(program);gl.deleteShader(vs);gl.deleteShader(fs);
    if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error("预览着色器链接失败");
    gl.useProgram(program);
    const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);
    const pos=gl.getAttribLocation(program,"position");gl.enableVertexAttribArray(pos);gl.vertexAttribPointer(pos,2,gl.FLOAT,false,0,0);
    const texture=gl.createTexture();gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,texture);
    for(const wrap of [gl.TEXTURE_WRAP_S,gl.TEXTURE_WRAP_T])gl.texParameteri(gl.TEXTURE_2D,wrap,gl.CLAMP_TO_EDGE);
    for(const filter of [gl.TEXTURE_MIN_FILTER,gl.TEXTURE_MAG_FILTER])gl.texParameteri(gl.TEXTURE_2D,filter,gl.LINEAR);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,false);gl.uniform1i(gl.getUniformLocation(program,"source"),0);
    const loc=Object.fromEntries(["inputSize","outputSize","intrinsics","distortion","focal"].map(key=>[key,gl.getUniformLocation(program,key)]));
    // Limits, identity and geometry are read only at setup/change, avoiding
    // synchronous GL queries and repeated uniform writes in the frame loop.
    const maxTextureSize=gl.getParameter(gl.MAX_TEXTURE_SIZE),debug=gl.getExtension("WEBGL_debug_renderer_info");
    const backend=debug?gl.getParameter(debug.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER);
    const nvidia=/NVIDIA/i.test(backend)&&!/(SwiftShader|llvmpipe|software)/i.test(backend);
    let geometryKey="",textureWidth=0,textureHeight=0;
    return {kind:nvidia?"NVIDIA GPU / WebGL":"WebGL",backend,maxFps:60,
      render(source,p){
        if(gl.isContextLost())throw Error("GPU 预览上下文已丢失，请刷新页面");
        // HTMLVideoElement uploads reuse the existing HDMI stream directly;
        // canvas inputs from calibration retain the identical geometry/math.
        const width=source.videoWidth||source.width,height=source.videoHeight||source.height;
        const key=JSON.stringify([width,height,p]);
        if(key!==geometryKey){
          checkDomain(p,width,height);
          if(width>maxTextureSize||height>maxTextureSize)throw Error("输入尺寸超过 GPU 纹理限制");
          const k=scaledIntrinsics(p,width,height);
          if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
          gl.viewport(0,0,width,height);gl.useProgram(program);
          gl.uniform2f(loc.inputSize,width,height);gl.uniform2f(loc.outputSize,width,height);
          gl.uniform4f(loc.intrinsics,k.fx,k.fy,k.cx,k.cy);gl.uniform4f(loc.distortion,p.k1,p.k2,p.k3,p.k4);
          gl.uniform1f(loc.focal,width/(2*Math.tan(p.output_fov_deg*RAD/2)));geometryKey=key;
        }
        // Chrome's video texImage2D path is markedly faster on this Jetson
        // than video texSubImage2D (measured separately). Retain that direct
        // video import; canvas samples still reuse allocated texture storage.
        if(source.nodeName==="VIDEO"||width!==textureWidth||height!==textureHeight){
          gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,source);
          textureWidth=width;textureHeight=height;
        }else gl.texSubImage2D(gl.TEXTURE_2D,0,0,0,gl.RGBA,gl.UNSIGNED_BYTE,source);
        gl.drawArrays(gl.TRIANGLE_STRIP,0,4);
      },
      clear(){gl.clearColor(0,0,0,1);gl.clear(gl.COLOR_BUFFER_BIT);},
      dispose(){gl.deleteTexture(texture);gl.deleteBuffer(buffer);gl.deleteProgram(program);}};
  }

  // Purpose: retain a usable reference preview when WebGL is unavailable.
  // Cached coordinates and a 640px-wide output bound CPU work and stay labelled.
  function createCpuRenderer(canvas){
    const context=canvas.getContext("2d"),cache={key:"",points:null};
    let input=null;
    if(!context)throw Error("当前浏览器无法创建图像预览");
    return {kind:"CPU（预览最大宽度 640）",maxFps:8,
      render(source,p){
        // Only the CPU fallback copies video pixels to an intermediate canvas.
        // Source dimensions stay native; the reference output is bounded to 640.
        const sourceWidth=source.videoWidth||source.width,sourceHeight=source.videoHeight||source.height;
        let sourceContext=source.getContext?.("2d");
        if(!sourceContext){
          input ||= canvas.ownerDocument.createElement("canvas");
          if(input.width!==sourceWidth||input.height!==sourceHeight){input.width=sourceWidth;input.height=sourceHeight;}
          sourceContext=input.getContext("2d",{willReadFrequently:true});
          sourceContext.drawImage(source,0,0,sourceWidth,sourceHeight);
        }
        const width=Math.min(640,sourceWidth),height=Math.round(sourceHeight*width/sourceWidth);
        checkDomain(p,width,height);
        if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
        const key=JSON.stringify([p,sourceWidth,sourceHeight,width,height]);
        if(cache.key!==key){
          cache.points=new Float32Array(width*height*2);
          for(let y=0;y<height;y++)for(let x=0;x<width;x++)cache.points.set(sourcePoint(p,sourceWidth,sourceHeight,x,y,width,height),2*(y*width+x));
          cache.key=key;
        }
        const pixels=sourceContext.getImageData(0,0,sourceWidth,sourceHeight).data,result=context.createImageData(width,height);
        for(let i=0;i<width*height;i++){
          const sx=cache.points[2*i],sy=cache.points[2*i+1],offset=i*4;result.data[offset+3]=255;
          if(sx<0||sy<0||sx>sourceWidth-1||sy>sourceHeight-1)continue;
          const x=Math.floor(sx),y=Math.floor(sy),ax=sx-x,ay=sy-y;
          const a=4*(y*sourceWidth+x),b=4*(y*sourceWidth+Math.min(x+1,sourceWidth-1));
          const c=4*(Math.min(y+1,sourceHeight-1)*sourceWidth+x),d=4*(Math.min(y+1,sourceHeight-1)*sourceWidth+Math.min(x+1,sourceWidth-1));
          for(let channel=0;channel<3;channel++)result.data[offset+channel]=(pixels[a+channel]*(1-ax)+pixels[b+channel]*ax)*(1-ay)+(pixels[c+channel]*(1-ax)+pixels[d+channel]*ax)*ay;
        }
        context.putImageData(result,0,0);
      },clear(){context.clearRect(0,0,canvas.width,canvas.height);},dispose(){cache.points=null;input=null;}};
  }

  // Purpose: expose only manual reference settings in downloads and browser
  // storage; never claim FPGA compatibility, paired identity or calibrated truth.
  function exportSettings(p){
    return {schema:STORAGE_KEY,parameters:normalize(p),
      parameters_origin:"manual_approximate",processing_location:"pc_software_reference",
      fpga_compatible:false,source_frame_id:null,pairing_status:"unverified"};
  }
  const api={STORAGE_KEY,MARKER_COUNT,preset,normalize,scaledIntrinsics,sourcePoint,destinationPoint,markerPixels,
    createPixelOverlay,createMarkerToggle,createRenderer,exportSettings,loadSettings};
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
  root.PangoFisheyePreview=api;
})(typeof globalThis!=="undefined"?globalThis:this);
