#version 450 core
#pragma stage : vert

#include <AdaEngine/View.glsl>

layout (location = 0) in vec4 a_Position;
layout (location = 1) in vec4 a_Color;
layout (location = 2) in vec2 a_TexCoordinate;

struct VertexOut
{
    vec2 TexCoordinate;
};

layout (location = 0) out VertexOut Output;

[[main]]
void linear_gradient_vertex()
{
    Output.TexCoordinate = a_TexCoordinate;
    gl_Position = u_ViewProjection * a_Position;
}

#version 450 core
#pragma stage : frag

layout (location = 0) out vec4 color;

struct VertexOut
{
    vec2 TexCoordinate;
};

layout (location = 0) in VertexOut Input;

layout (binding = 0) uniform GradientUniform {
    vec2 u_StartPoint;
    vec2 u_EndPoint;
    int u_StopCount;
    int u_Padding;
    vec4 u_StopColor0;
    vec4 u_StopColor1;
    vec4 u_StopColor2;
    vec4 u_StopColor3;
    vec4 u_StopColor4;
    vec4 u_StopColor5;
    vec4 u_StopColor6;
    vec4 u_StopColor7;
    vec4 u_StopColor8;
    vec4 u_StopColor9;
    vec4 u_StopColor10;
    vec4 u_StopColor11;
    vec4 u_StopColor12;
    vec4 u_StopColor13;
    vec4 u_StopColor14;
    vec4 u_StopColor15;
    vec4 u_StopLocations0;
    vec4 u_StopLocations1;
    vec4 u_StopLocations2;
    vec4 u_StopLocations3;
} gradient;

vec4 stopColor(int index) {
    switch (index) {
        case 0: return gradient.u_StopColor0;
        case 1: return gradient.u_StopColor1;
        case 2: return gradient.u_StopColor2;
        case 3: return gradient.u_StopColor3;
        case 4: return gradient.u_StopColor4;
        case 5: return gradient.u_StopColor5;
        case 6: return gradient.u_StopColor6;
        case 7: return gradient.u_StopColor7;
        case 8: return gradient.u_StopColor8;
        case 9: return gradient.u_StopColor9;
        case 10: return gradient.u_StopColor10;
        case 11: return gradient.u_StopColor11;
        case 12: return gradient.u_StopColor12;
        case 13: return gradient.u_StopColor13;
        case 14: return gradient.u_StopColor14;
        default: return gradient.u_StopColor15;
    }
}

float stopLocation(int index) {
    if (index < 4) {
        return gradient.u_StopLocations0[index];
    }
    if (index < 8) {
        return gradient.u_StopLocations1[index - 4];
    }
    if (index < 12) {
        return gradient.u_StopLocations2[index - 8];
    }
    return gradient.u_StopLocations3[index - 12];
}

float resolveGradientProgress(vec2 uv) {
    vec2 axis = gradient.u_EndPoint - gradient.u_StartPoint;
    float lengthSquared = dot(axis, axis);
    if (lengthSquared <= 0.000001) {
        return 1.0;
    }

    float projected = dot(uv - gradient.u_StartPoint, axis) / lengthSquared;
    return clamp(projected, 0.0, 1.0);
}

vec4 resolveGradientColor(float progress) {
    int stopCount = max(gradient.u_StopCount, 1);
    vec4 currentColor = stopColor(0);
    float currentLocation = stopLocation(0);

    if (stopCount == 1) {
        return currentColor;
    }

    for (int index = 1; index < stopCount; index++) {
        vec4 nextColor = stopColor(index);
        float nextLocation = stopLocation(index);

        if (progress <= nextLocation) {
            float range = nextLocation - currentLocation;
            if (range <= 0.000001) {
                return nextColor;
            }

            float t = clamp((progress - currentLocation) / range, 0.0, 1.0);
            return mix(currentColor, nextColor, t);
        }

        currentColor = nextColor;
        currentLocation = nextLocation;
    }

    return currentColor;
}

[[main]]
void linear_gradient_fragment()
{
    color = resolveGradientColor(resolveGradientProgress(Input.TexCoordinate));

    if (color.a == 0.0) {
        discard;
    }
}
