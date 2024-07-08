const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const zm = @import("zmath");

var gl_procs: gl.ProcTable = undefined;

const glfw_log = std.log.scoped(.glfw);
const gl_log = std.log.scoped(.gl);

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = false,
}){};

pub fn main() !void {
    @setFloatMode(.optimized);
    // _ = try std.DynLib.open("/usr/lib/librenderdoc.so");

    glfw.setErrorCallback(logGLFWError);

    // todo: switch to wayland when done with renderdoc
    if (!glfw.init(.{ .platform = .x11 })) {
        glfw_log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
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
            // .srgb_capable = true,
            // what happens if the platform doesn't support KHR_no_error?
            // .context_no_error = !std.debug.runtime_safety,
            // .context_creation_api = .egl_context_api,
            // .samples = 8,
        },
    ) orelse {
        glfw_log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.CreateWindowFailed;
    };
    defer window.destroy();

    // Make the window's OpenGL context current.
    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    // Make sure viewport stays consistent with framebuffer
    window.setFramebufferSizeCallback(onFramebufferResized);
    window.setKeyCallback(onKeyEvent);

    // Enable VSync to avoid drawing more often than necessary.
    glfw.swapInterval(1);

    // Initialize the OpenGL procedure table.
    if (!gl_procs.init(glfw.getProcAddress)) {
        gl_log.err("failed to load OpenGL functions", .{});
        return error.GLInitFailed;
    }

    // Make the OpenGL procedure table current.
    gl.makeProcTableCurrent(&gl_procs);
    defer gl.makeProcTableCurrent(null);

    // Enable debug messages in debug mode if possible
    if (std.debug.runtime_safety and glfw.extensionSupported("GL_KHR_debug")) {
        gl.DebugMessageCallbackKHR(logGLError, null);
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
        gl.DebugMessageInsertKHR(gl.DEBUG_SOURCE_APPLICATION_KHR, gl.DEBUG_TYPE_OTHER_KHR, 0, gl.DEBUG_SEVERITY_NOTIFICATION_KHR, message.len, message);
    }

    var random = std.Random.Xoroshiro128.init(@bitCast(std.time.milliTimestamp()));
    const rand = random.random();

    const alloc = gpa.allocator();

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

    const aspect_ratio = @as(f32, @floatFromInt(preferred_width)) / @as(f32, @floatFromInt(preferred_height));
    const fov_x = 50.0 * @as(f32, @floatFromInt(preferred_height)) / @as(f32, @floatFromInt(preferred_width));
    // don't use GL version, we want the depth values between 0 and 1
    const projection_matrix = zm.perspectiveFovRh(
        fov_x * std.math.pi / 180.0,
        aspect_ratio,
        0.1,
        10.0,
    );

    // Set blending mode
    gl.BlendFuncSeparate(
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
        gl.ONE,
        gl.ONE_MINUS_SRC_ALPHA,
    );

    // Enable depth test (good for stars behind mountains)
    gl.Enable(gl.DEPTH_TEST);

    // Create vertex arrays for the stars and terrain pipelines
    var vertex_arrays: [3]gl.uint = undefined;
    gl.GenVertexArraysOES(vertex_arrays.len, &vertex_arrays);
    defer gl.DeleteVertexArraysOES(vertex_arrays.len, &vertex_arrays);
    const terrain_vao = vertex_arrays[0];
    const stars_vao = vertex_arrays[1];
    const framebuffer_vao = vertex_arrays[2];

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
        @sizeOf(@TypeOf(stars.vertices)),
        &stars.vertices,
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

    ////
    //// TERRAIN SETUP
    ////

    // Build the terrain
    const terrain = try genTerrain(alloc, rand);
    defer alloc.destroy(terrain);

    // Create and fill the terrain vertex and index buffers
    gl.BindVertexArrayOES(terrain_vao);

    var terrain_buffers: [2]gl.uint = undefined;
    gl.GenBuffers(terrain_buffers.len, &terrain_buffers);
    defer gl.DeleteBuffers(terrain_buffers.len, &terrain_buffers);
    const terrain_vertex_buffer = terrain_buffers[0];
    const terrain_index_buffer = terrain_buffers[1];

    gl.BindBuffer(gl.ARRAY_BUFFER, terrain_vertex_buffer);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(@TypeOf(terrain.vertices)),
        &terrain.vertices,
        gl.STATIC_DRAW,
    );

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, terrain_index_buffer);
    gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @sizeOf(@TypeOf(terrain.indices)),
        &terrain.indices,
        gl.STATIC_DRAW,
    );

    // Set up shaders
    const terrain_vert_shader_text = @embedFile("shaders/terrain.vert");
    const terrain_vert_shader = gl.CreateShader(gl.VERTEX_SHADER);
    defer gl.DeleteShader(terrain_vert_shader);
    gl.ShaderSource(
        terrain_vert_shader,
        1,
        &.{terrain_vert_shader_text},
        &.{terrain_vert_shader_text.len},
    );
    gl.CompileShader(terrain_vert_shader);

    const terrain_frag_shader_text = @embedFile("shaders/terrain.frag");
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

    ////
    //// FRAMEBUFFER SETUP
    ////

    // Create and fill the terrain vertex and index buffers
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

    // Set up opacity uniform
    const opacity_uniform = gl.GetUniformLocation(framebuffer_program, "opacity");

    // Create stars framebuffer and texture
    var stars_framebuffer: gl.uint = undefined;
    gl.GenFramebuffers(1, @as(*[1]gl.uint, &stars_framebuffer));
    defer gl.DeleteFramebuffers(1, @as(*[1]gl.uint, &stars_framebuffer));

    var stars_fb_texture: gl.uint = undefined;
    gl.GenTextures(1, @as(*[1]gl.uint, &stars_fb_texture));
    defer gl.DeleteTextures(1, @as(*[1]gl.uint, &stars_fb_texture));

    const fbo_bounds = window.getFramebufferSize();
    gl.BindFramebuffer(gl.FRAMEBUFFER, stars_framebuffer);
    setupTextureTarget(
        @intCast(fbo_bounds.width),
        @intCast(fbo_bounds.height),
        stars_fb_texture,
    );

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

    // bind default framebuffer
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0);

    var global_star_scale = @as(f32, @floatFromInt(window.getFramebufferSize().height)) / 100.0;
    var stars_fb_needs_clear = true;
    // smear start time, smear end time

    main_loop: while (true) {
        glfw.pollEvents();

        if (window.shouldClose()) break :main_loop;

        const ms_time: u64 = @intCast(std.time.milliTimestamp());

        // const stars_smear_opacity: f32 = @as(f32, @floatFromInt(@as(u31, @truncate(ms_time)) % 3000)) / 3000.0;
        const stars_smear_opacity = 0.0;

        // stars.vertices[0].x = (@as(f32, @floatFromInt(@as(u14, @truncate(ms_time)))) / 8192.0) - 1.0;
        // stars.vertices[0].y = @sin(@as(f32, @floatFromInt(@as(u31, @truncate(ms_time)) % 10000)) / comptime (10000.0 / std.math.tau));

        if (resize_event) |e| {
            const width: gl.sizei = @intCast(e.width);
            const height: gl.sizei = @intCast(e.height);

            gl.Viewport(0, 0, width, height);
            setupTextureTarget(
                width,
                height,
                stars_fb_texture,
            );
            stars_fb_needs_clear = true;

            global_star_scale = @as(f32, @floatFromInt(e.height)) / 100.0;

            resize_event = null;
        }

        // Render terrain
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.ClearColor(0.0, 0.0, 0.0, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        // TODO: render terrain with STREAM_DRAW to max-width, scaled constrained height texture.
        //   render that texture through an SSAA shader to downscale to another texture.
        //   finally, use that texture to render a quad with the depth calculations to allow
        //   for depth test.
        // https://github.com/TheRensei/OpenGL-MSAA-SSAA/blob/master/Coursework/OpenGL/Resources/Shaders/SSAA.fs
        gl.UseProgram(terrain_program);
        gl.BindVertexArrayOES(terrain_vao);
        gl.DrawElements(gl.TRIANGLES, terrain_indices, gl.UNSIGNED_SHORT, 0);

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
        gl.Enable(gl.BLEND);
        gl.UseProgram(stars_program);
        gl.BindVertexArrayOES(stars_vao);

        const angle = @as(f32, @floatFromInt(@as(u31, @truncate(ms_time)) % 600000)) * comptime (std.math.tau / 600000.0);
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
        gl.BlendEquation(gl.FUNC_ADD);

        // when the smears are translucent or gone, render stars to default framebuffer
        if (stars_smear_opacity < 1.0) {
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

        window.swapBuffers();
    }
}

const stars = genStars();
const star_count: u16 = 9110 - 14;

const stars_color_attrib = 0;
const stars_pos_attrib = 1;
const stars_size_attrib = 2;

const StarVertex = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    x: f32,
    y: f32,
    z: f32,

    size: f32,
};

const Stars = struct {
    vertices: [star_count]StarVertex,
};

fn genStars() Stars {
    const stars_uninit: Stars = undefined;

    const bcs5_data = @embedFile("assets/BSC5");
    // 28 byte offset for header
    var pointer: []const u8 = bcs5_data[28..];

    var idx: u16 = 0;
    while (pointer.len > 0) {
        const right_ascension: f64 = @bitCast(pointer[4..12].*);
        const declination: f64 = @bitCast(pointer[12..20].*);
        const mk_class: [2]u8 = pointer[20..22].*;
        const v_magnitude: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(pointer[22..24].*)))) / 100.0;

        // 32 bytes per entry
        pointer = pointer[32..];

        if (std.mem.eql(u8, &spectral_type, "  ")) {
            // invalid entry
            continue;
        }

        idx += 1;

        stars_uninit.vertices[idx] = StarVertex{
            .r = rand.float(f32),
            .g = rand.float(f32),
            .b = rand.float(f32),
            .a = rand.float(f32),

            .x = rand.float(f32) - 0.5,
            .y = rand.float(f32) - 0.5,
            .z = rand.float(f32) - 0.5,

            .size = rand.float(f32),
        };
    }

    return stars_uninit;
}

fn rgbColorFromMk(mk_class: [2]u8) @Vector(3, u8) {
    const letter = mk_class[0];
    // ascii code for '0'
    const number = mk_class[1] - 48;

    const blend_colors = [_]@Vector(3, u8){
        .{155, 176, 255},
        .{170, 191, 255},
        .{202, 215, 255},
        .{248, 247, 255},
        .{255, 244, 234},
        .{255, 210, 161},
        .{255, 204, 111},
    };

    const low_blend_idx: usize = switch (letter) {
        'O' => 6,
        'B' => 5,
        'A' => 4,
        'F' => 3,
        'G' => 2,
        'K' => 1,
        'M' => 0,
        else => unreachable,
    };
    
    const low_blend = blend_colors[low_blend_idx];
    const high_blend = blend_colors[low_blend_idx + 1];
}

const terrain_divisions: u16 = 100;
const terrain_vertices: u16 = 2 + (terrain_divisions * 2);
const terrain_indices: u32 = terrain_divisions * 6;

const terrain_pos_attrib: gl.uint = 0;

const Vertex2D = struct {
    x: f32,
    y: f32,
};

const Terrain = struct {
    vertices: [terrain_vertices]Vertex2D,
    indices: [terrain_indices]u16,
};

fn genTerrain(alloc: std.mem.Allocator, rand: std.Random) !*Terrain {
    // TODO: https://arpit.substack.com/p/1d-procedural-terrain-generation
    // TODO: software render with supersampling or msaa

    var terrain = try alloc.create(Terrain);

    var vert_idx: u16 = 0;

    for (0..terrain_divisions + 1) |div_idx| {
        const x = @as(f32, @floatFromInt(2 * div_idx)) / @as(f32, @floatFromInt(terrain_divisions)) - 1.0;
        const y = -0.5 + (rand.float(f32) * 0.1);

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

const framebuffer_pos_attrib: gl.uint = 0;

const framebuffer_vertices = [_]Vertex2D{
    .{ .x = -1.0, .y = -1.0 },
    .{ .x = 3.0, .y = -1.0 },
    .{ .x = -1.0, .y = 3.0 },
};

fn setupTextureTarget(width: gl.sizei, height: gl.sizei, texture: gl.uint) void {
    gl.BindTexture(gl.TEXTURE_2D, texture);
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
}

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

fn logGLFWError(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    glfw_log.err("{}: {s}\n", .{ error_code, description });
}

fn logGLError(
    source: gl.@"enum",
    message_type: gl.@"enum",
    id: gl.uint,
    severity: gl.@"enum",
    _: gl.sizei,
    message: [*:0]const gl.char,
    _: ?*const anyopaque,
) callconv(gl.APIENTRY) void {
    const source_string: []const u8 = switch (source) {
        gl.DEBUG_SOURCE_API_KHR => "API",
        gl.DEBUG_SOURCE_APPLICATION_KHR => "Application",
        gl.DEBUG_SOURCE_SHADER_COMPILER_KHR => "Shader Compiler",
        gl.DEBUG_SOURCE_THIRD_PARTY_KHR => "Third Party",
        gl.DEBUG_SOURCE_WINDOW_SYSTEM_KHR => "Window System",
        gl.DEBUG_TYPE_OTHER_KHR => "Other",
        else => unreachable,
    };

    const type_string: []const u8 = switch (message_type) {
        gl.DEBUG_TYPE_ERROR_KHR => "Error",
        gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR_KHR => "Deprecated Behavior",
        gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR_KHR => "Undefined Behavior",
        gl.DEBUG_TYPE_PORTABILITY_KHR => "Portability",
        gl.DEBUG_TYPE_PERFORMANCE_KHR => "Performance",
        gl.DEBUG_TYPE_MARKER_KHR => "Marker",
        gl.DEBUG_TYPE_PUSH_GROUP_KHR => "Push Group",
        gl.DEBUG_TYPE_POP_GROUP_KHR => "Pop Group",
        gl.DEBUG_TYPE_OTHER_KHR => "Other",
        else => unreachable,
    };

    switch (severity) {
        gl.DEBUG_SEVERITY_HIGH_KHR => gl_log.err("Severity: High, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        gl.DEBUG_SEVERITY_MEDIUM_KHR => gl_log.warn("Severity: Medium, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        gl.DEBUG_SEVERITY_LOW_KHR => gl_log.info("Severity: Low, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        gl.DEBUG_SEVERITY_NOTIFICATION_KHR => gl_log.info("Severity: Notification, Type: {s}, Source: {s}, ID: {} | {s}\n", .{
            type_string,
            source_string,
            id,
            message,
        }),
        else => unreachable,
    }
}
