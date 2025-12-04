const std = @import("std");
const vaxis = @import("vaxis");

const UiState = @import("ui_state.zig").UiState;
const TaskIndex = @import("task_index.zig").TaskIndex;

const Cell = vaxis.Cell;

// Event type for the vaxis loop (matches the libvaxis README example)
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub fn run(
    allocator: std.mem.Allocator,
    index: *const TaskIndex,
    ui: *UiState,
) !void {
    _ = ui; // unused for now; will drive selection/navigation later

    // TTY + Vaxis setup as in the official low-level example.
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    defer {
        // Best-effort cleanup; ignore failures on teardown.
        _ = vx.exitAltScreen(tty.writer()) catch {};
        _ = vx.resetState(tty.writer()) catch {};
    }

    // Probe terminal capabilities; required for libvaxis feature detection.
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var running = true;
    while (running) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                // Hard exit: Ctrl+C or plain 'q'
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches('q', .{}))
                {
                    running = false;
                }
                // Additional key handling will come later.
            },
            .winsize => |ws| {
                // Keep vaxis’ internal screen in sync with terminal size.
                try vx.resize(allocator, tty.writer(), ws);
            },
            else => {},
        }

        const win = vx.window();
        win.clear();

        try renderHeader(win);
        try renderCounts(win, index);

        try vx.render(tty.writer());
    }
}

fn renderHeader(win: anytype) !void {
    const header = "ztask  –  Ctrl+C or q to quit";

    const SizeInt = @TypeOf(win.width);

    const row: SizeInt = 0;
    const width: SizeInt = win.width;

    const header_len: usize = header.len;
    const header_width: SizeInt = @intCast(header_len);

    const start_col: SizeInt = if (width > header_width)
        (width - header_width) / 2
    else
        0;

    const style: vaxis.Style = .{ .bold = true };

    var i: usize = 0;
    while (i < header_len) : (i += 1) {
        const col = start_col + @as(SizeInt, @intCast(i));
        if (col >= width) break;

        const ch = header[i];

        const cell: Cell = .{
            .char = .{
                .grapheme = &[_]u8{ ch },
                .width = 1,
            },
            .style = style,
        };

        _ = win.writeCell(col, row, cell);
    }
}

fn renderCounts(win: anytype, index: *const TaskIndex) !void {
    const SizeInt = @TypeOf(win.width);

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buf,
        "TODO: {d}    DONE: {d}",
        .{ index.todo.len, index.done.len },
    );

    const row: SizeInt = if (win.height > 2) 2 else 0;
    const width: SizeInt = win.width;

    const text_len: usize = text.len;
    const text_width: SizeInt = @intCast(text_len);

    const start_col: SizeInt = if (width > text_width)
        (width - text_width) / 2
    else
        0;

    const style: vaxis.Style = .{};

    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const col = start_col + @as(SizeInt, @intCast(i));
        if (col >= width) break;

        const ch = text[i];

        const cell: Cell = .{
            .char = .{
                .grapheme = &[_]u8{ ch },
                .width = 1,
            },
            .style = style,
        };

        _ = win.writeCell(col, row, cell);
    }
}
