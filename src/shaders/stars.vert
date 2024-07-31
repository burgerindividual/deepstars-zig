#version 100

precision highp float;

uniform mat4 mvp_matrix;
uniform float global_scale;

attribute vec4 a_color;
attribute vec3 position;
attribute float a_size;

varying vec4 v_color;
varying float v_border_size;

void main() {
    float size = a_size * global_scale;
    v_border_size = 1.0 / size;
    v_color = a_color; //vec4(a_color.rgb, a_color.a * min(size, 1.0));
    gl_PointSize = size;
    gl_Position = mvp_matrix * vec4(position, 1.0);
}
