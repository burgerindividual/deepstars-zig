#version 100
#extension GL_EXT_frag_depth : require

precision mediump float;

uniform sampler2D terrain_texture;

varying vec2 tex_coords;

void main() {
    float sample = texture2D(terrain_texture, tex_coords).a;
    
    gl_FragColor = vec4(0.02, 0.02, 0.051, sample);
}
