const std = @import("std");
const vaxis = @import("vaxis");
const store = @import("task_store.zig");
const math = std.math;

const dt = @import("due_datetime.zig");

var g_due_cfg: *const dt.DueFormatConfig = undefined;

const due_today_mod = @import("due_today.zig");
const task_index = @import("task_index.zig");
const view_sort = @import("view_sort.zig");

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

const VisibleFn = *const fn (focus: ListKind) []const usize;

const undo_mod = @import("undo.zig");
var g_undo: undo_mod.Undo = .{};


const Tri = enum { empty, ok, invalid };

const LIST_START_ROW: usize = 4;
const STATUS_WIDTH: usize = 4;
const CREATED_COLS: usize = 13;
const META_SUFFIX_BUF_LEN: usize = 48;

const PROJECT_PANEL_MIN_TERM_WIDTH: usize = 40;
const PROJECT_PANEL_MIN_LIST_WIDTH: usize = 20;
const PROJECT_PANEL_MIN_WIDTH: usize = 16;
const PROJECT_PANEL_MAX_WIDTH: usize = 32;

const PROJECT_PANE_MAX_WIDTH: usize = 20;
const PROJECT_PANE_MIN_WIDTH: usize = 14;

// Sidebar UI state; kept local to tui so UiState does not grow yet.
var g_projects_focus: bool = false;

// 0 means "all"
var g_projects_selected_todo: usize = 0;
var g_projects_selected_done: usize = 0;

// visible task indices (into the underlying todo/done slices)
var g_visible_todo = std.ArrayListUnmanaged(usize){};
var g_visible_done = std.ArrayListUnmanaged(usize){};

var g_due_today: due_today_mod.DueToday = .{};

var g_sort_scratch: view_sort.Scratch = .{};


var g_dbg_seq: u64 = 0;


fn dbg(comptime fmt: []const u8, args: anytype) void {
    // Unbuffered writer: every call becomes direct syscalls.
    // For debugging, this is desirable because it survives abrupt exits.
    var wr = std.fs.File.stderr().writer(&.{});
    const w = &wr.interface;
    w.print(fmt, args) catch {};
    w.print("\n", .{}) catch {};
}


const builtin = @import("builtin");

inline fn trace(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .Debug) return;
    std.debug.print(fmt, args);
}

/// Event type for the libvaxis low-level loop.
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};


pub const TuiContext = struct {
    todo_file: *fs.File,
    done_file: *fs.File,
    index: *TaskIndex,
    due_cfg: *const dt.DueFormatConfig,
};

const AppView = enum {
    list,
    due_today,
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
    defer g_due_today.deinit(allocator);
    defer g_undo.deinit(allocator);
    defer g_sort_scratch.deinit(allocator);

    g_due_cfg = ctx.due_cfg;
    
    var view: AppView = .list;
    var return_view: AppView = .list;
    var editor = EditorState.init();
    var due_view: ListView = .{
        .selected_index = 0,
        .scroll_offset = 0,
        .last_move = 0,
    };

    var list_cmd_active = false;
    var list_cmd_new = false;
    var list_cmd_done = false;
    var list_cmd_edit = false;

    var pending_g_list: bool = false;
    var pending_g_due: bool = false;

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
    try g_due_today.refresh(allocator, ctx.index);

    var running = true;
    while (running) {
        const event = loop.nextEvent();
        g_dbg_seq += 1;

        switch (event) {
            .key_press => |key| {
                keypress: {
                    if (key.matches('c', .{ .ctrl = true })) {
                        running = false;
                        break :keypress;
                    }

                    switch (view) {
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
                                    &due_view, &return_view,
                                );
                                break :keypress;
                            }

                            if (key.matches(':', .{})) {

                                pending_g_list = false;
                                pending_g_due = false;
                                list_cmd_active = true;
                                list_cmd_new = false;
                                list_cmd_done = false;
                                list_cmd_edit = false;
                                break :keypress;
                            }


                            if (key.matches('D', .{})) {
                                if (!g_projects_focus) {
                                    try deleteSelectedGeneric(ctx, allocator, ui, ui.focus, ui.activeView(), visibleMain);
                                }
                                break :keypress;
                            }

                            if (key.matches('d', .{}) and !g_projects_focus) {
                                pending_g_list = false;
                                pending_g_due = false;

                                g_projects_focus = false;
                                try g_due_today.refresh(allocator, ctx.index);
                                view = .due_today;
                                break :keypress;
                            }

                            if (key.matches('u', .{})) {
                                try g_undo.toggle(allocator, ctx.index, ctx.todo_file, ctx.done_file);
                                try rebuildVisibleAll(allocator, ctx.index);
                                // clamp whichever view is active in that pane
                                break :keypress;
                            }

                            if (try handleListFocusKey(key, ui, ctx.index, allocator)) {
                                break :keypress;
                            }

                            if (g_projects_focus) {
                                break :keypress;
                            }

                            // gg / G navigation (task list only)
                            {
                                const visible = visibleIndicesForFocus(ui.focus);
                                const vlen = visible.len;

                                const lv = ui.activeView();
                                clampViewToVisible(lv, vlen);

                                if (!g_projects_focus) {
                                    if (handleVimJumpKeys(key, lv, vlen, &pending_g_list)) {
                                        break :keypress;
                                    }
                                } else {
                                    pending_g_list = false;
                                }
                            }

                            if (key.matches('@', .{})) {
                                try toggleTodoOngoing(ctx, allocator, ui);
                                break :keypress;
                            }

                            if (key.matches('X', .{})) {
                                try toggleDoneTodo(ctx, allocator, ui);
                                break :keypress;
                            }

                            handleNavigation(&vx, ctx.index, ui, key);
                            break :keypress;
                        },

                        .due_today => {
                            if (list_cmd_active) {

                                try handleListCommandKey(
                                    key, &view, &editor,
                                    &list_cmd_active, &list_cmd_new, &list_cmd_done, &list_cmd_edit,
                                    ctx, allocator, ui,
                                    &due_view, &return_view,
                                );
                                break :keypress;
                            }

                            if (key.matches(':', .{})) {
                                pending_g_due = false;

                                list_cmd_active = true;
                                list_cmd_new = false;
                                list_cmd_done = false;
                                list_cmd_edit = false;
                                break :keypress;
                            }

                            if (key.matches('d', .{}) or key.matches(vaxis.Key.escape, .{})) {
                                pending_g_due = false;
                                view = .list;
                                break :keypress;
                            }

                            if (key.matches('D', .{})) {
                                // due_today is always TODO-backed
                                try deleteSelectedGeneric(ctx, allocator, ui, .todo, &due_view, visibleDueToday);
                                break :keypress;
                            }

                            if (key.matches('u', .{})) {
                                try g_undo.toggle(allocator, ctx.index, ctx.todo_file, ctx.done_file);
                                try rebuildVisibleAll(allocator, ctx.index);
                                // clamp whichever view is active in that pane
                                break :keypress;
                            }


                            if (try g_due_today.maybeRefresh(allocator, ctx.index)) {
                                // Day rolled over. due_today partition changed. Re-sort all views once.
                                try resortAllVisible(allocator, ctx.index);
                            }


                            const visible = g_due_today.visible.items;
                            const vlen = visible.len;
                            if (vlen == 0) break :keypress;

                            clampViewToVisible(&due_view, vlen);

                            if (handleVimJumpKeys(key, &due_view, vlen, &pending_g_due)){
                                break :keypress;
                            }

                            const sel_visible = due_view.selected_index;
                            const orig_idx = selectedOrigIndex(visible, &due_view) orelse break :keypress;

                            if (key.matches('@', .{})) {
                                try toggleTodoOngoingAtOrig(ctx, allocator, orig_idx);

                                const v2 = g_due_today.visible.items;
                                const v2len = v2.len;
                                if (v2len == 0) {
                                    due_view = .{};
                                } else {
                                    due_view.selected_index = if (sel_visible >= v2len) (v2len - 1) else sel_visible;
                                    if (due_view.scroll_offset >= v2len) due_view.scroll_offset = 0;
                                    due_view.last_move = -1;

                                }
                                break :keypress;
                            }

                            if (key.matches('X', .{})) {
                                try toggleDoneAtOrig(ctx, allocator, .todo, orig_idx);

                                const v2 = g_due_today.visible.items;
                                const v2len = v2.len;
                                if (v2len == 0) {
                                    due_view = .{};
                                } else {
                                    due_view.selected_index = if (sel_visible >= v2len) (v2len - 1) else sel_visible;
                                    if (due_view.scroll_offset >= v2len) due_view.scroll_offset = 0;
                                    due_view.last_move = -1;
                                }
                                break :keypress;
                            }

                            if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                                moveListViewSelection(&due_view, vlen, 1);
                                break :keypress;
                            }

                            if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                                moveListViewSelection(&due_view, vlen, -1);
                                break :keypress;
                            }

                            break :keypress;
                        },

                        .editor => {
                            try handleEditorKey(key, &view, &editor, ctx, allocator, ui, &return_view);
                            break :keypress;
                        },
                    }
                }
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
            },
        }

        try processRepeats(ctx, allocator);


        if (try g_due_today.maybeRefresh(allocator, ctx.index)) {
            // Day rolled over. due_today partition changed. Re-sort all views once.
            try resortAllVisible(allocator, ctx.index);
        }
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
            .due_today => {
                drawDueTodayView(win, ctx.index, &due_view);
                drawListCommandLine(win, list_cmd_active, list_cmd_new, list_cmd_done, list_cmd_edit); // <--- add
            },
            .editor => {
                drawEditorView(win, &editor);
            },
        }



        vx.render(tty.writer()) catch |err| {
            dbg("RENDER: error {s}\n", .{@errorName(err)});
            return err;
        };
    }
}


fn civilFromDays(days_since_epoch: i64) struct { y: i32, m: u8, d: u8 } {
    // Howard Hinnant: civil_from_days; days_since_epoch is relative to 1970-01-01.
    const z: i64 = days_since_epoch + 719468;
    const era: i64 = if (z >= 0) @divTrunc(z, 146097) else @divTrunc(z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: i64 = @divTrunc(5 * doy + 2, 153);
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m_raw: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    y += if (m_raw <= 2) @as(i64, 1) else @as(i64, 0);
    return .{
        .y = @intCast(y),
        .m = @intCast(m_raw),
        .d = @intCast(d),
    };
}

fn isoDateFromEpochMs(ms: i64, out: *[10]u8) bool {
    if (ms <= 0) return false;
    const secs: i64 = @divTrunc(ms, 1000);
    const days: i64 = @divTrunc(secs, 86400);
    const civ = civilFromDays(days);

    // Clamp year to 0000..9999 for fixed-width rendering.
    var y: i32 = civ.y;
    if (y < 0) y = 0;
    if (y > 9999) y = 9999;
    const yy: u32 = @intCast(y);

    out[0] = '0' + @as(u8, @intCast((yy / 1000) % 10));
    out[1] = '0' + @as(u8, @intCast((yy / 100) % 10));
    out[2] = '0' + @as(u8, @intCast((yy / 10) % 10));
    out[3] = '0' + @as(u8, @intCast(yy % 10));
    out[4] = '-';

    const mm: u8 = civ.m;
    out[5] = '0' + (mm / 10);
    out[6] = '0' + (mm % 10);
    out[7] = '-';

    const dd: u8 = civ.d;
    out[8] = '0' + (dd / 10);
    out[9] = '0' + (dd % 10);
    return true;
}

inline fn createdPrefixCols(created_ms: i64) usize {
    return if (created_ms != 0) CREATED_COLS else 0;
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
    try g_due_today.refresh(allocator, index);

    try resortAllVisible(allocator, index);
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


fn resortAllVisible(allocator: std.mem.Allocator, index: *const TaskIndex) !void {
    // Ensure today is current for due_today partitioning.
    const today = g_due_today.today_buf[0..];

    try view_sort.sortVisibleDueTodayPrioCreated(
        allocator,
        &g_sort_scratch,
        index.todoSlice(),
        g_visible_todo.items,
        today,
    );

    try view_sort.sortVisibleDueTodayPrioCreated(
        allocator,
        &g_sort_scratch,
        index.doneSlice(),
        g_visible_done.items,
        today,
    );

    // due_today view itself: already filtered to today, so only prio->created
    try view_sort.sortVisiblePrioCreated(
        allocator,
        &g_sort_scratch,
        index.todoSlice(),
        g_due_today.visible.items,
    );
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

        const orig_id = move_task.id;
        const orig_created = move_task.created_ms;

        var resurrect = move_task;

        resurrect.status = .todo;
        resurrect.repeat_next_ms = 0; // timer only re-armed on next completion
        //
        resurrect.id = orig_id;
        resurrect.created_ms = orig_created;

        try store.appendJsonTaskLine(allocator, &todo_file, resurrect);
        try store.rewriteJsonFileWithoutIndex(allocator, &done_file, dones, move_index);

        try ctx.index.reload(allocator, todo_file, done_file);

        try rebuildVisibleAll(allocator, ctx.index);

        // UI indices are clamped lazily in drawTodoList via activeView().
    }
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

    // feedback upon invalid input
    toast_buf: [96]u8 = undefined,
    toast_len: usize = 0,
    toast_until_ms: i64 = 0,
    toast_is_error: bool = false,


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

    pub fn toastClear(self: *EditorState) void {
        self.toast_len = 0;
        self.toast_until_ms = 0;
        self.toast_is_error = false;
    }

    pub fn toastActive(self: *const EditorState, now_ms: i64) bool {
        return self.toast_len != 0 and now_ms < self.toast_until_ms;
    }

    pub fn toastSlice(self: *const EditorState) []const u8 {
        return self.toast_buf[0..self.toast_len];
    }

    pub fn toastError(self: *EditorState, msg: []const u8) void {
        var n: usize = msg.len;
        if (n > self.toast_buf.len) n = self.toast_buf.len;
        @memcpy(self.toast_buf[0..n], msg[0..n]);
        self.toast_len = @intCast(n);
        self.toast_is_error = true;
        self.toast_until_ms = std.time.milliTimestamp() + 2500;
    }

    pub fn toastInfo(self: *EditorState, msg: []const u8) void {
        var n: usize = msg.len;
        if (n > self.toast_buf.len) n = self.toast_buf.len;
        @memcpy(self.toast_buf[0..n], msg[0..n]);
        self.toast_len = @intCast(n);
        self.toast_is_error = false;
        self.toast_until_ms = std.time.milliTimestamp() + 2000;
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



fn drawDueTodayView(win: vaxis.Window, index: *const TaskIndex, due_view: *ListView) void {
    const term_w: usize = @intCast(win.width);
    const term_h: usize = @intCast(win.height);
    if (term_w == 0 or term_h == 0) return;

    const today = g_due_today.todayIso();

    // var hdr_buf: [32]u8 = undefined;
    // const hdr = std.fmt.bufPrint(&hdr_buf, "DUE TODAY {s}", .{today}) catch "DUE TODAY";
    const hdr_style: vaxis.Style = .{ .bold = true };
    writeCenteredAscii2(win, 0, "DUE TODAY ", today, hdr_style);

    const hint_style: vaxis.Style = .{ .fg = .{ .index = 8 } };
    if (term_h >= 2) {
        drawCenteredText(win, @intCast(term_h - 1), "d: back   j/k: move", hint_style);
    }

    drawDueTodayList(win, index, due_view);
}

fn drawDueTodayList(win: vaxis.Window, index: *const TaskIndex, due_view: *ListView) void {
    const visible = g_due_today.visible.items;
    const todos = index.todoSlice();

    const term_h: usize = @intCast(win.height);
    if (term_h == 0) return;

    const list_start: usize = 2;
    const reserved_rows: usize = if (term_h > 1) 1 else 0;


    if (visible.len == 0) {
        const style: vaxis.Style = .{ .fg = .{ .index = 8 } };
        const mid_row_usize: usize = if (term_h == 0) 0 else @min(term_h / 2, term_h - 1);
        writeCenteredAscii2(win, @intCast(mid_row_usize), "", "No tasks due today", style);
        due_view.* = .{ .selected_index = 0, .scroll_offset = 0, .last_move = 0 };
        return;
    }

    drawTaskListCore(
        win,
        todos,
        visible,
        due_view,
        index.todoSpanRefs(),
        index.todoSpanPool(),
        list_start,
        reserved_rows,
        0,
        false,
    );
}

fn drawTaskListCore(
    win: vaxis.Window,
    tasks_all: []const Task,
    visible: []const usize,
    view: *ListView,
    span_refs: []const task_index.TextSpanRef,
    span_pool: []const task_index.TextSpan,
    list_start_row: usize,
    reserved_rows: usize,
    proj_pane_width: usize,
    suppress_indicator: bool,
) void {
    const term_height: usize = @intCast(win.height);
    const term_width: usize = @intCast(win.width);
    if (term_height == 0 or term_width == 0) return;
    if (visible.len == 0) return;

    if (term_height <= list_start_row + reserved_rows) return;
    const viewport_height: usize = term_height - list_start_row - reserved_rows;
    if (viewport_height == 0) return;

    if (view.selected_index >= visible.len) view.selected_index = visible.len - 1;
    if (view.scroll_offset >= visible.len) view.scroll_offset = 0;

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
    // const sel_style: vaxis.Style = .{
    //     .bold = true,
    //     .fg = .{ .index = 7 },
    // };
    // Distinct token hues; selection adds boldness without annihilating fg.
    const base_styles: LineStyleSet = .{
        .normal  = base_style,
        .project = .{ .fg = .{ .index = 2 } },
        .context = .{ .fg = .{ .index = 12 } },
        .due     = .{ .fg = .{ .index = 13 } },
    };
    var sel_styles: LineStyleSet = base_styles;
    sel_styles.normal.bold = true;
    sel_styles.project.bold = true;
    sel_styles.context.bold = true;
    sel_styles.due.bold = true;

    var row: usize = list_start_row;
    var remaining_rows: usize = viewport_height;
    var vi: usize = view.scroll_offset;

    while (vi < visible.len and remaining_rows > 0 and row < term_height) : (vi += 1) {

        const orig = visible[vi];
        if (orig >= tasks_all.len) {
            dbg("DBG: visible index OOB: orig={d} tasks_all.len={d} vi={d} visible.len={d}\n",
                .{ orig, tasks_all.len, vi, visible.len });
            break;
        }
        const task = tasks_all[orig];

        const selected = (view.selected_index == vi);

        const styles_ptr: *const LineStyleSet = if (selected) &sel_styles else &base_styles;

        if (orig >= span_refs.len) {
            // If this triggers, your span index fell out of sync with the task slices.
            break;
        }
        const ref = span_refs[orig];
        const first: usize = @intCast(ref.first);
        const count: usize = @intCast(ref.count);

        if (first + count > span_pool.len) break;
        const spans = span_pool[first .. first + count];

        var layout = computeLayout(task, content_width);
        if (layout.rows == 0) layout.rows = 1;
        if (layout.rows > remaining_rows) break;

        const row_u16: u16 = @intCast(row);

        if (arrow_col < win.width) {
            const g = if (selected and !suppress_indicator) indicator_slice else space_slice;
            _ = win.writeCell(arrow_col, row_u16, .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = styles_ptr.normal,
            });
        }

        if (pad_col < win.width) {
            _ = win.writeCell(pad_col, row_u16, .{
                .char = .{ .grapheme = space_slice, .width = 1 },
                .style = styles_ptr.normal,
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
            _ = win.writeCell(col_status, row_u16, .{
                .char = .{ .grapheme = status_text[s_i .. s_i + 1], .width = 1 },
                .style = styles_ptr.normal,
            });
            col_status += 1;
        }

        if (col_status < win.width) {
            _ = win.writeCell(col_status, row_u16, .{
                .char = .{ .grapheme = space_slice, .width = 1 },
                .style = styles_ptr.normal,
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
                styles_ptr.normal,
            );
        }

        if (content_width > layout.prefix) {
            const text_width = content_width - layout.prefix;
            drawWrappedTask(
                win,
                task,
                spans,
                row,
                @intCast(text_start_col),
                layout.rows,
                text_width,
                styles_ptr,
            );
        }

        row += layout.rows;
        remaining_rows -= layout.rows;
    }
}

fn moveListViewSelection(view: *ListView, len: usize, delta: i32) void {

    if (len == 0) {
        view.selected_index = 0;
        view.scroll_offset = 0;
        view.last_move = 0;
        return;
    }

    const cur: i32 = @intCast(view.selected_index);
    var next = cur + delta;
    if (next < 0) next = 0;
    const max: i32 = @intCast(len - 1);
    if (next > max) next = max;

    view.selected_index = @intCast(next);
    view.last_move = if (delta < 0) -1 else 1;
}



fn deleteAtOrig(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    focus: ListKind,
    orig_idx: usize,
) !void {
    const tasks: []const Task = if (focus == .todo)
        ctx.index.todoSlice()
    else
        ctx.index.doneSlice();

    if (orig_idx >= tasks.len) return;

    const victim = tasks[orig_idx];

    // Undo must own the bytes inside victim, do not store slices into file image.
    try g_undo.armDelete(allocator, focus, victim);
    // If you want positional restore:
    // try g_undo.armDeleteAt(allocator, focus, orig_idx, victim);

    if (focus == .todo) {
        var todo_file = ctx.todo_file.*;
        try store.rewriteJsonFileWithoutIndex(allocator, &todo_file, tasks, orig_idx);
    } else {
        var done_file = ctx.done_file.*;
        try store.rewriteJsonFileWithoutIndex(allocator, &done_file, tasks, orig_idx);
    }

    // Reload both. The file handle identity is what matters.
    try ctx.index.reload(allocator, ctx.todo_file.*, ctx.done_file.*);
    try rebuildVisibleAll(allocator, ctx.index);
}



fn visibleMain(focus: ListKind) []const usize {
    return visibleIndicesForFocus(focus);
}

// due_today is a projection over TODO originals; focus is ignored.
fn visibleDueToday(_: ListKind) []const usize {
    return g_due_today.visible.items;
}



fn deleteSelectedGeneric(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
    focus: ListKind,          // which backing file to delete from
    view: *ListView,          // pane-local view (ui.activeView() or due_view, etc.)
    visibleFn: VisibleFn,     // pane projection resolver
) !void {
    const visible_before = visibleFn(focus);
    if (visible_before.len == 0) return;

    clampViewToVisible(view, visible_before.len);

    const prev_sel = view.selected_index;
    const orig_idx = selectedOrigIndex(visible_before, view) orelse return;

    try deleteAtOrig(ctx, allocator, focus, orig_idx);

    // Re-clamp all canonical views defensively after reload/rebuild.
    clampViewToVisible(&ui.todo, visibleLenForFocus(.todo));
    clampViewToVisible(&ui.done, visibleLenForFocus(.done));

    // Re-resolve the projection after rebuild and preserve row when possible.
    const visible_after = visibleFn(focus);
    keepRowAfterRebuild(view, prev_sel, visible_after.len);
    view.last_move = -1;
}


inline fn selectedOrigIndex(visible: []const usize, view: *const ListView) ?usize {
    if (visible.len == 0) return null;
    if (view.selected_index >= visible.len) return null;
    return visible[view.selected_index]; // index into backing slice
}

inline fn clampViewToVisible(view: *ListView, visible_len: usize) void {
    if (visible_len == 0) {
        view.* = .{ .selected_index = 0, .scroll_offset = 0, .last_move = 0 };
        return;
    }
    if (view.selected_index >= visible_len) view.selected_index = visible_len - 1;
    if (view.scroll_offset >= visible_len) view.scroll_offset = 0;
}


inline fn selectedOrigFromVisible(view: *ListView, visible: []const usize) ?usize {
    clampViewToVisible(view, visible.len);
    return selectedOrigIndex(visible, view);
}

fn resetListView(view: *ListView) void {
    view.selected_index = 0;
    view.scroll_offset = 0;
    view.last_move = 0;
}


/// Handles:
///   - gg -> top
///   - G  -> bottom
/// Any non-'g' key cancels a pending 'g'.
fn handleVimJumpKeys(
    key: vaxis.Key,
    view: *ListView,
    visible_len: usize,
    pending_g: *bool,
) bool {
    if (key.matches('G', .{})) {
        pending_g.* = false;

        if (visible_len == 0) {
            resetListView(view);
        } else {
            view.selected_index = visible_len - 1;
            view.last_move = 1;
            // Let drawTaskListCore compute the correct scroll offset.
        }
        return true;
    }

    if (key.matches('g', .{})) {
        if (pending_g.*) {
            pending_g.* = false;

            if (visible_len == 0) {
                resetListView(view);
            } else {
                view.selected_index = 0;
                view.scroll_offset = 0;
                view.last_move = -1;
            }
        } else {
            pending_g.* = true;
        }
        return true;
    }

    pending_g.* = false;
    return false;
}


fn keepRowAfterRebuild(view: *ListView, prev_sel: usize, new_len: usize) void {
    if (new_len == 0) {
        view.* = .{ .selected_index = 0, .scroll_offset = 0, .last_move = 0 };
        return;
    }
    view.selected_index = if (prev_sel >= new_len) (new_len - 1) else prev_sel;
    if (view.scroll_offset >= new_len) view.scroll_offset = 0;
}


fn toggleTodoOngoingAtOrig(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    orig_idx: usize,
) !void {
    const todos = ctx.index.todoSlice();
    if (orig_idx >= todos.len) return;

    const old = todos[orig_idx];
    var updated = old;
    updated.status = if (old.status == .ongoing) .todo else .ongoing;
    updated.repeat_next_ms = 0;

    try g_undo.armReplace(allocator, .todo, old, updated);

    var todo_file = ctx.todo_file.*;
    try store.rewriteJsonFileReplacingIndex(allocator, &todo_file, todos, orig_idx, updated);

    try ctx.index.reload(allocator, todo_file, ctx.done_file.*);
    try rebuildVisibleAll(allocator, ctx.index);
}

fn toggleDoneAtOrig(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    focus: ListKind,      // .todo => move to done, .done => resurrect to todo
    orig_idx: usize,
) !void {
    if (focus == .todo) {
        const todos = ctx.index.todoSlice();
        if (orig_idx >= todos.len) return;

        const original = todos[orig_idx];
        const orig_id = original.id;
        const orig_created = original.created_ms;

        var moved = original;
        moved.status = .done;

        moved.repeat_next_ms = 0;
        if (moved.repeat.len != 0) {
            const now_ms = std.time.milliTimestamp();
            moved.repeat_next_ms = computeRepeatNextMs(moved.repeat, now_ms);
        }

        moved.id = orig_id;
        moved.created_ms = orig_created;

        try g_undo.armMove(allocator, .todo, .done, original, moved);

        var done_file = ctx.done_file.*;
        try store.appendJsonTaskLine(allocator, &done_file, moved);

        var todo_file = ctx.todo_file.*;
        try store.rewriteJsonFileWithoutIndex(allocator, &todo_file, todos, orig_idx);

        try ctx.index.reload(allocator, todo_file, done_file);
        try rebuildVisibleAll(allocator, ctx.index);
        return;
    }

    // focus == .done
    const dones = ctx.index.doneSlice();
    if (orig_idx >= dones.len) return;

    const original = dones[orig_idx];
    const orig_id = original.id;
    const orig_created = original.created_ms;

    var moved = original;
    moved.status = .todo;
    moved.repeat_next_ms = 0;

    moved.id = orig_id;
    moved.created_ms = orig_created;

    try g_undo.armMove(allocator, .done, .todo, original, moved);

    var todo_file = ctx.todo_file.*;
    try store.appendJsonTaskLine(allocator, &todo_file, moved);

    var done_file = ctx.done_file.*;
    try store.rewriteJsonFileWithoutIndex(allocator, &done_file, dones, orig_idx);

    try ctx.index.reload(allocator, todo_file, done_file);
    try rebuildVisibleAll(allocator, ctx.index);
}

fn toggleTodoOngoing(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    if (ui.focus != .todo) return;

    const view = ui.activeView();
    const visible = visibleIndicesForFocus(.todo);
    const prev_sel = view.selected_index;

    const orig_idx = selectedOrigFromVisible(view, visible) orelse return;
    try toggleTodoOngoingAtOrig(ctx, allocator, orig_idx);

    keepRowAfterRebuild(view, prev_sel, visibleLenForFocus(.todo));
}

fn toggleDoneTodo(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    ui: *UiState,
) !void {
    const focus = ui.focus;

    const view = ui.activeView();
    const visible = visibleIndicesForFocus(focus);
    const prev_sel = view.selected_index;

    const orig_idx = selectedOrigFromVisible(view, visible) orelse return;
    try toggleDoneAtOrig(ctx, allocator, focus, orig_idx);

    // Focus preserved; selection repaired for the same list kind.
    ui.focus = focus;
    const view2 = ui.activeView();
    keepRowAfterRebuild(view2, prev_sel, visibleLenForFocus(focus));
    view2.last_move = -1;
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
        .fg = .{ .index = 7 },
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
        .fg = .{ .index = 7 },
    };
    const style_active: vaxis.Style = .{
        .bold = true,
        .fg = .{ .index = 11 },
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



fn isAsciiSpace(b: u8) bool { return b == ' ' or b == '\t'; }

fn trimAsciiSpacesLocal(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isAsciiSpace(s[a])) : (a += 1) {}
    while (b > a and isAsciiSpace(s[b - 1])) : (b -= 1) {}
    return s[a..b];
}

fn triDueDate(raw: []const u8, out: *[10]u8) Tri {
    const s = trimAsciiSpacesLocal(raw);
    if (s.len == 0) return .empty;
    return if (dt.parseUserDueDateCanonical(s, out)) .ok else .invalid;
}

fn triDueTime(raw: []const u8, out: *[5]u8) Tri {
    const s = trimAsciiSpacesLocal(raw);
    if (s.len == 0) return .empty;
    return if (dt.parseUserDueTimeCanonical(s, out)) .ok else .invalid;
}

fn triRepeat(raw: []const u8, buf: *[16]u8) Tri {
    const s = trimAsciiSpacesLocal(raw);
    if (s.len == 0) return .empty;
    return if (parseRepeatCanonical(s, buf) != null) .ok else .invalid;
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


fn drawToastLine(win: vaxis.Window, msg: []const u8) void {
    if (win.height == 0) return;
    const row: u16 = win.height - 1;

    // Red foreground. Adjust to whatever your vaxis version expects.
    var style: vaxis.Style = .{};
    style.fg = .{ .index = 1 }; // if your palette index 1 is red
    // If you use RGB:
    // style.fg = .{ .rgb = .{ .r = 255, .g = 64, .b = 64 } };

    // Clear the row quickly.
    var x: u16 = 0;
    while (x < win.width) : (x += 1) {
        _ = win.writeCell(x, row, .{
            .char = .{ .grapheme = " "[0..1], .width = 1 },
            .style = .{},
        });
    }

    // Write message, truncated to width.
    const max = @as(usize, win.width);
    const n = if (msg.len < max) msg.len else max;

    x = 0;
    while (x < n) : (x += 1) {
        const slice = graphemeFromByte(msg[@intCast(x)]);
        _ = win.writeCell(x, row, .{
            .char = .{ .grapheme = slice, .width = 1 },
            .style = style,
        });
    }
}

fn drawEditorFooter(win: vaxis.Window, editor: *EditorState, new_flag: bool, done_flag: bool, edit_flag: bool) void {
    if (win.height == 0) return;

    const now_ms = std.time.milliTimestamp();
    if (editor.toast_len != 0 and now_ms >= editor.toast_until_ms) {
        editor.toastClear();
    }

    if (editor.cmd_active) {
        drawListCommandLine(win, true, new_flag, done_flag, edit_flag);
        return;
    }

    if (editor.toast_len != 0) {
        drawToastLine(win, editor.toastSlice());
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
    cursor_pos_raw: usize,
    focused: bool,
) void {
    if (top + 2 >= win.height) return;
    if (label_field_width + 3 >= win.width) return;

    const base_style: vaxis.Style = .{};
    const label_focus_style: vaxis.Style = .{ .bold = true };
    const cursor_style: vaxis.Style = .{ .bold = true, .reverse = true };

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
    if (col < win.width and col < label_field_width) {
        const sp = " "[0..1];
        _ = win.writeCell(col, mid_row, .{
            .char = .{ .grapheme = sp, .width = 1 },
            .style = base_style,
        });
        col += 1;
    }

    const available: usize = @intCast(win.width - label_field_width);
    if (available <= 3) return;

    const min_inner: usize = 8;
    const max_inner: usize = available - 2; // leave room for borders

    // Reserve one interior cell so cursor_pos==value.len is drawable.
    // Also tolerate cursor_pos drift by clamping later.
    var inner_w: usize = value.len + 1;
    if (inner_w < min_inner) inner_w = min_inner;
    if (inner_w > max_inner) inner_w = max_inner;

    const total_w: u16 = @intCast(inner_w + 2);
    const box_right: u16 = label_field_width + total_w - 1;
    if (box_right >= win.width) return;

    const box_bottom: u16 = top + 2;

    drawRect(win, label_field_width, top, box_right, box_bottom, base_style);

    // Clamp cursor into interior range [0 .. inner_w-1]
    const cursor_pos: usize = if (cursor_pos_raw < inner_w) cursor_pos_raw else (inner_w - 1);

    // Draw full interior width (clears stale glyphs), and apply cursor style at cursor_pos.
    const inner_left: u16 = label_field_width + 1;
    var x: u16 = inner_left;
    var j: usize = 0;
    while (j < inner_w and x < box_right) : (j += 1) {
        const g: []const u8 = if (j < value.len) value[j .. j + 1] else " "[0..1];
        const st: vaxis.Style = if (focused and cursor_pos == j) cursor_style else base_style;

        _ = win.writeCell(x, mid_row, .{
            .char = .{ .grapheme = g, .width = 1 },
            .style = st,
        });
        x += 1;
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

    const now_ms: i64 = std.time.milliTimestamp();

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


    // bottom-row feedback: toast dominates; otherwise hints.
    if (term_height > 0) {
        const hint = "i: insert   :w save+quit   :q quit   :p/:d/:r/:t focus meta fields";

        if (editor.toastActive(now_ms)) {
            // If ":" command-line is active, keep the last row for ":" input.
            const row_u: u16 = if (editor.cmd_active) blk: {
                if (term_height < 2) break :blk 0;
                break :blk @intCast(term_height - 2);
            } else @intCast(term_height - 1);

            const toast_style: vaxis.Style = if (editor.toast_is_error)
                .{ .fg = .{ .rgb = .{ 255, 80, 80 } }, .bold = true }
            else
                .{ .fg = .{ .rgb = .{ 180, 180, 180 } } };

            drawCenteredText(win, row_u, editor.toastSlice(), toast_style);
        } else if (term_height > 6 and !editor.cmd_active) {
            const hint_row: u16 = @intCast(term_height - 1);
            const hint_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 150, 150, 150 } },
            };
            drawCenteredText(win, hint_row, hint, hint_style);
        }
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
    if (win.height == 0 or win.width == 0) return;
    if (row >= win.height) return; // hard bound check

    const term_width: usize = @intCast(win.width);
    const len: usize = text.len;

    var start_col: usize = 0;
    if (term_width > len) start_col = (term_width - len) / 2;

    var col: usize = start_col;
    var i: usize = 0;
    while (i < len and col < term_width) : (i += 1) {
        const b: u8 = text[i];
        _ = win.writeCell(@intCast(col), row, .{
            .char = .{ .grapheme = graphemeFromByte(b), .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

fn writeCenteredAscii2(win: vaxis.Window, row: u16, a: []const u8, b: []const u8, style: vaxis.Style) void {
    if (win.height == 0 or win.width == 0) return;
    if (row >= win.height) return;

    const term_w: usize = @intCast(win.width);
    const total: usize = a.len + b.len;

    var start: usize = 0;
    if (term_w > total) start = (term_w - total) / 2;

    var col: usize = start;

    for (a) |ch| {
        if (col >= term_w) break;
        _ = win.writeCell(@intCast(col), row, .{
            .char = .{ .grapheme = graphemeFromByte(ch), .width = 1 },
            .style = style,
        });
        col += 1;
    }
    for (b) |ch| {
        if (col >= term_w) break;
        _ = win.writeCell(@intCast(col), row, .{
            .char = .{ .grapheme = graphemeFromByte(ch), .width = 1 },
            .style = style,
        });
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
    due_view: *ListView,        // <--- add
    return_view: *AppView,      // <--- add
) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        list_cmd_active.* = false;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
        return;
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
        return;
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        const src_view = view.*;

        if (list_cmd_new.*) {
            editor.* = EditorState.init();
            return_view.* = src_view; // <--- return where you came from
            view.* = .editor;
        } else if (list_cmd_done.*) {
            const focus: ListKind = if (src_view == .due_today) .todo else ui.focus;
            const visible: []const usize =
                if (src_view == .due_today) g_due_today.visible.items else visibleIndicesForFocus(focus);
            const lv: *ListView =
                if (src_view == .due_today) due_view else ui.activeView();

            if (visible.len != 0) {
                clampViewToVisible(lv, visible.len);
                const sel_visible = lv.selected_index;
                if (selectedOrigIndex(visible, lv)) |orig_idx| {
                    try toggleDoneAtOrig(ctx, allocator, focus, orig_idx);

                    // preserve row position post-rebuild
                    const visible2: []const usize =
                        if (src_view == .due_today) g_due_today.visible.items else visibleIndicesForFocus(focus);
                    const vlen2 = visible2.len;
                    if (vlen2 == 0) {
                        lv.* = .{ .selected_index = 0, .scroll_offset = 0, .last_move = 0 };
                    } else {
                        lv.selected_index = if (sel_visible >= vlen2) (vlen2 - 1) else sel_visible;
                        if (lv.scroll_offset >= vlen2) lv.scroll_offset = 0;
                        lv.last_move = -1;
                    }
                }
            }
        } else if (list_cmd_edit.*) {
            const src_focus: ListKind = if (src_view == .due_today) .todo else ui.focus;
            const tasks_all: []const Task = switch (src_focus) {
                .todo => ctx.index.todoSlice(),
                .done => ctx.index.doneSlice(),
            };
            const visible: []const usize =
                if (src_view == .due_today) g_due_today.visible.items else visibleIndicesForFocus(src_focus);
            const lv: *ListView =
                if (src_view == .due_today) due_view else ui.activeView();

            if (visible.len != 0) {
                clampViewToVisible(lv, visible.len);
                if (selectedOrigIndex(visible, lv)) |orig_idx| {
                    if (orig_idx < tasks_all.len) {
                        var e = EditorState.fromTask(tasks_all[orig_idx]);
                        e.editing_index = orig_idx;
                        e.editing_status = if (src_focus == .done) store.Status.done else store.Status.todo;

                        editor.* = e;
                        return_view.* = src_view; // <--- return to list or due_today
                        view.* = .editor;
                    }
                }
            }
        }

        list_cmd_active.* = false;
        list_cmd_new.* = false;
        list_cmd_done.* = false;
        list_cmd_edit.* = false;
        return;
    }

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
    if (key.matches('e', .{})) {
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


fn saveEditorToDisk(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !bool {
    if (editor.is_new) {
        return try saveNewTask(ctx, allocator, editor, ui);
    } else {
        return try saveExistingTask(ctx, allocator, editor, ui);
    }
}


fn saveExistingTask(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !bool {
    const editing_status = editor.editing_status;
    const focus: ListKind = if (editing_status == .done) .done else .todo;

    var file: fs.File = undefined;
    const tasks: []const Task = switch (editing_status) {
        .done => blk: { file = ctx.done_file.*; break :blk ctx.index.doneSlice(); },
        else  => blk: { file = ctx.todo_file.*; break :blk ctx.index.todoSlice(); },
    };

    if (tasks.len == 0 or editor.editing_index >= tasks.len) {
        editor.toastError("stale edit target");
        return false;
    }

    const old = tasks[editor.editing_index];

    var date_buf: [10]u8 = undefined;
    var time_buf: [5]u8 = undefined;

    var repeat_buf: [16]u8 = undefined;

    const v = validateEditorFields(editor, &date_buf, &time_buf, &repeat_buf);
    if (!v.ok) return false;

    var repeat_next_ms: i64 = 0;
    if (v.repeat.len != 0) {
        if (old.status == .done) {
            if (old.repeat_next_ms != 0 and std.mem.eql(u8, v.repeat, old.repeat)) {
                repeat_next_ms = old.repeat_next_ms;
            } else {
                const now_ms = std.time.milliTimestamp();
                repeat_next_ms = computeRepeatNextMs(v.repeat, now_ms);
            }
        }
    }

    const new_task: store.Task = .{
        .id            = old.id,
        .text          = editor.taskSlice(),
        .proj_first    = 0,
        .proj_count    = 0,
        .ctx_first     = 0,
        .ctx_count     = 0,
        .priority      = editor.priorityValue(),
        .status        = old.status,
        .due_date      = v.due_date,
        .due_time      = v.due_time,
        .repeat        = v.repeat,
        .repeat_next_ms = repeat_next_ms,
        .created_ms    = old.created_ms,
    };

    // Arm undo with a deep copy of BOTH tasks.
    // This must copy all slice fields out of old/new_task.
    try g_undo.armReplace(allocator, focus, old, new_task);

    try store.rewriteJsonFileReplacingIndex(
        allocator,
        &file,
        tasks,
        editor.editing_index,
        new_task,
    );

    try ctx.index.reload(allocator, ctx.todo_file.*, ctx.done_file.*);
    try rebuildVisibleAll(allocator, ctx.index);

    ui.focus = focus;

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
        const idx = if (editor.editing_index < new_slice.len) editor.editing_index else new_slice.len - 1;
        list_view.selected_index = idx;
        list_view.last_move = 0;
    }

    return true;
}


fn validateEditorFields(
    editor: *EditorState,
    date_buf: *[10]u8,
    time_buf: *[5]u8,
    repeat_buf: *[16]u8,
) struct {
    ok: bool,
    due_date: []const u8,
    due_time: []const u8,
    repeat: []const u8,
} {
    const raw_date = trimAsciiSpacesLocal(editor.dueSlice());
    const raw_time = trimAsciiSpacesLocal(editor.timeSlice());
    const raw_repeat = trimAsciiSpacesLocal(editor.repeatSlice());

    var due_date: []const u8 = &[_]u8{};
    var due_time: []const u8 = &[_]u8{};
    var repeat: []const u8 = &[_]u8{};

    var d: Tri = .empty;
    if (raw_date.len != 0) {
        d = if (dt.parseUserDueDateCanonical(raw_date, date_buf)) .ok else .invalid;
    }

    if (d == .invalid) {
        editor.toastError("invalid due date (use YYYY-MM-DD or D/M/YY)");
        return .{ .ok = false, .due_date = due_date, .due_time = due_time, .repeat = repeat };
    }

    // Due time tri-state; time requires date.
    var t: Tri = .empty;
    if (raw_time.len != 0) {
        t = if (dt.parseUserDueTimeCanonical(raw_time, time_buf)) .ok else .invalid;
    }
    if (d == .empty and t != .empty) {
        editor.toastError("due time requires a valid due date");
        return .{ .ok = false, .due_date = due_date, .due_time = due_time, .repeat = repeat };
    }

    if (d == .ok) {
        due_date = date_buf[0..];
        if (t == .invalid) {
            editor.toastError("invalid due time (use HH:MM, HHMM, or 1pm)");
            return .{ .ok = false, .due_date = due_date, .due_time = due_time, .repeat = repeat };
        }
        if (t == .ok) due_time = time_buf[0..];
    }

    // Repeat tri-state: empty clears; invalid refuses.
    if (raw_repeat.len != 0) {
        if (parseRepeatCanonical(raw_repeat, repeat_buf)) |canon| {
            repeat = canon;
        } else {
            editor.toastError("invalid repeat (examples: 2d, 3 weeks, 1h)");
            return .{ .ok = false, .due_date = due_date, .due_time = due_time, .repeat = repeat };
        }
    }

    return .{ .ok = true, .due_date = due_date, .due_time = due_time, .repeat = repeat };
}


fn saveNewTask(
    ctx: *TuiContext,
    allocator: std.mem.Allocator,
    editor: *EditorState,
    ui: *UiState,
) !bool {
    const text = editor.taskSlice();
    if (text.len == 0) {
        editor.toastError("empty task text");
        return false;
    }

    var date_buf: [10]u8 = undefined;
    var time_buf: [5]u8 = undefined;

    var repeat_buf: [16]u8 = undefined;
    const v = validateEditorFields(editor, &date_buf, &time_buf, &repeat_buf);
    if (!v.ok) return false;

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
        .due_date   = v.due_date,
        .due_time   = v.due_time,
        .repeat     = v.repeat,
        .repeat_next_ms = 0,
        .created_ms = now_ms,
    };

    try g_undo.armAdd(allocator, .todo, new_task);

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

    return true;
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

    const orig_id = original.id;
    const orig_created = original.created_ms;

    var moved = original;
    moved.status = .done;

    moved.repeat_next_ms = 0;
    if (moved.repeat.len != 0) {
        const now_ms = std.time.milliTimestamp();
        moved.repeat_next_ms = computeRepeatNextMs(moved.repeat, now_ms);
    }

    // Identity invariants: never change on status moves.
    moved.id = orig_id;
    moved.created_ms = orig_created;

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
    return_view: *AppView,
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
                view.* = return_view.*;
                return;
            }

            // :w or :wq -> save and exit
            if (std.mem.eql(u8, cmd, "w") or std.mem.eql(u8, cmd, "wq")) {
                const ok = try saveEditorToDisk(ctx, allocator, editor, ui);
                editor.resetCommand();

                if (ok) {
                    view.* = return_view.*;
                } else {
                    // Stay in editor, command-line closes, toast is visible.
                    editor.cmd_active = false;
                    editor.mode = .normal;
                }
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
    if (task.due_date.len == 0) return &[_]u8{};

    // " d:[" + payload + "]"
    if (buf.len < 6) return &[_]u8{};

    var pos: usize = 0;
    buf[pos] = ' '; pos += 1;
    buf[pos] = 'd'; pos += 1;
    buf[pos] = ':'; pos += 1;
    buf[pos] = '['; pos += 1;

    // payload
    const payload = dt.formatDueForSuffix(g_due_cfg, task.due_date, task.due_time, buf[pos .. buf.len - 1]);
    pos += payload.len;

    buf[pos] = ']'; pos += 1;
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

const LineStyleSet = struct {
    normal:  vaxis.Style,
    project: vaxis.Style,
    context: vaxis.Style,
    due:     vaxis.Style,
};

inline fn styleForSpanKind(styles: *const LineStyleSet, kind: task_index.TextSpanKind) vaxis.Style {
    return switch (kind) {
        .project => styles.project,
        .context => styles.context,
    };
}


/// Draw `<task.text>` optionally followed by ` d:[YYYY-MM-DD HH:MM]`,
/// wrapped into `max_rows` rows and `max_cols` columns, starting at
/// (start_row, col_offset).
fn drawWrappedTask(
    win: vaxis.Window,
    task: Task,
    spans: []const task_index.TextSpan,
    start_row: usize,
    col_offset: usize,
    max_rows: usize,
    max_cols: usize,
    styles: *const LineStyleSet,
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
    var span_i: usize = 0;

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

            // Select style by span for main text; suffix uses dedicated due style.
            var cell_style: vaxis.Style = undefined;
            if (j < main.len) {
                // Advance span cursor monotonically.
                while (span_i < spans.len and j >= spans[span_i].end) : (span_i += 1) {}

                if (span_i < spans.len and j >= spans[span_i].start and j < spans[span_i].end) {
                    cell_style = styleForSpanKind(styles, spans[span_i].kind);
                } else {
                    cell_style = styles.normal;
                }
            } else {
                cell_style = styles.due;
            }

            const cell: Cell = .{
                .char = .{ .grapheme = g, .width = 1 },
                .style = cell_style,
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

fn prefixWidthForTask(task: Task) usize {
    var w: usize = STATUS_WIDTH;
    w += createdPrefixCols(task.created_ms);
    if (task.priority != 0) {
        w += priorityLen(task.priority) + 1; // "P{digits} "
    }
    return w;
}

const TaskLayout = struct {
    prefix: usize,
    rows: usize,
};


fn computeLayout(task: Task, content_width: usize) TaskLayout {
    if (content_width == 0) {
        return .{ .prefix = 0, .rows = 0 };
    }

    const prefix = prefixWidthForTask(task);

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


fn computeProjectsPaneWidth(
    term_width: usize,
    index: *const TaskIndex,
    focus: ListKind,
) usize {
    // No projects => no sidebar.
    if (projectsForFocus(index, focus).len == 0) return 0;

    // Terminal too narrow => no sidebar.
    if (term_width < PROJECT_PANEL_MIN_TERM_WIDTH) return 0;

    const header_len: usize = "Projects".len;
    const max_label: usize = switch (focus) {
        .todo => index.projectsTodoMaxLabelLen(),
        .done => index.projectsDoneMaxLabelLen(),
    };
    const label_w: usize = if (max_label > header_len) max_label else header_len;

    // Layout invariant in drawProjectsPane:
    //   separator at col (pane_width - 1)
    //   gutter uses cols 0..1, text starts at col 2
    //   reserve 1 padding col before the separator
    //   => usable label cols = pane_width - 4
    var w: usize = label_w + 4;

    if (w < PROJECT_PANE_MIN_WIDTH) w = PROJECT_PANE_MIN_WIDTH;
    if (w > PROJECT_PANE_MAX_WIDTH) w = PROJECT_PANE_MAX_WIDTH;
    if (term_width <= w + PROJECT_PANEL_MIN_LIST_WIDTH) return 0;
    return w;
}


fn drawProjectsPane(win: vaxis.Window, index: *const TaskIndex, focus: ListKind) void {
    const term_width: usize = @intCast(win.width);
    const term_height: usize = @intCast(win.height);
    if (term_height == 0 or term_width == 0) return;

    const pane_width = computeProjectsPaneWidth(term_width, index, focus);
    if (pane_width == 0 or pane_width >= term_width) return;

    const right_col: usize = pane_width - 1;

    const projects = projectsForFocus(index, focus);

    const base_style: vaxis.Style = .{};

    const separator_style: vaxis.Style = .{

        .fg = .{ .index = 8 },
    };
    const header_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .index = 4},
    };
    const selected_style: vaxis.Style = .{
        .bold = true,
        .fg = .{ .index = 4 },
    };

    // separator
    var row: usize = 2;
    while (row < term_height-2) : (row += 1) {
        _ = win.writeCell(@intCast(right_col), @intCast(row), .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = separator_style,
        });
    }

    // header
    const header = "Projects";
    const usable_cols = if (right_col > 0) right_col else 0;

    var start_col: usize = 0;
    if (usable_cols > header.len) start_col = (usable_cols - header.len) / 2;

    const header_row: usize = if (term_height > 2) 2 else 0;
    var col: usize = start_col;
    var i: usize = 0;
    while (i < header.len and col < usable_cols) : (i += 1) {
        _ = win.writeCell(@intCast(col), @intCast(header_row), .{
            .char = .{ .grapheme = header[i .. i + 1], .width = 1 },
            .style = header_style,
        });
        col += 1;
    }

    if (projects.len == 0) return;

    // use per-tab selection (todo vs done), not g_projects_selected
    const sel_ptr = selectedProjectPtr(focus);
    if (sel_ptr.* >= projects.len) sel_ptr.* = projects.len - 1;
    const sel_idx = sel_ptr.*;

    var proj_row: usize = header_row + 2;
    if (proj_row >= term_height) return;

    // we draw in columns [0..right_col-1]
    const max_text_width = right_col;
    if (max_text_width == 0) return;

    // two-column gutter: [indicator][space], then text begins at col 2
    const text_col: usize = 2;
    if (right_col <= text_col) return;

    // max columns available for the ASCII label, staying left of separator
    const max_label_cols: usize = right_col - text_col;
    if (max_label_cols == 0) return;

    var idx: usize = 0;
    while (idx < projects.len and proj_row < term_height) : (idx += 1) {
        const entry = projects[idx];
        const is_sel = (idx == sel_idx);

        const selected_focused_style: vaxis.Style = selected_style;
        const selected_unfocused_style: vaxis.Style = .{
            .fg = selected_style.fg, // keep your color index
            .bold = false,           // your requested distinction
        };

        const row_style: vaxis.Style =
            if (is_sel)
                (if (g_projects_focus) selected_focused_style else selected_unfocused_style)
            else
                base_style;

        const row_u16: u16 = @intCast(proj_row);

        // gutter cell 0: indicator glyph
        _ = win.writeCell(0, row_u16, .{
            // pick one:
            // .char = .{ .grapheme = if (is_sel) ">" else " ", .width = 1 },
            .char = .{ .grapheme = if (is_sel) "❚" else " ", .width = 1 },
            .style = row_style,
        });

        // gutter cell 1: pad space, always present
        _ = win.writeCell(1, row_u16, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = base_style,
        });

        // build ASCII label (drawWrappedText cannot safely render UTF-8)
        var label_buf: [64]u8 = undefined;
        var pos: usize = 0;

        if (idx == 0) {
            const lit = "all";
            const n = @min(lit.len, label_buf.len);
            @memcpy(label_buf[0..n], lit[0..n]);
            pos = n;
        } else {
            label_buf[pos] = '+';
            pos += 1;

            const n = @min(entry.name.len, label_buf.len - pos);
            if (n != 0) {
                @memcpy(label_buf[pos .. pos + n], entry.name[0..n]);
                pos += n;
            }
        }

        const label = label_buf[0..pos];

        drawWrappedText(
            win,
            proj_row,
            text_col,        // text always starts after the gutter
            1,               // one row per project
            max_label_cols,  // stay left of the separator
            label,
            row_style,
        );

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

    const span_refs: []const task_index.TextSpanRef = switch (ui.focus) {
        .todo => index.todoSpanRefs(),
        .done => index.doneSpanRefs(),
    };
    const span_pool: []const task_index.TextSpan = switch (ui.focus) {
        .todo => index.todoSpanPool(),
        .done => index.doneSpanPool(),
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


    const proj_pane_width = computeProjectsPaneWidth(term_width, index, ui.focus);

    drawTaskListCore(
        win,
        tasks_all,
        visible,
        view,
        span_refs,
        span_pool,
        LIST_START_ROW,
        reserved_rows,
        proj_pane_width,
        g_projects_focus,
    );

}
