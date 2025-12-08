const std = @import("std");
const vaxis = @import("vaxis");
const store = @import("task_store.zig");

const Cell = vaxis.Cell;

const fs = std.fs;

var counts_buf: [64]u8 = undefined;

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const Task = task_mod.Task;


const ui_mod = @import("ui_state.zig");
const UiState = ui_mod.UiState;
const ListKind = ui_mod.ListKind;

const ListView = ui_mod.ListView;

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


fn insertIntoBuffer(buf: []u8, len: *usize, cursor: *usize, ch: u8) void {
    if (len.* >= buf.len) return;
    if (cursor.* > len.*) cursor.* = len.*;

    var i: usize = len.*;
    while (i > cursor.*) : (i -= 1) {
        buf[i] = buf[i - 1];
    }
    buf[cursor.*] = ch;
    len.* += 1;
    cursor.* += 1;
}

fn deleteBeforeInBuffer(buf: []u8, len: *usize, cursor: *usize) void {
    if (cursor.* == 0 or len.* == 0) return;

    var i: usize = cursor.* - 1;
    while (i + 1 < len.*) : (i += 1) {
        buf[i] = buf[i + 1];
    }
    len.* -= 1;
    cursor.* -= 1;
}

fn moveCursorInBuffer(len: usize, cursor: *usize, delta: i32) void {
    const cur = @as(i32, @intCast(cursor.*));
    var next = cur + delta;

    if (next < 0) next = 0;
    const max = @as(i32, @intCast(len));
    if (next > max) next = max;

    cursor.* = @intCast(next);
}

const EditorState = struct {
    pub const Mode = enum {
        normal,
        insert,
    };

    pub const Field = enum {
        task,
        priority,
        due,
        repeat,
    };

    mode: Mode = .insert,
    focus: Field = .task,

    // main single-line task text
    buf: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    // priority, edited as a tiny string, parsed to u8 on save
    prio_buf: [4]u8 = undefined,
    prio_len: usize = 0,
    prio_cursor: usize = 0,

    // due date string
    due_buf: [64]u8 = undefined,
    due_len: usize = 0,
    due_cursor: usize = 0,

    // repeat rule string
    repeat_buf: [64]u8 = undefined,
    repeat_len: usize = 0,
    repeat_cursor: usize = 0,

    // ":" command-line inside the editor
    cmd_active: bool = false,
    cmd_buf: [32]u8 = undefined,
    cmd_len: usize = 0,

    pub fn init() EditorState {
        return .{
            .mode = .insert,
            .focus = .task,

            .buf = undefined,
            .len = 0,
            .cursor = 0,

            .prio_buf = undefined,
            .prio_len = 0,
            .prio_cursor = 0,

            .due_buf = undefined,
            .due_len = 0,
            .due_cursor = 0,

            .repeat_buf = undefined,
            .repeat_len = 0,
            .repeat_cursor = 0,

            .cmd_active = false,
            .cmd_buf = undefined,
            .cmd_len = 0,
        };
    }

    // main task text
    pub fn asSlice(self: *const EditorState) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn taskSlice(self: *const EditorState) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn prioSlice(self: *const EditorState) []const u8 {
        return self.prio_buf[0..self.prio_len];
    }

    pub fn dueSlice(self: *const EditorState) []const u8 {
        return self.due_buf[0..self.due_len];
    }

    pub fn repeatSlice(self: *const EditorState) []const u8 {
        return self.repeat_buf[0..self.repeat_len];
    }

    // parse priority text into u8 (empty or invalid => 0)
    pub fn priorityValue(self: *const EditorState) u8 {
        const s = self.prioSlice();
        if (s.len == 0) return 0;

        var i: usize = 0;
        var v: u16 = 0;
        var saw_digit = false;

        while (i < s.len) : (i += 1) {
            const b = s[i];
            if (b < '0' or b > '9') break;
            saw_digit = true;
            v = v * 10 + (b - '0');
            if (v > 255) {
                v = 255;
                break;
            }
        }

        if (!saw_digit) return 0;
        return @intCast(v);
    }

    pub fn cmdSlice(self: *const EditorState) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }

    pub fn resetCommand(self: *EditorState) void {
        self.cmd_active = false;
        self.cmd_len = 0;
    }

    // Editing APIs now respect focus.

    pub fn insertChar(self: *EditorState, ch: u8) void {
        switch (self.focus) {
            .task => insertIntoBuffer(self.buf[0..], &self.len, &self.cursor, ch),
            .priority => insertIntoBuffer(self.prio_buf[0..], &self.prio_len, &self.prio_cursor, ch),
            .due => insertIntoBuffer(self.due_buf[0..], &self.due_len, &self.due_cursor, ch),
            .repeat => insertIntoBuffer(self.repeat_buf[0..], &self.repeat_len, &self.repeat_cursor, ch),
        }
    }

    pub fn deleteBeforeCursor(self: *EditorState) void {
        switch (self.focus) {
            .task => deleteBeforeInBuffer(self.buf[0..], &self.len, &self.cursor),
            .priority => deleteBeforeInBuffer(self.prio_buf[0..], &self.prio_len, &self.prio_cursor),
            .due => deleteBeforeInBuffer(self.due_buf[0..], &self.due_len, &self.due_cursor),
            .repeat => deleteBeforeInBuffer(self.repeat_buf[0..], &self.repeat_len, &self.repeat_cursor),
        }
    }

    pub fn moveCursor(self: *EditorState, delta: i32) void {
        switch (self.focus) {
            .task => moveCursorInBuffer(self.len, &self.cursor, delta),
            .priority => moveCursorInBuffer(self.prio_len, &self.prio_cursor, delta),
            .due => moveCursorInBuffer(self.due_len, &self.due_cursor, delta),
            .repeat => moveCursorInBuffer(self.repeat_len, &self.repeat_cursor, delta),
        }
    }

    pub fn moveToStart(self: *EditorState) void {
        switch (self.focus) {
            .task => self.cursor = 0,
            .priority => self.prio_cursor = 0,
            .due => self.due_cursor = 0,
            .repeat => self.repeat_cursor = 0,
        }
    }

    pub fn moveToEnd(self: *EditorState) void {
        switch (self.focus) {
            .task => self.cursor = self.len,
            .priority => self.prio_cursor = self.prio_len,
            .due => self.due_cursor = self.due_len,
            .repeat => self.repeat_cursor = self.repeat_len,
        }
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
    var list_cmd_done = false;


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
                            try handleListCommandKey(
                                key,
                                &view,
                                &editor,
                                &list_cmd_active,
                                &list_cmd_new,
                                &list_cmd_done,
                                ctx,
                                allocator,
                                ui,
                            );
                        } else {
                            if (key.matches(':', .{})) {
                                // Start list-view ":" command-line
                                list_cmd_active = true;
                                list_cmd_new = false;
                                list_cmd_done = false;
                            } else if (!handleListFocusKey(key, ui, ctx.index)) {

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
                drawCounts(win, ctx.index, ui);
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


fn switchFocus(ui: *UiState, index: *const TaskIndex, target: ListKind) void {
    if (ui.focus == target) return;
    ui.focus = target;

    var view = ui.activeView();

    const len: usize = switch (target) {
        .todo => index.todoSlice().len,
        .done => index.doneSlice().len,
    };

    if (len == 0) {
        view.selected_index = 0;
        view.scroll_offset = 0;
        view.last_move = 0;
        return;
    }

    if (view.selected_index >= len) {
        view.selected_index = len - 1;
    }

    view.scroll_offset = 0;
    view.last_move = 0;
}

fn handleListFocusKey(
    key: vaxis.Key,
    ui: *UiState,
    index: *const TaskIndex,
) bool {
    // Tab toggles between TODO and DONE.
    if (key.matches('\t', .{})) {
        const next_focus: ListKind = if (ui.focus == .todo) .done else .todo;
        switchFocus(ui, index, next_focus);
        return true;
    }

    // 'H' forces TODO, 'L' forces DONE.
    if (key.matches('H', .{})) {
        switchFocus(ui, index, .todo);
        return true;
    }
    if (key.matches('L', .{})) {
        switchFocus(ui, index, .done);
        return true;
    }

    return false;
}


fn handleNavigation(vx: *vaxis.Vaxis, index: *const TaskIndex, ui: *UiState, key: vaxis.Key) void {
    const win = vx.window();
    const term_height: usize = @intCast(win.height);
    if (term_height <= LIST_START_ROW) return;

    const viewport_height = term_height - LIST_START_ROW;

    const active_len: usize = switch (ui.focus) {
        .todo => index.todoSlice().len,
        .done => index.doneSlice().len,
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
    const todo_len = index.todoSlice().len;
    const done_len = index.doneSlice().len;
    // Format into the static buffer.
    const text = std.fmt.bufPrint(
        &counts_buf,
        "TODO {d}  DONE {d}",
        .{ todo_len, done_len },
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

fn drawListCommandLine(win: vaxis.Window, active: bool, new_flag: bool, done_flag: bool) void {
    if (!active or win.height == 0) return;

    const row: u16 = win.height - 1;
    const style: vaxis.Style = .{};

    const colon = ":"[0..1];
    _ = win.writeCell(0, row, .{
        .char = .{ .grapheme = colon, .width = 1 },
        .style = style,
    });

    if (win.width > 1) {
        const ch = if (new_flag)
            "n"
        else if (done_flag)
            "d"
        else
            " ";

        const ch_slice = ch[0..1];
        _ = win.writeCell(1, row, .{
            .char = .{ .grapheme = ch_slice, .width = 1 },
            .style = style,
        });
    }
}


fn drawRect(
    win: vaxis.Window,
    left: u16,
    top: u16,
    right_incl: u16,
    bottom_incl: u16,
    style: vaxis.Style,
) void {
    if (left >= win.width or top >= win.height) return;

    var right = right_incl;
    var bottom = bottom_incl;
    if (right >= win.width) right = win.width - 1;
    if (bottom >= win.height) bottom = win.height - 1;
    if (right <= left or bottom <= top) return;

    const tl = "┌";
    const tr = "┐";
    const bl = "└";
    const br = "┘";
    const horiz = "─";
    const vert = "│";

    _ = win.writeCell(left, top, .{
        .char = .{ .grapheme = tl, .width = 1 },
        .style = style,
    });
    _ = win.writeCell(right, top, .{
        .char = .{ .grapheme = tr, .width = 1 },
        .style = style,
    });
    _ = win.writeCell(left, bottom, .{
        .char = .{ .grapheme = bl, .width = 1 },
        .style = style,
    });
    _ = win.writeCell(right, bottom, .{
        .char = .{ .grapheme = br, .width = 1 },
        .style = style,
    });

    var x: u16 = left + 1;
    while (x < right) : (x += 1) {
        _ = win.writeCell(x, top, .{
            .char = .{ .grapheme = horiz, .width = 1 },
            .style = style,
        });
        _ = win.writeCell(x, bottom, .{
            .char = .{ .grapheme = horiz, .width = 1 },
            .style = style,
        });
    }

    var y: u16 = top + 1;
    while (y < bottom) : (y += 1) {
        _ = win.writeCell(left, y, .{
            .char = .{ .grapheme = vert, .width = 1 },
            .style = style,
        });
        _ = win.writeCell(right, y, .{
            .char = .{ .grapheme = vert, .width = 1 },
            .style = style,
        });
    }
}



fn drawLabelContainer(
    win: vaxis.Window,
    left: u16,
    top: u16,
    right_incl: u16,
    bottom_incl: u16,
    style: vaxis.Style,
) void {
    if (left >= win.width or top >= win.height) return;

    var right = right_incl;
    var bottom = bottom_incl;
    if (right >= win.width) right = win.width - 1;
    if (bottom >= win.height) bottom = win.height - 1;
    if (right <= left or bottom <= top) return;

    const tl = "┌";
    const tr = "┬";
    const bl = "└";
    const br = "┴";
    const horiz = "─";
    const vert = "│";

    _ = win.writeCell(left, top, .{
        .char = .{ .grapheme = tl, .width = 1 },
        .style = style,
    });
    _ = win.writeCell(right, top, .{
        .char = .{ .grapheme = tr, .width = 1 },
        .style = style,
    });
    _ = win.writeCell(left, bottom, .{
        .char = .{ .grapheme = bl, .width = 1 },
        .style = style,
    });
    _ = win.writeCell(right, bottom, .{
        .char = .{ .grapheme = br, .width = 1 },
        .style = style,
    });

    var x: u16 = left + 1;
    while (x < right) : (x += 1) {
        _ = win.writeCell(x, top, .{
            .char = .{ .grapheme = horiz, .width = 1 },
            .style = style,
        });
        _ = win.writeCell(x, bottom, .{
            .char = .{ .grapheme = horiz, .width = 1 },
            .style = style,
        });
    }

    var y: u16 = top + 1;
    while (y < bottom) : (y += 1) {
        _ = win.writeCell(left, y, .{
            .char = .{ .grapheme = vert, .width = 1 },
            .style = style,
        });
        _ = win.writeCell(right, y, .{
            .char = .{ .grapheme = vert, .width = 1 },
            .style = style,
        });
    }
}


fn drawMetaFieldBox(
    win: vaxis.Window,
    top: u16,
    label_col: u16,
    box_left: u16,
    label: []const u8,
    value: []const u8,
    focused: bool,
    show_cursor: bool,
) void {
    if (top + 2 >= win.height) return;

    const base_style: vaxis.Style = .{};
    const focus_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 220, 220, 255 } },
    };
    const style = if (focused) focus_style else base_style;

    const mid_row: u16 = top + 1;

    // Draw label text at fixed column, but never past the join column.
    var col: u16 = label_col;
    var i: usize = 0;
    while (i < label.len and col < win.width and col < box_left) : (i += 1) {
        const g = label[i .. i + 1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        });
        col += 1;
    }

    if (col < win.width and col < box_left) {
        const colon = ":"[0..1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = colon, .width = 1 },
            .style = style,
        });
        col += 1;
    }
    if (col < win.width and col < box_left) {
        const space = " "[0..1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = space, .width = 1 },
            .style = style,
        });
        col += 1;
    }

    // Value box sizing, same logic as before.
    if (box_left + 3 >= win.width) return;

    const min_inner: usize = 8;

    var inner_w: usize = value.len;
    if (show_cursor) inner_w += 1;
    if (inner_w < min_inner) inner_w = min_inner;

    const available: usize = @intCast(win.width - box_left);
    if (available <= 3) return;

    const max_inner: usize = available - 2;
    if (inner_w > max_inner) inner_w = max_inner;

    const total_w: u16 = @intCast(inner_w + 2);
    const box_right: u16 = box_left + total_w - 1;
    if (box_right >= win.width) return;

    const box_bottom: u16 = top + 2;

    // First draw the value box with plain corners.
    drawRect(win, box_left, top, box_right, box_bottom, style);

    // Then draw the label container so its right corner overwrites
    // the value box's top-left / bottom-left with ┬ and ┴.
    const label_box_left: u16 = if (label_col > 0) label_col - 1 else 0;
    if (label_box_left + 2 <= box_left and label_box_left < win.width) {
        drawLabelContainer(win, label_box_left, top, box_left, box_bottom, style);
    }

    // Finally, put the value text (and cursor) inside the value box.
    var val_col: u16 = box_left + 1;
    const val_row: u16 = mid_row;

    i = 0;
    while (i < value.len and val_col < box_right) : (i += 1) {
        const g = value[i .. i + 1];
        _ = win.writeCell(val_col, val_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        });
        val_col += 1;
    }

    if (show_cursor and val_col < box_right) {
        const cursor = "_"[0..1];
        _ = win.writeCell(val_col, val_row, .{
            .char = .{ .grapheme = cursor, .width = 1 },
            .style = style,
        });
    }
}


fn drawEditorMeta(
    win: vaxis.Window,
    first_top: u16,
    editor: *const EditorState,
) void {
    const term_height: u16 = win.height;
    if (first_top >= term_height) return;

    const label_col: u16 = 2;

    const l_prio = "prio";
    const l_due = "due";
    const l_repeat = "repeat";

    var max_label_len: u16 = @intCast(l_prio.len);
    const due_len: u16 = @intCast(l_due.len);
    if (due_len > max_label_len) max_label_len = due_len;
    const rep_len: u16 = @intCast(l_repeat.len);
    if (rep_len > max_label_len) max_label_len = rep_len;

    // label_col + max_label + ":" + space
    const box_left: u16 = label_col + max_label_len + 2;
    if (box_left + 3 >= win.width) return;

    var top: u16 = first_top;

    // priority
    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_col,
            box_left,
            l_prio,
            editor.prioSlice(),
            editor.focus == .priority,
            editor.focus == .priority and editor.mode == .insert,
        );
    }
    top += 3;
    if (top >= term_height) return;

    // due
    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_col,
            box_left,
            l_due,
            editor.dueSlice(),
            editor.focus == .due,
            editor.focus == .due and editor.mode == .insert,
        );
    }
    top += 3;
    if (top >= term_height) return;

    // repeat
    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_col,
            box_left,
            l_repeat,
            editor.repeatSlice(),
            editor.focus == .repeat,
            editor.focus == .repeat and editor.mode == .insert,
        );
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

    // "Task:" label and main text as before
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

    const text_row: u16 = if (term_height > 4) 4 else label_row + 1;
    const text = editor.taskSlice();
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

    if (editor.focus == .task and editor.mode == .insert and text_col < win.width) {
        const cursor = "_"[0..1];
        _ = win.writeCell(text_col, text_row, .{
            .char = .{ .grapheme = cursor, .width = 1 },
            .style = text_style,
        });
    }

    if (term_height > text_row + 2 and win.width > 10) {
        const meta_top: u16 = text_row + 2;
        drawEditorMeta(win, meta_top, editor);
    }

    // hints at bottom row (only when not in ":" command mode)
    if (term_height > 6 and !editor.cmd_active) {
        const hint = "i: insert   :w save+quit   :q quit   :p/:d/:r/:t focus meta fields";
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
    list_cmd_done: *bool,
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    // Esc: cancel command-line
    if (key.matches(vaxis.Key.escape, .{})) {
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        return;
    }

    // Backspace: clear any single-letter command
    if (key.matches(vaxis.Key.backspace, .{})) {
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        return;
    }

    // Enter: execute the command
    if (key.matches(vaxis.Key.enter, .{})) {
        if (list_cmd_new.*) {
            // ":n" -> open editor for new TODO task
            editor.* = EditorState.init();
            view.* = .editor;
        } else if (list_cmd_done.*) {
            // ":d" -> mark current TODO task as DONE
            try markDone(ctx, allocator, ui);
        }
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        return;
    }

    // For now we only support single-letter ":n" and ":d"
    if (key.matches('n', .{})) {
        list_cmd_new.* = true;
        list_cmd_done.* = false;
        return;
    }
    if (key.matches('d', .{})) {
        list_cmd_done.* = true;
        list_cmd_new.* = false;
        return;
    }
}


fn markDone(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    const todos = ctx.index.todoSlice();
    if (todos.len == 0) return;

    var todo_view = &ui.todo;
    if (todo_view.selected_index >= todos.len) return;

    const remove_index = todo_view.selected_index;
    const original = todos[remove_index];

    // Copy the task but mark it as done.
    var moved = original;
    moved.status = .done;

    // Append to done file.
    var done_file = ctx.done_file.*;
    try store.appendJsonTaskLine(allocator, &done_file, moved);

    // Rewrite todo file without that index (unchanged from your current code).
    var todo_file = ctx.todo_file.*;
    try store.rewriteJsonFileWithoutIndex(allocator, &todo_file, todos, remove_index);

    try ctx.index.reload(allocator, todo_file, done_file);

    ui.focus = .todo;
    const new_len = ctx.index.todoSlice().len;
    if (new_len == 0) {
        todo_view.selected_index = 0;
        todo_view.scroll_offset = 0;
    } else if (remove_index >= new_len) {
        todo_view.selected_index = new_len - 1;
    } else {
        todo_view.selected_index = remove_index;
    }
    todo_view.last_move = -1;
}


fn saveNewTask(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !void {
    const text = editor.taskSlice();
    if (text.len == 0) return; // ignore empty tasks

    const due = editor.dueSlice();
    const repeat = editor.repeatSlice();
    const prio_val: u8 = editor.priorityValue();

    // Compute next id cheaply: scan existing todo/done once and keep max.
    var max_id: u64 = 0;
    for (ctx.index.todoSlice()) |t| {
        if (t.id > max_id) max_id = t.id;
    }
    for (ctx.index.doneSlice()) |t| {
        if (t.id > max_id) max_id = t.id;
    }

    const new_id: u64 = max_id + 1;
    const now_ms: i64 = std.time.milliTimestamp();

    const new_task: store.Task = .{
        .id = new_id,
        .text = text,
        .proj_first = 0,
        .proj_count = 0,
        .ctx_first = 0,
        .ctx_count = 0,
        .priority = prio_val,
        .status = .todo,
        .due = due,
        .repeat = repeat,
        .created_ms = now_ms,
    };

    var file = ctx.todo_file.*; // copy; same OS handle
    try store.appendJsonTaskLine(allocator, &file, new_task);

    try ctx.index.reload(allocator, file, ctx.done_file.*);

    if (ctx.index.todoSlice().len != 0) {
        ui.focus = .todo;
        var todo_view = &ui.todo;
        todo_view.selected_index = ctx.index.todoSlice().len - 1;
        todo_view.last_move = 1;
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

            // :t / :p / :d / :r -> change focus and go to insert mode
            if (std.mem.eql(u8, cmd, "t")) {
                editor.resetCommand();
                editor.focus = .task;
                editor.mode = .insert;
                return;
            }
            if (std.mem.eql(u8, cmd, "p")) {
                editor.resetCommand();
                editor.focus = .priority;
                editor.mode = .insert;
                return;
            }
            if (std.mem.eql(u8, cmd, "d")) {
                editor.resetCommand();
                editor.focus = .due;
                editor.mode = .insert;
                return;
            }
            if (std.mem.eql(u8, cmd, "r")) {
                editor.resetCommand();
                editor.focus = .repeat;
                editor.mode = .insert;
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
            if (key.matches('i', .{})) {
                editor.mode = .insert;
                return;
            }

            if (key.matches('a', .{})) {
                switch (editor.focus) {
                    .task => editor.moveToEnd(),
                    .priority => editor.prio_cursor = editor.prio_len,
                    .due => editor.due_cursor = editor.due_len,
                    .repeat => editor.repeat_cursor = editor.repeat_len,
                }
                editor.mode = .insert;
                return;
            }

            // Vim motions only make sense on the main text for now.
            if (editor.focus == .task) {
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
            }
        },
        .insert => {
            // Backspace deletes in the focused field
            if (key.matches(vaxis.Key.backspace, .{})) {
                switch (editor.focus) {
                    .task => editor.deleteBeforeCursor(),
                    .priority => deleteBeforeInBuffer(
                        editor.prio_buf[0..],
                        &editor.prio_len,
                        &editor.prio_cursor,
                    ),
                    .due => deleteBeforeInBuffer(
                        editor.due_buf[0..],
                        &editor.due_len,
                        &editor.due_cursor,
                    ),
                    .repeat => deleteBeforeInBuffer(
                        editor.repeat_buf[0..],
                        &editor.repeat_len,
                        &editor.repeat_cursor,
                    ),
                }
                return;
            }

            // Enter: leave insert, stay in editor
            if (key.matches(vaxis.Key.enter, .{})) {
                editor.mode = .normal;
                return;
            }

            // Printable ASCII routes to the focused buffer
            if (keyToAscii(key)) |ch| {
                switch (editor.focus) {
                    .task => editor.insertChar(ch),
                    .priority => insertIntoBuffer(
                        editor.prio_buf[0..],
                        &editor.prio_len,
                        &editor.prio_cursor,
                        ch,
                    ),
                    .due => insertIntoBuffer(
                        editor.due_buf[0..],
                        &editor.due_len,
                        &editor.due_cursor,
                        ch,
                    ),
                    .repeat => insertIntoBuffer(
                        editor.repeat_buf[0..],
                        &editor.repeat_len,
                        &editor.repeat_cursor,
                        ch,
                    ),
                }
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
    view: *const ListView,
    tasks: []const Task,
    viewport_height: usize,
    content_width: usize,
) bool {
    if (tasks.len == 0 or viewport_height == 0 or content_width == 0) return true;
    if (view.selected_index >= tasks.len) return false;
    if (view.scroll_offset >= tasks.len) return false;

    var rows_used: usize = 0;
    var idx = view.scroll_offset;

    while (idx < tasks.len and rows_used < viewport_height) : (idx += 1) {
        var rows = measureWrappedRows(tasks[idx].text, content_width);
        if (rows == 0) rows = 1;

        if (rows_used + rows > viewport_height) {
            // This task would be partially clipped.
            if (idx == view.selected_index) return false;
            break;
        }

        if (idx == view.selected_index) {
            // Selected task fits entirely within [rows_used .. rows_used+rows).
            return true;
        }

        rows_used += rows;
    }

    return false;
}


fn recomputeScrollOffsetForSelection(
    view: *ListView,
    tasks: []const Task,
    viewport_height: usize,
    content_width: usize,
    dir: i8,
) void {
    if (tasks.len == 0 or viewport_height == 0 or content_width == 0) {
        view.scroll_offset = 0;
        view.selected_index = 0;
        return;
    }

    if (view.selected_index >= tasks.len) {
        view.selected_index = tasks.len - 1;
    }

    const sel = view.selected_index;

    var rows_sel = measureWrappedRows(tasks[sel].text, content_width);
    if (rows_sel == 0) rows_sel = 1;

    if (rows_sel > viewport_height) {
        // Pathological: one task taller than the viewport; anchor on it.
        view.scroll_offset = sel;
        return;
    }

    // Moving up: make the selected task the first in the viewport.
    if (dir < 0) {
        view.scroll_offset = sel;
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

    view.scroll_offset = start_idx;
}


/// Render the currently focused list with vim-style navigation.
/// Selected row is bold and prefixed with "> ".
fn drawTodoList(
    win: vaxis.Window,
    index: *const TaskIndex,
    ui: *UiState,
    cmd_active: bool,
) void {
    const tasks: []const Task = switch (ui.focus) {
        .todo => index.todoSlice(),
        .done => index.doneSlice(),
    };
    var view = ui.activeView();

    if (tasks.len == 0) {
        view.selected_index = 0;
        view.scroll_offset = 0;
        return;
    }

    const term_height: usize = @intCast(win.height);
    const term_width: usize = @intCast(win.width);
    if (term_height <= LIST_START_ROW) return;

    const reserved_rows: usize = if (cmd_active and term_height > LIST_START_ROW + 1) 1 else 0;
    if (term_height <= LIST_START_ROW + reserved_rows) return;

    const viewport_height = term_height - LIST_START_ROW - reserved_rows;
    if (viewport_height == 0) return;

    if (view.selected_index >= tasks.len) {
        view.selected_index = tasks.len - 1;
    }

    // Content starts at column 2: "> " then text.
    if (term_width <= 2) return;
    const content_width: usize = term_width - 2;

    const dir = view.last_move;

    // Only adjust scroll_offset if the selected task is not fully visible
    // with the current offset. This avoids jitter when moving inside the
    // existing viewport.
    if (!isSelectionFullyVisible(view, tasks, viewport_height, content_width)) {
        recomputeScrollOffsetForSelection(view, tasks, viewport_height, content_width, dir);
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

    var idx = view.scroll_offset;
    while (idx < tasks.len and remaining_rows > 0 and row < term_height) : (idx += 1) {
        const task = tasks[idx];
        const text = task.text;

        const selected = (view.selected_index == idx);
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
            row,
            2,
            rows_needed,
            content_width,
            text,
            style,
        );

        row += rows_needed;
        remaining_rows -= rows_needed;
    }
}
