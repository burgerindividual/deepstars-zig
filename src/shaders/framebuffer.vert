#version 100

precision highp float;

attribute vec2 position;

varying vec2 tex_coords;

void main() {
    tex_coords = 0.5 * position + vec2(0.5);
    gl_Position = vec4(position, -0.9, 1.0);
}
