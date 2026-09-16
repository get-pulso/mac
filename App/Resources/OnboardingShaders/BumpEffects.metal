#include <metal_stdlib>
using namespace metal;

struct BumpVertexOut { float4 position [[position]]; float2 uv; };
struct BumpUniforms { float4 geometry; float4 timing; float4 origin; };

vertex BumpVertexOut bumpVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y) };
}

float bumpHash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float bumpNoise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f*f*(3.0 - 2.0*f);
    return mix(mix(bumpHash(i), bumpHash(i + float2(1,0)), f.x),
               mix(bumpHash(i + float2(0,1)), bumpHash(i + 1), f.x), f.y);
}
float bumpGlow(float distance, float width) { return exp(-distance * distance / (width * width)); }
float bumpEnvelope(float t, float duration) {
    return smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(duration - 0.65, duration, t));
}
float bumpSegment(float2 p, float2 a, float2 b) {
    float2 d = b - a;
    return length(p - a - d * clamp(dot(p-a,d) / max(dot(d,d), 0.001), 0.0, 1.0));
}
float2 bumpArc(float2 a, float2 b, float t) {
    return mix(a,b,t) + float2(-34.0 * sin(t*M_PI_F), -40.0 * sin(t*M_PI_F));
}

float bumpStar(float2 p, float radius) {
    float distance = 1000.0;
    bool inside = false;
    for (int i=0;i<10;i++) {
        float a = float(i)*M_PI_F/5.0-M_PI_F/2.0;
        float b = float(i+1)*M_PI_F/5.0-M_PI_F/2.0;
        float2 start = float2(cos(a),sin(a))*radius*(i%2 == 0 ? 1.0 : 0.45);
        float2 end = float2(cos(b),sin(b))*radius*(i%2 == 0 ? 0.45 : 1.0);
        distance = min(distance,bumpSegment(p,start,end));
        if ((start.y>p.y)!=(end.y>p.y)) {
            if (p.x < (end.x-start.x)*(p.y-start.y)/(end.y-start.y)+start.x) inside = !inside;
        }
    }
    return inside ? -distance : distance;
}

float4 bumpMedal(float2 p, float2 center, float age, float life) {
    float scale = clamp(1.0-exp(-age*10.0)*cos(age*18.0),0.01,1.20);
    float angle = -0.26*exp(-age*3.0)*cos(age*9.0);
    float2 q = (p-center)/scale;
    q = float2(q.x*cos(angle)-q.y*sin(angle),q.x*sin(angle)+q.y*cos(angle));
    float r = length(q), edge = 22.0-r;
    float visible = smoothstep(-0.5,0.7,edge)*life;
    float3 normal = normalize(float3(q/22.0,1.6));
    float light = dot(normal,normalize(float3(-0.6,-0.8,1.4)));
    float bevel = bumpGlow(edge-1.1,0.7);
    float lip = bumpGlow(r-18.8,0.7);
    float brushed = sin(q.y*8.0+q.x*0.4)*0.018;
    float shine = bumpGlow(q.x*0.80+q.y*0.60-mix(-38.0,50.0,clamp((age-0.20)/1.25,0.0,1.0)),3.2);
    float3 gold = mix(float3(0.63,0.29,0.045),float3(1.0,0.82,0.31),light);
    gold += brushed + bevel*float3(0.30,0.24,0.11) - lip*0.10;
    float star = bumpStar(q,12.3);
    float inner = 1.0-smoothstep(-0.4,0.5,star);
    float upper = bumpStar(q+float2(0.0,0.65),12.3)-star;
    gold = mix(gold,gold*0.64+float3(0.04,0.02,0.0),inner);
    gold += bumpGlow(star,0.65)*upper*float3(0.44,0.31,0.09);
    gold += shine*float3(0.35,0.31,0.18);
    return float4(clamp(gold,0.0,1.0)*visible,visible);
}

float4 bumpGrass(float2 p, float2 size, float t, float duration) {
    float rootY = size.y-54.0;
    if (p.y < rootY-75.0 || p.y > rootY+2.0) return float4(0);
    float3 color = 0;
    float alpha = 0;
    float settling = 1.0-smoothstep(duration-0.65,duration,t);
    for (int i=0;i<34;i++) {
        float random = bumpHash(float2(i,4.8));
        float rootX = 5.0+float(i)*(size.x-10.0)/33.0;
        float arrive = 0.34+(size.x-rootX)*0.0023;
        float grow = smoothstep(arrive,arrive+0.65,t)*settling;
        float height = (22.0+random*40.0)*grow;
        if (height < 0.2 || abs(p.x-rootX)>38.0) continue;
        float v = clamp((rootY-p.y)/height,0.0,1.0);
        float lean = (random-0.35)*19.0;
        float wind = sin(t*2.1+rootX*0.013)*8.0+sin(t*3.5+float(i))*1.8;
        float bend = lean*v*v + wind*v*v*v;
        float width = mix(1.8+random*1.2,0.12,v);
        float blade = 1.0-smoothstep(width-0.4,width+0.45,abs(p.x-rootX-bend));
        blade *= smoothstep(-0.5,0.8,rootY-p.y)*(1.0-smoothstep(height-0.7,height+0.5,rootY-p.y));
        float3 green = mix(float3(0.16,0.37,0.08),float3(0.53,0.74,0.22),v*0.65+random*0.35);
        green += bumpGlow(p.x-rootX-bend+width*0.40,0.5)*float3(0.12,0.13,0.03);
        color = mix(color,green,blade*0.94);
        alpha = alpha+(1.0-alpha)*blade*0.94;
    }
    return float4(color*alpha,alpha);
}

fragment float4 bumpLight(BumpVertexOut in [[stage_in]], constant BumpUniforms& u [[buffer(0)]]) {
    float2 size = u.geometry.xy, p = in.uv * size, center = u.geometry.zw;
    float t = u.timing.x, kind = u.timing.y, reduced = u.timing.z, dark = u.timing.w;
    bool emojiBurst = kind >= 4.0;
    if (emojiBurst) kind -= 4.0;
    float radius = u.origin.x, duration = u.origin.w;
    if (t < 0 || t >= duration) return float4(0);
    float2 q = p-center;
    float dist = length(q), rim = abs(dist-radius-1.0);
    float edge = min(min(p.x, size.x-p.x), min(p.y, size.y-p.y));
    float env = bumpEnvelope(t, duration);
    float3 tint = kind < 0.5 ? float3(1.0,0.73,0.24) :
                  kind < 1.5 ? float3(1.0,0.38,0.06) :
                  kind < 2.5 ? float3(0.23,0.70,1.0) : float3(0.50,0.77,0.29);
    float3 light = 0;
    float alpha = 0;
    float shadow = 0;
    float4 object = float4(0);
    float illumination = dark > 0.5 ? 1.0 : 0.8;

    // Accessibility variant is stationary: no wave, flight, turbulence or deformation.
    if (reduced > 0.5) {
        float fade = sin(clamp(t / duration,0.0,1.0) * M_PI_F);
        alpha = fade * (0.07 + 0.34*bumpGlow(rim,3.0) + 0.08*exp(-edge/10.0));
        return float4(tint*alpha, alpha);
    }

    // The animated artwork supplies the objects. A short pulse binds the burst
    // to the actual capsule and the surrounding glass, without another illustration.
    if (emojiBurst && abs(kind-2.0)>0.1) {
        float originDistance = length(p-u.origin.yz);
        float wave = bumpGlow(originDistance-t*400.0,12.0+t*6.0)*exp(-t*3.0);
        float bloom = bumpGlow(originDistance,80.0)*exp(-t*5.0);
        float contact = exp(-edge/5.0)*wave;
        float fade = smoothstep(0.0,0.06,t)*(1.0-smoothstep(1.1,1.7,t));
        float strength = (wave*0.11+bloom*0.10+contact*0.30)*fade*illumination;
        return float4(tint*strength,strength);
    }

    // A single object departs from the floating capsule and lands at the portrait.
    if (t < 0.40) {
        float progress = smoothstep(0.0,0.38,t);
        float2 destination = kind > 2.5 ? float2(size.x-27.0,size.y-54.0) : center + float2(radius*0.70,radius*0.70);
        float2 head = bumpArc(u.origin.yz,destination,progress);
        float d = length(p-head);
        float spark = bumpGlow(d,2.4)*0.9 + bumpGlow(d,12.0)*0.18;
        float trail = 0;
        for (int j=1;j<=5;j++) {
            float tail = max(0.0,progress-float(j)*0.025);
            trail += bumpGlow(length(p-bumpArc(u.origin.yz,destination,tail)),2.0)*0.07;
        }
        alpha += (spark+trail)*smoothstep(0.0,0.07,t);
        light += mix(tint,float3(1.0),0.55)*(spark+trail);
    }
    float impact = max(0.0,t-0.38);
    float land = smoothstep(0.35,0.43,t);
    if (kind < 0.5) {
        // A tiny foil seal is physically stamped into the portrait. Its bevel catches
        // one moving reflection while the impact travels into the glass around it.
        float waveRadius = radius + impact*430.0;
        float wave = bumpGlow(dist-waveRadius,3.2 + impact*6.0)*exp(-impact*2.4)*land;
        float halo = bumpGlow(rim,2.6)*exp(-impact*7.0)*land;
        float conduction = exp(-edge/3.2)*bumpGlow(dist-waveRadius,25.0)*land;
        alpha += wave*0.32 + halo*0.46 + conduction*0.56;
        light += mix(tint,float3(0.92,0.91,1),0.45)*(wave*0.32+halo*0.46+conduction*0.56);
        alpha += bumpGlow(dist,180.0)*0.05*exp(-impact*3.0)*land;
        light += tint*bumpGlow(dist,180.0)*0.05*exp(-impact*3.0)*land;
        float life = land*(1.0-smoothstep(duration-0.55,duration,t));
        float2 sealCenter = center+float2(radius*0.66,radius*0.67);
        float sealShadow = bumpGlow(length(p-sealCenter-float2(1.5,4.0)),24.0)*life*0.18;
        shadow += sealShadow;
        object = bumpMedal(p,sealCenter,impact,life);
    } else if (kind < 1.5) {
        // The portrait is the source of real, irregular flame. White-hot roots and
        // translucent orange tips share an upward flow, never a spinning outline.
        float heat = smoothstep(0.0,0.40,impact)*(1.0-smoothstep(2.2,3.22,impact))*land;
        float angle = atan2(q.y,q.x);
        float shimmer = 0.82+0.18*sin(angle*5.0-t*4.0+2.0*bumpNoise(q*0.045+t*0.5));
        float hotRim = bumpGlow(rim,2.4)*heat*shimmer;
        float halo = exp(-max(0.0,dist-radius)/29.0)*smoothstep(radius-1.0,radius+4.0,dist)*heat;
        float room = bumpGlow(length(q/float2(1.1,1.8)),220.0)*heat;
        float edgeFlow = bumpNoise(float2(p.y*0.055-t*1.9,edge*0.09+t*0.3));
        float edgeHeat = exp(-edge/(3.0+edgeFlow*9.0))*heat*(0.3+0.7*bumpGlow(p.y-center.y,230.0));
        alpha += hotRim*0.8 + halo*0.23 + room*0.14 + edgeHeat*0.36;
        light += float3(1.0,0.76,0.29)*hotRim*0.8 + tint*(halo*0.23+room*0.14+edgeHeat*0.36);
        for (int j=0;j<7;j++) {
            float a = (float(j)-3.0)*0.40;
            float2 base = center+float2(sin(a),-cos(a))*(radius+1.0);
            float height = (19.0+bumpHash(float2(j,4))*24.0)*heat;
            float rise = clamp((base.y-p.y)/max(height,0.01),0.0,1.0);
            float flicker = bumpNoise(float2(float(j)*7.1,p.y*0.07+t*2.2));
            float curl = sin(rise*3.8-t*3.0+float(j))*rise*7.0;
            float width = (6.8+flicker*4.0)*(1.0-rise)*heat;
            float flame = (1.0-smoothstep(width*0.45,width+0.6,abs(p.x-base.x-curl)));
            flame *= smoothstep(-1.0,2.0,base.y-p.y)*(1.0-smoothstep(height-1.0,height+1.0,base.y-p.y));
            flame *= smoothstep(radius-1.0,radius+2.0,dist)*heat;
            float3 fire = mix(float3(1.0,0.88,0.44),float3(0.98,0.18,0.025),rise);
            alpha += flame*0.64;
            light += fire*flame*0.64;
        }
        for (int j=0;j<7;j++) {
            float age = impact-0.22-float(j)*0.22;
            if (age>0.0 && age<1.7) {
                float2 ember = center+float2(sin(float(j)*2.1)*32.0+sin(age*2.0+float(j))*12.0,-radius-age*42.0);
                float glow = bumpGlow(length(p-ember),1.2)*sin(age/1.7*M_PI_F)*0.85;
                alpha += glow; light += float3(1.0,0.80,0.35)*glow;
            }
        }
    } else if (kind < 2.5) {
        // A broad updraft reaches the activity card first, then lifts the portrait.
        float height = mix(size.y+80.0,center.y-110.0,clamp(t/1.45,0.0,1.0));
        float front = bumpGlow(p.y-height,38.0)*env;
        float vertical = 0.5+0.5*bumpGlow(p.x-center.x,130.0);
        float boundary = exp(-edge/4.0)*front;
        float arc = bumpGlow(rim,2.2)*bumpGlow(t-0.75,0.4)*land;
        alpha += front*vertical*0.14+boundary*0.6+arc*0.48;
        light += tint*(front*vertical*0.14+boundary*0.6)+float3(0.75,0.93,1.0)*arc*0.48;
        for (int j=0;j<4;j++) {
            float x = 24.0+float(j)*(size.x-48.0)/3.0;
            float y = height+sin(float(j)*2.0)*22.0;
            float streak = bumpGlow(p.x-x,1.1)*bumpGlow(p.y-y,13.0)*env*0.24;
            alpha += streak; light += tint*streak;
        }
    } else {
        // The lower seam becomes a tiny garden. Each blade grows at a different time
        // and bends in one shared gust; the sun and canopy shadows reach the portrait.
        float daylight = smoothstep(0.25,0.9,t)*(1.0-smoothstep(duration-0.9,duration,t));
        float slant = p.x*0.76+p.y*0.32;
        float beams = pow(0.5+0.5*sin(slant*0.034+t*0.26),5.0);
        float sun = bumpGlow(length((p-float2(size.x+20.0,-10.0))/float2(1.0,1.7)),340.0);
        float foliage = bumpNoise(p*0.014+float2(sin(t*0.8)*0.12,t*0.045));
        shadow = smoothstep(0.48,0.69,foliage)*daylight*0.19;
        alpha += (sun*0.17+beams*0.11)*daylight;
        light += float3(1.0,0.86,0.51)*(sun*0.17+beams*0.11)*daylight;
        float grow = smoothstep(0.5,1.2,t);
        float2 root = center + float2(25.0,-radius+7.0);
        float2 tip = root + float2(sin(t*2.0)*2.5,-22.0*grow);
        float stem = (1.0-smoothstep(0.65,1.5,bumpSegment(p,root,tip)))*daylight;
        float2 leafP = p-(tip+float2(4.5,-1.0));
        float2 leafQ = float2(leafP.x*0.78+leafP.y*0.63,-leafP.x*0.63+leafP.y*0.78);
        float leaf = (1.0-smoothstep(0.8,1.1,length(leafQ/float2(max(0.2,8.0*grow),max(0.2,3.8*grow)))))*daylight;
        alpha += (stem+leaf)*0.85;
        light += float3(0.38,0.69,0.20)*(stem+leaf)*0.85;
        object = bumpGrass(p,size,t,duration);
    }
    light *= illumination;
    alpha *= illumination;
    // Premultiplied compositing; light stays restrained over labels and native controls.
    float combined = clamp(alpha+shadow,0.0,0.88);
    float4 field = float4(min(light,float3(combined)),combined);
    // Opaque physical objects have their own coverage. The atmosphere stays light.
    return object + field*(1.0-object.a);
}
