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
    pub const Mode = enum {
        normal,
        insert,
    };

    mode: Mode = .insert,

    // single-line task text buffer
    buf: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn init() EditorState {
        return .{
            .mode = .insert,
            .len = 0,
            .cursor = 0,
        };
    }

    pub fn asSlice(self: *const EditorState) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn insertChar(self: *EditorState, ch: u8) void {
        if (self.len >= self.buf.len) return;

        if (self.cursor > self.len) self.cursor = self.len;

        var i: usize = self.len;
        while (i > self.cursor) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
    }

    pub fn deleteBeforeCursor(self: *EditorState) void {
        if (self.cursor == 0 or self.len == 0) return;

        var i: usize = self.cursor - 1;
        while (i + 1 < self.len) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
        self.cursor -= 1;
    }

    pub fn moveCursor(self: *EditorState, delta: i32) void {
        const cur = @as(i32, @intCast(self.cursor));
        var next = cur + delta;

        if (next < 0) next = 0;
        const max = @as(i32, @intCast(self.len));
        if (next > max) next = max;

        self.cursor = @intCast(next);
    }

    pub fn moveToStart(self: *EditorState) void {
        self.cursor = 0;
    }

    pub fn moveToEnd(self: *EditorState) void {
        self.cursor = self.len;
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
        var w = tty.writer();

        // Leave alt screen and reset vaxis state
        _ = vx.exitAltScreen(w) catch {};
        _ = vx.resetState(w) catch {};

        // Force-disable Kitty keyboard protocol so later programs
        // (fzf, shells, tmux panes) see normal keycodes again.
        _ = w.writeAll("\x1b[>0u") catch {};
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
                        handleEditorKey(key, &view, &editor);
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
                drawEditorView(win, &editor);
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


fn drawEditorView(win: vaxis.Window, editor: *const EditorState) void {
    const term_width: usize = @intCast(win.width);
    const term_height: usize = @intCast(win.height);
    if (term_width == 0 or term_height == 0) return;

    const header = "NEW TASK";
    const mode_insert = "[INSERT]";
    const mode_normal = "[NORMAL]";

    const header_style: vaxis.Style = .{ .bold = true };
    drawCenteredText(win, 0, header, header_style);

    const mode_text = if (editor.mode == .insert) mode_insert else mode_normal;
    const mode_style: vaxis.Style = .{
        .fg = .{ .rgb = .{ 180, 180, 180 } },
    };

    // mode indicator at row 1, left-aligned
    var col: u16 = 0;
    var i: usize = 0;
    while (i < mode_text.len and col < win.width) : (i += 1) {
        const g = mode_text[i .. i + 1];
        _ = win.writeCell(col, 1, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = mode_style,
        });
        col += 1;
    }

    // label "Task:" at row 3
    const label = "Task:";
    const label_row: u16 = if (term_height > 3) 3 else 1;
    col = 2;
    i = 0;
    const label_style: vaxis.Style = .{};
    while (i < label.len and col < win.width) : (i += 1) {
        const g = label[i .. i + 1];
        _ = win.writeCell(col, label_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = label_style,
        });
        col += 1;
    }

    // task text at row 4
    const text_row: u16 = if (term_height > 4) 4 else label_row + 1;
    const text = editor.asSlice();
    const text_style: vaxis.Style = .{};

    var text_col: u16 = 2;
    i = 0;
    while (i < text.len and text_col < win.width) : (i += 1) {
        const g = text[i .. i + 1];
        _ = win.writeCell(text_col, text_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = text_style,
        });
        text_col += 1;
    }

    // simple cursor indicator: underscore after current cursor position
    if (editor.mode == .insert and text_col < win.width) {
        const cursor = "_"[0..1];
        _ = win.writeCell(text_col, text_row, .{
            .char = .{ .grapheme = cursor, .width = 1 },
            .style = text_style,
        });
    }

    // hints at bottom row
    if (term_height > 6) {
        const hint = "i: insert  Esc: normal/quit  Ctrl-S: save (stub)";
        const hint_row: u16 = @intCast(term_height - 1);
        const hint_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 150, 150, 150 } },
        };
        drawCenteredText(win, hint_row, hint, hint_style);
    }
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


fn keyToAscii(key: vaxis.Key) ?u8 {
    // brute-force map key events to ASCII 0x20..0x7e using only .matches
    var c: u8 = 32; // space
    while (true) {
        const cp: u21 = @intCast(c);
        if (key.matches(cp, .{})) {
            return c;
        }
        if (c == 126) break;
        c += 1;
    }
    return null;
}

fn handleEditorKey(
    key: vaxis.Key,
    view: *AppView,
    editor: *EditorState,
) void {
    // Esc: insert -> normal, normal -> leave editor.
    if (key.matches(vaxis.Key.escape, .{})) {
        switch (editor.mode) {
            .insert => editor.mode = .normal,
            .normal => view.* = .list,
        }
        return;
    }

    // Ctrl-S: stub "save" – for now just exit editor.
    if (key.matches('s', .{ .ctrl = true })) {
        view.* = .list;
        return;
    }

    switch (editor.mode) {
        .normal => {
            // basic vim-like motions on a single line
            if (key.matches('i', .{})) {
                editor.mode = .insert;
                return;
            }
            if (key.matches('a', .{})) {
                editor.moveToEnd();
                editor.mode = .insert;
                return;
            }
            if (key.matches('h', .{})) {
                editor.moveCursor(-1);
                return;
            }
            if (key.matches('l', .{})) {
                editor.moveCursor(1);
                return;
            }
            if (key.matches('0', .{})) {
                editor.moveToStart();
                return;
            }
            if (key.matches('$', .{})) {
                editor.moveToEnd();
                return;
            }
        },
        .insert => {
            // Backspace deletes
            if (key.matches(vaxis.Key.backspace, .{})) {
                editor.deleteBeforeCursor();
                return;
            }

            // Enter: leave insert, stay in editor
            if (key.matches(vaxis.Key.enter, .{})) {
                editor.mode = .normal;
                return;
            }

            // Printable ASCII
            if (keyToAscii(key)) |ch| {
                editor.insertChar(ch);
            }
        },
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
