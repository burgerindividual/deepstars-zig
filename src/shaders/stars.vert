#version 100

precision highp float;

uniform mat4 mvp_matrix;
uniform float global_scale;

attribute vec4 a_color;
attribute vec3 position;
attribute float a_size;

varying vec4 v_color;
varying float v_size;

const float pi = 3.1415926535897932384626433832795;
const float border_size = 0.15;
const float circle_radius_scale = 0.5 - (border_size / 2.0);
const float circle_radius_scale_sq = circle_radius_scale * circle_radius_scale;

float square(float x) {
    return x * x;
}

void main() {
    float size = a_size * global_scale;
    // if the star is very small, size up and dim the star proportionally to it's surface area.
    // account for size when smaller than 1.0.
    float circle_area_ratio = pi * circle_radius_scale_sq * square(min(size, 1.0));
    float single_pixel_alpha_mod = size < 2.0 ? circle_area_ratio : 1.0;
    v_size = size;
    v_color = vec4(a_color.rgb, a_color.a * single_pixel_alpha_mod);
    gl_PointSize = max(size, 1.0);
    gl_Position = mvp_matrix * vec4(position, 1.0);
}
