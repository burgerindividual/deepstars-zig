const std = @import("std");
const m = @import("main.zig");

const StarsGeometry = m.StarsGeometry;
const StarVertex = m.StarVertex;
const star_count = m.star_count;

pub fn main() !void {
    const loaded_stars = genStarGeometry();
    const file = std.fs.cwd().createFile(
        "stars-preloaded.bin",
        .{},
    ) catch unreachable;
    file.writeAll(@as(*const [@sizeOf(StarsGeometry)]u8, @ptrCast(&loaded_stars))) catch unreachable;
    file.close();
}

const alpha_multiplier = 2.0;
const size_multiplier = 1.0 / @sqrt(alpha_multiplier);
const magnitude_modifier = 4.0;

// TODO: when comptime is fast enough, just make this comptime and remove preloading
fn genStarGeometry() StarsGeometry {
    var stars_uninit: StarsGeometry = undefined;

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

        // vmag high -1.46 (Sirius), low 8.00ish
        // We add an offset to make darker stars more easily visible on screens.
        // TODO: bloom on the alpha component when above 1.0?
        const offset_mag = v_magnitude + 1.46 - magnitude_modifier;

        // To get a direct brightness from 0 to 1, the following can be done:
        // const direct_brightness: f32 = @floatCast(@min(std.math.pow(
        //     f64,
        //     100.0,
        //     offset_mag / -5.0,
        // ), 1.0));
        //
        // We want to split this brightness attribute to contribute to both the size of
        // the point and the alpha of the point. The size of the point has a squared relationship
        // with brightness because it has a squared relationship with the surface area.
        // We want the total brightness of a given star on the screen to be the same as
        // the direct brightness.
        //
        // The following system of equations achieves what we want:
        // direct_brightness = alpha * size^2
        // alpha = size^2
        //
        // Solving this system gives us the following:
        // alpha = direct_brightness^(1/2);
        // size = direct_brightness^(1/4);
        //
        // To put this into place, we can simply multiply the exponents.
        //
        // From here, we can also multiply our outputs by a balance factor to balance
        // whether alpha or size should take a larger split. This should also account for
        // the difference in exponents.
        const alpha = std.math.pow(
            f64,
            100.0,
            offset_mag / -10.0,
        ) * alpha_multiplier;
        const size = std.math.pow(
            f64,
            100.0,
            offset_mag / -20.0,
        ) * size_multiplier;

        stars_uninit.vertices[idx] = StarVertex{
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = @floatCast(@min(alpha, 1.0)),

            .x = x,
            .y = y,
            .z = z,

            .size = @floatCast(@min(size, 1.0)),
        };

        idx += 1;
    }

    std.debug.assert(idx == star_count);

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
