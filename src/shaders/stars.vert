#version 100

precision mediump float;

attribute vec4 a_color;
attribute vec3 position;
attribute float a_size;

varying vec4 v_color;
varying float v_size;

void main() {
    v_color = a_color;
    v_size = a_size;
    gl_PointSize = a_size;
    // do mat mul
    gl_Position = vec4(position, 1.0);
}
