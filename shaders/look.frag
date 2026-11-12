// The editor's adjustments and filters, for its preview: the same steps as
// saving takes (packages/native_imaging/src/look.cpp). Change one, change
// both.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uExposure;
uniform float uBrightness;
uniform float uContrast;
uniform float uHighlights;
uniform float uShadows;
uniform float uVignette;
uniform float uSaturation;
uniform float uWarmth;
uniform float uTint;
uniform float uMono;
uniform float uFade;
uniform sampler2D uImage;

out vec4 fragColor;

float luma(vec3 c) {
  return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec4 texel = texture(uImage, uv);
  float alpha = texel.a;
  vec3 c = alpha > 0.0 ? texel.rgb / alpha : vec3(0.0);

  // Light: exposure in stops (±1.5), then brightness as a curve through the
  // middle tones.
  c = pow(max(c * exp2(uExposure * 1.5), vec3(0.0)), vec3(exp2(-uBrightness * 0.8)));

  // Shadows and highlights: the dark and the bright, lifted or pulled down.
  float l = clamp(luma(c), 0.0, 1.0);
  c *= 1.0 + uShadows * 0.6 * (1.0 - l) * (1.0 - l) + uHighlights * 0.5 * l * l;

  // Contrast, about the middle grey.
  c = (c - 0.5) * (1.0 + uContrast * 0.6) + 0.5;

  // Colour: saturation, then as much black and white as asked for.
  l = luma(c);
  c = vec3(l) + (c - vec3(l)) * (1.0 + uSaturation);
  c = c + (vec3(l) - c) * uMono;

  // Warmth (blue to amber) and tint (green to magenta).
  c.r *= 1.0 + uWarmth * 0.15;
  c.b *= 1.0 - uWarmth * 0.15;
  c.g *= 1.0 - uTint * 0.12;

  // Faded: blacks lifted, whites a touch dimmer, as old prints.
  c = uFade * 0.12 + c * (1.0 - uFade * 0.22);

  // Vignette: the corners darkened, or for less than 0, lightened.
  float edge = smoothstep(0.35, 1.1, length(uv - 0.5) * 1.41421356);
  if (uVignette >= 0.0) {
    c *= 1.0 - uVignette * 0.75 * edge;
  } else {
    c += (1.0 - c) * (-uVignette * 0.6 * edge);
  }

  c = clamp(c, 0.0, 1.0);
  fragColor = vec4(c * alpha, alpha);
}
