#version 100
#extension GL_EXT_frag_depth : require

precision mediump float;

uniform sampler2D framebuffer;

varying vec2 tex_coords;

void main() {
    vec4 sample = texture2D(framebuffer, tex_coords);
    if (sample.a != 1.0) {
        gl_FragDepth = 1.0;
    }
    gl_FragColor = sample;
}
