import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
// Install tooling in a scratch directory, not in the application workspace.
const require=createRequire((process.env.BUMP_RENDER_MODULES || '/tmp/firstlight-vector-render')+'/package.json');
const {createCanvas}=await import(pathToFileURL(require.resolve('@napi-rs/canvas')));
const {DotLottie}=await import(pathToFileURL(require.resolve('@lottiefiles/dotlottie-web')));
const {default:sharp}=await import(pathToFileURL(require.resolve('sharp')));
DotLottie.setWasmUrl(new URL('./dotlottie-player.wasm',pathToFileURL(require.resolve('@lottiefiles/dotlottie-web'))).href);
const input=process.argv[2], output=process.argv[3];
const data=gunzipSync(await readFile(input)).toString();
const meta=JSON.parse(data);
const width=192,height=192;
const animation=new DotLottie({canvas:createCanvas(width,height),data,autoplay:false,loop:false,useFrameInterpolation:true,renderConfig:{devicePixelRatio:1,autoResize:false}});
await new Promise((resolve,reject)=>{animation.addEventListener('load',resolve);animation.addEventListener('loadError',reject);if(animation.isLoaded)resolve();});
const count=Math.ceil((meta.op-meta.ip)/meta.fr*60);
const frames=Buffer.alloc(width*height*4*count);
for(let frame=0;frame<count;frame++){
 animation.setFrame(frame/60*meta.fr);
 frames.set(animation.buffer,frame*width*height*4);
}
await sharp(frames,{raw:{width,height:height*count,channels:4,pageHeight:height}}).webp({quality:90,effort:3,loop:0,delay:Array.from({length:count},(_,i)=>Math.round((i+1)*1000/60)-Math.round(i*1000/60))}).toFile(output);
animation.destroy();console.log(output,count,'frames at 60 fps');
