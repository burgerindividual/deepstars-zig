#version 100
#extension GL_EXT_frag_depth : require

precision mediump float;

uniform sampler2D terrain_texture;

varying vec2 tex_coords;

void main() {
    float sample = texture2D(terrain_texture, tex_coords).a;
    
    gl_FragColor = vec4(0.02, 0.02, 0.051, sample);

    // theoretically anything above 0.75 should pass due to using 4 samples
    if (sample >= 0.9) {
        gl_FragDepthEXT = -1.0;
    } else {
        gl_FragDepthEXT = 1.0;
    }
}
