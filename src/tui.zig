const std = @import("std");
const vaxis = @import("vaxis");
const store = @import("task_store.zig");

const dt = @import("due_datetime.zig");

const Cell = vaxis.Cell;

const fs = std.fs;

var counts_buf: [64]u8 = undefined;

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const Task = task_mod.Task;


const ProjectEntry = task_mod.ProjectEntry;



const ui_mod = @import("ui_state.zig");
const UiState = ui_mod.UiState;
const ListKind = ui_mod.ListKind;

const ListView = ui_mod.ListView;

const LIST_START_ROW: usize = 4;
const STATUS_WIDTH: usize = 4;
const META_SUFFIX_BUF_LEN: usize = 48;

const PROJECT_PANEL_MIN_TERM_WIDTH: usize = 40;
const PROJECT_PANEL_MIN_LIST_WIDTH: usize = 20;
const PROJECT_PANEL_MIN_WIDTH: usize = 16;
const PROJECT_PANEL_MAX_WIDTH: usize = 32;

const PROJECT_PANE_MAX_WIDTH: usize = 24;
const PROJECT_PANE_MIN_WIDTH: usize = 14;

// Sidebar UI state; kept local to tui so UiState does not grow yet.
var g_projects_focus: bool = false;

// 0 means "all"
var g_projects_selected_todo: usize = 0;
var g_projects_selected_done: usize = 0;

// visible task indices (into the underlying todo/done slices)
var g_visible_todo = std.ArrayListUnmanaged(usize){};
var g_visible_done = std.ArrayListUnmanaged(usize){};

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


const ascii_graphemes = blk: {
    var table: [256][1]u8 = undefined;
    var i: usize = 0;
    while (i < table.len) : (i += 1) {
        table[i][0] = @intCast(i);
    }
    break :blk table;
};

inline fn graphemeFromByte(b: u8) []const u8 {
    return ascii_graphemes[b][0..1];
}

fn projectsForFocus(index: *const TaskIndex, focus: ListKind) []const ProjectEntry {
    return switch (focus) {
        .todo => index.projectsTodoSlice(),
        .done => index.projectsDoneSlice(),
    };
}

fn selectedProjectPtr(focus: ListKind) *usize {
    return switch (focus) {
        .todo => &g_projects_selected_todo,
        .done => &g_projects_selected_done,
    };
}

fn selectedProjectName(index: *const TaskIndex, focus: ListKind) []const u8 {
    const projects = projectsForFocus(index, focus);
    if (projects.len == 0) return &[_]u8{};

    const sel = selectedProjectPtr(focus);
    if (sel.* >= projects.len) sel.* = projects.len - 1;

    // entry 0 is "all" -> no filter
    if (sel.* == 0) return &[_]u8{};
    return projects[sel.*].name;
}

// Uses spans precomputed in loadFile; no rescanning strings every frame.
fn taskHasProject(img: *const store.FileImage, task: store.Task, project: []const u8) bool {
    if (project.len == 0) return true;

    const first: usize = @intCast(task.proj_first);
    const count: usize = @intCast(task.proj_count);
    if (count == 0) return false;
    if (first + count > img.spans.len) return false;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const sp = img.spans[first + i];
        const start: usize = @intCast(sp.start);
        const len: usize = @intCast(sp.len);
        if (start + len > img.buf.len) continue;

        const name = img.buf[start .. start + len];
        if (std.mem.eql(u8, name, project)) return true;
    }

    return false;
}

fn rebuildVisibleFor(
    allocator: std.mem.Allocator,
    index: *const TaskIndex,
    focus: ListKind,
) !void {
    const project = selectedProjectName(index, focus);

    switch (focus) {
        .todo => {
            g_visible_todo.clearRetainingCapacity();
            const img = &index.todo_img;
            try g_visible_todo.ensureTotalCapacity(allocator, img.tasks.len);

            for (img.tasks, 0..) |t, ti| {
                if (taskHasProject(img, t, project)) {
                    try g_visible_todo.append(allocator, ti);
                }
            }
        },
        .done => {
            g_visible_done.clearRetainingCapacity();
            const img = &index.done_img;
            try g_visible_done.ensureTotalCapacity(allocator, img.tasks.len);

            for (img.tasks, 0..) |t, ti| {
                if (taskHasProject(img, t, project)) {
                    try g_visible_done.append(allocator, ti);
                }
            }
        },
    }
}

fn rebuildVisibleAll(allocator: std.mem.Allocator, index: *const TaskIndex) !void {
    try rebuildVisibleFor(allocator, index, .todo);
    try rebuildVisibleFor(allocator, index, .done);
}

fn visibleLenForFocus(focus: ListKind) usize {
    return switch (focus) {
        .todo => g_visible_todo.items.len,
        .done => g_visible_done.items.len,
    };
}

fn visibleIndicesForFocus(focus: ListKind) []const usize {
    return switch (focus) {
        .todo => g_visible_todo.items,
        .done => g_visible_done.items,
    };
}


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


fn moveCursorImpl(cur: *usize, len: usize, delta: i32) void {
    const cur_i: i32 = @intCast(cur.*);
    var next = cur_i + delta;

    if (next < 0) next = 0;
    const max: i32 = @intCast(len);
    if (next > max) next = max;

    cur.* = @intCast(next);
}


fn asciiLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn eqLower(s: []const u8, lit: []const u8) bool {
    if (s.len != lit.len) return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (asciiLower(s[i]) != lit[i]) return false;
    }
    return true;
}

fn parseRepeatUnit(unit_raw: []const u8) ?u8 {
    if (unit_raw.len == 0) return null;

    // single-letter short forms
    if (unit_raw.len == 1) {
        const c = asciiLower(unit_raw[0]);
        return switch (c) {
            'm' => 'm',
            'h' => 'h',
            'd' => 'd',
            'w' => 'w',
            'y' => 'y',
            else => null,
        };
    }

    // full words, case-insensitive
    if (eqLower(unit_raw, "minute") or eqLower(unit_raw, "minutes")) return 'm';
    if (eqLower(unit_raw, "hour")   or eqLower(unit_raw, "hours"))   return 'h';
    if (eqLower(unit_raw, "day")    or eqLower(unit_raw, "days"))    return 'd';
    if (eqLower(unit_raw, "week")   or eqLower(unit_raw, "weeks"))   return 'w';
    if (eqLower(unit_raw, "year")   or eqLower(unit_raw, "years"))   return 'y';

    return null;
}

/// Parse a user repeat string into canonical "<N><u>" (e.g. "2d").
/// Returns null on invalid input.
fn parseRepeatCanonical(input: []const u8, buf: *[16]u8) ?[]const u8 {
    // Trim leading/trailing ASCII space/tab.
    var start: usize = 0;
    var end: usize = input.len;

    while (start < end and isSpaceByte(input[start])) {
        start += 1;
    }
    while (end > start and isSpaceByte(input[end - 1])) {
        end -= 1;
    }

    if (start == end) return null;
    const s = input[start..end];

    // Parse integer prefix.
    var i: usize = 0;
    var value: u32 = 0;
    var digits: usize = 0;

    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b < '0' or b > '9') break;
        digits += 1;
        // Guard against absurdly long numbers.
        if (digits > 9) return null;
        value = value * 10 + @as(u32, b - '0');
    }

    if (digits == 0) return null;
    if (value == 0) return null;

    // Skip spaces between number and unit.
    while (i < s.len and isSpaceByte(s[i])) : (i += 1) {}

    if (i >= s.len) return null;

    // Unit token until next space.
    const unit_start = i;
    while (i < s.len and !isSpaceByte(s[i])) : (i += 1) {}
    const unit_slice = s[unit_start..i];

    // Only spaces allowed after the unit.
    while (i < s.len and isSpaceByte(s[i])) : (i += 1) {}
    if (i != s.len) return null;

    const unit_char = parseRepeatUnit(unit_slice) orelse return null;

    // Write "<digits><unit_char>" into buf.
    var tmp_digits: [10]u8 = undefined;
    var n = value;
    var rev_len: usize = 0;

    while (true) {
        const d: u8 = @intCast(n % 10);
        tmp_digits[rev_len] = '0' + d;
        rev_len += 1;
        n /= 10;
        if (n == 0) break;
        if (rev_len == tmp_digits.len) return null;
    }

    var pos: usize = 0;
    while (rev_len > 0) {
        rev_len -= 1;
        buf[pos] = tmp_digits[rev_len];
        pos += 1;
    }

    buf[pos] = unit_char;
    pos += 1;

    return buf[0..pos];
}

/// Canonical repeat string from the editor.
/// Empty slice means "no valid repeat".
fn canonicalRepeatFromEditor(
    editor: *const EditorState,
    buf: *[16]u8,
) []const u8 {
    const raw = editor.repeatSlice();
    if (parseRepeatCanonical(raw, buf)) |canon| {
        return canon;
    }
    return &[_]u8{};
}

fn canonicalDueFromEditor(
    editor: *const EditorState,
    date_buf: *[10]u8,
    time_buf: *[5]u8,
) struct {
    date: []const u8,
    time: []const u8,
} {
    const raw_date = editor.dueSlice();
    const raw_time = editor.timeSlice();

    var date_slice: []const u8 = &[_]u8{};
    var time_slice: []const u8 = &[_]u8{};

    if (dt.parseUserDueDateCanonical(raw_date, date_buf)) {
        date_slice = date_buf[0..];

        // Only consider time when date is valid
        if (dt.parseUserDueTimeCanonical(raw_time, time_buf)) {
            time_slice = time_buf[0..];
        }
    }

    return .{
        .date = date_slice,
        .time = time_slice,
    };
}

const EditorState = struct {
    pub const Mode = enum {
        normal,
        insert,
    };

    pub const Field = enum {
        task,
        priority,
        due_date,
        due_time,
        repeat,
    };

    mode: Mode = .insert,
    focus: Field = .task,

    // new task vs editing existing task
    is_new: bool = true,
    editing_status: store.Status = .todo,
    editing_index: usize = 0,

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


    // due time string, e.g. "23:59" or "11:59pm" as typed
    time_buf: [32]u8 = undefined,
    time_len: usize = 0,
    time_cursor: usize = 0,

    // repeat rule string
    repeat_buf: [64]u8 = undefined,
    repeat_len: usize = 0,
    repeat_cursor: usize = 0,

    // ":" command-line inside the editor
    cmd_active: bool = false,
    cmd_buf: [32]u8 = undefined,
    cmd_len: usize = 0,

    pub fn initNew() EditorState {
        return .{
            .mode = .insert,
            .focus = .task,

            .is_new = true,
            .editing_status = store.Status.todo,
            .editing_index = 0,

            .buf = undefined,
            .len = 0,
            .cursor = 0,

            .prio_buf = undefined,
            .prio_len = 0,
            .prio_cursor = 0,

            .due_buf = undefined,
            .due_len = 0,
            .due_cursor = 0,

            .time_buf = undefined,
            .time_len = 0,
            .time_cursor = 0,

            .repeat_buf = undefined,
            .repeat_len = 0,
            .repeat_cursor = 0,

            .cmd_active = false,
            .cmd_buf = undefined,
            .cmd_len = 0,
        };
    }

    // keep the old name for callers that still use .init()
    pub fn init() EditorState {
        return EditorState.initNew();
    }

    /// Build an editor pre-filled from an existing task.
    pub fn fromTask(task: store.Task) EditorState {
        var self = EditorState.initNew();
        self.is_new = false;
        self.editing_status = task.status;

        // text
        const text_len = @min(task.text.len, self.buf.len);
        if (text_len != 0) {
            @memcpy(self.buf[0..text_len], task.text[0..text_len]);
        }
        self.len = text_len;
        self.cursor = text_len;

        // priority -> ascii
        if (task.priority != 0) {
            var tmp: [3]u8 = undefined;
            var n: u16 = task.priority;
            var digits: usize = 0;

            while (n != 0 and digits < tmp.len) : (n /= 10) {
                const d: u8 = @intCast(n % 10);
                tmp[digits] = '0' + d;
                digits += 1;
            }

            var j: usize = 0;
            while (j < digits) : (j += 1) {
                self.prio_buf[j] = tmp[digits - 1 - j];
            }
            self.prio_len = digits;
            self.prio_cursor = digits;
        }

        // due_date
        const date_len = @min(task.due_date.len, self.due_buf.len);
        if (date_len != 0) {
            @memcpy(self.due_buf[0..date_len], task.due_date[0..date_len]);
            self.due_len = date_len;
            self.due_cursor = date_len;
        }

        // due_time
        const time_len = @min(task.due_time.len, self.time_buf.len);
        if (time_len != 0) {
            @memcpy(self.time_buf[0..time_len], task.due_time[0..time_len]);
            self.time_len = time_len;
            self.time_cursor = time_len;
        }

        // repeat
        const rep_len = @min(task.repeat.len, self.repeat_buf.len);
        if (rep_len != 0) {
            @memcpy(self.repeat_buf[0..rep_len], task.repeat[0..rep_len]);
            self.repeat_len = rep_len;
            self.repeat_cursor = rep_len;
        }

        return self;
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

    pub fn timeSlice(self: *const EditorState) []const u8 {
        return self.time_buf[0..self.time_len];
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

    pub fn insertChar(self: *EditorState, ch: u8) void {
        switch (self.focus) {
            .task      => insertIntoBuffer(self.buf[0..],       &self.len,       &self.cursor,       ch),
            .priority  => insertIntoBuffer(self.prio_buf[0..],  &self.prio_len,  &self.prio_cursor,  ch),
            .due_date  => insertIntoBuffer(self.due_buf[0..],   &self.due_len,   &self.due_cursor,   ch),
            .due_time  => insertIntoBuffer(self.time_buf[0..],  &self.time_len,  &self.time_cursor,  ch),
            .repeat    => insertIntoBuffer(self.repeat_buf[0..],&self.repeat_len,&self.repeat_cursor,ch),
        }
    }

    pub fn deleteBeforeCursor(self: *EditorState) void {
        switch (self.focus) {
            .task      => deleteBeforeInBuffer(self.buf[0..],       &self.len,       &self.cursor),
            .priority  => deleteBeforeInBuffer(self.prio_buf[0..],  &self.prio_len,  &self.prio_cursor),
            .due_date  => deleteBeforeInBuffer(self.due_buf[0..],   &self.due_len,   &self.due_cursor),
            .due_time  => deleteBeforeInBuffer(self.time_buf[0..],  &self.time_len,  &self.time_cursor),
            .repeat    => deleteBeforeInBuffer(self.repeat_buf[0..],&self.repeat_len,&self.repeat_cursor),
        }
    }

    pub fn moveCursor(self: *EditorState, delta: i32) void {
        switch (self.focus) {
            .task      => moveCursorImpl(&self.cursor,       self.len,       delta),
            .priority  => moveCursorImpl(&self.prio_cursor,  self.prio_len,  delta),
            .due_date  => moveCursorImpl(&self.due_cursor,   self.due_len,   delta),
            .due_time  => moveCursorImpl(&self.time_cursor,  self.time_len,  delta),
            .repeat    => moveCursorImpl(&self.repeat_cursor,self.repeat_len,delta),
        }
    }

    pub fn moveToStart(self: *EditorState) void {
        switch (self.focus) {
            .task      => self.cursor       = 0,
            .priority  => self.prio_cursor  = 0,
            .due_date  => self.due_cursor   = 0,
            .due_time  => self.time_cursor  = 0,
            .repeat    => self.repeat_cursor= 0,
        }
    }

    pub fn moveToEnd(self: *EditorState) void {
        switch (self.focus) {
            .task      => self.cursor       = self.len,
            .priority  => self.prio_cursor  = self.prio_len,
            .due_date  => self.due_cursor   = self.due_len,
            .due_time  => self.time_cursor  = self.time_len,
            .repeat    => self.repeat_cursor= self.repeat_len,
        }
    }

    pub fn setFocus(self: *EditorState, field: Field) void {
        self.focus = field;
        switch (field) {
            .task => {
                if (self.cursor > self.len) self.cursor = self.len;
            },
            .priority => {
                if (self.prio_cursor > self.prio_len) self.prio_cursor = self.prio_len;
            },
            .due_date => {
                if (self.due_cursor > self.due_len) self.due_cursor = self.due_len;
            },
            .due_time => {
                if (self.time_cursor > self.time_len) self.time_cursor = self.time_len;
            },
            .repeat => {
                if (self.repeat_cursor > self.repeat_len) self.repeat_cursor = self.repeat_len;
            },
        }
    }

    pub fn focusNext(self: *EditorState) void {
        const next: Field = switch (self.focus) {
            .task      => .priority,
            .priority  => .due_date,
            .due_date  => .due_time,
            .due_time  => .repeat,
            .repeat    => .task,
        };
        self.setFocus(next);
    }

    pub fn focusPrev(self: *EditorState) void {
        const prev: Field = switch (self.focus) {
            .task      => .repeat,
            .priority  => .task,
            .due_date  => .priority,
            .due_time  => .due_date,
            .repeat    => .due_time,
        };
        self.setFocus(prev);
    }
};


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


    defer g_visible_todo.deinit(allocator);
    defer g_visible_done.deinit(allocator);

    var view: AppView = .list;
    var editor = EditorState.init();

    var list_cmd_active = false;
    var list_cmd_new = false;
    var list_cmd_done = false;
    var list_cmd_edit = false;


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

    try processRepeats(ctx, allocator);

    try rebuildVisibleAll(allocator, ctx.index);

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
                                &list_cmd_edit,
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
                            } else if (!(try handleListFocusKey(key, ui, ctx.index, allocator))) {

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

        try processRepeats(ctx, allocator);

        const win = vx.window();
        clearAll(win);

        switch (view) {
            .list => {
                drawHeader(win);
                drawCounts(win, ctx.index, ui);
                drawProjectsPane(win, ctx.index, ui.focus);
                drawTodoList(win, ctx.index, ui, list_cmd_active);
                drawListCommandLine(win, list_cmd_active, list_cmd_new, list_cmd_done, list_cmd_edit);
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
    allocator: std.mem.Allocator,
) !bool {
    const projects = projectsForFocus(index, ui.focus);
    const proj_len = projects.len;

    // 'p' toggles focus on the projects sidebar when there is at least one project.
    if (key.matches('p', .{})) {
        if (proj_len != 0) {
            g_projects_focus = !g_projects_focus;

            const sel = selectedProjectPtr(ui.focus);
            if (sel.* >= proj_len) sel.* = proj_len - 1;
        }
        return true;
    }

    // When the sidebar has focus, j/k and arrows move inside it.
    if (g_projects_focus and proj_len != 0) {
        const sel = selectedProjectPtr(ui.focus);

        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (sel.* + 1 < proj_len) {
                sel.* += 1;
                try rebuildVisibleFor(allocator, index, ui.focus);

                var view = ui.activeView();
                const vlen = visibleLenForFocus(ui.focus);
                if (vlen == 0) {
                    view.selected_index = 0;
                    view.scroll_offset = 0;
                    view.last_move = 0;
                } else if (view.selected_index >= vlen) {
                    view.selected_index = vlen - 1;
                }
            }
            return true;
        }

        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (sel.* > 0) {
                sel.* -= 1;
                try rebuildVisibleFor(allocator, index, ui.focus);

                var view = ui.activeView();
                const vlen = visibleLenForFocus(ui.focus);
                if (vlen == 0) {
                    view.selected_index = 0;
                    view.scroll_offset = 0;
                    view.last_move = 0;
                } else if (view.selected_index >= vlen) {
                    view.selected_index = vlen - 1;
                }
            }
            return true;
        }
        // fall through for Tab/H/L
    }

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


fn handleNavigation(vx: *vaxis.Vaxis, _: *const TaskIndex, ui: *UiState, key: vaxis.Key) void {
    const win = vx.window();
    const term_height: usize = @intCast(win.height);
    if (term_height <= LIST_START_ROW) return;

    const viewport_height = term_height - LIST_START_ROW;

    const active_len: usize = visibleLenForFocus(ui.focus);

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


fn drawListCommandLine(
    win: vaxis.Window,
    active: bool,
    new_flag: bool,
    done_flag: bool,
    edit_flag: bool,
) void {
    if (!active or win.height == 0) return;

    const row: u16 = win.height - 1;
    const style: vaxis.Style = .{};

    const colon = ":"[0..1];
    _ = win.writeCell(0, row, .{
        .char = .{ .grapheme = colon, .width = 1 },
        .style = style,
    });

    if (win.width > 1) {
        const ch: u8 = if (new_flag)
            'n'
        else if (done_flag)
            'd'
        else if (edit_flag)
            'e'
        else
            ' ';

        const slice = graphemeFromByte(ch);

        _ = win.writeCell(1, row, .{
            .char = .{ .grapheme = slice, .width = 1 },
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

/// A logical view of the rendered task line:
///     "<task.text>[ optional space ]d:[YYYY-MM-DD[ HH:MM]]"
///
/// All segments point either into the task's own buffers or into
/// string literals. No stack-backed storage is exposed to vaxis.
const TaskLine = struct {
    segs: [7][]const u8,
    seg_count: usize,
    total_len: usize,
};

fn appendTaskSeg(line: *TaskLine, seg: []const u8) void {
    if (seg.len == 0) return;
    if (line.seg_count >= line.segs.len) return; // guard, should not happen
    line.segs[line.seg_count] = seg;
    line.seg_count += 1;
    line.total_len += seg.len;
}


fn repeatIntervalMsCanonical(canon: []const u8) ?i64 {
    if (canon.len < 2) return null;

    const unit = canon[canon.len - 1];
    const unit_ms: i64 = switch (unit) {
        'm' => 60 * 1000,
        'h' => 60 * 60 * 1000,
        'd' => 24 * 60 * 60 * 1000,
        'w' => 7 * 24 * 60 * 60 * 1000,
        'y' => 365 * 24 * 60 * 60 * 1000,
        else => return null,
    };

    var v: i64 = 0;
    var i: usize = 0;
    while (i + 1 < canon.len) : (i += 1) {
        const b = canon[i];
        if (b < '0' or b > '9') return null;

        const digit: i64 = @intCast(b - '0');
        const max = std.math.maxInt(i64);
        if (max <= 0) return null; 

        const limit: i64 = @divTrunc(max - digit, @as(i64, 10));
        if (v > limit) return null;

        v = v * 10 + digit;
    }

    if (v <= 0) return null;

    const max = std.math.maxInt(i64);
    if (unit_ms <= 0) return null;

    const limit: i64 = @divTrunc(max, unit_ms);
    if (v > limit) return null;

    return v * unit_ms;
}

/// Given canonical "<N><unit>" and a base time, compute the next epoch.
/// Returns 0 on any invalid/overflow situation (meaning: disable timer).
fn computeRepeatNextMs(canon: []const u8, now_ms: i64) i64 {
    if (repeatIntervalMsCanonical(canon)) |interval| {
        if (interval <= 0) return 0;

        const max = std.math.maxInt(i64);
        if (now_ms <= max - interval) {
            return now_ms + interval;
        }
    }
    return 0;
}

/// Build the concatenated logical string for a task.
///
/// Shapes:
///   text only:
///       "<text>"
///   text + date:
///       "<text> d:[YYYY-MM-DD]"
///   text + date + time:
///       "<text> d:[YYYY-MM-DD HH:MM]"
///   date only:
///       "d:[YYYY-MM-DD[ HH:MM]]"
fn buildTaskLine(task: Task) TaskLine {
    var line = TaskLine{
        .segs = undefined,
        .seg_count = 0,
        .total_len = 0,
    };

    // main text (may be empty)
    appendTaskSeg(&line, task.text);

    const date = task.due_date;
    if (date.len == 0) {
        // no due date => just text
        return line;
    }

    // single space between text and due block when text exists
    if (task.text.len != 0) {
        appendTaskSeg(&line, " ");
    }

    appendTaskSeg(&line, "d:[");
    appendTaskSeg(&line, date);

    const time = task.due_time;
    if (time.len != 0) {
        appendTaskSeg(&line, " ");
        appendTaskSeg(&line, time);
    }

    appendTaskSeg(&line, "]");

    return line;
}

/// Access the byte at global index `idx` within the logical concatenation
/// of all segments. Caller guarantees idx < total_len.
fn taskLineByte(line: *const TaskLine, idx: usize) u8 {
    var remaining = idx;
    var s: usize = 0;
    while (s < line.seg_count) : (s += 1) {
        const seg = line.segs[s];
        if (remaining < seg.len) {
            return seg[remaining];
        }
        remaining -= seg.len;
    }
    return 0; // should be unreachable for valid idx
}


/// Access a 1-byte grapheme slice at global index `idx`, backed by the
/// underlying segment memory (task buffers or string literals).
fn taskLineGrapheme(line: *const TaskLine, idx: usize) []const u8 {
    var remaining = idx;
    var s: usize = 0;
    while (s < line.seg_count) : (s += 1) {
        const seg = line.segs[s];
        if (remaining < seg.len) {
            const off = remaining;
            return seg[off .. off + 1];
        }
        remaining -= seg.len;
    }
    return "?"[0..1]; // defensive fallback
}

fn drawTaskLine(
    win: vaxis.Window,
    row: u16,
    editor: *const EditorState,
) void {
    const text = editor.taskSlice();
    const term_width: u16 = win.width;
    if (term_width <= 2) return;

    const base_style: vaxis.Style = .{};
    const cursor_style: vaxis.Style = .{
        .bold = true,
        .reverse = true,
    };

    const cursor_pos: usize = editor.cursor;

    var col: u16 = 2;
    var i: usize = 0;
    while (i < text.len and col < term_width) : (i += 1) {
        const g = text[i .. i + 1];
        const style = if (editor.focus == .task and cursor_pos == i)
            cursor_style
        else
            base_style;

        _ = win.writeCell(col, row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style,
        });
        col += 1;
    }

    // Cursor at end of line -> highlighted space cell.
    if (editor.focus == .task and cursor_pos == text.len and col < term_width) {
        const space = " "[0..1];
        _ = win.writeCell(col, row, .{
            .char = .{ .grapheme = space, .width = 1 },
            .style = cursor_style,
        });
    }
}

fn drawMetaFieldBox(
    win: vaxis.Window,
    top: u16,
    label_field_width: u16,
    label: []const u8,
    value: []const u8,
    cursor_pos: usize,
    focused: bool,
) void {
    if (top + 2 >= win.height) return;
    if (label_field_width + 3 >= win.width) return;

    const base_style: vaxis.Style = .{};
    const label_focus_style: vaxis.Style = .{
        .bold = true,
    };
    const cursor_style: vaxis.Style = .{
        .bold = true,
        .reverse = true,
    };

    const label_style = if (focused) label_focus_style else base_style;

    const mid_row: u16 = top + 1;

    // draw "label:" left box like you already do
    var col: u16 = 2;
    var i: usize = 0;
    while (i < label.len and col < win.width and col < label_field_width) : (i += 1) {
        const g = label[i .. i + 1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = label_style,
        });
        col += 1;
    }
    if (col < win.width and col < label_field_width) {
        const colon = ":"[0..1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = colon, .width = 1 },
            .style = label_style,
        });
        col += 1;
    }

    // space before box
    if (col < win.width and col < label_field_width) {
        const sp = " "[0..1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = sp, .width = 1 },
            .style = base_style,
        });
        col += 1;
    }


    const min_inner: usize = 8;
    var inner_w: usize = value.len;
    if (inner_w < min_inner) inner_w = min_inner;

    const available: usize = @intCast(win.width - label_field_width);
    if (available <= 3) return;

    const max_inner: usize = available - 2;
    if (inner_w > max_inner) inner_w = max_inner;

    const total_w: u16 = @intCast(inner_w + 2);
    const box_right: u16 = label_field_width + total_w - 1;
    if (box_right >= win.width) return;

    const box_bottom: u16 = top + 2;

    drawRect(win, label_field_width, top, box_right, box_bottom, base_style);

    // contents
    var val_col: u16 = label_field_width + 1;
    const val_row: u16 = mid_row;

    i = 0;
    while (i < value.len and val_col < box_right) : (i += 1) {
        const g = value[i .. i + 1];
        const style_for_cell =
            if (focused and cursor_pos == i) cursor_style else base_style;

        _ = win.writeCell(val_col, val_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = style_for_cell,
        });
        val_col += 1;
    }

    // cursor at end of value -> highlight trailing space
    if (focused and cursor_pos == value.len and val_col < box_right) {
        const space = " "[0..1];
        _ = win.writeCell(val_col, val_row, .{
            .char = .{ .grapheme = space, .width = 1 },
            .style = cursor_style,
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
    const l_date = "due date";
    const l_time = "due time";
    const l_repeat = "repeat";

    var max_label_len: u16 = @intCast(l_prio.len);
    const date_len: u16 = @intCast(l_date.len);
    if (date_len > max_label_len) max_label_len = date_len;
    const time_len: u16 = @intCast(l_time.len);
    if (time_len > max_label_len) max_label_len = time_len;
    const rep_len: u16 = @intCast(l_repeat.len);
    if (rep_len > max_label_len) max_label_len = rep_len;

    // label_col + max_label + ":" + space
    const label_field_width: u16 = label_col + max_label_len + 2;
    if (label_field_width + 3 >= win.width) return;

    var top = first_top;

    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_field_width,
            "prio",
            editor.prioSlice(),
            editor.prio_cursor,
            editor.focus == .priority,
        );
    }
    top += 3;
    if (top >= term_height) return;

    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_field_width,
            "due date",
            editor.dueSlice(),
            editor.due_cursor,
            editor.focus == .due_date,
        );
    }


    top += 3;
    if (top >= term_height) return;

    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_field_width,
            "due time",
            editor.timeSlice(),
            editor.time_cursor,
            editor.focus == .due_time,
        );
    }

    top += 3;
    if (top >= term_height) return;

    if (top + 2 < term_height) {
        drawMetaFieldBox(
            win,
            top,
            label_field_width,
            "repeat",
            editor.repeatSlice(),
            editor.repeat_cursor,
            editor.focus == .repeat,
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

    const base_style: vaxis.Style = .{};
    const focus_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 220, 220, 255 } },
    };

    const label_style: vaxis.Style =
        if (editor.focus == .task) focus_style else base_style;
    const text_style: vaxis.Style =
        if (editor.focus == .task) focus_style else base_style;

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

    drawTaskLine(win, text_row, editor);

    // if (editor.focus == .task) {
    //     var cursor_col: u16 = 2;
    //     var idx: usize = 0;
    //     const cursor_index = editor.cursor;
    //
    //     // advance one column per byte until cursor_index
    //     while (idx < cursor_index and cursor_col < win.width) : (idx += 1) {
    //         cursor_col += 1;
    //     }
    //
    //     if (cursor_col < win.width) {
    //         const cursor = "_"[0..1];
    //         _ = win.writeCell(cursor_col, text_row, .{
    //             .char = .{ .grapheme = cursor, .width = 1 },
    //             .style = text_style,
    //         });
    //     }
    // }

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
    list_cmd_edit: *bool,
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    // Esc: cancel command-line
    if (key.matches(vaxis.Key.escape, .{})) {
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
        return;
    }

    // Backspace: clear any single-letter command
    if (key.matches(vaxis.Key.backspace, .{})) {
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
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
        } else if (list_cmd_edit.*){
            try beginEditSelectedTask(ctx,ui,editor,view);
        }
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
        return;
    }

    // For now we only support single-letter ":n" and ":d"
    if (key.matches('n', .{})) {
        list_cmd_new.* = true;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
        return;
    }
    if (key.matches('d', .{})) {
        list_cmd_done.* = true;
        list_cmd_new.* = false;
        list_cmd_edit.* = false;
        return;
    }
    if (key.matches('e', .{})){
        list_cmd_edit.* = true;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        return;
    }
}


fn beginEditSelectedTask(
    ctx: *TuiContext,
    ui: *UiState,
    editor: *EditorState,
    view: *AppView,
) !void {
    const tasks_all: []const Task = switch (ui.focus) {
        .todo => ctx.index.todoSlice(),
        .done => ctx.index.doneSlice(),
    };

    const visible: []const usize = visibleIndicesForFocus(ui.focus);
    if (visible.len == 0) return;

    var list_view = ui.activeView();
    if (list_view.selected_index >= visible.len) {
        list_view.selected_index = visible.len - 1;
    }

    const sel_visible = list_view.selected_index;
    const sel_original = visible[sel_visible];

    const t = tasks_all[sel_original];

    var e = EditorState.fromTask(t);
    e.editing_index = sel_original; // ORIGINAL index into the file slice
    e.editing_status = if (ui.focus == .done) store.Status.done else store.Status.todo;

    editor.* = e;
    view.* = .editor;
}


fn saveExistingTask(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !void {
    const editing_status = editor.editing_status;

    var file: fs.File = undefined;
    const tasks: []const Task = switch (editing_status) {
        .done => blk: {
            file = ctx.done_file.*;
            break :blk ctx.index.doneSlice();
        },
        else => blk: {
            file = ctx.todo_file.*;
            break :blk ctx.index.todoSlice();
        },
    };

    if (tasks.len == 0) return;
    if (editor.editing_index >= tasks.len) return;

    const old = tasks[editor.editing_index];

    var date_buf: [10]u8 = undefined;
    var time_buf: [5]u8 = undefined;
    const due_info = canonicalDueFromEditor(editor, &date_buf, &time_buf);


    var repeat_buf: [16]u8 = undefined;
    const repeat_canon = canonicalRepeatFromEditor(editor, &repeat_buf);


    var repeat_next_ms: i64 = 0;
    if (repeat_canon.len != 0) {
        if (old.status == .done) {
            // If repeat unchanged and we already had a timer, preserve it.
            if (old.repeat_next_ms != 0 and std.mem.eql(u8, repeat_canon, old.repeat)) {
                repeat_next_ms = old.repeat_next_ms;
            } else {
                const now_ms = std.time.milliTimestamp();
                repeat_next_ms = computeRepeatNextMs(repeat_canon, now_ms);
            }
        } else {
            // TODO/other statuses: timer starts only when marked done.
            repeat_next_ms = 0;
        }
    } else {
        // No repeat configured.
        repeat_next_ms = 0;
    }

    const new_task: store.Task = .{
        .id         = old.id,
        .text       = editor.taskSlice(),
        .proj_first = 0,
        .proj_count = 0,
        .ctx_first  = 0,
        .ctx_count  = 0,
        .priority   = editor.priorityValue(),
        .status     = old.status,
        .due_date   = due_info.date,
        .due_time   = due_info.time,
        .repeat     = repeat_canon,
        .repeat_next_ms = repeat_next_ms,
        .created_ms = old.created_ms,
    };

    try store.rewriteJsonFileReplacingIndex(
        allocator,
        &file,
        tasks,
        editor.editing_index,
        new_task,
    );

    try ctx.index.reload(allocator, ctx.todo_file.*, ctx.done_file.*);

    try rebuildVisibleAll(allocator, ctx.index);

    ui.focus = if (editing_status == .done) .done else .todo;

    var list_view = ui.activeView();
    const new_slice: []const Task = switch (ui.focus) {
        .todo => ctx.index.todoSlice(),
        .done => ctx.index.doneSlice(),
    };

    if (new_slice.len == 0) {
        list_view.selected_index = 0;
        list_view.scroll_offset = 0;
        list_view.last_move = 0;
    } else {
        const idx = if (editor.editing_index < new_slice.len)
            editor.editing_index
        else
            new_slice.len - 1;

        list_view.selected_index = idx;
        list_view.last_move = 0;
    }
}

fn saveEditorToDisk(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !void {
    if (editor.is_new) {
        try saveNewTask(ctx, allocator, editor, ui);
    } else {
        try saveExistingTask(ctx, allocator, editor, ui);
    }
}

fn markDone(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    const todos = ctx.index.todoSlice();
    const visible = g_visible_todo.items;

    if (visible.len == 0) return;

    var todo_view = &ui.todo;
    if (todo_view.selected_index >= visible.len) return;

    const sel_visible = todo_view.selected_index;
    const remove_index = visible[sel_visible]; // ORIGINAL index into todos
    const original = todos[remove_index];

    var moved = original;
    moved.status = .done;

    moved.repeat_next_ms = 0;
    if (moved.repeat.len != 0) {
        const now_ms = std.time.milliTimestamp();
        moved.repeat_next_ms = computeRepeatNextMs(moved.repeat, now_ms);
    }

    var done_file = ctx.done_file.*;
    try store.appendJsonTaskLine(allocator, &done_file, moved);

    var todo_file = ctx.todo_file.*;
    try store.rewriteJsonFileWithoutIndex(allocator, &todo_file, todos, remove_index);

    try ctx.index.reload(allocator, todo_file, done_file);
    try rebuildVisibleAll(allocator, ctx.index);

    ui.focus = .todo;

    // keep selection at same visible row if possible
    const new_vis_len = g_visible_todo.items.len;
    if (new_vis_len == 0) {
        todo_view.selected_index = 0;
        todo_view.scroll_offset = 0;
        todo_view.last_move = 0;
        return;
    }

    if (sel_visible >= new_vis_len) {
        todo_view.selected_index = new_vis_len - 1;
    } else {
        todo_view.selected_index = sel_visible;
    }

    if (todo_view.scroll_offset >= new_vis_len) todo_view.scroll_offset = 0;
    todo_view.last_move = -1;
}

fn saveNewTask(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !void {
    const text = editor.taskSlice();
    if (text.len == 0) return;

    var date_buf: [10]u8 = undefined;
    var time_buf: [5]u8 = undefined;
    const due_info = canonicalDueFromEditor(editor, &date_buf, &time_buf);

    var repeat_buf: [16]u8 = undefined;
    const repeat_canon = canonicalRepeatFromEditor(editor, &repeat_buf);

    const prio_val: u8 = editor.priorityValue();

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
        .id         = new_id,
        .text       = text,
        .proj_first = 0,
        .proj_count = 0,
        .ctx_first  = 0,
        .ctx_count  = 0,
        .priority   = prio_val,
        .status     = .todo,
        .due_date   = due_info.date,
        .due_time   = due_info.time,
        .repeat     = repeat_canon,
        .repeat_next_ms = 0,
        .created_ms = now_ms,
    };

    var file = ctx.todo_file.*;
    try store.appendJsonTaskLine(allocator, &file, new_task);
    try ctx.index.reload(allocator, file, ctx.done_file.*);

    try rebuildVisibleAll(allocator, ctx.index);

    if (ctx.index.todoSlice().len != 0) {
        ui.focus = .todo;
        var todo_view = &ui.todo;
        todo_view.selected_index = ctx.index.todoSlice().len - 1;
        todo_view.last_move = 1;
    }
}


fn processRepeats(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
) !void {
    while (true) {
        const dones = ctx.index.doneSlice();
        if (dones.len == 0) return;

        const now_ms = std.time.milliTimestamp();

        var found = false;
        var move_index: usize = 0;
        var move_task: Task = undefined;

        var i: usize = 0;
        while (i < dones.len) : (i += 1) {
            const t = dones[i];
            if (t.repeat.len == 0) continue;
            if (t.repeat_next_ms <= 0) continue;
            if (t.repeat_next_ms > now_ms) continue;

            found = true;
            move_index = i;
            move_task = t;
            break;
        }

        if (!found) break;

        var todo_file = ctx.todo_file.*;
        var done_file = ctx.done_file.*;

        var resurrect = move_task;
        resurrect.status = .todo;
        resurrect.repeat_next_ms = 0; // timer only re-armed on next completion

        try store.appendJsonTaskLine(allocator, &todo_file, resurrect);
        try store.rewriteJsonFileWithoutIndex(allocator, &done_file, dones, move_index);

        try ctx.index.reload(allocator, todo_file, done_file);

        try rebuildVisibleAll(allocator, ctx.index);

        // UI indices are clamped lazily in drawTodoList via activeView().
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
                try saveEditorToDisk(ctx, allocator, editor, ui);
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
                editor.focus = .due_date;
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


    // Esc: in insert mode, return to normal mode.
    // In normal mode, stay in the editor; leaving the editor is done via :q.
    if (key.matches(vaxis.Key.escape, .{})) {
        if (editor.mode == .insert) {
            editor.mode = .normal;
        }
        return;
    }

    switch (editor.mode) {
        .normal => {
            // ":" enters editor command-line (from any mode, forces normal).
            if (key.matches(':', .{})) {
                editor.mode = .normal;
                editor.resetCommand();
                editor.cmd_active = true;
                return;
            }

            // vertical focus cycling between fields
            if (key.matches('j', .{})) {
                editor.focusNext();
                return;
            }
            if (key.matches('k', .{})) {
                editor.focusPrev();
                return;
            }

            if (key.matches('i', .{})) {
                editor.mode = .insert;
                return;
            }

            if (key.matches('I', .{})) {
                // go to start, then insert
                editor.moveToStart();
                editor.mode = .insert;
                return;
            }
            if (key.matches('a', .{})) {
                // append after current position
                editor.moveCursor(1);
                editor.mode = .insert;
                return;
            }
            if (key.matches('A', .{})) {
                // go to end, then insert
                editor.moveToEnd();
                editor.mode = .insert;
                return;
            }

            // horizontal motions
            if (key.matches('h', .{})) {
                editor.moveCursor(-1);
                return;
            }
            if (key.matches('l', .{})) {
                editor.moveCursor(1);
                return;
            }

            // line boundary motions
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
            // Backspace deletes in the focused field
            if (key.matches(vaxis.Key.backspace, .{})) {
                editor.deleteBeforeCursor();
                return;
            }

            // Enter: leave insert, stay in editor
            if (key.matches(vaxis.Key.enter, .{})) {
                editor.mode = .normal;
                return;
            }

            // Printable ASCII routes to the focused buffer
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


/// Build the textual meta suffix (due + repeat) for a task into `buf`.
///
/// Shape after the status / prio prefix:
///   "<task.text> d:[YYYY-MM-DD HH:MM] r:[2d]"
///
/// Rules:
///   - If there is no due_date and no repeat, returns an empty slice.
///   - If there is a due_date and no task text, suffix starts with "d:[...]".
///   - If there is repeat only and no task text, suffix starts with "r:[...]".
///   - If there is task text and at least one meta field, suffix starts with
///     a single space so the full line reads "... <text> d:[...] r:[...]".
///   - Time is shown only when there is also a non-empty date.
///
/// Invariants (for new data):
///   - `task.due_date` is either empty or "YYYY-MM-DD".
///   - `task.due_time` is either empty or "HH:MM".
///   - `task.repeat` is either empty or canonical "<N><unit>" (e.g. "2d").
///
/// For legacy or malformed data:
///   - If the combined meta string would exceed `buf.len`, this returns
///     an empty slice instead of risking overflow.
fn buildMetaSuffixForTask(task: Task, buf: []u8) []const u8 {
    const date = task.due_date;
    const time = task.due_time;
    const repeat = task.repeat;

    const have_date = (date.len != 0);
    const have_repeat = (repeat.len != 0);
    if (!have_date and !have_repeat) return buf[0..0];

    const has_time = (time.len != 0 and have_date);

    // Leading space only when task text exists.
    const space_before_meta: usize =
        if (task.text.len != 0) 1 else 0;

    const due_size: usize = if (have_date) blk: {
        var n: usize = 0;
        // "d:["
        n += 3;
        // date
        n += date.len;
        if (has_time) {
            // " " + time
            n += 1 + time.len;
        }
        // "]"
        n += 1;
        break :blk n;
    } else 0;

    const repeat_size: usize = if (have_repeat)
        (3 + repeat.len + 1) // "r:[" + repeat + "]"
    else
        0;

    const space_between_meta: usize =
        if (have_date and have_repeat) 1 else 0;

    const total_needed: usize =
        space_before_meta + due_size + repeat_size + space_between_meta;

    if (total_needed > buf.len) {
        // Fail closed: no meta rendered instead of risking overflow.
        return buf[0..0];
    }

    var pos: usize = 0;

    if (space_before_meta == 1) {
        buf[pos] = ' ';
        pos += 1;
    }

    if (have_date) {
        buf[pos] = 'd'; pos += 1;
        buf[pos] = ':'; pos += 1;
        buf[pos] = '['; pos += 1;

        @memcpy(buf[pos .. pos + date.len], date);
        pos += date.len;

        if (has_time) {
            buf[pos] = ' ';
            pos += 1;
            @memcpy(buf[pos .. pos + time.len], time);
            pos += time.len;
        }

        buf[pos] = ']';
        pos += 1;
    }

    if (have_repeat) {
        if (have_date) {
            buf[pos] = ' ';
            pos += 1;
        }

        buf[pos] = 'r'; pos += 1;
        buf[pos] = ':'; pos += 1;
        buf[pos] = '['; pos += 1;

        @memcpy(buf[pos .. pos + repeat.len], repeat);
        pos += repeat.len;

        buf[pos] = ']';
        pos += 1;
    }

    return buf[0..pos];
}

/// Access a byte of the conceptual string `main ++ suffix` at global index `idx`.
fn twoPartByte(main: []const u8, suffix: []const u8, idx: usize) u8 {
    return if (idx < main.len) main[idx] else suffix[idx - main.len];
}


/// Count rows needed for a full task line (task text + due suffix),
/// given `max_cols` columns of content.
fn measureWrappedRowsForTask(task: Task, max_cols: usize) usize {
    if (max_cols == 0) return 0;

    var suffix_buf: [META_SUFFIX_BUF_LEN]u8 = undefined;
    const suffix = buildMetaSuffixForTask(task, suffix_buf[0..]);

    const main = task.text;
    const total_len = main.len + suffix.len;
    if (total_len == 0) return 0;

    var rows: usize = 0;
    var i: usize = 0;

    while (i < total_len) {
        rows += 1;

        const line_start = i;
        var last_space: ?usize = null;
        var col_count: usize = 0;

        while (i < total_len and col_count < max_cols) : (col_count += 1) {
            const b = twoPartByte(main, suffix, i);
            if (isSpaceByte(b)) {
                last_space = i;
            }
            i += 1;
        }

        if (i < total_len and col_count == max_cols) {
            if (last_space) |sp| {
                if (sp >= line_start) {
                    i = sp + 1;
                }
            }
        }

        while (i < total_len) {
            const b = twoPartByte(main, suffix, i);
            if (!isSpaceByte(b)) break;
            i += 1;
        }
    }

    return rows;
}

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
            const b = text[j];
            const g = graphemeFromByte(b);

            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(@intCast(col), row, cell);
            col += 1;
        }
    }
}


/// Draw `<task.text>` optionally followed by ` d:[YYYY-MM-DD HH:MM]`,
/// wrapped into `max_rows` rows and `max_cols` columns, starting at
/// (start_row, col_offset).
fn drawWrappedTask(
    win: vaxis.Window,
    task: Task,
    start_row: usize,
    col_offset: usize,
    max_rows: usize,
    max_cols: usize,
    style: vaxis.Style,
) void {
    if (max_rows == 0 or max_cols == 0) return;

    var suffix_buf: [META_SUFFIX_BUF_LEN]u8 = undefined;
    const suffix = buildMetaSuffixForTask(task, suffix_buf[0..]);

    const main = task.text;
    const total_len = main.len + suffix.len;
    if (total_len == 0) return;

    const height = win.height;

    var i: usize = 0;
    var row_index: usize = 0;

    while (i < total_len and row_index < max_rows and (start_row + row_index) < height) : (row_index += 1) {
        const row: u16 = @intCast(start_row + row_index);

        const line_start = i;
        var last_space: ?usize = null;
        var col_count: usize = 0;

        while (i < total_len and col_count < max_cols) : (col_count += 1) {
            const b = twoPartByte(main, suffix, i);
            if (isSpaceByte(b)) {
                last_space = i;
            }
            i += 1;
        }

        var line_end = i;

        if (i < total_len and col_count == max_cols) {
            if (last_space) |sp| {
                if (sp >= line_start) {
                    line_end = sp;
                    i = sp + 1;
                }
            }
        }

        var seg_start = line_start;
        while (seg_start < line_end) {
            const b = twoPartByte(main, suffix, seg_start);
            if (!isSpaceByte(b)) break;
            seg_start += 1;
        }

        var col: usize = col_offset;
        var j: usize = seg_start;
        while (j < line_end and col < win.width) : (j += 1) {
            const b = twoPartByte(main, suffix, j);
            const g = graphemeFromByte(b);

            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            };
            _ = win.writeCell(@intCast(col), row, cell);
            col += 1;
        }

        while (i < total_len) {
            const b = twoPartByte(main, suffix, i);
            if (!isSpaceByte(b)) break;
            i += 1;
        }
    }
}


/// Logical width of the "P{prio}" prefix in columns.
/// This is kept in sync with how drawPriorityPrefix paints cells:
/// one "P" plus 1–3 decimal digits.
fn priorityLen(prio: u8) usize {
    if (prio == 0) return 0;
    if (prio < 10) return 2;   // "P3"
    if (prio < 100) return 3;  // "P42"
    return 4;                  // "P255"
}

/// Draw a single decimal digit using only static storage.
/// This avoids any stack-backed grapheme slices that would outlive
/// the current call when vaxis later renders the grid.
fn drawPriorityDigit(
    win: vaxis.Window,
    row: u16,
    col: u16,
    digit: u8,
    style: vaxis.Style,
) u16 {
    if (col >= win.width) return col;
    if (digit > 9) return col;

    const digits = "0123456789";
    const g = digits[digit .. digit + 1];

    _ = win.writeCell(col, row, .{
        .char = .{ .grapheme = g, .width = 1 },
        .style = style,
    });

    return col + 1;
}

/// Paints "P{prio} " starting at `start_col`, returns the column after
/// the trailing space. For prio == 0 it returns start_col and paints
/// nothing. All graphemes come from string literals, so lifetimes are safe.
fn drawPriorityPrefix(
    win: vaxis.Window,
    row: u16,
    start_col: u16,
    prio: u8,
    style: vaxis.Style,
) u16 {
    if (prio == 0 or start_col >= win.width) return start_col;

    var col = start_col;

    const P_slice = "P"[0..1];
    _ = win.writeCell(col, row, .{
        .char = .{ .grapheme = P_slice, .width = 1 },
        .style = style,
    });
    col += 1;
    if (col >= win.width) return col;

    if (prio >= 100) {
        const hundreds: u8 = prio / 100;
        const tens: u8 = (prio / 10) % 10;
        const ones: u8 = prio % 10;

        col = drawPriorityDigit(win, row, col, hundreds, style);
        if (col >= win.width) return col;
        col = drawPriorityDigit(win, row, col, tens, style);
        if (col >= win.width) return col;
        col = drawPriorityDigit(win, row, col, ones, style);
    } else if (prio >= 10) {
        const tens: u8 = prio / 10;
        const ones: u8 = prio % 10;

        col = drawPriorityDigit(win, row, col, tens, style);
        if (col >= win.width) return col;
        col = drawPriorityDigit(win, row, col, ones, style);
    } else {
        col = drawPriorityDigit(win, row, col, prio, style);
    }

    // trailing space after "Pnn"
    if (col < win.width) {
        const space = " "[0..1];
        _ = win.writeCell(col, row, .{
            .char = .{ .grapheme = space, .width = 1 },
            .style = style,
        });
        col += 1;
    }

    return col;
}

/// Width of status + optional priority segment (exclusive of the leading
/// "> " prefix, inclusive of all spaces before the task text).
fn prefixWidthForPrio(prio: u8) usize {
    const len = priorityLen(prio);
    if (len == 0) {
        // "[ ] " only
        return STATUS_WIDTH;
    }
    // "[ ] " + "Pnn" + " "
    return STATUS_WIDTH + len + 1;
}

const TaskLayout = struct {
    prefix: usize,
    rows: usize,
};


fn computeLayout(task: Task, content_width: usize) TaskLayout {
    if (content_width == 0) {
        return .{ .prefix = 0, .rows = 0 };
    }

    const prefix = prefixWidthForPrio(task.priority);

    if (content_width <= prefix) {
        // Only enough room for status/prio on the first row.
        return .{ .prefix = prefix, .rows = 1 };
    }

    const text_width = content_width - prefix;
    var rows = measureWrappedRowsForTask(task, text_width);
    if (rows == 0) rows = 1;

    return .{ .prefix = prefix, .rows = rows };
}


fn isSelectionFullyVisible(
    view: *const ListView,
    tasks_all: []const Task,
    visible: []const usize,
    viewport_height: usize,
    content_width: usize,
) bool {
    if (visible.len == 0 or viewport_height == 0 or content_width == 0) return true;

    if (view.selected_index >= visible.len) return false;
    if (view.scroll_offset >= visible.len) return false;

    var rows_used: usize = 0;
    var vi: usize = view.scroll_offset;

    while (vi < visible.len and rows_used < viewport_height) : (vi += 1) {
        const task = tasks_all[visible[vi]];
        var layout = computeLayout(task, content_width);
        if (layout.rows == 0) layout.rows = 1;

        if (rows_used + layout.rows > viewport_height) {
            if (vi == view.selected_index) return false;
            break;
        }

        if (vi == view.selected_index) return true;

        rows_used += layout.rows;
    }

    return false;
}

fn recomputeScrollOffsetForSelection(
    view: *ListView,
    tasks_all: []const Task,
    visible: []const usize,
    viewport_height: usize,
    content_width: usize,
    dir: i8,
) void {
    if (visible.len == 0 or viewport_height == 0 or content_width == 0) {
        view.scroll_offset = 0;
        view.selected_index = 0;
        return;
    }

    if (view.selected_index >= visible.len) {
        view.selected_index = visible.len - 1;
    }

    const sel_vi = view.selected_index;
    const sel_task = tasks_all[visible[sel_vi]];

    var sel_layout = computeLayout(sel_task, content_width);
    if (sel_layout.rows == 0) sel_layout.rows = 1;

    if (sel_layout.rows > viewport_height) {
        view.scroll_offset = sel_vi;
        return;
    }

    if (dir < 0) {
        view.scroll_offset = sel_vi;
        return;
    }

    var rows_total: usize = sel_layout.rows;
    var start_vi: usize = sel_vi;

    while (start_vi > 0) {
        const prev_vi = start_vi - 1;
        const prev_task = tasks_all[visible[prev_vi]];

        var prev_layout = computeLayout(prev_task, content_width);
        if (prev_layout.rows == 0) prev_layout.rows = 1;

        if (rows_total + prev_layout.rows > viewport_height) break;

        rows_total += prev_layout.rows;
        start_vi = prev_vi;
    }

    view.scroll_offset = start_vi;
}


fn computeProjectPanelWidth(
    win: vaxis.Window,
    index: *const TaskIndex,
    focus:ListKind,
) usize {

    const projects = projectsForFocus(index,focus);
    if (projects.len == 0) return 0;

    const term_width: usize = @intCast(win.width);
    if (term_width < PROJECT_PANEL_MIN_TERM_WIDTH) return 0;

    // Longest project name.
    var longest: usize = 0;
    var i: usize = 0;
    while (i < projects.len) : (i += 1) {
        const name_len = projects[i].name.len;
        if (name_len > longest) longest = name_len;
    }

    var width: usize = longest + 6; // "[n] " plus some slack
    if (width < PROJECT_PANEL_MIN_WIDTH) width = PROJECT_PANEL_MIN_WIDTH;

    const max_panel = @min(PROJECT_PANEL_MAX_WIDTH, term_width / 3);
    if (width > max_panel) width = max_panel;

    // Keep the main list from becoming absurdly narrow.
    if (term_width <= width + PROJECT_PANEL_MIN_LIST_WIDTH) {
        return 0;
    }


    return width;
}


fn computeProjectsPaneWidth(term_width: usize) usize {
    // If the terminal is too narrow, disable the sidebar entirely.
    if (term_width < PROJECT_PANE_MIN_WIDTH + 8) return 0;

    const one_third = term_width / 3;
    var w = if (one_third < PROJECT_PANE_MAX_WIDTH) one_third else PROJECT_PANE_MAX_WIDTH;
    if (w < PROJECT_PANE_MIN_WIDTH) w = PROJECT_PANE_MIN_WIDTH;
    return w;
}


fn drawProjectsPane(win: vaxis.Window, index: *const TaskIndex, focus:ListKind) void {
    const term_width: usize = @intCast(win.width);
    const term_height: usize = @intCast(win.height);
    if (term_height == 0 or term_width == 0) return;

    const pane_width = computeProjectsPaneWidth(term_width);
    if (pane_width == 0 or pane_width >= term_width) return;

    const right_col: usize = pane_width - 1;

    const projects = projectsForFocus(index, focus);

    const base_style: vaxis.Style = .{};
    const header_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 200, 200, 255 } },
    };
    const selected_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .rgb = .{ 220, 220, 255 } },
    };

    // Vertical separator at the right edge of the pane.
    var row: usize = 0;
    while (row < term_height) : (row += 1) {
        const cell: Cell = .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = base_style,
        };
        _ = win.writeCell(@intCast(right_col), @intCast(row), cell);
    }

    // Header "Projects" centered within the pane, not across the whole screen.
    const header = "Projects";
    const header_len: usize = header.len;

    const usable_cols = if (right_col > 0) right_col else 0;
    var start_col: usize = 0;
    if (usable_cols > header_len) {
        start_col = (usable_cols - header_len) / 2;
    }

    const header_row: usize = if (term_height > 2) 2 else 0;
    var col: usize = start_col;
    var i: usize = 0;
    while (i < header_len and col < usable_cols) : (i += 1) {
        const g = header[i .. i + 1];
        const cell: Cell = .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = header_style,
        };
        _ = win.writeCell(@intCast(col), @intCast(header_row), cell);
        col += 1;
    }

    if (projects.len == 0) return;


    // List of "+project" entries, wrapped within the pane.
    var proj_row: usize = header_row + 2;
    if (proj_row >= term_height) return;

    const max_text_width = if (right_col > 1) right_col - 1 else 0;
    if (max_text_width == 0) return;


    const sel_ptr = selectedProjectPtr(focus);
    if (sel_ptr.* >= projects.len) sel_ptr.* = projects.len - 1;

    var idx: usize = 0;
    while (idx < projects.len and proj_row < term_height) : (idx += 1) {
        const entry = projects[idx];

        var line_buf: [64]u8 = undefined;
        var pos: usize = 0;

        if (idx == 0) {
            // "all" entry, no '+'
            const lit = "all";
            const copy_len = @min(lit.len, line_buf.len);
            @memcpy(line_buf[0..copy_len], lit[0..copy_len]);
            pos = copy_len;
        } else {
            line_buf[pos] = '+';
            pos += 1;

            if (entry.name.len != 0) {
                const copy_len = @min(entry.name.len, line_buf.len - pos);
                @memcpy(line_buf[pos .. pos + copy_len], entry.name[0..copy_len]);
                pos += copy_len;
            }
        }

        const line = line_buf[0..pos];

        const style =
            if (g_projects_focus and idx == sel_ptr.*)
                selected_style
            else
                base_style;

        drawWrappedText(win, proj_row, 1, 1, max_text_width, line, style);
        proj_row += 1;
    }
}


/// Render the currently focused list with vim-style navigation.
/// Selected row is bold and prefixed with "> ".

fn drawTodoList(
    win: vaxis.Window,
    index: *const TaskIndex,
    ui: *UiState,
    cmd_active: bool,
) void {
    const tasks_all: []const Task = switch (ui.focus) {
        .todo => index.todoSlice(),
        .done => index.doneSlice(),
    };

    const visible: []const usize = visibleIndicesForFocus(ui.focus);
    var view = ui.activeView();

    // empty because filter hid everything
    if (visible.len == 0) {
        view.selected_index = 0;
        view.scroll_offset = 0;
        return;
    }

    const term_height: usize = @intCast(win.height);
    const term_width: usize = @intCast(win.width);
    if (term_height <= LIST_START_ROW or term_width == 0) return;

    const reserved_rows: usize =
        if (cmd_active and term_height > LIST_START_ROW + 1) 1 else 0;
    if (term_height <= LIST_START_ROW + reserved_rows) return;

    const viewport_height = term_height - LIST_START_ROW - reserved_rows;
    if (viewport_height == 0) return;

    if (view.selected_index >= visible.len) {
        view.selected_index = visible.len - 1;
    }
    if (view.scroll_offset >= visible.len) {
        view.scroll_offset = 0;
    }

    const proj_pane_width = computeProjectsPaneWidth(term_width);

    var arrow_col_usize: usize = 0;
    var pad_col_usize: usize = 1;
    var content_start_col_usize: usize = 2;

    if (proj_pane_width != 0) {
        arrow_col_usize = proj_pane_width;
        pad_col_usize = proj_pane_width + 1;
        content_start_col_usize = proj_pane_width + 2;
    }

    if (content_start_col_usize >= term_width) return;

    const content_width: usize = term_width - content_start_col_usize;
    if (content_width <= STATUS_WIDTH) return;

    const arrow_col: u16 = @intCast(arrow_col_usize);
    const pad_col: u16 = @intCast(pad_col_usize);
    const content_start_col: u16 = @intCast(content_start_col_usize);

    const dir = view.last_move;
    if (!isSelectionFullyVisible(view, tasks_all, visible, viewport_height, content_width)) {
        recomputeScrollOffsetForSelection(view, tasks_all, visible, viewport_height, content_width, dir);
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

    var vi: usize = view.scroll_offset;
    while (vi < visible.len and remaining_rows > 0 and row < term_height) : (vi += 1) {
        const task = tasks_all[visible[vi]];
        const selected = (view.selected_index == vi);
        const style = if (selected) sel_style else base_style;

        var layout = computeLayout(task, content_width);
        if (layout.rows == 0) layout.rows = 1;

        const rows_needed = layout.rows;
        const prefix = layout.prefix;

        if (rows_needed > remaining_rows) break;

        const row_u16: u16 = @intCast(row);

        if (arrow_col < win.width) {
            const g = if (selected and !g_projects_focus) indicator_slice else space_slice;
            _ = win.writeCell(arrow_col, row_u16, .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            });
        }
        if (pad_col < win.width) {
            _ = win.writeCell(pad_col, row_u16, .{
                .char = .{ .grapheme = space_slice, .width = 1 },
                .style = style,
            });
        }

        const status_text: []const u8 = switch (task.status) {
            .todo => "[ ]",
            .ongoing => "[@]",
            .done => "[x]",
        };

        var col_status: u16 = content_start_col;
        var s_i: usize = 0;
        while (s_i < status_text.len and col_status < win.width) : (s_i += 1) {
            const g = status_text[s_i .. s_i + 1];
            _ = win.writeCell(col_status, row_u16, .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = style,
            });
            col_status += 1;
        }
        if (col_status < win.width) {
            _ = win.writeCell(col_status, row_u16, .{
                .char = .{ .grapheme = space_slice, .width = 1 },
                .style = style,
            });
            col_status += 1;
        }

        var text_start_col: u16 = col_status;
        if (task.priority != 0 and col_status < win.width) {
            text_start_col = drawPriorityPrefix(
                win,
                row_u16,
                col_status,
                task.priority,
                style,
            );
        }

        if (content_width > prefix) {
            const text_width = content_width - prefix;
            drawWrappedTask(
                win,
                task,
                row,
                @intCast(text_start_col),
                rows_needed,
                text_width,
                style,
            );
        }

        row += rows_needed;
        remaining_rows -= rows_needed;
    }
}
