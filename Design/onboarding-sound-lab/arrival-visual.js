// The native pacing curve drives this lightweight visual preview.
(() => {
  const keys = [[0,0,0],[1,.06,.15],[4,1.75,.75],[4.25,2.05,1.3],
    [5.6,3.15,.55],[5.95,3.6,1.1],[8.95,6.15,.6]];
  const canvas = document.querySelector('#rays');
  const win = document.querySelector('#arrival-window');
  const mark = document.querySelector('#mark');
  const name = document.querySelector('#brand-name');
  const wordmark = document.querySelector('#wordmark');
  const welcome = document.querySelector('#welcome');
  const next = document.querySelector('#continue');
  const caption = document.querySelector('#stage-caption');
  const fill = document.querySelector('#scene-fill');
  const phases = document.querySelectorAll('[data-phase]');
  let lastTime = 0;
  const clamp = (v) => Math.max(0,Math.min(1,v));
  function smooth(a,b,v) { const t=clamp((v-a)/(b-a)); return t*t*(3-2*t); }
  function shaderTime(real) {
    if (real <= 0) return 0;
    if (real >= 8.95) return 6.15;
    const i=keys.findIndex(k=>k[0]>real)-1;
    const [ra,sa,va]=keys[i], [rb,sb,vb]=keys[i+1];
    const h=rb-ra, t=(real-ra)/h, t2=t*t, t3=t2*t;
    return Math.min(sb,Math.max(sa,(2*t3-3*t2+1)*sa+(t3-2*t2+t)*h*va+(-2*t3+3*t2)*sb+(t3-t2)*h*vb));
  }
  function rays(shader) {
    const ratio=Math.min(2,window.devicePixelRatio||1);
    const width=canvas.clientWidth,height=canvas.clientHeight;
    if (!width || !height) return;
    if(canvas.width!==Math.round(width*ratio)||canvas.height!==Math.round(height*ratio)){
      canvas.width=Math.round(width*ratio);canvas.height=Math.round(height*ratio);
    }
    const ctx=canvas.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(ratio,0,0,ratio,0,0);ctx.clearRect(0,0,width,height);
    const intensity=smooth(.06,1.65,shader)*(1-smooth(2.1,3.6,shader));
    if(intensity<.001)return;
    const x=width/2,y=height/2;
    const core=ctx.createRadialGradient(x,y,0,x,y,width*.4);
    core.addColorStop(0,`rgba(245,214,255,${.28*intensity})`);
    core.addColorStop(.3,`rgba(176,113,226,${.07*intensity})`);
    core.addColorStop(1,'rgba(110,65,150,0)');
    ctx.fillStyle=core;ctx.fillRect(0,0,width,height);
    for(let i=0;i<13;i++){
      const a=-2.7+i*.475+Math.sin(shader*.7+i)*.014;
      const length=Math.max(width,height)*(.47+(i%4)*.085);
      const spread=.014+(i%3)*.008;
      const g=ctx.createLinearGradient(x,y,x+Math.cos(a)*length,y+Math.sin(a)*length);
      g.addColorStop(0,`rgba(251,227,255,${.30*intensity})`);
      g.addColorStop(.45,`rgba(198,142,239,${.085*intensity})`);
      g.addColorStop(1,'rgba(136,77,211,0)');ctx.fillStyle=g;
      ctx.beginPath();ctx.moveTo(x,y);
      ctx.lineTo(x+Math.cos(a-spread)*length,y+Math.sin(a-spread)*length);
      ctx.lineTo(x+Math.cos(a+spread)*length,y+Math.sin(a+spread)*length);
      ctx.closePath();ctx.fill();
    }
  }
  function render(real) {
    lastTime=real;
    // Fit only the visual clock to the original recording. Audio runs at 1x.
    const sceneReal=real*(window.ORIGINAL_AUDIO?.visualScale || 1);
    const t=shaderTime(sceneReal);
    fill.style.width=(100*clamp(real/(window.ORIGINAL_AUDIO?.duration || 10)))+'%';
    win.style.opacity=smooth(1.65,2.3,t);
    mark.style.opacity=smooth(2.82,3.58,t);
    const n=smooth(3.7,4.25,t);
    name.style.opacity=n;name.style.transform=`translateX(${-12*(1-n)}px)`;
    const rise=smooth(4.35,4.95,t);
    wordmark.style.top=(50-37*rise)+'%';
    wordmark.style.transform=`translate(-50%,-50%) scale(${1-.44*rise})`;
    const welcomeIn=smooth(5,5.3,t);
    welcome.style.opacity=welcomeIn;welcome.style.transform=`translateY(${12*(1-welcomeIn)}px)`;
    next.style.opacity=smooth(5.78,6.15,t);
    const phase=sceneReal<3.75?'dawn':sceneReal<6.671?'reveal':sceneReal<7.319?'rise':'hope';
    for(const element of phases)element.classList.toggle('active',sceneReal>=1&&element.dataset.phase===phase);
    caption.textContent=sceneReal<1?'Начало сцены':sceneReal<3.75?'Ожидание':sceneReal<6.671?'Раскрытие':sceneReal<7.319?'Подъём':'Затухание';
    rays(t);
  }
  window.ArrivalScene={render};
  window.addEventListener('resize',()=>render(lastTime));
  render(0);
})();
