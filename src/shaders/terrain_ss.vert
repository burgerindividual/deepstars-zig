#version 100

precision mediump float;

uniform vec2 sample_offset;

attribute vec2 position;

void main() {
    // z doesn't matter here because we have no depth buffer.
    // w is set to zoom slightly to avoid seams in the AA process.
    gl_Position = vec4(position + sample_offset, 0.0, 0.995);
}
