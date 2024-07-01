#version 100

precision mediump float;

uniform sampler2D framebuffer;

varying vec2 tex_coords;

void main() {
    gl_FragColor = texture2D(framebuffer, tex_coords);
}
