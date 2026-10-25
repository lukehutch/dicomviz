#version 460 core
#include <flutter/runtime_effect.glsl>

// GPU ray casting of a CT volume.
//
// The volume is stored as 8-bit densities in a 2D atlas: each texel holds
// three consecutive slices in R, G and B, and groups of three slices are laid
// out as tiles. A 256x256 pre-integrated lookup table maps a ray segment's
// (front density, back density) pair to the premultiplied color and opacity
// of that segment. The table encodes either translucent level-set surfaces
// or a banded volume transfer function, so this shader does not change
// between the two modes.

uniform vec2 uSize;        // viewport size in pixels
uniform vec4 uDims;        // volume size in voxels (x, y, z), slice groups
uniform vec4 uAtlas;       // tile columns, unused, atlas width, atlas height
uniform vec3 uExtent;      // box half-size in world units
uniform vec3 uCamPos;      // eye position in volume space
uniform vec3 uCamRight;    // camera basis in volume space
uniform vec3 uCamUp;
uniform vec3 uCamFwd;
uniform float uTanHalfFov;
uniform float uStep;       // step length in world units
uniform float uStepRatio;  // uStep / table step (opacity correction)
uniform float uShading;    // 0 = flat, 1 = lit
uniform float uGradStep;   // gradient stencil half-width in voxels
uniform vec4 uBackground;

uniform sampler2D uVolume;
uniform sampler2D uTable;

out vec4 fragColor;

const int MAX_STEPS = 1536;

// Density at slice z (integer), xy in voxels.
float sliceDensity(vec2 xy, float z) {
  float g = floor(z / 3.0);
  float ch = z - 3.0 * g;
  float row = floor(g / uAtlas.x);
  float col = g - row * uAtlas.x;
  vec2 p = clamp(xy + 0.5, vec2(0.5), uDims.xy - 0.5);
  vec2 uv = (vec2(col, row) * uDims.xy + p) / uAtlas.zw;
  vec3 t = texture(uVolume, uv).rgb;
  vec3 m = vec3(1.0 - step(0.5, ch), step(0.5, ch) * (1.0 - step(1.5, ch)), step(1.5, ch));
  return dot(t, m);
}

// Trilinear density at texture coordinate tc in [0,1]^3.
float density(vec3 tc) {
  vec3 v = tc * uDims.xyz - 0.5;
  float z = clamp(v.z, 0.0, uDims.z - 1.0);
  float z0 = floor(z);
  float z1 = min(z0 + 1.0, uDims.z - 1.0);
  float a = sliceDensity(v.xy, z0);
  float b = sliceDensity(v.xy, z1);
  return mix(a, b, z - z0);
}

// Gradient from the 8 corners of a cube uGradStep voxels from tc along
// each axis. Each component differences two faces of four samples, so
// voxel noise is averaged in all three directions; it otherwise shows as
// pits in lit surfaces.
vec3 gradient(vec3 tc) {
  vec3 h = uGradStep / uDims.xyz;
  float d000 = density(tc + vec3(-h.x, -h.y, -h.z));
  float d100 = density(tc + vec3(h.x, -h.y, -h.z));
  float d010 = density(tc + vec3(-h.x, h.y, -h.z));
  float d110 = density(tc + vec3(h.x, h.y, -h.z));
  float d001 = density(tc + vec3(-h.x, -h.y, h.z));
  float d101 = density(tc + vec3(h.x, -h.y, h.z));
  float d011 = density(tc + vec3(-h.x, h.y, h.z));
  float d111 = density(tc + vec3(h.x, h.y, h.z));
  return vec3(
      (d100 + d110 + d101 + d111) - (d000 + d010 + d001 + d011),
      (d010 + d110 + d011 + d111) - (d000 + d100 + d001 + d101),
      (d001 + d101 + d011 + d111) - (d000 + d100 + d010 + d110)) / (8.0 * h);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  // Screen position in [-1,1], y up, aspect-corrected.
  vec2 ndc = (frag - 0.5 * uSize) / (0.5 * uSize.y);
  ndc.y = -ndc.y;
  vec3 dir = normalize(uCamFwd + uTanHalfFov * (ndc.x * uCamRight + ndc.y * uCamUp));
  vec3 org = uCamPos;

  // Ray against the volume box.
  vec3 inv = 1.0 / dir;
  vec3 t0 = (-uExtent - org) * inv;
  vec3 t1 = (uExtent - org) * inv;
  vec3 tn = min(t0, t1);
  vec3 tf = max(t0, t1);
  float tNear = max(max(tn.x, tn.y), max(tn.z, 0.0));
  float tFar = min(min(tf.x, tf.y), tf.z);
  if (tNear >= tFar) {
    fragColor = uBackground;
    return;
  }

  // Jitter the start to turn sampling bands into fine noise.
  float jitter = fract(sin(dot(frag, vec2(12.9898, 78.233))) * 43758.5453);
  float t = tNear + jitter * uStep;
  vec3 toTc = 0.5 / uExtent;
  float sf = density((org + dir * t) * toTc + 0.5);
  vec4 acc = vec4(0.0);
  vec3 lightDir = -dir;

  for (int i = 0; i < MAX_STEPS; i++) {
    float tn2 = t + uStep;
    if (tn2 > tFar) break;
    vec3 tc = (org + dir * tn2) * toTc + 0.5;
    float sb = density(tc);
    vec4 s = texture(uTable, vec2(sf * 255.0 + 0.5, sb * 255.0 + 0.5) / 256.0);
    if (s.a > 0.002) {
      // Opacity correction when the step differs from the table's step.
      float a = 1.0 - pow(max(1.0 - s.a, 0.0), uStepRatio);
      vec3 c = s.rgb * (a / s.a);
      if (uShading > 0.5) {
        vec3 g = gradient(tc);
        float gl = length(g);
        if (gl > 1e-4) {
          vec3 n = g / gl;
          float diff = abs(dot(n, lightDir));
          vec3 hv = normalize(lightDir - dir);
          float spec = pow(abs(dot(n, hv)), 40.0);
          c = c * (0.25 + 0.75 * diff) + vec3(0.35 * spec) * a;
        }
      }
      acc.rgb += (1.0 - acc.a) * c;
      acc.a += (1.0 - acc.a) * a;
      if (acc.a > 0.985) break;
    }
    sf = sb;
    t = tn2;
  }
  vec3 bg = uBackground.rgb;
  fragColor = vec4(acc.rgb + (1.0 - acc.a) * bg, 1.0);
}
