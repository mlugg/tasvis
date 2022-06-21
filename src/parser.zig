const std = @import("std");

const Parser = @This();

allocator: std.mem.Allocator,

data: []const u8,
cur_idx: usize,

pub const Framebulk = struct {
    tick: u32,
    view_analog: @Vector(2, f32),
    move_analog: @Vector(2, f32),
    buttons: Buttons,

    pub const Buttons = struct {
        j: bool = false,
        d: bool = false,
        u: bool = false,
        z: bool = false,
        b: bool = false,
        o: bool = false,
    };
};

pub fn parse(allocator: std.mem.Allocator, filename: []const u8) ![]Framebulk {
    const data = try std.fs.cwd().readFileAlloc(allocator, filename, std.math.maxInt(usize));
    defer allocator.free(data);

    var parser = Parser{
        .allocator = allocator,
        .data = data,
        .cur_idx = 0,
    };

    return try parser.parseData();
}

fn parseData(self: *Parser) ![]Framebulk {
    const version = self.getNextLine() orelse return error.NoVersionLine;
    if (!std.mem.startsWith(u8, version, "version ")) return error.BadVersionLine;

    const start = self.getNextLine() orelse return error.NoStartLine;
    if (!std.mem.startsWith(u8, start, "start ")) return error.BadStartLine;

    var last_fb = Framebulk{
        .tick = 0,
        .view_analog = @Vector(2, f32){ 0, 0 },
        .move_analog = @Vector(2, f32){ 0, 0 },
        .buttons = .{},
    };

    var bulks = std.ArrayList(Framebulk).init(self.allocator);
    defer bulks.deinit();

    while (self.getNextLine()) |line| {
        if (std.mem.startsWith(u8, line, "repeat")) return error.RepeatInRaw;
        if (std.mem.startsWith(u8, line, "end")) return error.EndInRaw;

        if (std.mem.startsWith(u8, line, "rngmanip")) continue; // these should only be in the header but idc enough to check that

        const tick_idx = std.mem.indexOfScalar(u8, line, '>') orelse return error.InvalidFramebulk;
        const tick_str = line[0..tick_idx];

        const tick = if (line[0] == '+') blk: {
            if (bulks.items.len == 0) return error.FirstFramebulkRelative;
            break :blk last_fb.tick + (std.fmt.parseInt(u32, tick_str, 10) catch return error.BadTick);
        } else std.fmt.parseInt(u32, tick_str, 10) catch return error.BadTick;

        if (bulks.items.len > 0 and tick <= last_fb.tick) {
            return error.NoLaterTick;
        } else {
            // append in-between ticks
            var i: u32 = last_fb.tick + 1;
            while (i < tick) : (i += 1) try bulks.append(last_fb);
        }

        var it = std.mem.split(u8, line[tick_idx + 1 ..], "|");

        const move = (try parseAnalog(it.next() orelse "")) orelse
            last_fb.move_analog;

        const view = (try parseAnalog(it.next() orelse "")) orelse
            last_fb.view_analog;

        const button_deltas = try parseButtons(it.next() orelse "");

        var buttons = last_fb.buttons;
        if (button_deltas.j) |j| buttons.j = j;
        if (button_deltas.d) |d| buttons.d = d;
        if (button_deltas.u) |u| buttons.u = u;
        if (button_deltas.z) |z| buttons.z = z;
        if (button_deltas.b) |b| buttons.b = b;
        if (button_deltas.o) |o| buttons.o = o;

        const fb = Framebulk{
            .tick = tick,
            .view_analog = view,
            .move_analog = move,
            .buttons = buttons,
        };

        last_fb = fb;
        try bulks.append(fb);
    }

    return bulks.toOwnedSlice();
}

fn getNextLine(self: *Parser) ?[]const u8 {
    while (self.cur_idx < self.data.len) {
        switch (self.data[self.cur_idx]) {
            ' ', '\r', '\n', '\t' => self.cur_idx += 1,
            else => break,
        }
    }

    if (self.cur_idx >= self.data.len) return null;

    const rem = self.data[self.cur_idx..];

    const len = std.mem.indexOfAny(u8, rem, "\r\n") orelse rem.len;
    self.cur_idx += len;

    return rem[0..len];
}

fn parseAnalog(str: []const u8) !?@Vector(2, f32) {
    const trimmed = std.mem.trim(u8, str, " ");

    if (trimmed.len == 0) return null;

    const sep = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.InvalidFramebulk;

    const l = trimmed[0..sep];
    const r = std.mem.trimLeft(u8, trimmed[sep + 1 ..], " ");

    return @Vector(2, f32){
        std.fmt.parseFloat(f32, l) catch return error.InvalidFramebulk,
        std.fmt.parseFloat(f32, r) catch return error.InvalidFramebulk,
    };
}

const ButtonDeltas = struct {
    j: ?bool = null,
    d: ?bool = null,
    u: ?bool = null,
    z: ?bool = null,
    b: ?bool = null,
    o: ?bool = null,
};

fn parseButtons(str: []const u8) !ButtonDeltas {
    var buts = ButtonDeltas{};

    for (str) |c| {
        const set = std.ascii.isUpper(c);
        switch (std.ascii.toLower(c)) {
            'j' => buts.j = set,
            'd' => buts.d = set,
            'u' => buts.u = set,
            'z' => buts.z = set,
            'b' => buts.b = set,
            'o' => buts.o = set,
            ' ' => {},
            else => return error.InvalidFramebulk,
        }
    }

    return buts;
}
