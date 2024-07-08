#version 100

precision mediump float;

uniform sampler2D framebuffer;
uniform float opacity;

varying vec2 tex_coords;

void main() {
    vec4 sample = texture2D(framebuffer, tex_coords);
    float alpha = sample.a * opacity;
    // the premultiplication expects a black clear color
    vec3 color_premultiplied = sample.rgb * alpha;
    gl_FragColor = vec4(color_premultiplied, 1.0);
}
