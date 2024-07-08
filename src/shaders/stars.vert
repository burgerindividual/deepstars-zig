#version 100

precision mediump float;

uniform mat4 mvp_matrix;
uniform float global_scale;

attribute vec4 a_color;
attribute vec3 position;
attribute float a_size;

varying vec4 v_color;
varying float v_size;

void main() {
    v_color = a_color;
    v_size = a_size * global_scale;
    gl_PointSize = v_size;
    gl_Position = mvp_matrix * vec4(position, 1.0);
}
