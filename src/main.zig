const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const zm = @import("zmath");

var gl_procs: gl.ProcTable = undefined;

const glfw_log = std.log.scoped(.glfw);
const gl_log = std.log.scoped(.gl);

// var gpa = std.heap.GeneralPurposeAllocator(.{
//     .thread_safe = false,
// }){};

pub fn main() !void {
    @setFloatMode(.optimized);

    glfw.setErrorCallback(logGLFWError);

    // todo: switch to wayland when done with renderdoc
    const preferred_platform: glfw.PlatformType = if (glfw.platformSupported(.wayland)) .wayland else .any;
    if (!glfw.init(.{ .platform = preferred_platform })) {
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

    // Disable cursor
    window.setInputModeCursor(.hidden);

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

    // uncomment this to generate stars-preloaded.bin
    // _ = genStars();

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
    const fov_x = 45.0;
    const fov_y = fov_x * @as(f32, @floatFromInt(preferred_height)) / @as(f32, @floatFromInt(preferred_width));
    // don't use GL version, we want the depth values between 0 and 1
    const projection_matrix = zm.perspectiveFovRh(
        fov_y * std.math.rad_per_deg,
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
    const terrain = genTerrain(rand);

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

    var global_star_scale = @as(f32, @floatFromInt(window.getFramebufferSize().height)) / 120.0;
    var stars_fb_needs_clear = true;
    var smear_start_time: i64 = -1;
    var smear_end_time: i64 = -1;

    main_loop: while (true) {
        glfw.pollEvents();

        if (window.shouldClose()) break :main_loop;

        const ms_time: i64 = std.time.milliTimestamp();

        var stars_smear_opacity: f32 = 0.0;
        if (ms_time > smear_start_time and ms_time < smear_end_time) {
            const smear_time_remaining = smear_end_time - ms_time;
            stars_smear_opacity = @min(@as(f32, @floatFromInt(smear_time_remaining)) / 5000.0, 1.0);
        } else if (ms_time >= smear_end_time) {
            smear_start_time = ms_time + rand.intRangeAtMost(u32, 10000, 120000);
            smear_end_time = smear_start_time + rand.intRangeAtMost(u32, 20000, 50000);
            stars_fb_needs_clear = true;
        }

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

            global_star_scale = @as(f32, @floatFromInt(e.height)) / 120.0;

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

// 14 misclassified stars in the initial dataset
const star_count: u16 = 9110 - 14;

const stars = genStarsPreloaded();

const stars_color_attrib = 0;
const stars_pos_attrib = 1;
const stars_size_attrib = 2;

const StarVertex = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    x: f32,
    y: f32,
    z: f32,

    size: f32,
};

const Stars = extern struct {
    vertices: [star_count]StarVertex,
};

fn genStarsPreloaded() Stars {
    std.debug.assert(builtin.cpu.arch.endian() == .little);

    const preloaded_data = @embedFile("assets/stars-preloaded.bin");
    const non_terminated_data = @as(*const [preloaded_data.len]u8, preloaded_data);

    return @bitCast(non_terminated_data.*);
}

fn genStars() Stars {
    var stars_uninit: Stars = undefined;

    const bcs5_data = @embedFile("assets/bsc5.dat");

    var idx: u16 = 0;
    var iter = std.mem.splitScalar(u8, bcs5_data[0..], '\n');
    while (iter.next()) |line| {
        if (line.len < 113) {
            continue;
        }

        const right_ascension_hr: f64 = @floatFromInt(std.fmt.parseInt(u8, line[75..77], 10) catch continue);
        const right_ascension_min: f64 = @floatFromInt(std.fmt.parseInt(u8, line[77..79], 10) catch continue);
        const right_ascension_sec: f64 = std.fmt.parseFloat(f64, line[79..83]) catch continue;
        const declination_sign: f64 = if (line[83] == '-') -1.0 else 1.0;
        const declination_deg: f64 = @floatFromInt(std.fmt.parseInt(u8, line[84..86], 10) catch continue);
        const declination_min: f64 = @floatFromInt(std.fmt.parseInt(u8, line[86..88], 10) catch continue);
        const declination_sec: f64 = @floatFromInt(std.fmt.parseInt(u8, line[88..90], 10) catch continue);
        const v_magnitude = std.fmt.parseFloat(
            f32,
            std.mem.trim(u8, line[102..107], &std.ascii.whitespace),
        ) catch continue;
        // some entries don't have a B-V, so fall back to 0.0
        const bv = std.fmt.parseFloat(
            f32,
            std.mem.trim(u8, line[109..114], &std.ascii.whitespace),
        ) catch 0.0;

        const right_ascension_rad: f64 = (right_ascension_hr + right_ascension_min / 60.0 + right_ascension_sec / 3600.0) * (std.math.tau / 24.0);
        const declination_rad: f64 = declination_sign * (declination_deg + declination_min / 60.0 + declination_sec / 3600.0) * std.math.rad_per_deg;
        const color = rgbFromBv(bv);

        const x: f32 = @floatCast(@cos(declination_rad) * @cos(right_ascension_rad));
        const y: f32 = @floatCast(@cos(declination_rad) * @sin(right_ascension_rad));
        const z: f32 = @floatCast(@sin(declination_rad));

        const star_brightness_modifier = 5.5;
        // vmag high -1.46, low 8.00ish
        const scaled_mag: f32 = @floatCast(@min(std.math.pow(
            f64,
            100.0,
            (-v_magnitude - 1.46 + star_brightness_modifier) / 5.0,
        ), 1.0));
        // the sqrt accounts for the surface area having a squared relationship to diameter.
        // having the alpha and the size be the square root of the scaled magnitude makes the
        // final percieved brightness the same as the scaled magnitude.
        const sqrt_mag = @sqrt(scaled_mag);

        const color_trunc: f32x3 = @floatCast(color);

        stars_uninit.vertices[idx] = StarVertex{
            .r = color_trunc[0],
            .g = color_trunc[1],
            .b = color_trunc[2],
            .a = sqrt_mag,

            .x = x,
            .y = y,
            .z = z,

            .size = sqrt_mag,
        };

        idx += 1;
    }

    std.debug.assert(idx == star_count);

    const file = std.fs.cwd().createFile(
        "stars-preloaded.bin",
        .{},
    ) catch unreachable;
    defer file.close();

    file.writeAll(@as(*const [@sizeOf(Stars)]u8, @ptrCast(&stars_uninit))) catch unreachable;

    return stars_uninit;
}

const f64x4 = @Vector(4, f64);
const f64x3 = @Vector(3, f64);
const f32x3 = @Vector(3, f32);

// D65 white point approximation from the following table:
// http://www.vendian.org/mncharity/dir3/blackbody/UnstableURLs/bbr_color.html
fn rgbFromBv(bv: f64) f32x3 {
    @setFloatMode(.optimized);
    const bv_splat: f64x4 = @splat(bv);

    // R, G1, B, G2
    const coeff_vectors = [_]f64x4{
        .{ 1.0244838411856621e-2, -1.2981528394826059e-3, -1.4462486359369586e-2, 9.7277840557748207e-4 },
        .{ 9.4009027654247290e-2, 2.4919995578097424e-2, 1.3036467204988925e-1, 3.4402198113594427e-2 },
        .{ 3.9806863413614252e-1, -2.1607300214538638e-1, -5.9516947822267696e-1, 2.4389228181984887e-1 },
        .{ 7.9561522955560138e-1, 1.0713298831304217e+0, 1.2478054530763567e+0, 8.5766884841475788e-1 },
    };

    var poly_eval = coeff_vectors[0];
    inline for (1..coeff_vectors.len) |idx| {
        poly_eval = poly_eval * bv_splat + coeff_vectors[idx];
    }

    const bottom_clamp: f64x3 = @splat(0.0);
    // use G2 as a top clamp for G1, otherwise clamp to 1.0
    const top_clamp: f64x3 = @shuffle(
        f64,
        @Vector(1, f64){1.0},
        poly_eval,
        @Vector(3, i32){ 0, ~@as(i32, 3), 0 },
    );
    const trimmed_poly_eval = @shuffle(
        f64,
        poly_eval,
        undefined,
        @Vector(3, i32){ 0, 1, 2 },
    );
    const clamped_result = @min(@max(trimmed_poly_eval, bottom_clamp), top_clamp);

    return @floatCast(clamped_result);
}

const terrain_divisions: u16 = 75;
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

fn genTerrain(rand: std.Random) Terrain {
    // TODO: software render with supersampling or msaa
    var raw_noise_array: [terrain_divisions + 1]f32 = undefined;

    for (0..raw_noise_array.len) |idx| {
        const float = rand.float(f32);
        const float_bits: u32 = @bitCast(float);
        const sign_bit: u32 = @as(u32, rand.int(u1)) << 31;
        raw_noise_array[idx] = @bitCast(float_bits | sign_bit);
    }

    var terrain: Terrain = undefined;

    var vert_idx: u16 = 0;

    // var y: f32 = -0.65;
    for (0..terrain_divisions + 1) |div_idx| {
        const x = @as(f32, @floatFromInt(2 * div_idx)) / @as(f32, @floatFromInt(terrain_divisions)) - 1.0;
        // y += (rand.float(f32) - 0.5) * 0.07;

        const octaves = 4;
        var frequency: f32 = std.math.pow(f32, 2.0, @floatFromInt(-octaves));
        var amplitude: f32 = 0.10;
        var perlin_output: f32 = 0.0;
        for (0..octaves) |_| {
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

        const y = perlin_output - 0.7;

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
