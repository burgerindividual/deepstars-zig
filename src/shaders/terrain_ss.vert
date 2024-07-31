#version 100

precision highp float;

uniform mat4 mvp_matrix;
uniform vec2 sample_offset;

attribute vec3 position;

void main() {
    vec4 initial_position = mvp_matrix * vec4(position, 1.0);
    vec2 normalized_sample_offset = sample_offset * initial_position.w;
    vec4 sample_position = vec4(initial_position.xy + normalized_sample_offset, initial_position.zw);
    gl_Position = sample_position;
}
