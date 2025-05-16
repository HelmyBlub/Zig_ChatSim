#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 transformation;
    vec2 translate;
} ubo;

layout(location = 0) in vec2 inPosition;

layout(location = 0) out vec2 scale;
layout(location = 1) out uint spriteIndex;
layout(location = 2) out uint size;
layout(location = 3) out float rotate;
layout(location = 4) out float cutY;

void main() {
    const uint IMAGE_BIG_HOUSE = 8;
    gl_Position = ubo.transformation * vec4(inPosition + ubo.translate, 1, 1);
    gl_Position[2] = 0.9 - (gl_Position[1] / gl_Position[3] + 1) / 3.0;
    spriteIndex = IMAGE_BIG_HOUSE;
    scale[0] = ubo.transformation[0][0];
    scale[1] = ubo.transformation[1][1];
    size = 20;
    rotate = 0;
    cutY = 0;
}
