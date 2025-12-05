const std = @import("std");
const vaxis = @import("vaxis");

const Cell = vaxis.Cell;

var counts_buf: [64]u8 = undefined;

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const ui_mod = @import("ui_state.zig");
const UiState = ui_mod.UiState;
const ListKind = ui_mod.ListKind;

/// Event type for the libvaxis low-level loop.
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};


const AppView = enum {
    list,
    editor,
};

const EditorState = struct {
    pub const Mode = enum { normal };

    mode: Mode = .normal,

    pub fn init() EditorState {
        return .{};
    }
};

/// First row used for the task list (0 = header, 2 = counts, 3 blank).
const LIST_START_ROW: usize = 4;

pub fn run(
    allocator: std.mem.Allocator,
    index: *const TaskIndex,
    ui: *UiState,
) !void {
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    var view: AppView = .list;
    var editor = EditorState.init();

    var list_cmd_active = false;
    var list_cmd_new = false;


    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    defer {
        _ = vx.exitAltScreen(tty.writer()) catch {};
        _ = vx.resetState(tty.writer()) catch {};
    }

    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var running = true;
    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                // Ctrl-C always exits the whole app.
                if (key.matches('c', .{ .ctrl = true })) {
                    running = false;
                } else switch (view) {
                    .list => {
                        if (list_cmd_active) {
                            handleListCommandKey(
                                key,
                                &view,
                                &editor,
                                &list_cmd_active,
                                &list_cmd_new,
                            );
                        } else {
                            if (key.matches(':', .{})) {
                                // Start list-view ":" command-line
                                list_cmd_active = true;
                                list_cmd_new = false;
                            } else {
                                // Normal list navigation (j/k, arrows, etc.)
                                handleNavigation(&vx, index, ui, key);
                            }
                        }
                    },
                    .editor => {
                        handleEditorKey(key, &view);
                    },
                }
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
            },
        }

        const win = vx.window();
        clearAll(win);

        switch (view) {
            .list => {
                drawHeader(win);
                drawCounts(win, index);
                drawTodoList(win, index, ui, list_cmd_active);
                drawListCommandLine(win, list_cmd_active, list_cmd_new);
            },
            .editor => {
                drawEditorPlaceholder(win);
            },
        }

        try vx.render(tty.writer());
    }
}



fn handleNavigation(vx: *vaxis.Vaxis, index: *const TaskIndex, ui: *UiState, key: vaxis.Key) void {
    const win = vx.window();
    const term_height: usize = @intCast(win.height);
    if (term_height <= LIST_START_ROW) return;

    const viewport_height = term_height - LIST_START_ROW;
    const todo_len = index.todo.len;
    if (todo_len == 0 or viewport_height == 0) return;

    // Down: 'j' or Down arrow
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        ui.moveSelection(todo_len, viewport_height, 1);
    }
    // Up: 'k' or Up arrow
    else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        ui.moveSelection(todo_len, viewport_height, -1);
    }
}

fn clearAll(win: vaxis.Window) void {
    const space = " "[0..1];
    const style: vaxis.Style = .{};

    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            const cell: Cell = .{
                .char = .{ .grapheme = space, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(col, row, cell);
        }
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
    while (i < title_len and col < term_width) : (i += 1) {
        const g = title[i .. i + 1]; // slice into static string
        const cell: Cell = .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        };
        _ = win.writeCell(@intCast(col), row, cell);
        col += 1;
    }
}


fn drawCounts(win: vaxis.Window, index: *const TaskIndex) void {
    // Format into the static buffer so grapheme slices stay valid
    const text = std.fmt.bufPrint(
        &counts_buf,
        "TODO: {d}  DONE: {d}",
        .{ index.todo.len, index.done.len },
    ) catch counts_buf[0..0];

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
    while (i < text_len and col < term_width) : (i += 1) {
        // Grapheme slices point into counts_buf, which is static
        const g = text[i .. i + 1];
        const cell: Cell = .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        };
        _ = win.writeCell(@intCast(col), row, cell);
        col += 1;
    }
}

fn drawListCommandLine(win: vaxis.Window, active: bool, new_flag: bool) void {
    if (!active or win.height == 0) return;

    const row: u16 = win.height - 1;
    const style: vaxis.Style = .{};

    const colon = ":"[0..1];
    _ = win.writeCell(0, row, .{
        .char = .{ .grapheme = colon, .width = 1 },
        .style = style,
    });

    if (new_flag and win.width > 1) {
        const n_slice = "n"[0..1];
        _ = win.writeCell(1, row, .{
            .char = .{ .grapheme = n_slice, .width = 1 },
            .style = style,
        });
    }
}

fn drawEditorPlaceholder(win: vaxis.Window) void {
    const title = "NEW TASK";
    const hint = "editor placeholder - Esc returns to list";

    const term_width: usize = @intCast(win.width);
    const term_height: usize = @intCast(win.height);
    if (term_width == 0 or term_height == 0) return;

    const mid_row: u16 = @intCast(term_height / 2);
    const hint_row: u16 = mid_row + 2;

    const title_style: vaxis.Style = .{ .bold = true };
    const hint_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 180, 180, 180 } } };

    drawCenteredText(win, mid_row, title, title_style);
    drawCenteredText(win, hint_row, hint, hint_style);
}

fn drawCenteredText(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    const term_width: usize = @intCast(win.width);
    const len = text.len;

    var start_col: usize = 0;
    if (term_width > len) {
        start_col = (term_width - len) / 2;
    }

    var col = start_col;
    var i: usize = 0;
    while (i < len and col < term_width) : (i += 1) {
        const g = text[i .. i + 1];
        const cell: Cell = .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        };
        _ = win.writeCell(@intCast(col), row, cell);
        col += 1;
    }
}


fn handleListCommandKey(
    key: vaxis.Key,
    view: *AppView,
    editor: *EditorState,
    list_cmd_active: *bool,
    list_cmd_new: *bool,
) void {
    // Esc: cancel command-line
    if (key.matches(vaxis.Key.escape, .{})) {
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        return;
    }

    // Backspace: clear the "n" if present
    if (key.matches(vaxis.Key.backspace, .{})) {
        list_cmd_new.* = false;
        return;
    }

    // Enter: execute
    if (key.matches(vaxis.Key.enter, .{})) {
        if (list_cmd_new.*) {
            // ":n" -> open editor
            editor.* = EditorState.init();
            view.* = .editor;
        }
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        return;
    }

    // For now we only support ":n"
    if (key.matches('n', .{})) {
        list_cmd_new.* = true;
    }
}

fn handleEditorKey(key: vaxis.Key, view: *AppView) void {
    // Esc from editor returns to list view, discarding edits for now.
    if (key.matches(vaxis.Key.escape, .{})) {
        view.* = .list;
    }
}

/// Render TODO list with vim-style navigation.
/// Selected row is bold and prefixed with "> ".
fn drawTodoList(win: vaxis.Window, index: *const TaskIndex, ui: *UiState, cmd_active:bool) void {
    const tasks = index.todo;
    if (tasks.len == 0) return;

    const term_height: usize = @intCast(win.height);
    const term_width: usize = @intCast(win.width);
    if (term_height <= LIST_START_ROW) return;


    const reserved_rows: usize = if (cmd_active and term_height > LIST_START_ROW + 1) 1 else 0;

    if (term_height <= LIST_START_ROW + reserved_rows) return;

    const viewport_height = term_height - LIST_START_ROW - reserved_rows;
    if (viewport_height == 0) return;

    ui.ensureValidSelection(tasks.len, viewport_height);

    const indicator_slice = ">"[0..1];
    const space_slice = " "[0..1];

    const base_style: vaxis.Style = .{};
    const sel_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 220, 220, 255 } },
    };

    const max_visible = ui.scroll_offset + viewport_height;
    const end_index = if (max_visible < tasks.len) max_visible else tasks.len;

    var row = LIST_START_ROW;
    var idx = ui.scroll_offset;

    while (idx < end_index and row < term_height) : ({
        idx += 1;
        row += 1;
    }) {
        const task = tasks[idx];
        const text = task.text;

        const selected = (ui.focus == .todo and ui.selected_index == idx);
        const style = if (selected) sel_style else base_style;

        // Column 0: indicator for selected line (">") or a space.
        if (term_width > 0) {
            const g = if (selected) indicator_slice else space_slice;
            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(0, @intCast(row), cell);
        }

        // Column 1: space after indicator (for readability).
        if (term_width > 1) {
            const cell: Cell = .{
                .char = .{ .grapheme = space_slice, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(1, @intCast(row), cell);
        }

        // Text starts at column 2.
        var col: usize = 2;
        var i: usize = 0;
        while (i < text.len and col < term_width) : (i += 1) {
            const g = text[i .. i + 1]; // slice into the file-backed buffer
            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(@intCast(col), @intCast(row), cell);
            col += 1;
        }
    }
}
