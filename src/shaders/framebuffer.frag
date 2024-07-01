#version 100

precision mediump float;

uniform sampler2D framebuffer;
uniform float opacity;

varying vec2 tex_coords;

void main() {
    vec4 sample = texture2D(framebuffer, tex_coords);
    gl_FragColor = vec4(sample.rgb, sample.a * opacity);
}
