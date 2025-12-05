const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const fs = std.fs;

var counts_buf: [64]u8 = undefined;

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const Task = task_mod.Task;

const ui_mod = @import("ui_state.zig");
const UiState = ui_mod.UiState;
const ListKind = ui_mod.ListKind;

/// Event type for the libvaxis low-level loop.
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};


pub const TuiContext = struct {
    todo_file: *fs.File,
    done_file: *fs.File,
    index: *TaskIndex,
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

    // main single-line task text
    buf: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    // ":" command-line inside the editor, e.g. "w", "q", "wq"
    cmd_active: bool = false,
    cmd_buf: [32]u8 = undefined,
    cmd_len: usize = 0,

    pub fn init() EditorState {
        return .{
            .mode = .insert,
            .len = 0,
            .cursor = 0,
            .cmd_active = false,
            .cmd_len = 0,
        };
    }

    pub fn asSlice(self: *const EditorState) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn cmdSlice(self: *const EditorState) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }

    pub fn resetCommand(self: *EditorState) void {
        self.cmd_active = false;
        self.cmd_len = 0;
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
    ctx: *TuiContext,
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
                                handleNavigation(&vx, ctx.index, ui, key);
                            }
                        }
                    },
                    .editor => {
                        try handleEditorKey(key, &view, &editor, ctx, allocator,ui);
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
                drawCounts(win, ctx.index);
                drawTodoList(win, ctx.index, ui, list_cmd_active);
                drawListCommandLine(win, list_cmd_active, list_cmd_new, list_cmd_done);
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

    const active_len: usize = switch (ui.focus) {
        .todo => index.todo.len,
        .done => index.done.len,
    };

    if (active_len == 0 or viewport_height == 0) return;

    // Down: 'j' or Down arrow
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        ui.moveSelection(active_len, 1);
    }
    // Up: 'k' or Up arrow
    else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        ui.moveSelection(active_len, -1);
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



fn drawCounts(win: vaxis.Window, index: *const TaskIndex, ui: *const UiState) void {
    // Format into the static buffer.
    const text = std.fmt.bufPrint(
        &counts_buf,
        "TODO {d}  DONE {d}",
        .{ index.todo.len, index.done.len },
    ) catch counts_buf[0..0];

    const term_width: usize = @intCast(win.width);
    const row: u16 = if (win.height > 2) 2 else 0;

    const text_len = text.len;
    var start_col: usize = 0;
    if (term_width > text_len) {
        start_col = (term_width - text_len) / 2;
    }

    const style_inactive: vaxis.Style = .{
        .fg = .{ .rgb = .{ 180, 180, 180 } },
    };
    const style_active: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 230, 230, 255 } },
    };

    // "TODO {todo}  DONE {done}"
    const todo_prefix_len: usize = "TODO ".len;

    // Find the double-space delimiter between TODO and DONE segments.
    var delim_index: usize = text_len;
    var k: usize = 0;
    while (k + 1 < text_len) : (k += 1) {
        if (text[k] == ' ' and text[k + 1] == ' ') {
            delim_index = k;
            break;
        }
    }

    const todo_end = if (delim_index <= text_len) delim_index else text_len;
    const done_start = if (delim_index + 2 <= text_len) delim_index + 2 else text_len;

    const focus_todo = (ui.focus == .todo);

    var col = start_col;
    var i: usize = 0;
    while (i < text_len and col < term_width) : (i += 1) {
        const g = text[i .. i + 1];

        const style =
            if (i < todo_end)
                (if (focus_todo) style_active else style_inactive)
            else if (i >= done_start)
                (if (!focus_todo) style_active else style_inactive)
            else
                style_inactive;

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

    // hints at bottom row (only when not in ":" command mode)
    if (term_height > 6 and !editor.cmd_active) {
        const hint = "i: insert   :w save+quit   :q quit";
        const hint_row: u16 = @intCast(term_height - 1);
        const hint_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 150, 150, 150 } },
        };
        drawCenteredText(win, hint_row, hint, hint_style);
    }


    // editor ":" command-line at the bottom when active
    if (editor.cmd_active and term_height > 0) {
        const row: u16 = @intCast(term_height - 1);
        const style: vaxis.Style = .{};

        const colon = ":"[0..1];
        _ = win.writeCell(0, row, .{
            .char = .{ .grapheme = colon, .width = 1 },
            .style = style,
        });

        const cmd = editor.cmdSlice();
        var col2: u16 = 1;
        var j: usize = 0;
        while (j < cmd.len and col2 < win.width) : (j += 1) {
            const g = cmd[j .. j + 1];
            _ = win.writeCell(col2, row, .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            });
            col2 += 1;
        }
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


fn saveNewTask(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !void {
    const line = editor.asSlice();
    if (line.len == 0) return; // ignore empty tasks

    // Append to todo.txt
    var file = ctx.todo_file.*; // copy; shares the same OS handle
    const stat = try file.stat();
    try file.seekTo(stat.size);
    try file.writeAll(line);
    try file.writeAll("\n");

    // Reload index from disk.
    // NOTE: this is O(file_size). For very large files we can later
    // replace this with an incremental path that parses only the newly
    // appended bytes and updates the index in place.
    try ctx.index.reload(allocator, file, ctx.done_file.*);

    // Focus new task at bottom of TODO list.
    if (ctx.index.todo.len != 0) {
        ui.focus = .todo;
        ui.selected_index = ctx.index.todo.len - 1;
        ui.last_move = 1;
        // scroll_offset will be normalized in drawTodoList via ensureValidSelection
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
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    // If ":" command-line is active, all keys go there.
    if (editor.cmd_active) {
        // Esc: cancel command-line
        if (key.matches(vaxis.Key.escape, .{})) {
            editor.resetCommand();
            return;
        }

        // Backspace: delete last command char
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (editor.cmd_len > 0) editor.cmd_len -= 1;
            return;
        }

        // Enter: execute
        if (key.matches(vaxis.Key.enter, .{})) {
            const cmd = editor.cmdSlice();

            // :q -> exit editor without saving
            if (std.mem.eql(u8, cmd, "q")) {
                editor.resetCommand();
                view.* = .list;
                return;
            }

            // :w or :wq -> save and exit
            if (std.mem.eql(u8, cmd, "w") or std.mem.eql(u8, cmd, "wq")) {
                try saveNewTask(ctx, allocator, editor, ui);
                editor.resetCommand();
                view.* = .list;
                return;
            }

            // Unknown command: just clear for now.
            editor.resetCommand();
            return;
        }

        // Printable ASCII into command buffer
        if (keyToAscii(key)) |ch| {
            if (editor.cmd_len < editor.cmd_buf.len) {
                editor.cmd_buf[editor.cmd_len] = ch;
                editor.cmd_len += 1;
            }
        }

        return;
    }

    // ":" enters editor command-line (from any mode, forces normal).
    if (key.matches(':', .{})) {
        editor.mode = .normal;
        editor.resetCommand();
        editor.cmd_active = true;
        return;
    }

    // Esc: insert -> normal, normal -> leave editor.
    if (key.matches(vaxis.Key.escape, .{})) {
        switch (editor.mode) {
            .insert => editor.mode = .normal,
            .normal => view.* = .list,
        }
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



fn isSpaceByte(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// Count how many terminal rows are needed to render `text` if we wrap
/// on ASCII spaces/tabs and allow at most `max_cols` columns per row.
fn measureWrappedRows(text: []const u8, max_cols: usize) usize {
    if (text.len == 0 or max_cols == 0) return 0;

    var rows: usize = 0;
    var i: usize = 0;
    const len = text.len;

    while (i < len) {
        rows += 1;

        const line_start = i;
        var last_space: ?usize = null;
        var col_count: usize = 0;

        // Consume up to max_cols bytes for this row.
        while (i < len and col_count < max_cols) : (col_count += 1) {
            const b = text[i];
            if (isSpaceByte(b)) {
                last_space = i;
            }
            i += 1;
        }

        // If we hit the column limit and still have more text, prefer
        // breaking at the last recorded space on this line.
        if (i < len and col_count == max_cols) {
            if (last_space) |sp| {
                if (sp >= line_start) {
                    // Next line starts after the space.
                    i = sp + 1;
                }
            }
        }

        // Skip leading spaces at the start of the next line.
        while (i < len and isSpaceByte(text[i])) {
            i += 1;
        }
    }

    return rows;
}

/// Draw `text` starting at (start_row, col_offset), wrapping on ASCII
/// spaces/tabs into at most `max_rows` rows and `max_cols` columns.
fn drawWrappedText(
    win: vaxis.Window,
    start_row: usize,
    col_offset: usize,
    max_rows: usize,
    max_cols: usize,
    text: []const u8,
    style: vaxis.Style,
) void {
    if (text.len == 0 or max_rows == 0 or max_cols == 0) return;

    const len = text.len;
    var i: usize = 0;
    var row_index: usize = 0;

    while (i < len and row_index < max_rows and (start_row + row_index) < win.height) : (row_index += 1) {
        const row: u16 = @intCast(start_row + row_index);

        const line_start = i;
        var last_space: ?usize = null;
        var col_count: usize = 0;

        // Determine how many bytes fit on this row.
        while (i < len and col_count < max_cols) : (col_count += 1) {
            const b = text[i];
            if (isSpaceByte(b)) {
                last_space = i;
            }
            i += 1;
        }

        var line_end = i;

        if (i < len and col_count == max_cols) {
            if (last_space) |sp| {
                if (sp >= line_start) {
                    line_end = sp;
                    i = sp + 1;
                }
            }
        }

        // Skip leading spaces for what we actually draw on this line.
        var seg_start = line_start;
        while (seg_start < line_end and isSpaceByte(text[seg_start])) {
            seg_start += 1;
        }

        var col: usize = col_offset;
        var j: usize = seg_start;
        while (j < line_end and col < win.width) : (j += 1) {
            const g = text[j .. j + 1];
            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(@intCast(col), row, cell);
            col += 1;
        }

        // Skip leading spaces at the start of the next row.
        while (i < len and isSpaceByte(text[i])) {
            i += 1;
        }
    }
}


fn isSelectionFullyVisible(
    ui: *const UiState,
    tasks: []const Task,
    viewport_height: usize,
    content_width: usize,
) bool {
    if (tasks.len == 0 or viewport_height == 0 or content_width == 0) return true;
    if (ui.selected_index >= tasks.len) return false;
    if (ui.scroll_offset >= tasks.len) return false;

    var rows_used: usize = 0;
    var idx = ui.scroll_offset;

    while (idx < tasks.len and rows_used < viewport_height) : (idx += 1) {
        var rows = measureWrappedRows(tasks[idx].text, content_width);
        if (rows == 0) rows = 1;

        if (rows_used + rows > viewport_height) {
            // This task would be partially clipped.
            if (idx == ui.selected_index) return false;
            break;
        }

        if (idx == ui.selected_index) {
            // Selected task fits entirely within [rows_used .. rows_used+rows).
            return true;
        }

        rows_used += rows;
    }

    return false;
}


fn recomputeScrollOffsetForSelection(
    ui: *UiState,
    tasks: []const Task,
    viewport_height: usize,
    content_width: usize,
    dir: i8,
) void {
    if (tasks.len == 0 or viewport_height == 0 or content_width == 0) {
        ui.scroll_offset = 0;
        ui.selected_index = 0;
        return;
    }

    if (ui.selected_index >= tasks.len) {
        ui.selected_index = tasks.len - 1;
    }

    const sel = ui.selected_index;

    var rows_sel = measureWrappedRows(tasks[sel].text, content_width);
    if (rows_sel == 0) rows_sel = 1;

    if (rows_sel > viewport_height) {
        // Pathological: one task taller than the viewport; anchor on it.
        ui.scroll_offset = sel;
        return;
    }

    // Moving up: make the selected task the first in the viewport.
    if (dir < 0) {
        ui.scroll_offset = sel;
        return;
    }

    // Moving down or unknown: keep behaviour where we pack as many
    // tasks above the selection as will fit.
    var rows_total: usize = rows_sel;
    var start_idx: usize = sel;

    while (start_idx > 0) {
        const prev_idx = start_idx - 1;
        var r = measureWrappedRows(tasks[prev_idx].text, content_width);
        if (r == 0) r = 1;

        if (rows_total + r > viewport_height) break;

        rows_total += r;
        start_idx = prev_idx;
    }

    ui.scroll_offset = start_idx;
}


/// Render TODO list with vim-style navigation.
/// Selected row is bold and prefixed with "> ".
fn drawTodoList(
    win: vaxis.Window,
    index: *const TaskIndex,
    ui: *UiState,
    cmd_active: bool,
) void {
    const tasks = index.todo;
    if (tasks.len == 0) {
        ui.scroll_offset = 0;
        ui.selected_index = 0;
        return;
    }

    const term_height: usize = @intCast(win.height);
    const term_width: usize = @intCast(win.width);
    if (term_height <= LIST_START_ROW) return;

    const reserved_rows: usize = if (cmd_active and term_height > LIST_START_ROW + 1) 1 else 0;
    if (term_height <= LIST_START_ROW + reserved_rows) return;

    const viewport_height = term_height - LIST_START_ROW - reserved_rows;
    if (viewport_height == 0) return;

    if (ui.selected_index >= tasks.len) {
        ui.selected_index = tasks.len - 1;
    }

    const dir= ui.last_move;

    // Content starts at column 2: "> " then text.
    if (term_width <= 2) return;
    const content_width: usize = term_width - 2;

    // Only adjust scroll_offset if the selected task is not fully visible
    // with the current offset. This avoids jitter when moving inside the
    // existing viewport.
    if (!isSelectionFullyVisible(ui, tasks, viewport_height, content_width)) {
        recomputeScrollOffsetForSelection(ui, tasks, viewport_height, content_width, dir);
    }

    const indicator_slice = ">"[0..1];
    const space_slice = " "[0..1];

    const base_style: vaxis.Style = .{};
    const sel_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 220, 220, 255 } },
    };

    var row: usize = LIST_START_ROW;
    var remaining_rows: usize = viewport_height;

    var idx = ui.scroll_offset;
    while (idx < tasks.len and remaining_rows > 0 and row < term_height) : (idx += 1) {
        const task = tasks[idx];
        const text = task.text;

        const selected = (ui.focus == .todo and ui.selected_index == idx);
        const style = if (selected) sel_style else base_style;

        const rows_needed = measureWrappedRows(text, content_width);
        if (rows_needed == 0) continue;

        if (rows_needed > remaining_rows) {
            // Do not draw a partially visible task; leave the rest blank.
            break;
        }

        const row_u16: u16 = @intCast(row);

        // First visual row: draw indicator in column 0, space in column 1.
        if (term_width > 0) {
            const g = if (selected) indicator_slice else space_slice;
            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(0, row_u16, cell);
        }
        if (term_width > 1) {
            const cell: Cell = .{
                .char = .{ .grapheme = space_slice, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(1, row_u16, cell);
        }

        // Draw wrapped text starting at this row and column 2.
        drawWrappedText(
            win,
            row,           // start_row
            2,             // col_offset ("  " prefix)
            rows_needed,   // max_rows allowed for this task
            content_width, // max_cols
            text,
            style,
        );

        row += rows_needed;
        remaining_rows -= rows_needed;
    }
}
