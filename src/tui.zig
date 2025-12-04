const std = @import("std");
const vaxis = @import("vaxis");

const Cell = vaxis.Cell;

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const ui_mod = @import("ui_state.zig");
const UiState = ui_mod.UiState;
const ListKind = ui_mod.ListKind;

/// Events we care about. Matches libvaxis low-level API requirements:
/// vaxis will only send .key_press / .winsize because those are present. 
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn run(
    allocator: std.mem.Allocator,
    index: *const TaskIndex,
    ui: *UiState,
) !void {
    // Initialize TTY exactly as in libvaxis README. 
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    // Initialize Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    // Event loop: vaxis reads the TTY in a separate thread.
    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // Alternate screen, with proper teardown.
    try vx.enterAltScreen(tty.writer());
    defer {
        _ = vx.exitAltScreen(tty.writer()) catch {};
        _ = vx.resetState(tty.writer()) catch {};
    }

    // Feature detection via terminal queries.
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var running = true;
    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    running = false;
                }
                // We will wire arrow keys into UiState.moveSelection later.
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
            },
        }

        const win = vx.window();
        win.clear();

        drawHeader(win);
        drawCounts(win, index);
        drawTodoList(win, index, ui);

        try vx.render(tty.writer());
    }
}

fn drawHeader(win: vaxis.Window) void {
    const title = "ztask";

    const term_width: usize = @intCast(win.width);
    const row: u16 = 0;

    const title_len = title.len;
    const total_width = title_len;

    var start_col: usize = 0;
    if (term_width > total_width) {
        start_col = (term_width - total_width) / 2;
    }

    const style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 200, 200, 255 } },
    };

    var col = start_col;

    var i: usize = 0;
    while (i < title_len) : (i += 1) {
        const g = title[i .. i + 1]; // slice into static string, stable
        const cell: Cell = .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        };
        _ = win.writeCell(@intCast(col), row, cell);
        col += 1;
    }
}

fn drawCounts(win: vaxis.Window, index: *const TaskIndex) void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "TODO: {d}  DONE: {d}",
        .{ index.todo.len, index.done.len },
    ) catch buf[0..0];

    const term_width: usize = @intCast(win.width);
    const row: u16 = if (win.height > 2) 2 else 0;

    const text_len = text.len;
    var start_col: usize = 0;
    if (term_width > text_len) {
        start_col = (term_width - text_len) / 2;
    }

    const style: vaxis.Style = .{
        .fg = .{ .rgb = .{ 180, 180, 180 } },
    };

    var col = start_col;
    var i: usize = 0;
    while (i < text_len) : (i += 1) {
        const g = text[i .. i + 1]; // slice into `buf`, stable for this frame
        const cell: Cell = .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        };
        _ = win.writeCell(@intCast(col), row, cell);
        col += 1;
    }
}

/// Render the TODO list starting a few rows below the header.
/// Uses TaskIndex.todo[i].text directly so what you wrote in todo.txt
/// shows verbatim.
fn drawTodoList(win: vaxis.Window, index: *const TaskIndex, ui: *UiState) void {
    const tasks = index.todo;

    if (tasks.len == 0) return;

    const term_height: usize = @intCast(win.height);
    const term_width: usize = @intCast(win.width);

    // Rows 0 and 2 are used for header and counts. Leave one blank line.
    const start_row: usize = 4;
    if (term_height <= start_row) return;

    const viewport_height = term_height - start_row;

    // We have not wired scrolling yet, so force scroll_offset to 0
    // and clamp selected_index into range.
    if (ui.selected_index >= tasks.len) {
        ui.selected_index = tasks.len - 1;
    }
    ui.scroll_offset = 0;

    const end_index = @min(tasks.len, ui.scroll_offset + viewport_height);

    const base_style: vaxis.Style = .{};
    const sel_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 220, 220, 255 } },
    };

    var row = start_row;
    var idx = ui.scroll_offset;
    while (idx < end_index and row < term_height) : ({
        idx += 1;
        row += 1;
    }) {
        const task = tasks[idx];
        const text = task.text;

        const style = if (ui.focus == .todo and ui.selected_index == idx)
            sel_style
        else
            base_style;

        var col: usize = 0;
        const max_cols = term_width;

        var i: usize = 0;
        while (i < text.len and col < max_cols) : (i += 1) {
            const g = text[i .. i + 1]; // slice into underlying file buffer
            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(@intCast(col), @intCast(row), cell);
            col += 1;
        }
    }
}
