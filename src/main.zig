const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const log = @import("log.zig");
const zm = @import("zmath");

const fov_y_degrees = 45.0;
const star_scale_degrees = 0.28;

const terrain_divisions: u16 = 600;
const terrain_octaves = 7;
const terrain_amplitude = 0.25;
const terrain_y_offset = -0.9;

var gl_procs: gl.ProcTable = undefined;

pub fn main() !void {
    glfw.setErrorCallback(log.logGLFWError);

    if (!glfw.init(.{ .platform = getPreferredPlatform() })) {
        return error.GLFWInitFailed;
    }
    defer glfw.terminate();

    const primary_monitor = glfw.Monitor.getPrimary();

    var preferred_width: u32 = 640;
    var preferred_height: u32 = 480;
    if (primary_monitor) |monitor| {
        if (monitor.getVideoMode()) |video_mode| {
            preferred_width = video_mode.getWidth();
            preferred_height = video_mode.getHeight();
        }
    }

    // Create our window, specifying that we want to use OpenGL.
    const window: glfw.Window = glfw.Window.create(
        preferred_width,
        preferred_height,
        "DarkStars",
        primary_monitor,
        null,
        .{
            .context_version_major = gl.info.version_major,
            .context_version_minor = gl.info.version_minor,
            .context_debug = std.debug.runtime_safety,
            .client_api = .opengl_es_api,
            .decorated = false,
            .transparent_framebuffer = false,
            .stencil_bits = 0,
            // .srgb_capable = true,
            // what happens if the platform doesn't support KHR_no_error?
            // .context_no_error = !std.debug.runtime_safety,
            // .context_creation_api = .egl_context_api,
            // .samples = 8,
        },
    ) orelse {
        return error.CreateWindowFailed;
    };
    defer window.destroy();

    // Make the window's OpenGL context current.
    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    // Make sure viewport stays consistent with framebuffer
    window.setFramebufferSizeCallback(onFramebufferResized);
    window.setKeyCallback(onKeyEvent);

    // Disable cursor
    window.setInputModeCursor(.hidden);

    // Enable VSync to avoid drawing more often than necessary.
    glfw.swapInterval(1);

    // Initialize the OpenGL procedure table.
    if (!gl_procs.init(glfw.getProcAddress)) {
        log.gl.err("failed to load OpenGL functions", .{});
        return error.GLInitFailed;
    }

    // Make the OpenGL procedure table current.
    gl.makeProcTableCurrent(&gl_procs);
    defer gl.makeProcTableCurrent(null);

    // Enable debug messages in debug mode if possible
    if (std.debug.runtime_safety and glfw.extensionSupported("GL_KHR_debug")) {
        gl.DebugMessageCallbackKHR(log.logGLError, null);
        // Enable all messages
        gl.DebugMessageControlKHR(
            gl.DONT_CARE,
            gl.DONT_CARE,
            gl.DONT_CARE,
            0,
            null,
            gl.TRUE,
        );

        const message: [:0]const u8 = "OpenGL Debug Messages Initialized";
        gl.DebugMessageInsertKHR(
            gl.DEBUG_SOURCE_APPLICATION_KHR,
            gl.DEBUG_TYPE_OTHER_KHR,
            0,
            gl.DEBUG_SEVERITY_NOTIFICATION_KHR,
            message.len,
            message,
        );
    }

    var random = std.Random.Xoroshiro128.init(@bitCast(std.time.milliTimestamp()));
    const rand = random.random();

    ////
    //// Set up matrices and star geometry
    ////
    const up_dir_quaternion = zm.quatFromNormAxisAngle(
        zm.f32x4(1.0, 0.0, 0.0, 1.0),
        std.math.tau * rand.float(f32),
    );
    const look_dir_quaternion = zm.quatFromNormAxisAngle(
        zm.f32x4(0.0, 0.0, 1.0, 1.0),
        std.math.tau * rand.float(f32),
    );
    const up_direction = zm.rotate(
        up_dir_quaternion,
        zm.f32x4(0.0, 0.0, 1.0, 1.0),
    );
    const look_direction = zm.rotate(
        zm.qmul(
            look_dir_quaternion,
            up_dir_quaternion,
        ),
        zm.f32x4(1.0, 0.0, 0.0, 1.0),
    );
    // +Z represents the north pole, but we randomize the up direction
    // +X represents going into the screen
    const view_matrix = zm.lookToRh(
        zm.f32x4(0.0, 0.0, 0.0, 0.0),
        look_direction,
        up_direction,
    );

    // Enable blending
    gl.Enable(gl.BLEND);

    // Enable depth test (good for stars behind mountains)
    gl.Enable(gl.DEPTH_TEST);

    // Create vertex arrays for the stars and terrain pipelines
    var vertex_arrays: [4]gl.uint = undefined;
    gl.GenVertexArraysOES(vertex_arrays.len, &vertex_arrays);
    defer gl.DeleteVertexArraysOES(vertex_arrays.len, &vertex_arrays);
    const terrain_vao = vertex_arrays[0];
    const stars_vao = vertex_arrays[1];
    const framebuffer_vao = vertex_arrays[2];
    const terrain_tex_vao = vertex_arrays[3];

    ////
    //// FRAMEBUFFER DRAW SETUP
    ////

    // Create and fill the vertex and index buffers
    gl.BindVertexArrayOES(framebuffer_vao);

    var framebuffer_vertex_buffer: gl.uint = undefined;
    gl.GenBuffers(1, @as(*[1]gl.uint, &framebuffer_vertex_buffer));
    defer gl.DeleteBuffers(1, @as(*[1]gl.uint, &framebuffer_vertex_buffer));

    gl.BindBuffer(gl.ARRAY_BUFFER, framebuffer_vertex_buffer);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(@TypeOf(framebuffer_vertices)),
        &framebuffer_vertices,
        gl.STATIC_DRAW,
    );

    // Set up shaders
    const framebuffer_vert_shader_text = @embedFile("shaders/framebuffer.vert");
    const framebuffer_vert_shader = gl.CreateShader(gl.VERTEX_SHADER);
    defer gl.DeleteShader(framebuffer_vert_shader);
    gl.ShaderSource(
        framebuffer_vert_shader,
        1,
        &.{framebuffer_vert_shader_text},
        &.{framebuffer_vert_shader_text.len},
    );
    gl.CompileShader(framebuffer_vert_shader);

    const framebuffer_frag_shader_text = @embedFile("shaders/framebuffer.frag");
    const framebuffer_frag_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    defer gl.DeleteShader(framebuffer_frag_shader);
    gl.ShaderSource(
        framebuffer_frag_shader,
        1,
        &.{framebuffer_frag_shader_text},
        &.{framebuffer_frag_shader_text.len},
    );
    gl.CompileShader(framebuffer_frag_shader);

    const framebuffer_program = gl.CreateProgram();
    defer gl.DeleteProgram(framebuffer_program);
    gl.AttachShader(framebuffer_program, framebuffer_vert_shader);
    gl.AttachShader(framebuffer_program, framebuffer_frag_shader);
    gl.LinkProgram(framebuffer_program);
    gl.UseProgram(framebuffer_program);

    // Set up vertex attributes
    gl.BindAttribLocation(framebuffer_program, framebuffer_pos_attrib, "position");
    // tightly packed vec2 array
    gl.VertexAttribPointer(
        framebuffer_pos_attrib,
        2,
        gl.FLOAT,
        gl.FALSE,
        0,
        0,
    );
    gl.EnableVertexAttribArray(framebuffer_pos_attrib);

    const opacity_uniform = gl.GetUniformLocation(framebuffer_program, "opacity");

    ////
    //// STARS SETUP
    ////

    // Create stars vertex buffer, fill it with some data so we can use BufferSubData later
    gl.BindVertexArrayOES(stars_vao);

    var stars_vertex_buffer: gl.uint = undefined;
    gl.GenBuffers(1, @as(*[1]gl.uint, &stars_vertex_buffer));
    defer gl.DeleteBuffers(1, @as(*[1]gl.uint, &stars_vertex_buffer));

    gl.BindBuffer(gl.ARRAY_BUFFER, stars_vertex_buffer);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(@TypeOf(stars_geometry.vertices)),
        &stars_geometry.vertices,
        gl.STATIC_DRAW,
    );

    // Set up shaders
    const stars_vert_shader_text = @embedFile("shaders/stars.vert");
    const stars_vert_shader = gl.CreateShader(gl.VERTEX_SHADER);
    defer gl.DeleteShader(stars_vert_shader);
    gl.ShaderSource(
        stars_vert_shader,
        1,
        &.{stars_vert_shader_text},
        &.{stars_vert_shader_text.len},
    );
    gl.CompileShader(stars_vert_shader);

    const stars_frag_shader_text = @embedFile("shaders/stars.frag");
    const stars_frag_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    defer gl.DeleteShader(stars_frag_shader);
    gl.ShaderSource(
        stars_frag_shader,
        1,
        &.{stars_frag_shader_text},
        &.{stars_frag_shader_text.len},
    );
    gl.CompileShader(stars_frag_shader);

    const stars_program = gl.CreateProgram();
    defer gl.DeleteProgram(stars_program);
    gl.AttachShader(stars_program, stars_vert_shader);
    gl.AttachShader(stars_program, stars_frag_shader);
    gl.LinkProgram(stars_program);
    gl.UseProgram(stars_program);

    // Set up vertex attributes
    gl.BindAttribLocation(stars_program, stars_color_attrib, "a_color");
    // vec4
    gl.VertexAttribPointer(
        stars_color_attrib,
        4,
        gl.FLOAT,
        gl.FALSE,
        32,
        0,
    );
    gl.EnableVertexAttribArray(stars_color_attrib);

    gl.BindAttribLocation(stars_program, stars_pos_attrib, "position");
    // vec3
    gl.VertexAttribPointer(
        stars_pos_attrib,
        3,
        gl.FLOAT,
        gl.FALSE,
        32,
        16,
    );
    gl.EnableVertexAttribArray(stars_pos_attrib);

    gl.BindAttribLocation(stars_program, stars_size_attrib, "a_size");
    // float
    gl.VertexAttribPointer(
        stars_size_attrib,
        1,
        gl.FLOAT,
        gl.FALSE,
        32,
        28,
    );
    gl.EnableVertexAttribArray(stars_size_attrib);

    const global_scale_uniform = gl.GetUniformLocation(stars_program, "global_scale");
    const mvp_matrix_uniform = gl.GetUniformLocation(stars_program, "mvp_matrix");

    // Create stars framebuffer and texture
    var stars_framebuffer: gl.uint = undefined;
    gl.GenFramebuffers(1, @as(*[1]gl.uint, &stars_framebuffer));
    defer gl.DeleteFramebuffers(1, @as(*[1]gl.uint, &stars_framebuffer));

    var stars_fb_texture: gl.uint = undefined;
    gl.GenTextures(1, @as(*[1]gl.uint, &stars_fb_texture));
    defer gl.DeleteTextures(1, @as(*[1]gl.uint, &stars_fb_texture));

    gl.BindFramebuffer(gl.FRAMEBUFFER, stars_framebuffer);
    gl.BindTexture(gl.TEXTURE_2D, stars_fb_texture);
    // the default parameters rely on mipmaps, which we don't want
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        stars_fb_texture,
        0,
    );

    ////
    //// TERRAIN SETUP
    ////

    // Build the terrain
    const terrain_geometry = genTerrainGeometry(rand);

    // Create and fill the vertex and index buffers
    gl.BindVertexArrayOES(terrain_vao);

    var terrain_buffers: [2]gl.uint = undefined;
    gl.GenBuffers(terrain_buffers.len, &terrain_buffers);
    defer gl.DeleteBuffers(terrain_buffers.len, &terrain_buffers);
    const terrain_vertex_buffer = terrain_buffers[0];
    const terrain_index_buffer = terrain_buffers[1];

    gl.BindBuffer(gl.ARRAY_BUFFER, terrain_vertex_buffer);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(@TypeOf(terrain_geometry.vertices)),
        &terrain_geometry.vertices,
        gl.STATIC_DRAW,
    );

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, terrain_index_buffer);
    gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @sizeOf(@TypeOf(terrain_geometry.indices)),
        &terrain_geometry.indices,
        gl.STATIC_DRAW,
    );

    // Set up shaders
    const terrain_vert_shader_text = @embedFile("shaders/terrain_ss.vert");
    const terrain_vert_shader = gl.CreateShader(gl.VERTEX_SHADER);
    defer gl.DeleteShader(terrain_vert_shader);
    gl.ShaderSource(
        terrain_vert_shader,
        1,
        &.{terrain_vert_shader_text},
        &.{terrain_vert_shader_text.len},
    );
    gl.CompileShader(terrain_vert_shader);

    const terrain_frag_shader_text = @embedFile("shaders/terrain_ss.frag");
    const terrain_frag_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    defer gl.DeleteShader(terrain_frag_shader);
    gl.ShaderSource(
        terrain_frag_shader,
        1,
        &.{terrain_frag_shader_text},
        &.{terrain_frag_shader_text.len},
    );
    gl.CompileShader(terrain_frag_shader);

    const terrain_program = gl.CreateProgram();
    defer gl.DeleteProgram(terrain_program);
    gl.AttachShader(terrain_program, terrain_vert_shader);
    gl.AttachShader(terrain_program, terrain_frag_shader);
    gl.LinkProgram(terrain_program);
    gl.UseProgram(terrain_program);

    // Set up vertex attributes
    gl.BindAttribLocation(terrain_program, terrain_pos_attrib, "position");
    // tightly packed vec2 array
    gl.VertexAttribPointer(
        terrain_pos_attrib,
        2,
        gl.FLOAT,
        gl.FALSE,
        0,
        0,
    );
    gl.EnableVertexAttribArray(terrain_pos_attrib);

    // Create terrain framebuffer and texture
    var terrain_framebuffer: gl.uint = undefined;
    gl.GenFramebuffers(1, @as(*[1]gl.uint, &terrain_framebuffer));
    defer gl.DeleteFramebuffers(1, @as(*[1]gl.uint, &terrain_framebuffer));

    var terrain_fb_texture: gl.uint = undefined;
    gl.GenTextures(1, @as(*[1]gl.uint, &terrain_fb_texture));
    defer gl.DeleteTextures(1, @as(*[1]gl.uint, &terrain_fb_texture));

    gl.BindFramebuffer(gl.FRAMEBUFFER, terrain_framebuffer);
    gl.BindTexture(gl.TEXTURE_2D, terrain_fb_texture);
    // the default parameters rely on mipmaps, which we don't want
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

    gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        terrain_fb_texture,
        0,
    );

    const sample_offset_uniform = gl.GetUniformLocation(terrain_program, "sample_offset");

    // Terrain texture setup

    // get max height of what we drew, then scale and add a small buffer
    var max_height: f32 = -1.0;
    for (terrain_geometry.vertices) |vertex| {
        max_height = @max(max_height, vertex.y);
    }
    // account for W coordinate in shader
    max_height /= 0.995;
    max_height += 0.005;

    const terrain_tex_vertices = [_]Vertex2D{
        .{ .x = -1.0, .y = max_height },
        .{ .x = -1.0, .y = -1.0 },
        .{ .x = 1.0, .y = max_height },
        .{ .x = 1.0, .y = -1.0 },
    };

    // Create and fill the vertex and index buffers
    gl.BindVertexArrayOES(terrain_tex_vao);

    var terrain_tex_buffers: [2]gl.uint = undefined;
    gl.GenBuffers(terrain_tex_buffers.len, &terrain_tex_buffers);
    defer gl.DeleteBuffers(terrain_tex_buffers.len, &terrain_tex_buffers);
    const terrain_tex_vertex_buffer = terrain_tex_buffers[0];
    const terrain_tex_index_buffer = terrain_tex_buffers[1];

    gl.BindBuffer(gl.ARRAY_BUFFER, terrain_tex_vertex_buffer);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(@TypeOf(terrain_tex_vertices)),
        &terrain_tex_vertices,
        gl.STATIC_DRAW,
    );

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, terrain_tex_index_buffer);
    gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @sizeOf(@TypeOf(terrain_tex_indices)),
        &terrain_tex_indices,
        gl.STATIC_DRAW,
    );

    // Set up shaders
    const terrain_tex_depth_frag_shader_text = @embedFile("shaders/terrain_tex_depth.frag");
    const terrain_tex_depth_frag_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    defer gl.DeleteShader(terrain_tex_depth_frag_shader);
    gl.ShaderSource(
        terrain_tex_depth_frag_shader,
        1,
        &.{terrain_tex_depth_frag_shader_text},
        &.{terrain_tex_depth_frag_shader_text.len},
    );
    gl.CompileShader(terrain_tex_depth_frag_shader);

    const terrain_tex_depth_program = gl.CreateProgram();
    defer gl.DeleteProgram(terrain_tex_depth_program);
    gl.AttachShader(terrain_tex_depth_program, framebuffer_vert_shader);
    gl.AttachShader(terrain_tex_depth_program, terrain_tex_depth_frag_shader);
    gl.LinkProgram(terrain_tex_depth_program);
    gl.UseProgram(terrain_tex_depth_program);

    const terrain_tex_color_frag_shader_text = @embedFile("shaders/terrain_tex_color.frag");
    const terrain_tex_color_frag_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    defer gl.DeleteShader(terrain_tex_color_frag_shader);
    gl.ShaderSource(
        terrain_tex_color_frag_shader,
        1,
        &.{terrain_tex_color_frag_shader_text},
        &.{terrain_tex_color_frag_shader_text.len},
    );
    gl.CompileShader(terrain_tex_color_frag_shader);

    const terrain_tex_color_program = gl.CreateProgram();
    defer gl.DeleteProgram(terrain_tex_color_program);
    gl.AttachShader(terrain_tex_color_program, framebuffer_vert_shader);
    gl.AttachShader(terrain_tex_color_program, terrain_tex_color_frag_shader);
    gl.LinkProgram(terrain_tex_color_program);
    gl.UseProgram(terrain_tex_color_program);

    // Set up vertex attributes
    gl.BindAttribLocation(terrain_tex_color_program, terrain_tex_pos_attrib, "position");
    // tightly packed vec2 array
    gl.VertexAttribPointer(
        terrain_tex_pos_attrib,
        2,
        gl.FLOAT,
        gl.FALSE,
        0,
        0,
    );
    gl.EnableVertexAttribArray(terrain_tex_pos_attrib);

    // bind default framebuffer
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0);

    var global_star_scale: f32 = undefined;
    var smear_start_time: i64 = -1;
    var smear_end_time: i64 = -1;

    var projection_matrix: zm.Mat = undefined;

    // create fake resize event to initialize things that rely on the window size
    {
        const framebuffer_size = window.getFramebufferSize();
        resize_event = ResizeEvent{
            .width = framebuffer_size.width,
            .height = framebuffer_size.height,
        };
    }

    main_loop: while (true) {
        glfw.pollEvents();

        if (window.shouldClose()) break :main_loop;

        const ms_time: i64 = std.time.milliTimestamp();

        var stars_fb_needs_clear = false;
        var stars_smear_opacity: f32 = 0.0;
        if (ms_time > smear_start_time and ms_time < smear_end_time) {
            const smear_time_remaining = smear_end_time - ms_time;
            stars_smear_opacity = @min(@as(f32, @floatFromInt(smear_time_remaining)) / 5000.0, 1.0);
        } else if (ms_time >= smear_end_time) {
            smear_start_time = ms_time + rand.intRangeAtMost(u32, 15000, 80000);
            smear_end_time = smear_start_time + rand.intRangeAtMost(u32, 20000, 50000);
            stars_fb_needs_clear = true;
        }

        if (resize_event) |e| {
            const width_f: f32 = @floatFromInt(e.width);
            const height_f: f32 = @floatFromInt(e.height);
            const width: gl.sizei = @intCast(e.width);
            const height: gl.sizei = @intCast(e.height);

            const aspect_ratio = width_f / height_f;
            // don't use GL version, we want the depth values between 0 and 1
            projection_matrix = zm.perspectiveFovRh(
                fov_y_degrees * std.math.rad_per_deg,
                aspect_ratio,
                0.1,
                2.0,
            );

            // 220 generally seems realistic
            global_star_scale = (height_f / fov_y_degrees) * star_scale_degrees;

            gl.Viewport(0, 0, width, height);

            gl.BindTexture(gl.TEXTURE_2D, stars_fb_texture);
            gl.TexImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                width,
                height,
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                null,
            );
            stars_fb_needs_clear = true;

            const px_width = 2.0 / @as(f64, @floatFromInt(e.width));
            const px_height = 2.0 / @as(f64, @floatFromInt(e.height));
            const sample_offset_1: f32 = @floatCast(px_width / 8.0);
            const sample_offset_2: f32 = @floatCast((px_height * 3.0) / 8.0);

            gl.BindTexture(gl.TEXTURE_2D, terrain_fb_texture);
            gl.TexImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                width,
                height,
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                null,
            );

            gl.BindFramebuffer(gl.FRAMEBUFFER, terrain_framebuffer);
            gl.ClearColor(0.0, 0.0, 0.0, 0.0);
            // no depth on render target
            gl.Clear(gl.COLOR_BUFFER_BIT);

            // draw terrain to texture using 4 samples in a titled square pattern
            gl.BlendFunc(gl.ONE, gl.ONE);
            gl.BlendEquation(gl.FUNC_ADD);
            gl.UseProgram(terrain_program);
            gl.BindVertexArrayOES(terrain_vao);
            gl.Uniform2f(sample_offset_uniform, -sample_offset_1, sample_offset_2);
            gl.DrawElements(gl.TRIANGLES, terrain_indices, gl.UNSIGNED_SHORT, 0);
            gl.Uniform2f(sample_offset_uniform, sample_offset_1, -sample_offset_2);
            gl.DrawElements(gl.TRIANGLES, terrain_indices, gl.UNSIGNED_SHORT, 0);
            gl.Uniform2f(sample_offset_uniform, sample_offset_2, sample_offset_1);
            gl.DrawElements(gl.TRIANGLES, terrain_indices, gl.UNSIGNED_SHORT, 0);
            gl.Uniform2f(sample_offset_uniform, -sample_offset_2, -sample_offset_1);
            gl.DrawElements(gl.TRIANGLES, terrain_indices, gl.UNSIGNED_SHORT, 0);

            gl.BlendFuncSeparate(
                gl.SRC_ALPHA,
                gl.ONE_MINUS_SRC_ALPHA,
                gl.ONE,
                gl.ONE_MINUS_SRC_ALPHA,
            );

            resize_event = null;
        }

        // Render terrain texture
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.DepthMask(gl.TRUE);
        gl.ClearColor(0.0, 0.0, 0.0, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.UseProgram(terrain_tex_depth_program);
        gl.BindVertexArrayOES(terrain_tex_vao);
        gl.BindTexture(gl.TEXTURE_2D, terrain_fb_texture);
        gl.DrawElements(gl.TRIANGLES, terrain_tex_indices.len, gl.UNSIGNED_SHORT, 0);

        // Render stars and smears
        if (stars_fb_needs_clear) {
            gl.BindFramebuffer(gl.FRAMEBUFFER, stars_framebuffer);
            gl.ClearColor(0.0, 0.0, 0.0, 0.0);
            gl.Clear(gl.COLOR_BUFFER_BIT);

            stars_fb_needs_clear = false;
        } else if (stars_smear_opacity > 0.0) {
            // don't rebind if already bound
            gl.BindFramebuffer(gl.FRAMEBUFFER, stars_framebuffer);
        }

        gl.DepthMask(gl.FALSE);
        gl.UseProgram(stars_program);
        gl.BindVertexArrayOES(stars_vao);

        const angle = @as(f32, @floatFromInt(@mod(ms_time, 800000))) * (std.math.tau / 800000.0);
        const earth_rot_quaternion = zm.quatFromRollPitchYawV(zm.f32x4(
            0.0,
            0.0,
            angle,
            0.0,
        ));

        const model_matrix = zm.matFromQuat(earth_rot_quaternion);
        const mvp_matrix = zm.mul(zm.mul(model_matrix, view_matrix), projection_matrix);
        gl.UniformMatrix4fv(
            mvp_matrix_uniform,
            1,
            gl.FALSE,
            zm.arrNPtr(&mvp_matrix),
        );
        gl.Uniform1f(global_scale_uniform, global_star_scale);

        if (stars_smear_opacity > 0.0) {
            // Render smears to framebuffer
            gl.BlendEquation(gl.MAX_EXT);
            gl.DrawArrays(gl.POINTS, 0, star_count);
        }

        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);

        // when the smears are translucent or gone, render stars to default framebuffer
        if (stars_smear_opacity < 1.0) {
            gl.BlendEquation(gl.FUNC_ADD);
            gl.DrawArrays(gl.POINTS, 0, star_count);
        }

        if (stars_smear_opacity > 0.0) {
            // Render smears framebuffer as fullscreen tri
            gl.BlendEquation(gl.MAX_EXT);
            gl.UseProgram(framebuffer_program);
            gl.BindVertexArrayOES(framebuffer_vao);
            gl.BindTexture(gl.TEXTURE_2D, stars_fb_texture);

            gl.Uniform1f(opacity_uniform, stars_smear_opacity);

            gl.DrawArrays(gl.TRIANGLES, 0, framebuffer_vertices.len);
        }

        // we're only writing color in this pass
        gl.DepthMask(gl.FALSE);
        // Don't depth test with it's own depth values from the depth pass
        gl.DepthFunc(gl.ALWAYS);
        gl.BlendEquation(gl.FUNC_ADD);
        gl.UseProgram(terrain_tex_color_program);
        gl.BindVertexArrayOES(terrain_tex_vao);
        gl.BindTexture(gl.TEXTURE_2D, terrain_fb_texture);
        gl.DrawElements(gl.TRIANGLES, terrain_tex_indices.len, gl.UNSIGNED_SHORT, 0);

        gl.DepthFunc(gl.LESS);

        window.swapBuffers();
    }
}

pub fn getPreferredPlatform() glfw.PlatformType {
    if (glfw.platformSupported(.wayland)) {
        return .wayland;
    } else {
        return .any;
    }
}

// 14 misclassified stars in the initial dataset
pub const star_count: u16 = 9110 - 14;

const stars_geometry = genStarGeometryPreloaded();

const stars_color_attrib = 0;
const stars_pos_attrib = 1;
const stars_size_attrib = 2;

pub const StarVertex = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    x: f32,
    y: f32,
    z: f32,

    size: f32,
};

pub const StarsGeometry = extern struct {
    vertices: [star_count]StarVertex,
};

fn genStarGeometryPreloaded() StarsGeometry {
    std.debug.assert(builtin.cpu.arch.endian() == .little);

    const preloaded_data = @embedFile("assets/stars-preloaded.bin");
    const non_terminated_data = @as(*const [preloaded_data.len]u8, preloaded_data);

    return @bitCast(non_terminated_data.*);
}

const terrain_vertices: u16 = 2 + (terrain_divisions * 2);
const terrain_indices: u32 = terrain_divisions * 6;

const terrain_pos_attrib: gl.uint = 0;

const Vertex2D = struct {
    x: f32,
    y: f32,
};

const TerrainGeometry = struct {
    vertices: [terrain_vertices]Vertex2D,
    indices: [terrain_indices]u16,
};

fn genTerrainGeometry(rand: std.Random) TerrainGeometry {
    var raw_noise_array: [terrain_divisions + 1]f32 = undefined;

    for (0..raw_noise_array.len) |idx| {
        raw_noise_array[idx] = rand.float(f32);
    }

    var terrain: TerrainGeometry = undefined;

    var vert_idx: u16 = 0;

    for (0..terrain_divisions + 1) |div_idx| {
        const x = @as(f32, @floatFromInt(2 * div_idx)) / @as(f32, @floatFromInt(terrain_divisions)) - 1.0;

        var frequency: f32 = std.math.pow(f32, 2.0, @floatFromInt(-terrain_octaves));
        var amplitude: f32 = terrain_amplitude;
        var perlin_output: f32 = 0.0;
        for (0..terrain_octaves) |_| {
            const sample_x = @as(f32, @floatFromInt(div_idx)) * frequency;
            const sample_x_left: u32 = @intFromFloat(sample_x);
            const sample_x_right = sample_x_left + 1;
            const sample_x_fract = sample_x - @floor(sample_x);
            perlin_output += amplitude * std.math.lerp(
                raw_noise_array[sample_x_left],
                raw_noise_array[sample_x_right],
                sample_x_fract,
            );
            frequency *= 2.0;
            amplitude /= 2.0;
        }

        const y = perlin_output + terrain_y_offset;

        terrain.vertices[vert_idx] = .{
            .x = x,
            .y = y,
        };
        terrain.vertices[vert_idx + 1] = .{
            .x = x,
            .y = -1.0,
        };
        vert_idx += 2;
    }

    vert_idx = 0;
    var index_idx: usize = 0;

    for (0..terrain_divisions) |_| {
        // bottom left tri
        terrain.indices[index_idx] = vert_idx;
        terrain.indices[index_idx + 1] = vert_idx + 1;
        terrain.indices[index_idx + 2] = vert_idx + 3;
        // top right tri
        terrain.indices[index_idx + 3] = vert_idx;
        terrain.indices[index_idx + 4] = vert_idx + 3;
        terrain.indices[index_idx + 5] = vert_idx + 2;

        index_idx += 6;
        vert_idx += 2;
    }

    return terrain;
}

const terrain_tex_pos_attrib: gl.uint = 0;

const terrain_tex_indices = [_]u16{
    0, 1, 3,
    0, 3, 2,
};

const framebuffer_pos_attrib: gl.uint = 0;

const framebuffer_vertices = [_]Vertex2D{
    .{ .x = -1.0, .y = -1.0 },
    .{ .x = 3.0, .y = -1.0 },
    .{ .x = -1.0, .y = 3.0 },
};

const ResizeEvent = struct {
    width: u32,
    height: u32,
};

var resize_event: ?ResizeEvent = null;

fn onFramebufferResized(_: glfw.Window, width: u32, height: u32) void {
    resize_event = .{
        .width = width,
        .height = height,
    };
}

fn onKeyEvent(window: glfw.Window, key: glfw.Key, _: i32, _: glfw.Action, _: glfw.Mods) void {
    if (key == .escape) {
        window.setShouldClose(true);
    }
}
