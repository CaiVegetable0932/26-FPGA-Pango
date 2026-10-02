/* Manual fish-eye preview: PC software reference, independent of FPGA output
 * and immutable calibration records. Pixel centers follow OpenCV conventions. */
(function(root){
  "use strict";
  const RAD=Math.PI/180;

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

  // Purpose: use GPU bilinear sampling to keep live tuning responsive without
  // sending video to a Python remap endpoint or changing the main video route.
  function createRenderer(canvas){
    const gl=canvas.getContext("webgl",{alpha:false,antialias:false,preserveDrawingBuffer:true});
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
    return {kind:"WebGL",maxFps:20,
      render(source,p){
        if(gl.isContextLost())throw Error("GPU 预览上下文已丢失，请刷新页面");
        const width=source.width,height=source.height,k=scaledIntrinsics(p,width,height);
        checkDomain(p,width,height);
        if(width>gl.getParameter(gl.MAX_TEXTURE_SIZE)||height>gl.getParameter(gl.MAX_TEXTURE_SIZE))throw Error("输入尺寸超过 GPU 纹理限制");
        if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
        gl.viewport(0,0,width,height);gl.useProgram(program);
        gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,source);
        gl.uniform2f(loc.inputSize,width,height);gl.uniform2f(loc.outputSize,width,height);
        gl.uniform4f(loc.intrinsics,k.fx,k.fy,k.cx,k.cy);gl.uniform4f(loc.distortion,p.k1,p.k2,p.k3,p.k4);
        gl.uniform1f(loc.focal,width/(2*Math.tan(p.output_fov_deg*RAD/2)));gl.drawArrays(gl.TRIANGLE_STRIP,0,4);
      },
      clear(){gl.clearColor(0,0,0,1);gl.clear(gl.COLOR_BUFFER_BIT);},
      dispose(){gl.deleteTexture(texture);gl.deleteBuffer(buffer);gl.deleteProgram(program);}};
  }

  // Purpose: retain a usable reference preview when WebGL is unavailable.
  // Cached coordinates and a 640px-wide output bound CPU work and stay labelled.
  function createCpuRenderer(canvas){
    const context=canvas.getContext("2d"),cache={key:"",points:null};
    if(!context)throw Error("当前浏览器无法创建图像预览");
    return {kind:"CPU（预览最大宽度 640）",maxFps:8,
      render(source,p){
        const width=Math.min(640,source.width),height=Math.round(source.height*width/source.width);
        checkDomain(p,width,height);
        if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
        const key=JSON.stringify([p,source.width,source.height,width,height]);
        if(cache.key!==key){
          cache.points=new Float32Array(width*height*2);
          for(let y=0;y<height;y++)for(let x=0;x<width;x++)cache.points.set(sourcePoint(p,source.width,source.height,x,y,width,height),2*(y*width+x));
          cache.key=key;
        }
        const pixels=source.getContext("2d").getImageData(0,0,source.width,source.height).data,result=context.createImageData(width,height);
        for(let i=0;i<width*height;i++){
          const sx=cache.points[2*i],sy=cache.points[2*i+1],offset=i*4;result.data[offset+3]=255;
          if(sx<0||sy<0||sx>source.width-1||sy>source.height-1)continue;
          const x=Math.floor(sx),y=Math.floor(sy),ax=sx-x,ay=sy-y;
          const a=4*(y*source.width+x),b=4*(y*source.width+Math.min(x+1,source.width-1));
          const c=4*(Math.min(y+1,source.height-1)*source.width+x),d=4*(Math.min(y+1,source.height-1)*source.width+Math.min(x+1,source.width-1));
          for(let channel=0;channel<3;channel++)result.data[offset+channel]=(pixels[a+channel]*(1-ax)+pixels[b+channel]*ax)*(1-ay)+(pixels[c+channel]*(1-ax)+pixels[d+channel]*ax)*ay;
        }
        context.putImageData(result,0,0);
      },clear(){context.clearRect(0,0,canvas.width,canvas.height);},dispose(){cache.points=null;}};
  }

  // Purpose: expose only manual reference settings in downloads and browser
  // storage; never claim FPGA compatibility, paired identity or calibrated truth.
  function exportSettings(p){
    return {schema:"pango.fisheye-preview.v1",parameters:normalize(p),
      parameters_origin:"manual_approximate",processing_location:"pc_software_reference",
      fpga_compatible:false,source_frame_id:null,pairing_status:"unverified"};
  }
  const api={preset,normalize,scaledIntrinsics,sourcePoint,createRenderer,exportSettings};
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
  root.PangoFisheyePreview=api;
})(typeof globalThis!=="undefined"?globalThis:this);
