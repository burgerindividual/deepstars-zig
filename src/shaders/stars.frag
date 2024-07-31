#version 100

precision mediump float;

varying vec4 v_color;
varying float v_border_size;

void main() {
    float alpha = 1.0;
    if (v_border_size < 0.5) {
        vec2 point = gl_PointCoord - vec2(0.5);
        float border_in = 0.5 - v_border_size;
        float border_out = 0.5;
        alpha = (length(point) - border_out) / (border_in - border_out);
    }
    // alpha = clamp((length(point) - border_out) / (border_in - border_out), 0.0, 1.0);
    // float alpha = smoothstep(0.5 + half_pixel, 0.5 - half_pixel,
    //         length(point));

    gl_FragColor = vec4(v_color.rgb, v_color.a * alpha);
}
