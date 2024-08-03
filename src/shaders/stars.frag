#version 100

precision mediump float;

varying vec4 v_color;
varying float v_size;

const float border_size = 0.15;

void main() {
    float alpha = 1.0;
    if (v_size > 2.0) {
        vec2 point = gl_PointCoord - vec2(0.5);
        float border_in = 0.5 - border_size;
        float border_out = 0.5;
        alpha = min((length(point) - border_out) / (border_in - border_out), 1.0);
    }

    gl_FragColor = vec4(v_color.rgb, v_color.a * alpha);
}
