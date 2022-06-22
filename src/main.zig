const std = @import("std");
const render = @import("render.zig");
const parser = @import("parser.zig");
const zpng = @import("zpng.zig");

// minimum duration to hold buttons for
const minhold = 6;

// background color, useful for keying out
const bg_color = [3]u8{ 0, 255, 0 };

inline fn empty_bulk(tick: u32) parser.Framebulk {
    return parser.Framebulk{
        .tick = tick,
        .view_analog = @Vector(2, f32){ 0, 0 },
        .move_analog = @Vector(2, f32){ 0, 0 },
        .buttons = .{},
    };
}

const ControllerFrameProducer = struct {
    arena: std.heap.ArenaAllocator,

    // tas framebulks
    framebulks: []parser.Framebulk,

    // images used to construct frames
    base: zpng.Image,
    stick: zpng.Image,
    trigger_l: zpng.Image,
    trigger_r: zpng.Image,
    trigger_l_pressed: zpng.Image,
    trigger_r_pressed: zpng.Image,
    button_d: zpng.Image,
    button_u: zpng.Image,
    button_j: zpng.Image,
    button_z: zpng.Image,
    button_d_pressed: zpng.Image,
    button_u_pressed: zpng.Image,
    button_j_pressed: zpng.Image,
    button_z_pressed: zpng.Image,

    // how many frames do we want to interpolate sticks over for each tick?
    frames_per_tick: u16,

    // how many ticks do we want to render in total?
    render_ticks: u32,

    // tracking ticks and frames
    tick: u32 = 0,
    frames_to_next_tick: u16 = 0,

    // how many ticks each button has been held for
    button_hold_duration: struct {
        j: u32 = 0,
        d: u32 = 0,
        u: u32 = 0,
        z: u32 = 0,
        b: u32 = 0,
        o: u32 = 0,
    } = .{},

    // current states of buttons
    buttons: parser.Framebulk.Buttons = .{},

    pub fn getWidth(self: ControllerFrameProducer) u16 {
        return @intCast(u16, self.base.width);
    }

    pub fn getHeight(self: ControllerFrameProducer) u16 {
        return @intCast(u16, self.base.height);
    }

    pub fn getRate(self: ControllerFrameProducer) u16 {
        return 60 * self.frames_per_tick;
    }

    pub fn hasFrame(self: ControllerFrameProducer) bool {
        return self.tick < self.render_ticks;
    }

    pub fn init(allocator: std.mem.Allocator, img_dir: []const u8, tas_file: []const u8, render_ticks: u32, frames_per_tick: u16) !ControllerFrameProducer {
        var dir = try std.fs.cwd().openDir(img_dir, .{});
        defer dir.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const framebulks = try parser.parse(arena.allocator(), tas_file);

        var cfp = ControllerFrameProducer{
            .arena = arena,

            .framebulks = framebulks,

            .base = try readImage(arena.allocator(), dir, "base.png"),
            .stick = try readImage(arena.allocator(), dir, "stick.png"),
            .trigger_l = try readImage(arena.allocator(), dir, "trigger_l.png"),
            .trigger_r = try readImage(arena.allocator(), dir, "trigger_r.png"),
            .trigger_l_pressed = try readImage(arena.allocator(), dir, "trigger_l_pressed.png"),
            .trigger_r_pressed = try readImage(arena.allocator(), dir, "trigger_r_pressed.png"),
            .button_d = try readImage(arena.allocator(), dir, "button_d.png"),
            .button_u = try readImage(arena.allocator(), dir, "button_u.png"),
            .button_j = try readImage(arena.allocator(), dir, "button_j.png"),
            .button_z = try readImage(arena.allocator(), dir, "button_z.png"),
            .button_d_pressed = try readImage(arena.allocator(), dir, "button_d_pressed.png"),
            .button_u_pressed = try readImage(arena.allocator(), dir, "button_u_pressed.png"),
            .button_j_pressed = try readImage(arena.allocator(), dir, "button_j_pressed.png"),
            .button_z_pressed = try readImage(arena.allocator(), dir, "button_z_pressed.png"),

            .frames_per_tick = frames_per_tick,
            .render_ticks = render_ticks,
        };

        cfp.updateTick();

        cfp.arena = arena; // make sure this is up-to-date when we return!

        return cfp;
    }

    pub fn deinit(self: *ControllerFrameProducer) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn updateTick(self: *ControllerFrameProducer) void {
        self.frames_to_next_tick = self.frames_per_tick;

        const prev_buttons = if (self.tick == 0 or self.tick > self.framebulks.len)
            parser.Framebulk.Buttons{}
        else
            self.framebulks[self.tick - 1].buttons;

        const cur = if (self.tick < self.framebulks.len)
            self.framebulks[self.tick]
        else
            empty_bulk(self.tick);

        // if button was held, increment its duration
        if (self.button_hold_duration.j > 0) self.button_hold_duration.j += 1;
        if (self.button_hold_duration.d > 0) self.button_hold_duration.d += 1;
        if (self.button_hold_duration.u > 0) self.button_hold_duration.u += 1;
        if (self.button_hold_duration.z > 0) self.button_hold_duration.z += 1;
        if (self.button_hold_duration.b > 0) self.button_hold_duration.b += 1;
        if (self.button_hold_duration.o > 0) self.button_hold_duration.o += 1;

        // make sure to reset hold timer if button was released at all
        if (cur.buttons.j and !prev_buttons.j) self.button_hold_duration.j = 1;
        if (cur.buttons.d and !prev_buttons.d) self.button_hold_duration.d = 1;
        if (cur.buttons.u and !prev_buttons.u) self.button_hold_duration.u = 1;
        if (cur.buttons.z and !prev_buttons.z) self.button_hold_duration.z = 1;
        if (cur.buttons.b and !prev_buttons.b) self.button_hold_duration.b = 1;
        if (cur.buttons.o and !prev_buttons.o) self.button_hold_duration.o = 1;

        // if not actually held and hold duration is sufficient, release
        if (!cur.buttons.j and self.button_hold_duration.j > minhold) self.button_hold_duration.j = 0;
        if (!cur.buttons.d and self.button_hold_duration.d > minhold) self.button_hold_duration.d = 0;
        if (!cur.buttons.u and self.button_hold_duration.u > minhold) self.button_hold_duration.u = 0;
        if (!cur.buttons.z and self.button_hold_duration.z > minhold) self.button_hold_duration.z = 0;
        if (!cur.buttons.b and self.button_hold_duration.b > minhold) self.button_hold_duration.b = 0;
        if (!cur.buttons.o and self.button_hold_duration.o > minhold) self.button_hold_duration.o = 0;

        // hold iff hold duration is nonzero
        const buttons = parser.Framebulk.Buttons{
            .j = self.button_hold_duration.j > 0,
            .d = self.button_hold_duration.d > 0,
            .u = self.button_hold_duration.u > 0,
            .z = self.button_hold_duration.z > 0,
            .b = self.button_hold_duration.b > 0,
            .o = self.button_hold_duration.o > 0,
        };

        self.buttons = buttons;
    }

    pub fn generate(self: *ControllerFrameProducer, dst: [][3]u8) void {
        const cur = if (self.tick < self.framebulks.len)
            self.framebulks[self.tick]
        else
            empty_bulk(self.tick);

        const next = if (self.tick + 1 == self.framebulks.len)
            cur
        else if (self.tick + 1 < self.framebulks.len)
            self.framebulks[self.tick + 1]
        else
            empty_bulk(self.tick + 1);

        const ratio = 1.0 - @intToFloat(f32, self.frames_to_next_tick) / @intToFloat(f32, self.frames_per_tick);

        const view_analog = cur.view_analog * @splat(2, 1.0 - ratio) + next.view_analog * @splat(2, ratio);
        const move_analog = cur.move_analog * @splat(2, 1.0 - ratio) + next.move_analog * @splat(2, ratio);

        self.createBaseImage(dst);

        // left stick
        const move_pos = calcStickPos(294, 273, 77, move_analog);
        self.overlayImage(dst, self.stick, move_pos[0], move_pos[1]);

        // right stick
        const view_pos = calcStickPos(1124, 273, 77, rescaleView(view_analog));
        self.overlayImage(dst, self.stick, view_pos[0], view_pos[1]);

        // buttons
        self.overlayImage(dst, if (self.buttons.z) self.button_z_pressed else self.button_z, 766, 383);
        self.overlayImage(dst, if (self.buttons.j) self.button_j_pressed else self.button_j, 766, 616);
        self.overlayImage(dst, if (self.buttons.u) self.button_u_pressed else self.button_u, 649, 499);
        self.overlayImage(dst, if (self.buttons.d) self.button_d_pressed else self.button_d, 882, 499);

        // triggers
        self.overlayImage(dst, if (self.buttons.o) self.trigger_l_pressed else self.trigger_l, 236, 0);
        self.overlayImage(dst, if (self.buttons.b) self.trigger_r_pressed else self.trigger_r, 1043, 0);

        self.frames_to_next_tick -= 1;
        if (self.frames_to_next_tick == 0) {
            self.tick += 1;
            self.updateTick();
            if (self.tick % 10 == 0) {
                std.io.getStdOut().writer().print("tick {}/{}\n", .{ self.tick, self.framebulks.len }) catch {};
            }
        }
    }

    fn rescaleView(ang_delta: @Vector(2, f32)) @Vector(2, f32) {
        if (ang_delta[0] == 0 and ang_delta[1] == 0) {
            return @Vector(2, f32){ 0, 0 };
        }

        const len = std.math.sqrt(@reduce(.Add, ang_delta * ang_delta));

        const norm = ang_delta / @splat(2, len);
        const new_len = std.math.pow(f32, len / 180.0, 0.3);

        return norm * @splat(2, new_len);
    }

    fn calcStickPos(center_x: u32, center_y: u32, rad: u32, stick: @Vector(2, f32)) @Vector(2, u32) {
        std.debug.assert(rad < center_x);
        std.debug.assert(rad < center_y);

        const dx = stick[0] * @intToFloat(f32, rad);
        const dy = stick[1] * @intToFloat(f32, rad);

        const x = @intCast(i32, center_x) + @floatToInt(i32, dx);
        const y = @intCast(i32, center_y) - @floatToInt(i32, dy);

        return @Vector(2, u32){
            @intCast(u32, x),
            @intCast(u32, y),
        };
    }

    fn createBaseImage(self: ControllerFrameProducer, dst: [][3]u8) void {
        @setRuntimeSafety(false);

        const bg_r = @intToFloat(f32, bg_color[0]);
        const bg_g = @intToFloat(f32, bg_color[1]);
        const bg_b = @intToFloat(f32, bg_color[2]);

        for (self.base.pixels) |pix, i| {
            const r = @intToFloat(f32, pix[0]) / 65535.0;
            const g = @intToFloat(f32, pix[1]) / 65535.0;
            const b = @intToFloat(f32, pix[2]) / 65535.0;
            const a = @intToFloat(f32, pix[3]) / 65535.0;

            dst[i] = [3]u8{
                @floatToInt(u8, r * a * 255.0) + @floatToInt(u8, bg_r * (1.0 - a)),
                @floatToInt(u8, g * a * 255.0) + @floatToInt(u8, bg_g * (1.0 - a)),
                @floatToInt(u8, b * a * 255.0) + @floatToInt(u8, bg_b * (1.0 - a)),
            };
        }
    }

    fn overlayImage(self: ControllerFrameProducer, dst: [][3]u8, image: zpng.Image, start_x: u32, start_y: u32) void {
        @setRuntimeSafety(false);

        const w = self.getWidth();

        var off_y: u32 = 0;
        while (off_y < image.height) : (off_y += 1) {
            const y = start_y + off_y;
            var off_x: u32 = 0;
            while (off_x < image.width) : (off_x += 1) {
                const x = start_x + off_x;
                const cur = dst[y * w + x];
                const over = image.pixels[off_y * image.width + off_x];

                const alpha = @intToFloat(f32, over[3]) / 65535.0;

                const cur_r = @floatToInt(u8, @intToFloat(f32, cur[0]) * (1.0 - alpha));
                const cur_g = @floatToInt(u8, @intToFloat(f32, cur[1]) * (1.0 - alpha));
                const cur_b = @floatToInt(u8, @intToFloat(f32, cur[2]) * (1.0 - alpha));

                const over_r = @floatToInt(u8, @intToFloat(f32, over[0]) / 65535.0 * 255.0 * alpha);
                const over_g = @floatToInt(u8, @intToFloat(f32, over[1]) / 65535.0 * 255.0 * alpha);
                const over_b = @floatToInt(u8, @intToFloat(f32, over[2]) / 65535.0 * 255.0 * alpha);

                dst[y * w + x] = [3]u8{
                    cur_r + over_r,
                    cur_g + over_g,
                    cur_b + over_b,
                };
            }
        }
    }
};

fn readImage(allocator: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !zpng.Image {
    var f = try dir.openFile(filename, .{});
    defer f.close();

    return try zpng.Image.read(allocator, std.io.bufferedReader(f.reader()).reader());
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    if (!args.skip()) return error.BadUsage;
    const filename = args.next() orelse return error.BadUsage;
    const ticks_str = args.next() orelse return error.BadUsage;
    const out_file = args.next() orelse "controller.mp4";

    const ticks = std.fmt.parseInt(u32, ticks_str, 10) catch return error.BadUsage;

    var producer = try ControllerFrameProducer.init(gpa.allocator(), "images", filename, ticks, 1);
    defer producer.deinit();

    try render.render(out_file, &producer);
}
