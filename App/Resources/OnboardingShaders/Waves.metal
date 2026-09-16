#include <metal_stdlib>
using namespace metal;

// Ray / Flow: the accepted onboarding light. Kept in step with
// playground/onboarding-shader/Shaders/Waves.metal minus the comparison styles.

struct VertexOutput { float4 position [[position]]; };
struct ShaderUniforms {
    float2 resolution;
    float time;
    float inset;
    float nativeSurface;
    float scale;
    float variant;
    float style;
    float2 targetSize;
    float2 targetOffset;
    float4 tuning;
};

struct RayPaletteUniforms {
    float4 low;
    float4 middle;
    float4 high;
    float4 core;
    float4 surface;
    float4 finish;
};

struct RayLogoUniforms {
    float4 frame;
    float4 crop;
    float4 options;
    float4 timing;
    float4 ending;
    /// Exit of the settled mark: blur progress, blur mip levels, fade, unused.
    float4 exit;
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

float2 rotate2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c*p.x-s*p.y, s*p.x+c*p.y);
}

float roundedBox(float2 p, float2 h, float r) {
    float2 q = abs(p) - h + r;
    return length(max(q, 0.0)) + min(max(q.x,q.y), 0.0) - r;
}

// Ray v3. Original Metal light volume, visually informed by Prismatic Burst:
// https://reactbits.dev/backgrounds/prismatic-burst
// Not a GLSL port. A continuous angular field is integrated through depth;
// there are no strip centre lines, fixed spoke count, or per-frame random seeds.
// This pass writes linear radiance to RGBA16Float. Bloom and display mapping
// happen afterwards, so bright intersections retain energy instead of clipping.
float smoother(float a, float b, float v) {
    float x = clamp((v-a)/(b-a),0.0,1.0);
    return x*x*x*(x*(x*6.0-15.0)+10.0);
}

float rayTime(float t, int transition) {
    float start = transition == 1 ? 2.60 : 2.35;
    float speed = transition == 1 ? 0.62 : 0.16;
    float x = clamp(t-start,0.0,1.0);
    // Flow stays visibly alive behind the text instead of nearly freezing as
    // the window appears. Integrating velocity keeps the optical phase intact.
    return t < start ? t : start+x-(1.0-speed)*(x*x*x-0.5*x*x*x*x)+max(0.0,t-start-1.0)*speed;
}

float3 raySpectrum(float local, float warmth, constant RayPaletteUniforms &palette) {
    // One coherent illuminant per palette, varied by local optical density.
    // No palette depends on screen x/y or divides the burst into colored halves.
    float3 color = mix(palette.low.rgb,palette.middle.rgb,smoother(0.20,0.78,local));
    color = mix(color,palette.high.rgb,smoother(0.60,0.90,local)*0.48);
    return color*float3(1.0+(warmth-0.55)*0.10,1.0,1.0-(warmth-0.55)*0.25);
}

// Only the projection changes. All variants transport the SAME 28-depth-sample
// angular volume, with the same seed, noise coordinates and optical phase.
// There is no final-state texture, second density field or image crossfade.
struct RayProjection {
    float2 source;
    float2 stretch;
    float rotation;
};

RayProjection rayProjection(float t, float2 target, int transition) {
    // Let the small emitter open before accelerating its travel, so fine
    // bright filaments do not race across the pane at peak exposure.
    float travel = transition == 1 ? smoother(1.80,3.25,t) : smoother(1.25,3.12,t);
    float2 source = float2(-0.12,-1.20);
    float2 stretch = float2(1);
    float rotation = 0;
    if (transition == 1) {
        // Bring the original emitter just beyond the upper-left corner. A
        // wide-angle diagonal lens spreads its existing shafts across the pane.
        source = float2(-1.05,-1.05);
        // Less anamorphic bunching: keep rays spread over the full quadrant,
        // rather than concentrating most fine structure on one diagonal.
        stretch = float2(1.0,0.64);
        rotation = 0.7853981634;
    } else if (transition == 2) {
        source = float2(-1.65,0.12);
        stretch = float2(1.0,0.48);
    } else if (transition == 3) {
        source = float2(0.60,-3.60);
        stretch = float2(0.23,1.0);
    }
    float L = 2.0*min(target.x,target.y);
    RayProjection projection;
    projection.source = source*target/L*travel;
    projection.stretch = exp(log(stretch)*travel);
    projection.rotation = rotation*travel;
    return projection;
}

float logoGather(float t, RayLogoUniforms logo) {
    if (logo.options.y >= 0) return logo.options.y;
    // This is one spatial deformation of the complete radiance field. It does
    // not resolve into constructed branches before the real mark appears.
    return logo.options.x > 0.5 ? smoother(logo.timing.x,logo.ending.w,t) : 0.0;
}

float lampTurn(float t,RayLogoUniforms logo) {
    if (logo.options.x < 0.5) return 0;
    if (logo.ending.z >= 0) return logo.ending.z; // Offscreen diagnostic only.
    return smoother(1.80,2.55,t);
}

// Rigid rotation of a light volume, not a screen-space opacity fan. At zero
// tilt the optical axis points at the viewer. At 82 degrees it points almost
// along the window towards the selected corner. Applying the inverse to each
// camera sample transports the ORIGINAL density/filaments with the flashlight.
float3 lampRotate(float3 p,float angle,float azimuth) {
    float2 a = float2(cos(azimuth),-sin(azimuth));
    float along = dot(p.xy,a),c = cos(angle),s = sin(angle);
    return float3(p.xy+a*(along*(c-1.0)+p.z*s),p.z*c-along*s);
}

// Intersect a camera ray with a rotated conical stratum analytically. Regular
// camera-Z slices alias narrow filaments into a crossing grid during rotation.
// Here every sample stays on its original optical ray for its ENTIRE length.
// xy = emitter-space direction, z = path-length scale, w = cone visibility.
float4 lampConeSample(float2 screenDirection,float tilt,float azimuth,float layer,int branch) {
    if (tilt < 0.00001) return float4(screenDirection,1.0,branch == 0 ? 1.0 : 0.0);
    float aperture = (66.0+layer*6.0)*0.01745329252;
    float c = cos(tilt),s = sin(tilt),ca = cos(aperture);
    float2 axis = float2(cos(azimuth),-sin(azimuth));
    float along = dot(screenDirection,axis)*s;
    float a = c*c-ca*ca,b = 2.0*along*c,cc = along*along-ca*ca;
    float discriminant = b*b-4.0*a*cc;
    if (discriminant <= 0) return float4(0);
    float q = -0.5*(b+(b >= 0 ? 1.0 : -1.0)*sqrt(discriminant));
    float safeA = (a >= 0 ? 1.0 : -1.0)*max(abs(a),0.000001);
    float safeQ = (q >= 0 ? 1.0 : -1.0)*max(abs(q),0.000001);
    float cameraZ = branch == 0 ? q/safeA : cc/safeQ;
    float3 local = lampRotate(float3(screenDirection,cameraZ),-tilt,azimuth);
    if (local.z <= 0) return float4(0);
    // A penumbra rather than a razor silhouette: the cone's power fades over
    // several degrees at its boundary, like a real lamp, instead of cutting.
    float visibility = smoothstep(0.0,0.22,discriminant);
    return float4(normalize(local.xy),length(local)*sin(aperture),visibility);
}

float2 logoFit(RayLogoUniforms logo) {
    return logo.crop.zw*min(logo.frame.z/logo.crop.z,logo.frame.w/logo.crop.w);
}

// The optical origin is taken from the original mark. No branch geometry is
// reproduced in Metal; the exact silhouette comes only from the bundled asset.
constant float2 logoRoot = float2(25.2,122.0);
// The fan of the original mark opens towards this screen azimuth. It must
// equal RayLogoTiming.defaultDirection; the direction slider only changes
// where the light travels first, never the orientation of the product mark.
constant float logoMarkAzimuth = 0.7853981634;
// Linear exposure of the fully collected field, before pigment replaces it.
constant float logoCollectedExposure = 0.30;
// Radius of the dark disc at the root of the original mark, in asset UV
// (petals begin ≈145 px from the root in the 1024 px icon). A luminous sun
// of this size sits at the apex of the turned cone until pigment arrives.
constant float logoDiscRadius = 0.128;

float2 logoRootUV() {
    return (logoRoot*3.84399+float2(175.08,242.83))/1024.0;
}

float2 logoEmitter(RayLogoUniforms logo) {
    return logo.frame.xy+((logoRootUV()-logo.crop.xy)/logo.crop.zw-0.5)*logoFit(logo);
}

// Distance (in pixels) from the optical root to the farthest corner of the
// original mark. The light's power envelope contracts towards this reach.
float logoReach(RayLogoUniforms logo,float scale) {
    float2 unit = logoFit(logo)/logo.crop.zw*scale;
    float2 root = logoRootUV();
    float reach = 0;
    for (int corner=0; corner<4; ++corner) {
        float2 c = logo.crop.xy+logo.crop.zw*float2((corner&1) ? 1.0 : 0.0,(corner&2) ? 1.0 : 0.0);
        reach = max(reach,length((c-root)*unit));
    }
    return reach;
}

float logoAssetMask(float4 ink,float2 uv) {
    float peak = max(ink.r,max(ink.g,ink.b));
    float mask = smoothstep(0.012,0.07,peak)*ink.a;
    return all(uv >= float2(0)) && all(uv <= float2(1)) ? mask : 0.0;
}

// A moving crop of the original field, never a second logo painted on top.
// The destination texture, source center and final silhouette do not move.
float logoSpatialClip(float progress,float2 point,float2 extent,int kind) {
    if (kind == 0 || progress <= 0.0 || progress >= 1.0) return progress;
    float2 q = point/extent;
    float delay;
    if (kind == 1) {
        // Iris gently clears the outside first. The common mask is already
        // active everywhere; it never waits for a round iris to reach the logo.
        delay = 1.0-clamp(length(q),0.0,1.0);
    } else if (kind == 2) {
        // Sweep: one coherent upper-left to lower-right pass.
        delay = clamp(0.5+dot(q,normalize(float2(1.0,0.65)))*0.48,0.0,1.0);
    } else {
        // A broad curved feather, not angular shutters: angular delays created
        // a second small spiky star around the mark during the old contraction.
        delay = clamp(0.5+q.y*0.42+sin(q.x*3.2+0.4)*0.16,0.0,1.0);
    }
    float local = smoother(delay,delay+0.64,progress*1.64);
    // Every choice clips the FIXED silhouette from the beginning. Spatial
    // variation only leads/trails that crop, never replaces it with an aperture.
    return mix(progress,local,0.38);
}

float logoOpticalTime(float t) {
    // Integrate a quintic brake: continuous optical velocity, zero by 3.10 s.
    // The collected light can then morph into pigment without changing noise.
    if (t <= 2.65) return t;
    float x = clamp((t-2.65)/0.45,0.0,1.0);
    return 2.65+0.45*(x-pow(x,6.0)+3.0*pow(x,5.0)-2.5*pow(x,4.0));
}

RayProjection gatherProjection(RayProjection projection,float2 target,RayLogoUniforms logo,float gather) {
    float L = 2.0*min(target.x,target.y);
    // Live Flow is anchored at the eventual logo from its very first frame.
    // Do not inherit the comparison preset's leftward source/diagonal lens.
    projection.source = logoEmitter(logo)/L;
    // Keep the original optical field at full scale while the mask crops it.
    // Scaling towards the mark first was producing the rejected central point.
    projection.stretch = float2(1.0);
    // Translation/scale stay fixed. The 3D lamp volume rotates independently
    // inside the integrator; this is not a spinning 2D image or a lens zoom.
    projection.rotation = 0;
    return projection;
}

float2 rayMaterialPoint(float2 point, RayProjection projection) {
    return rotate2(point-projection.source,-projection.rotation)/projection.stretch;
}

float2 rayMaterialDirection(float2 point, RayProjection projection) {
    float2 local = rayMaterialPoint(point,projection);
    return local/max(length(local),0.0001);
}

// The material has no morph time, transition index, or window-mode input.
// A given optical ray/depth/phase always refers to the same piece of light.
float4 rayMaterial(float2 direction, float z, float time, float seed, float4 tuning, float detail) {
    // Narrower depth shear preserves the increased number of shafts instead of
    // averaging neighbouring fine rays into a soft, nearly uniform cloud.
    // detail is a fixed preset for the ENTIRE run, never a morph/end-state mix.
    // Flow's denser field does not change the three slower comparison presets.
    float shear = mix(0.09+0.08*tuning.w,0.026+0.023*tuning.w,detail);
    float2 dir = rotate2(direction,z*shear);
    float flow = time*(0.80+1.40*tuning.w);
    // Richer aperture throughout the ENTIRE animation, not extra end-state
    // stripes. Fine transmission also supplies faint rays between broad shafts.
    float3 angular = float3(dir*mix(8.5,26.0,detail),z*0.72+seed);
    angular += float3(flow*0.50,-flow*0.35,flow*0.42);
    float large = noise3(angular);
    float2 fineDirection = rotate2(direction,z*mix(shear,0.008+0.006*tuning.w,detail));
    float fine = noise3(float3(fineDirection*mix(27.0,100.0,detail),z*1.15+seed-flow*0.67));
    float shafts = pow(smoothstep(0.30,0.83,large),mix(2.4,2.7,detail)*tuning.y);
    float filaments = pow(smoothstep(mix(0.44,0.40,detail),mix(0.91,0.89,detail),fine),mix(3.5,3.3,detail))*(0.14+0.86*shafts);
    return float4(large,fine,shafts,filaments);
}

// Offscreen regression probe. Follow individual material rays through the
// exact projection used for drawing, then compare their optical fingerprints.
kernel void rayVerifyTransport(device float *errors [[buffer(0)]],
                              constant RayLogoUniforms *logos [[buffer(1)]],
                              uint index [[thread_position_in_grid]]) {
    constexpr uint angles = 72, depths = 8, times = 9;
    if (index >= 8*angles*depths*times) return;
    uint a = index%angles;
    uint d = (index/angles)%depths;
    uint step = (index/(angles*depths))%times;
    int kind = int(index/(angles*depths*times));
    float stops[9] = {0.0,0.65,1.25,1.75,2.05,2.20,2.40,2.55,3.60};
    float angle = (float(a)+0.37)*6.28318530718/float(angles);
    float2 original = float2(cos(angle),sin(angle));
    RayProjection projection = rayProjection(stops[step],float2(334,234),kind >= 4 ? 1 : kind);
    float anchorError = 0;
    if (kind >= 4) {
        RayLogoUniforms logo = logos[kind-4];
        projection = gatherProjection(projection,float2(334,234),logo,logoGather(stops[step],logo));
        anchorError = length(projection.source*468.0-logoEmitter(logo))
            +abs(projection.rotation)
            +length(projection.stretch-float2(1.0));
    }
    float2 transported = projection.source+rotate2(original*0.28*projection.stretch,projection.rotation);
    float2 recovered = rayMaterialDirection(transported,projection);
    float z = -1.0+(float(d)+0.5)*2.0/float(depths);
    float seed = hash31(float3(703,19.3,7.1))*31.0;
    float detail = kind == 1 || kind >= 4 ? 1.0 : 0.0;
    float4 reference = rayMaterial(original,z,1.10,seed,float4(0.35,1,0.55,0.58),detail);
    if (kind >= 4) {
        RayLogoUniforms logo = logos[kind-4];
        float tilt = lampTurn(stops[step],logo)*1.4311699866;
        float3 local = float3(original*0.28,0.50+z*0.35);
        float3 world = lampRotate(local,tilt,logo.ending.x);
        float3 back = lampRotate(world,-tilt,logo.ending.x);
        anchorError += length(local-back);
        recovered = normalize(back.xy);
        float aperture = (66.0+z*6.0)*0.01745329252;
        float3 coneRay = lampRotate(float3(original*sin(aperture),cos(aperture)),tilt,logo.ending.x);
        if (length(coneRay.xy) > 0.02) {
            float2 screen = normalize(coneRay.xy);
            float4 front = lampConeSample(screen,tilt,logo.ending.x,z,0);
            float4 rear = lampConeSample(screen,tilt,logo.ending.x,z,1);
            // Away from a grazing silhouette, the actual rendering solver
            // must recover the SAME material ray after its projected motion.
            if (max(front.w,rear.w) > 0.10) {
                anchorError += min(length(front.xy-original),length(rear.xy-original));
            }
        }
    }
    float4 result = rayMaterial(recovered,z,1.10,seed,float4(0.35,1,0.55,0.58),detail);
    errors[index] = length(reference-result)+anchorError;
}

float4 rayRadiance(float2 canvasPoint, constant ShaderUniforms &u, float2 target,
                   constant RayPaletteUniforms &palette, constant float4 &transition,
                   constant RayLogoUniforms &logo) {
    bool native = u.nativeSurface > 0.5;
    int kind = int(transition.x);
    bool flow = kind == 1;
    float t = min(u.time,3.35);
    float birth = flow ? smoother(0.06,0.60,t) : smoother(0.06,0.48,t);
    if (birth == 0) return float4(0);
    // y is an offscreen-verification phase lock; live playback always sends -1.
    float opticalTime = logo.options.x > 0.5 ? logoOpticalTime(u.time) : u.time;
    float time = transition.y >= 0 ? transition.y : rayTime(opticalTime,kind);
    float L = 2.0*min(target.x,target.y);
    float2 p = canvasPoint-u.targetOffset;
    float2 q = p/L;
    float4 k = u.tuning;
    float seed = hash31(float3(u.variant,19.3,7.1))*31.0;
    // A restrained, floating birth precedes the bright transition. The window
    // and source movement still overlap; neither waits for the other's finish.
    float expand = flow ? smoother(1.05,1.75,t) : smoother(1.25,2.72,t);
    float condense = flow ? smoother(1.12,1.72,t) : smoother(1.70,3.08,t);
    float settle = flow ? smoother(1.35,1.95,t) : smoother(2.65,3.35,t);
    float edgeLock = flow ? smoother(1.35,1.95,t) : smoother(2.10,3.20,t);

    // The lens continuously carries existing shafts into their final projection.
    // It never closes their angular gaps into a cloud or introduces new rays.
    RayProjection projection = rayProjection(t,target,kind);
    float gather = logoGather(u.time,logo);
    if (logo.options.x > 0.5) projection = gatherProjection(projection,target,logo,gather);
    float gesture = smoother(1.25,1.75,t)*(1.0-smoother(2.25,2.88,t));
    if (kind == 3) gesture = smoother(1.25,2.05,t)*(1.0-smoother(2.25,2.88,t));
    float progress = flow ? expand : smoother(1.25,2.85,t);
    float2 opticalPoint = rayMaterialPoint(q,projection);
    float radius = length(opticalPoint);
    float2 direction = opticalPoint/max(radius,0.0001);
    float2 opticalDirection = rayMaterialDirection(q,projection);
    float front = smoother(0.12,1.17,t);
    float coneNoise = noise3(float3(direction*3.7,seed+time*k.w));
    float reach = k.x*(0.64+0.75*coneNoise)*mix(0.10,1.0,front);
    if (flow) reach *= 0.75;
    float frameReach = 0;
    for (int corner=0; corner<4; ++corner) {
        float2 sign = float2((corner&1) ? 1.0 : -1.0,(corner&2) ? 1.0 : -1.0);
        // Live logo collection is purely a crop, not a collapse of ray reach.
        float2 reference = sign*target;
        frameReach = max(frameReach,length(rayMaterialPoint(reference/L,projection)));
    }
    reach = mix(reach,frameReach*1.42,expand);
    float distance = roundedBox(p,target,10.0);
    float softness = mix(L*0.065,0.7,edgeLock);
    if (kind == 0) {
        // Bloom: a round wave meets the eventual window perimeter.
        float aperture = length(p)-length(target)*mix(0.32,1.1,progress);
        distance = mix(distance,max(distance,aperture),gesture*0.85);
    } else if (kind == 1) {
        // No delayed diagonal wipe: the whole light-filled window appears
        // together, then the original rays keep travelling within it.
    } else if (kind == 2) {
        float2 aperture = target*float2(1.0,mix(0.13,1.0,progress));
        distance = mix(distance,roundedBox(p,aperture,10.0),gesture);
        softness += L*0.015*gesture;
    } else {
        softness += L*0.11*gesture;
    }
    float frameMask = 1.0-smoothstep(-softness,softness,distance);
    if (!native && distance > L*0.20 && edgeLock > 0.999) return float4(0);
    if (!native && radius > max(reach*2.3,0.10) && condense == 0) return float4(0);

    float3 energy = 0;
    float transmittance = 1.0;
    bool lamp = logo.options.x > 0.5;
    // Flow opens with a few broad shafts and grows its fine structure while
    // the light expands; the dense field is only complete by the handoff.
    float detail = flow ? smoother(0.30,1.90,t) : 0.0;
    float tilt = lampTurn(u.time,logo)*1.4311699866;
    // Integrate an emissive, weakly absorbing volume along the camera ray.
    // Depth-dependent aperture/parallax separates broad shafts from filaments.
    constexpr int samples = 28;
    for (int i=0; i<samples; ++i) {
        float z = -1.0+(float(i)+0.5)*(2.0/float(samples));
      for (int branch=0; branch<2; ++branch) {
        if ((!lamp || tilt < 0.00001) && branch > 0) continue;
        float4 optical = lamp ? lampConeSample(opticalDirection,tilt,logo.ending.x,z,branch)
                             : float4(opticalDirection,1.0,1.0);
        if (optical.w <= 0.00001) continue;
        float r = radius*(1.0+z*0.11)*optical.z;
        float falloff = exp(-pow(r/max(reach,0.005),2.7));
        if (falloff < 0.00001) continue;
        float depth = exp(-z*z*3.8)*optical.w;
        // Two fixed materials, cross-faded: fine shafts grow inside the broad
        // ones. Sweeping the noise frequency instead would slide every shaft
        // angularly, like a zoom, and break 60 Hz continuity.
        float4 material = detail <= 0.0 ? rayMaterial(optical.xy,z,time,seed,k,0.0)
            : detail >= 1.0 ? rayMaterial(optical.xy,z,time,seed,k,1.0)
            : mix(rayMaterial(optical.xy,z,time,seed,k,0.0),rayMaterial(optical.xy,z,time,seed,k,1.0),detail);
        float large = material.x, fine = material.y;
        float shafts = material.z, filaments = material.w;
        // No radial sine bands: density tapers once along each independently
        // evolving direction. Light expands rather than crawling like a ribbon.
        float thickness = flow ? 1.0+1.5*progress : 1.0;
        // The expanding volume also scatters light through its low-density
        // directions. Keep a softly varying transmission floor between shafts
        // instead of leaving long black angular cuts across the window.
        // It follows the same material sample, depth, reach and optical phase;
        // no extra endpoint image, cloud field or text-region mask is added.
        float scattered = (flow ? 0.28 : 0.12)*progress*(0.85+0.15*large);
        float aperture = (shafts+filaments*1.6+scattered)*thickness;
        float inverseSquare = 0.055/(0.010+r*r);
        // Compensate only distance as the emitter leaves the centre. Optical
        // transmission still comes exclusively from the original density field.
        float2 centerRay = rayMaterialPoint(logo.options.x > 0.5 ? logo.frame.xy/L : float2(0),projection);
        float flux = mix(1.0,(0.01+dot(centerRay,centerRay))/0.30,expand);
        if (flow) flux = max(1.0,flux)*mix(0.42,7.5,progress);
        float excitation = inverseSquare*flux;
        float density = aperture*falloff*depth*(2.0/float(samples));
        float3 color = raySpectrum(large*0.70+fine*0.30+z*0.09,k.z,palette);
        energy += transmittance*density*color*excitation*3.1;
        transmittance *= exp(-density*0.32);
      }
    }
    // Small white-hot emitter, not a uniformly filled disk. Its energy spreads
    // as the surrounding field becomes optically thick.
    float coreWidth = 0.00075*(0.65+coneNoise*0.85);
    float core = exp(-radius*radius/coreWidth)*2.7;
    if (lamp) core *= pow(cos(tilt),4.0);
    energy += palette.core.rgb*core*(flow ? mix(0.35,1.0,expand) : 1.0);

    // No text-shaped exposure mask or reading plate. This radiance remains
    // untouched; the compositor lowers the opacity of the entire ray layer.
    float coverage = condense*frameMask;
    float bound = frameMask;
    // Fade Flow once in display space below. Scaling HDR energy here would
    // slam most pixels into their tone-map shoulder within a single frame.
    energy *= bound*(flow ? 1.0 : birth);
    // A low-energy prismatic meniscus belongs to the proxy only. Native corners
    // and shadow remain AppKit's; the meniscus is absent at exact handoff.
    float meniscus = exp(-abs(distance)/(1.0+3.0*(1.0-edgeLock)))*
        smoother(2.65,3.0,t)*(1.0-settle)*0.055;
    energy += raySpectrum(0.58,k.z,palette)*meniscus;
    if (native) coverage = 1.0;
    return float4(energy,max(coverage,0.0));
}

fragment half4 rayRadianceFragment(VertexOutput in [[stage_in]],
                                  constant ShaderUniforms &u [[buffer(0)]],
                                  constant RayPaletteUniforms &palette [[buffer(1)]],
                                  constant float4 &transition [[buffer(2)]],
                                  constant RayLogoUniforms &logo [[buffer(3)]]) {
    float2 p = (in.position.xy-u.resolution*0.5)/u.scale;
    float2 target = u.targetSize.x > 0 ? u.targetSize*0.5 : u.resolution/(2.0*u.scale)-u.inset/u.scale;
    return half4(rayRadiance(p,u,target,palette,transition,logo));
}

// Bloom runs at quarter resolution in private, reusable GPU textures. Four
// bilinear taps prefilter the bright pass; separable convolution has no CPU work.
kernel void rayBloomExtract(texture2d<half,access::sample> source [[texture(0)]],
                            texture2d<half,access::write> output [[texture(1)]],
                            uint2 id [[thread_position_in_grid]]) {
    if (id.x >= output.get_width() || id.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv = (float2(id)+0.5)/float2(output.get_width(),output.get_height());
    float2 d = 1.0/float2(source.get_width(),source.get_height());
    half3 color = (source.sample(s,uv+d).rgb+source.sample(s,uv-d).rgb+
                   source.sample(s,uv+d*float2(1,-1)).rgb+source.sample(s,uv+d*float2(-1,1)).rgb)*0.25h;
    half peak = max(color.r,max(color.g,color.b));
    color *= smoothstep(0.18h,0.90h,peak);
    output.write(half4(color,0),id);
}

kernel void rayBloomBlur(texture2d<half,access::sample> source [[texture(0)]],
                         texture2d<half,access::write> output [[texture(1)]],
                         constant float2 &axis [[buffer(0)]],
                         uint2 id [[thread_position_in_grid]]) {
    if (id.x >= output.get_width() || id.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 size = float2(output.get_width(),output.get_height());
    float2 uv = (float2(id)+0.5)/size;
    half3 sum = 0;
    float total = 0;
    for (int i=-8; i<=8; ++i) {
        float weight = exp(-float(i*i)/22.0);
        sum += source.sample(s,uv+axis*float(i)*1.5/size).rgb*half(weight);
        total += weight;
    }
    output.write(half4(sum/half(total),0),id);
}

fragment half4 rayCompositeFragment(VertexOutput in [[stage_in]],
                                    constant ShaderUniforms &u [[buffer(0)]],
                                    constant float4 &surface [[buffer(1)]],
                                    constant float4 &transition [[buffer(2)]],
                                    constant RayLogoUniforms &logo [[buffer(3)]],
                                    texture2d<half> radiance [[texture(0)]],
                                    texture2d<half> bloom [[texture(1)]],
                                    texture2d<float> logoColor [[texture(2)]]) {
    float2 pixel = in.position.xy;
    float2 uv = pixel/u.resolution;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 directLight = float4(radiance.read(uint2(pixel)));
    float4 light = directLight;
    float gather = logoGather(u.time,logo);
    float2 p = (pixel-u.resolution*0.5)/u.scale;
    float2 fit = logoFit(logo);
    // Condensation of the whole field towards the mark: 1 before the gather,
    // the window/mark ratio once the light has arrived. The mask below is
    // attached to this same scale, so it never appears as a separate small
    // logo inside a still-wide cone.
    float fieldScale = 1.0,condensation = 1.0;
    float2 rootPixel = u.resolution*0.5;
    if (logo.options.x > 0.5) {
        fieldScale = max(1.0,min(u.targetSize.x/fit.x,u.targetSize.y/fit.y));
        condensation = mix(1.0,fieldScale,gather);
        rootPixel = u.resolution*0.5+(u.targetOffset+logoEmitter(logo))*u.scale;
    }
    if (logo.options.x > 0.5 && gather > 0.0) {
        // Inverse-map the destination pixel through a growing uniform scale.
        // At the end, a logo-sized output samples the complete window-sized
        // radiance field. Every filament, noise cell and temporal variation is
        // therefore condensed into the mark rather than replaced by polygons.
        float2 targetCenter = u.resolution*0.5+u.targetOffset*u.scale;
        float2 targetHalf = u.targetSize*u.scale*0.5;
        float2 targetMin = targetCenter-targetHalf+12.0*u.scale;
        float2 targetMax = targetCenter+targetHalf-12.0*u.scale;
        float fieldRadius = min(min(rootPixel.x-targetMin.x,targetMax.x-rootPixel.x),
                                min(rootPixel.y-targetMin.y,targetMax.y-rootPixel.y))*0.62;
        float2 originalDelta = pixel-rootPixel;
        // The light first travels towards the selected direction, then the
        // same transport swings it back into the fixed orientation of the mark.
        // A rigid rotation of the sampling, not a rotated product logo.
        float2 aimedDelta = rotate2(originalDelta,(logoMarkAzimuth-logo.ending.x)*gather);
        float2 desiredDelta = aimedDelta*condensation;
        float desiredDistance = length(desiredDelta);
        // A tanh transport approaches the available source radius without ever
        // hitting it. Unlike clamp/repeat/zero sampling, it has no seam to show.
        float mappedDistance = fieldRadius*tanh(desiredDistance/max(fieldRadius,1.0));
        float2 boundedDelta = desiredDelta/max(desiredDistance,0.0001)*mappedDistance;
        float2 sourcePixel = rootPixel+mix(originalDelta,boundedDelta,gather);
        float2 sourceUV = sourcePixel/u.resolution;
        float4 warped = float4(radiance.sample(s,sourceUV));
        // Never clip the transported light. Its power falls continuously from
        // the emitter: a radial envelope whose reach contracts from far beyond
        // the window down to the mark itself. Neither the render-texture edge
        // nor an artificial boundary can become visible during the condensation.
        // The envelope's reach contracts with the field and its shoulder
        // steepens, so by the time the mark's silhouette becomes legible the
        // wide light has already lost its power rather than being masked.
        float reach = logoReach(logo,u.scale)*0.85;
        float envelopeReach = reach*pow(fieldScale,2.0*pow(1.0-gather,2.5));
        float shoulder = mix(2.2,4.0,gather);
        float powerEnvelope = exp(-pow(length(originalDelta)/max(envelopeReach,1.0),shoulder));
        warped.rgb *= powerEnvelope;
        // The window surface is the only bound. Light that the transport would
        // carry past the pane simply has no surface to land on; inside, the
        // coverage is already 1, so nothing is cropped within the field.
        warped.rgb *= directLight.a;
        // Do not cross-fade the old wide field with the condensed one. The UV
        // transform itself is continuous, so sampling it directly keeps one
        // physical shader state instead of a large ghost plus a small mark.
        light = float4(warped.rgb,directLight.a);
    }
    float settle = int(transition.x) == 1 ? smoother(1.35,1.95,u.time) : smoother(2.65,3.35,u.time);
    if (u.nativeSurface < 0.5 && settle < 1.0) {
        light.rgb += float3(bloom.sample(s,uv).rgb)*0.32*(1.0-settle);
    }
    // Smooth exposure shoulder, then linear-to-display conversion. Coverage is
    // derived from emitted light, avoiding black halos on a transparent desktop.
    // Exposure settles inside the same living volume, not into a static icon.
    float exposure = mix(1.0,logoCollectedExposure,pow(gather,0.72));
    float3 color = pow(1.0-exp(-max(light.rgb,float3(0))*exposure),float3(1.0/2.2));
    color *= mix(0.94,1.0,light.a);
    float alpha = max(light.a,max(color.r,max(color.g,color.b)));
    // A single scalar alpha over the ordinary macOS window color. It does not
    // depend on x/y, distance from the text, the ray source, or the palette.
    // w is an offscreen-only opacity override; live rendering always uses -1.
    bool flow = int(transition.x) == 1;
    float reveal = flow ? smoother(1.70,2.20,u.time) : smoother(2.25,3.25,u.time);
    float opacity = transition.w >= 0 ? transition.w : mix(1.0,surface.a,reveal);
    float3 emitted = color*opacity;
    if (logo.options.x > 0.5) {
        float2 extent = fit*0.60;
        float2 centered = p-u.targetOffset-logo.frame.xy;
        float2 local = (centered/fit+0.5)*logo.crop.zw+logo.crop.xy;
        constexpr sampler lobes(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
        // Level 0 is the untouched asset. The settled mark leaves by softening
        // into coarser levels while it fades (see the end of this block).
        float4 ink = logoColor.sample(lobes,clamp(local,float2(0),float2(1)),level(logo.exit.x*logo.exit.y));
        float assetMask = logoAssetMask(ink,local);

        // The silhouette is attached to the condensing field: while the field
        // is still larger than the mark, its terminal shape is magnified about
        // the same optical root by the same factor. Only in the last part of
        // the gather, when that shape already coincides with the light's power
        // envelope, does it become legible. There is never a small mark on
        // top of a wide cone, and nothing is cropped while wide light remains.
        float2 rootUV = logoRootUV();
        float2 attached = rootUV+(local-rootUV)*(condensation/fieldScale);
        float shape = smoother(0.78,1.0,gather);
        // Seven directions first appear as soft lobes of the light's own
        // distribution (a coarse mip of the mark), sharpening as it settles.
        float4 inkNow = logoColor.sample(lobes,clamp(attached,float2(0),float2(1)),level(8.0*(1.0-shape)));
        float attachedMask = logoAssetMask(inkNow,attached);
        float support = mix(1.0,attachedMask,shape);
        opacity = support*mix(1.0,logo.ending.y,pow(gather,0.72));
        opacity *= 1.0-exp(-max(light.r,max(light.g,light.b))*6.0);
        emitted = color*opacity;

        // The shader is already wholly contained by the original silhouette;
        // pigment only replaces its moving light with the asset's exact color.
        // Exactly 1 at the end: fast-math division can leave 1-ulp of shader
        // light in the final asset otherwise.
        float pigmentProgress = u.time >= logo.options.w ? 1.0 : smoother(logo.timing.w,logo.options.w,u.time);
        float pigment = logoSpatialClip(pigmentProgress,centered,extent,int(logo.options.z));
        if (pigment > 0.0) {
            float rayOpacity = opacity;
            emitted = mix(color*rayOpacity,ink.rgb*assetMask,pigment);
            opacity = mix(rayOpacity,assetMask,pigment);
            // End on the original asset's exact colors. No shader tint,
            // exposure adjustment, glint or animated modulation survives.
            // Interpolate covered color ONCE. Mixing straight color and alpha
            // separately multiplies two fades, creating a dark pulse at edges.
        }

        // The root disc of the mark, cut out of the rays early, by request:
        // the same dark circle the final logo has at its root, in the window's
        // own surface color. No light, no color, no glow. It grows from the
        // optical root with a soft edge that tightens as it settles, is
        // attached to the same condensing scale as the field, and hands the
        // region to the original asset (which is empty there) during pigment.
        float discRadius = logoDiscRadius*(fit.x/logo.crop.z)*u.scale*sqrt(fieldScale/condensation);
        float grow = smoother(logo.timing.x+0.10,logo.timing.x+0.60,u.time);
        float radius = discRadius*grow;
        float feather = mix(0.60,0.07,grow);
        float distance = length(pixel-rootPixel);
        float cut = (1.0-smoothstep(radius*(1.0-feather),radius*(1.0+feather*0.4),distance))*(1.0-pigment);
        emitted *= 1.0-cut;
        opacity *= 1.0-cut;
        // The settled mark's exit: everything this block emits fades together.
        emitted *= 1.0-logo.exit.z;
        opacity *= 1.0-logo.exit.z;
    }
    color = emitted+surface.rgb*light.a*(1.0-opacity);
    alpha = alpha*opacity+light.a*(1.0-opacity);
    if (u.nativeSurface < 0.5) {
        float2 edge = u.resolution/(2.0*u.scale)-abs(p);
        float feather = smoothstep(0.0,32.0,min(edge.x,edge.y));
        color *= feather;
        alpha *= feather;
    }
    float dither = (hash31(float3(floor((p-u.targetOffset)*u.scale),21.0))-0.5)/255.0;
    float birth = int(transition.x) == 1 ? smoother(0.06,0.60,u.time) : 1.0;
    return half4(float4(clamp(color+dither*min(alpha*16.0,1.0),0.0,alpha),alpha)*birth);
}

