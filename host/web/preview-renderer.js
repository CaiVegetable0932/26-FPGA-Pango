/* Upload compact display bytes directly; source RAW and archive APIs stay intact. */
(function(root){
  "use strict";
  function create(canvas){
    const gl=canvas.getContext("webgl",{alpha:false,antialias:false,depth:false,stencil:false,
      premultipliedAlpha:false,preserveDrawingBuffer:false});
    if(!gl)return null;
    // Flip texture coordinates, not the input bytes: received rows start at
    // the top while WebGL framebuffer coordinates start at the bottom.
    function shader(type,source){
      const value=gl.createShader(type);gl.shaderSource(value,source);gl.compileShader(value);
      if(!gl.getShaderParameter(value,gl.COMPILE_STATUS))throw Error("预览着色器不可用");
      return value;
    }
    const vertex=shader(gl.VERTEX_SHADER,"attribute vec2 position;varying vec2 uv;void main(){gl_Position=vec4(position,0.,1.);uv=vec2((position.x+1.)*.5,(1.-position.y)*.5);}");
    const fragment=shader(gl.FRAGMENT_SHADER,"precision mediump float;varying vec2 uv;uniform sampler2D image;void main(){gl_FragColor=vec4(texture2D(image,uv).rgb,1.);}");
    const program=gl.createProgram();gl.attachShader(program,vertex);gl.attachShader(program,fragment);gl.linkProgram(program);
    if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error("预览着色器链接失败");
    gl.deleteShader(vertex);gl.deleteShader(fragment);gl.useProgram(program);
    const geometry=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,geometry);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);
    const location=gl.getAttribLocation(program,"position");gl.enableVertexAttribArray(location);
    gl.vertexAttribPointer(location,2,gl.FLOAT,false,0,0);gl.uniform1i(gl.getUniformLocation(program,"image"),0);
    const texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT,1);gl.disable(gl.DITHER);
    const limit=gl.getParameter(gl.MAX_TEXTURE_SIZE);
    let previousWidth=0,previousHeight=0,previousFormat=null;
    return {lost:()=>gl.isContextLost(),
      draw(bytes,width,height,kind){
        // Check payload/geometry before submitting GPU commands. No resampling
        // or new color curve is applied here; the CPU fallback owns Bayer work.
        const channels={GRAY8:1,RGB888:3,RGBA8888:4}[kind];
        if(!channels||!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||
          width>limit||height>limit||bytes.byteLength!==width*height*channels||bytes.byteLength>8388608)
          throw Error("非法 GPU 预览数据");
        if(canvas.width!==width)canvas.width=width;if(canvas.height!==height)canvas.height=height;
        gl.viewport(0,0,width,height);
        const format=channels===1?gl.LUMINANCE:channels===3?gl.RGB:gl.RGBA;
        if(width===previousWidth&&height===previousHeight&&format===previousFormat)
          gl.texSubImage2D(gl.TEXTURE_2D,0,0,0,width,height,format,gl.UNSIGNED_BYTE,bytes);
        else{
          gl.texImage2D(gl.TEXTURE_2D,0,format,width,height,0,format,gl.UNSIGNED_BYTE,bytes);
          previousWidth=width;previousHeight=height;previousFormat=format;
        }
        gl.drawArrays(gl.TRIANGLE_STRIP,0,4);
      }};
  }
  root.PangoPreviewRenderer={create};
})(typeof self!=="undefined"?self:globalThis);
