#include <metal_stdlib>
using namespace metal;

struct VertexOutput { float4 position [[position]]; };
struct ShaderUniforms {
    float2 resolution;
    float time;
    float inset;
    float nativeSurface;
    float scale;
    float variant;
    float2 targetSize;
    float2 targetOffset;
};

vertex VertexOutput fullScreenVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return {float4(p[id], 0, 1)};
}

float hash31(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(
        mix(mix(hash31(i), hash31(i+float3(1,0,0)), f.x),
            mix(hash31(i+float3(0,1,0)), hash31(i+float3(1,1,0)), f.x), f.y),
        mix(mix(hash31(i+float3(0,0,1)), hash31(i+float3(1,0,1)), f.x),
            mix(hash31(i+float3(0,1,1)), hash31(i+float3(1,1,1)), f.x), f.y), f.z);
}

float cloudNoise(float3 p) {
    return 0.60*noise3(p) + 0.28*noise3(p*2.03+11.7) + 0.12*noise3(p*4.01-7.4);
}

float2 rotate2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c*p.x-s*p.y, s*p.x+c*p.y);
}

float roundedBox(float2 p, float2 h, float r) {
    float2 q = abs(p) - h + r;
    return length(max(q, 0.0)) + min(max(q.x,q.y), 0.0) - r;
}

// The analytic solution of an underdamped spring. Zero starting velocity,
// a genuine overshoot, and a small return instead of a cubic ease.
float spring(float seconds) {
    if (seconds <= 0.0) return 0.0;
    return 1.0-exp(-5.4*seconds)*(cos(8.7*seconds)+(5.4/8.7)*sin(8.7*seconds));
}

float3 spectralColor(float light, float hue, float variant) {
    float3 blue, lilac, ice;
    if (variant < 0.5) {
        blue = float3(0.22,0.27,0.94);
        lilac = float3(0.67,0.48,0.89);
        ice = float3(0.65,0.89,1.0);
    } else if (variant < 1.5) {
        blue = float3(0.10,0.32,0.76);
        lilac = float3(0.20,0.65,0.80);
        ice = float3(0.63,1.0,0.89);
    } else {
        blue = float3(0.39,0.25,0.83);
        lilac = float3(0.95,0.52,0.77);
        ice = float3(0.82,0.88,1.0);
    }
    float3 color = mix(blue, lilac, smoothstep(0.15,0.95,hue)*0.8);
    return mix(color, ice, smoothstep(0.16,0.90,light));
}

// Eight softly overlapping depth layers. No surface normals, specular rim,
// hard sphere, or isolated glowing dots: light is suspended inside the fog.
float4 gasVolume(float2 q, float t, float variant) {
    float3 sum = 0;
    float weight = 0;
    float2 drift = float2(t*0.09, -t*0.12);
    float2 flow = float2(cloudNoise(float3(q*1.2+drift,t*0.17)),
                         cloudNoise(float3(q*1.2-drift+4.3,t*0.14))) - 0.5;
    q += flow * (variant < 0.5 ? 0.46 : 0.66);
    if (variant > 0.5 && variant < 1.5) {
        q = rotate2(q, -0.28+sin(t*0.35)*0.18);
        q.x += 0.18*sin(q.y*2.4-t*0.7);
    } else if (variant > 1.5) {
        q = rotate2(q, 0.20*sin(t*0.38+length(q)*2.0));
    }
    for (int i=0; i<8; i++) {
        float z = -1.2+float(i)*(2.4/7.0);
        float3 p = float3(q,z);
        float fog = cloudNoise(p*1.65+float3(drift,t*0.22));
        float density = exp(-dot(p,p)*1.18)*(0.50+fog*0.85);
        float light = 0.5+0.5*sin(q.y*2.5+q.x*1.3+z*1.7+t*0.61+fog*3.2);
        float hue = 0.5+0.5*sin(q.x*2.0-z*1.5-t*0.34+fog*2.1);
        sum += spectralColor(light,hue,variant)*density;
        weight += density;
    }
    return float4(sum/max(weight,0.001), 1.0-exp(-weight*0.55));
}

float3 welcomeColor(float3 color, float2 q, float t) {
    float settled = smoothstep(4.35,5.55,t);
    float readingArea = exp(-dot(q*float2(1.4,1.15),q*float2(1.4,1.15)));
    return color*(1.0-settled*(0.18+0.30*readingArea));
}

float4 cloudArrival(float2 p, constant ShaderUniforms &u, float2 target) {
    p -= u.targetOffset;
    float t = u.time;
    float birth = smoothstep(0.30,1.45,t);
    if (birth == 0) return float4(0);
    float morphTime = max(0.0,t-3.6);
    float expansion = spring(morphTime);
    expansion = mix(expansion,1.0,smoothstep(1.45,1.85,morphTime));
    float materialize = smoothstep(0.0,0.95,morphTime);
    float orbRadius = min(142.0,min(target.x,target.y)*0.53);
    float breathe = 1.0+0.035*sin(t*1.65)+0.020*sin(t*2.3+1.2);
    float2 seed = float2(orbRadius,orbRadius*1.07)*mix(0.78,1.0,birth)*breathe;
    float2 h = mix(seed,target,expansion);
    // The explicit radius belongs only to the animation proxy.
    float radius = mix(min(seed.x,seed.y),10.0,clamp(expansion,0.0,1.0));
    radius = min(radius,min(h.x,h.y));
    float distance = roundedBox(p,h,radius);
    float softness = mix(46.0,0.7,materialize);
    if (distance > softness*1.7+26.0) return float4(0);
    float2 q = p/max(h,float2(1));
    float edgeNoise = cloudNoise(float3(q*2.0,t*0.30))-0.5;
    distance += edgeNoise*44.0*(1.0-materialize);
    float mask = 1.0-smoothstep(-softness,softness*1.3,distance);
    float4 gas = gasVolume(q,t,u.variant);
    float alpha = mask*mix(gas.a*0.95,1.0,materialize)*birth;
    if (u.nativeSurface > 0.5) alpha = 1.0;
    float3 color = welcomeColor(gas.rgb,q,t);
    float border = u.nativeSurface > 0.5 ? 0.0 : (1.0-smoothstep(0.0,1.1,abs(distance)))*materialize;
    color = mix(color,float3(0.84,0.91,1.0),border*0.23);
    if (alpha < 0.0002) return float4(0);
    return float4(color*alpha,alpha);
}


fragment half4 waveFragment(VertexOutput in [[stage_in]],
                           constant ShaderUniforms &u [[buffer(0)]]) {
    float2 p = (in.position.xy-u.resolution*0.5)/u.scale;
    float2 target = u.targetSize.x > 0 ? u.targetSize*0.5 : u.resolution/(2.0*u.scale)-u.inset/u.scale;
    return half4(cloudArrival(p,u,target));
}
