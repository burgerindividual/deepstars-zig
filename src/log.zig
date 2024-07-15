const std = @import("std");
const lib_glfw = @import("mach-glfw");
const lib_gl = @import("gl");

pub const glfw = std.log.scoped(.glfw);
pub const gl = std.log.scoped(.gl);

pub fn logGLFWError(error_code: lib_glfw.ErrorCode, description: [:0]const u8) void {
    glfw.err("{}: {s}\n", .{ error_code, description });
}

pub fn logGLError(
    source: lib_gl.@"enum",
    message_type: lib_gl.@"enum",
    id: lib_gl.uint,
    severity: lib_gl.@"enum",
    _: lib_gl.sizei,
    message: [*:0]const lib_gl.char,
    _: ?*const anyopaque,
) callconv(lib_gl.APIENTRY) void {
    const source_string: []const u8 = switch (source) {
        lib_gl.DEBUG_SOURCE_API_KHR => "API",
        lib_gl.DEBUG_SOURCE_APPLICATION_KHR => "Application",
        lib_gl.DEBUG_SOURCE_SHADER_COMPILER_KHR => "Shader Compiler",
        lib_gl.DEBUG_SOURCE_THIRD_PARTY_KHR => "Third Party",
        lib_gl.DEBUG_SOURCE_WINDOW_SYSTEM_KHR => "Window System",
        lib_gl.DEBUG_TYPE_OTHER_KHR => "Other",
        else => unreachable,
    };

    const type_string: []const u8 = switch (message_type) {
        lib_gl.DEBUG_TYPE_ERROR_KHR => "Error",
        lib_gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR_KHR => "Deprecated Behavior",
        lib_gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR_KHR => "Undefined Behavior",
        lib_gl.DEBUG_TYPE_PORTABILITY_KHR => "Portability",
        lib_gl.DEBUG_TYPE_PERFORMANCE_KHR => "Performance",
        lib_gl.DEBUG_TYPE_MARKER_KHR => "Marker",
        lib_gl.DEBUG_TYPE_PUSH_GROUP_KHR => "Push Group",
        lib_gl.DEBUG_TYPE_POP_GROUP_KHR => "Pop Group",
        lib_gl.DEBUG_TYPE_OTHER_KHR => "Other",
        else => unreachable,
    };

    switch (severity) {
        lib_gl.DEBUG_SEVERITY_HIGH_KHR => gl.err("Severity: High, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        lib_gl.DEBUG_SEVERITY_MEDIUM_KHR => gl.warn("Severity: Medium, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        lib_gl.DEBUG_SEVERITY_LOW_KHR => gl.info("Severity: Low, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        lib_gl.DEBUG_SEVERITY_NOTIFICATION_KHR => gl.info("Severity: Notification, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        else => unreachable,
    }
}
