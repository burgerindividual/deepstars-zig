#version 100

precision mediump float;

varying vec4 v_color;
varying float v_size;

void main() {
    vec2 point = gl_PointCoord - vec2(0.5);
    float half_pixel = 0.5 / v_size;
    float border_in = 0.5 - half_pixel;
    float border_out = 0.5 + half_pixel;
    float alpha =
        clamp((length(point) - border_out) / (border_in - border_out), 0.0, 1.0);
    // float alpha = smoothstep(0.5 + half_pixel, 0.5 - half_pixel,
    // length(point));

    gl_FragColor = vec4(v_color.rgb, v_color.a * alpha);
}
