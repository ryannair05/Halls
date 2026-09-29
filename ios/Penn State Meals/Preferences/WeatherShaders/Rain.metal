//
//  Rain.metal
//  Penn State Meals
//
//  Created by Ryan Nair on 9/27/26.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
#include "WeatherNoise.h"
using namespace metal;

// Point-space cells keep drops the same size on phones, tablets and previews.
static float rainLayer(float2 position, float time, float spacing, float speed,
                       float wind, float width, float length, float density) {
    float2 p = float2(position.x + position.y * wind, position.y);
    float column = floor(p.x / spacing);
    float columnSeed = hash11(column + spacing);
    float fallSpeed = speed * mix(0.8, 1.2, columnSeed);
    float cellHeight = length * 5.0;
    float travel = p.y - time * fallSpeed + columnSeed * 173.0;
    float row = floor(travel / cellHeight);
    float y = fract(travel / cellHeight) * cellHeight;
    float seed = hash21(float2(column, row));
    float present = step(1.0 - density, seed);
    float center = spacing * (0.2 + 0.6 * hash21(float2(column + 13.7, row)));
    float x = fract(p.x / spacing) * spacing - center;
    float line = 1.0 - smoothstep(0.0, width, abs(x));
    float dropLength = length * mix(0.65, 1.15, hash21(float2(column + 31.0, row)));
    float trail = smoothstep(0.0, dropLength, y)
                * (1.0 - smoothstep(dropLength, dropLength + 1.0, y));
    return line * trail * present;
}

[[ stitchable ]]
half4 Rain(float2 position, half4 color, float2 size, float time,
           float intensity, float wind, float speed, float darkAppearance) {
    // Most drops sit quietly in the distance. Only a few pass near the viewer.
    float slant = clamp(wind, -0.18, 0.18);
    float far = rainLayer(position, time, 13.0, 240.0 * speed, slant * 0.75,
                          0.65, 12.0, intensity * 0.65);
    float mid = rainLayer(position + float2(71.0, 37.0), time, 23.0, 370.0 * speed,
                          slant, 0.85, 21.0, intensity * 0.42);
    float near = rainLayer(position + float2(19.0, 83.0), time, 41.0, 510.0 * speed,
                           slant * 1.1, 1.1, 29.0, intensity * 0.13);
    float appearanceGain = mix(2.0, 1.0, darkAppearance);
    half alpha = half(saturate((far * 0.14 + mid * 0.22 + near * 0.27) * appearanceGain));
    half3 tint = mix(half3(0.20h, 0.30h, 0.40h), half3(0.78h, 0.86h, 0.94h), half(darkAppearance));
    return half4(tint * alpha, alpha);
}
