const std = @import("std");

const UserCmdInfo = struct {
    tick_count: i32,
    view_angles: [3]f32,
    forwardmove: f32,
    sidemove: f32,
    upmove: f32,
    buttons: u32,
};

fn parseUserCmdInfo(buf: []const u8, prev: UserCmdInfo) !UserCmdInfo {
    var stream = std.io.fixedBufferStream(buf);
    var br = std.io.bitReader(.Little, stream.reader());

    var info = prev;

    if (1 == try br.readBitsNoEof(u1, 1)) {
        _ = try br.reader().readIntLittle(i32); // CommandNumber
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.tick_count = try br.reader().readIntLittle(i32);
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.view_angles[0] = @bitCast(f32, try br.reader().readIntLittle(i32));
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.view_angles[1] = @bitCast(f32, try br.reader().readIntLittle(i32));
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.view_angles[2] = @bitCast(f32, try br.reader().readIntLittle(i32));
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.forwardmove = @bitCast(f32, try br.reader().readIntLittle(i32));
    } else {
        info.forwardmove = 0;
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.sidemove = @bitCast(f32, try br.reader().readIntLittle(i32));
    } else {
        info.sidemove = 0;
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        _ = @bitCast(f32, try br.reader().readIntLittle(i32)); // UpMove
    }

    if (1 == try br.readBitsNoEof(u1, 1)) {
        info.buttons = try br.reader().readIntLittle(u32);
    } else {
        info.buttons = 0;
    }

    return info;
}

pub fn convert(r: anytype, w: anytype) !void {
    if (!try r.isBytes("HL2DEMO\x00")) return error.BadDemo; // DemoFileStamp
    if (4 != try r.readIntLittle(i32)) return error.BadDemo; // DemoProtocol
    try r.skipBytes(4, .{}); // NetworkProtocol
    try r.skipBytes(260, .{}); // ServerName
    try r.skipBytes(260, .{}); // ClientName
    const map_name = try r.readBytesNoEof(260);
    try r.skipBytes(260, .{}); // GameDirectory
    try r.skipBytes(4, .{}); // PlaybackTime
    try r.skipBytes(4, .{}); // PlaybackTicks
    try r.skipBytes(4, .{}); // PlaybackFrames
    try r.skipBytes(4, .{}); // SignOnLength

    try w.print("start map {s}\n", .{std.mem.sliceTo(&map_name, 0)});
    try w.print("0>\n", .{});

    var last_tick: i32 = 0;
    var last_cmd_info = UserCmdInfo{
        .tick_count = 0,
        .view_angles = .{ 0, 0, 0 },
        .forwardmove = 0,
        .sidemove = 0,
        .upmove = 0,
        .buttons = 0,
    };

    while (true) {
        const msg = r.readIntLittle(u8) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        const tick = try r.readIntLittle(i32);
        const slot = try r.readIntLittle(u8);

        _ = slot;

        switch (msg) {
            1, 2 => { // SignOn/Packet
                try r.skipBytes(76 * 2, .{}); // PacketInfo
                try r.skipBytes(4, .{}); // InSequence
                try r.skipBytes(4, .{}); // OutSequence
                const size = try r.readIntLittle(u32);
                try r.skipBytes(size, .{}); // Data
            },
            3 => {}, // SyncTick
            4 => { // ConsoleCmd
                const size = try r.readIntLittle(u32);
                try r.skipBytes(size, .{}); // Data
            },
            5 => { // UserCmd
                try r.skipBytes(4, .{}); // Cmd
                const size = try r.readIntLittle(u32);

                if (tick <= last_tick) {
                    // skip this one
                    try r.skipBytes(size, .{});
                } else {
                    // try and parse it

                    var buf: [64]u8 = undefined;
                    try r.readNoEof(buf[0..size]);

                    const info = try parseUserCmdInfo(buf[0..size], last_cmd_info);

                    if (last_tick == 0) {
                        last_cmd_info.view_angles = info.view_angles;
                    }

                    const buttons_off = "jduzbo";
                    const buttons_on = "JDUZBO";
                    const buttons_mask = [6]u32{ 1 << 1, 1 << 2, 1 << 5, 1 << 19, 1 << 0, 1 << 11 };

                    var buttons: [6]u8 = undefined;
                    for (buttons) |*b, i| {
                        b.* = if ((buttons_mask[i] & info.buttons) != 0)
                            buttons_on[i]
                        else
                            buttons_off[i];
                    }

                    try w.print("+{}>{d} {d}||{s}||setang {d} {d}\n", .{
                        tick - last_tick,
                        info.sidemove / 175.0,
                        info.forwardmove / 175.0,
                        &buttons,
                        info.view_angles[0],
                        info.view_angles[1],
                    });

                    last_tick = tick;
                    last_cmd_info = info;
                }
            },
            6 => { // DataTables
                const size = try r.readIntLittle(u32);
                try r.skipBytes(size, .{}); // Data
            },
            7 => { // Stop
                std.log.info("Reached stop message at tick {}", .{tick});
                break;
            },
            8 => { // CustomData
                try r.skipBytes(4, .{}); // Type
                const size = try r.readIntLittle(u32);
                try r.skipBytes(size, .{}); // Data
            },
            9 => { // StringTables
                const size = try r.readIntLittle(u32);
                try r.skipBytes(size, .{}); // Data
            },
            else => return error.BadDemo,
        }
    }
}

pub fn main() anyerror!void {
    var dem = try std.fs.cwd().openFile("demo.dem", .{});
    defer dem.close();

    var tas = try std.fs.cwd().createFile("tas.p2tas", .{});
    defer tas.close();

    var buf_dem = std.io.bufferedReader(dem.reader());
    var buf_tas = std.io.bufferedWriter(tas.writer());

    try convert(buf_dem.reader(), buf_tas.writer());

    try buf_tas.flush();
}
