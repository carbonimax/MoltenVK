#version 450
layout(location = 0) in vec4 position;
layout(location = 0) out vec4 value;
out gl_PerVertex { vec4 gl_Position; };
void main() { gl_Position = position; value = position; }
