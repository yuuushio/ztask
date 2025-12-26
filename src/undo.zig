const std = @import("std");
const fs = std.fs;

const store = @import("task_store.zig");
const task_mod = @import("task_index.zig");
const ui_mod = @import("ui_state.zig");

const TaskIndex = task_mod.TaskIndex;
const Task = task_mod.Task;
const ListKind = ui_mod.ListKind;

pub const Undo = struct {
    const Mode = enum { empty, applied, undone };

    const Add = struct { focus: ListKind, id: u64, task: Task };
    const Delete = struct { focus: ListKind, id: u64, task: Task };
    const Replace = struct { focus: ListKind, id: u64, old: Task, new: Task };
    const Move = struct { from: ListKind, to: ListKind, id: u64, old: Task, new: Task };

    const Action = union(enum) { add: Add, delete: Delete, replace: Replace, move: Move };

    mode: Mode = .empty,
    buf: []u8 = &[_]u8{},
    action: Action = undefined,

    pub fn deinit(self: *Undo, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *Undo, allocator: std.mem.Allocator) void {
        if (self.buf.len != 0) allocator.free(self.buf);
        self.* = .{ .mode = .empty, .buf = &[_]u8{} };
    }

    inline fn take(buf: []u8, pos: *usize, s: []const u8) []const u8 {
        if (s.len == 0) return &[_]u8{};
        const out = buf[pos.* .. pos.* + s.len];
        @memcpy(out, s);
        pos.* += s.len;
        return out;
    }

    fn cloneTaskInto(buf: []u8, pos: *usize, src: Task) Task {
        const text = take(buf, pos, src.text);
        const due_date = take(buf, pos, src.due_date);
        const due_time = take(buf, pos, src.due_time);
        const repeat = take(buf, pos, src.repeat);

        return .{
            .id = src.id,
            .text = text,
            .proj_first = 0,
            .proj_count = 0,
            .ctx_first = 0,
            .ctx_count = 0,
            .priority = src.priority,
            .status = src.status,
            .due_date = due_date,
            .due_time = due_time,
            .repeat = repeat,
            .repeat_next_ms = src.repeat_next_ms,
            .created_ms = src.created_ms,
        };
    }

    fn allocForOne(allocator: std.mem.Allocator, t: Task) !struct { buf: []u8, pos: usize } {
        const total = t.text.len + t.due_date.len + t.due_time.len + t.repeat.len;
        return .{ .buf = try allocator.alloc(u8, total), .pos = 0 };
    }

    fn allocForTwo(allocator: std.mem.Allocator, a: Task, b: Task) !struct { buf: []u8, pos: usize } {
        const total =
            a.text.len + a.due_date.len + a.due_time.len + a.repeat.len +
            b.text.len + b.due_date.len + b.due_time.len + b.repeat.len;
        return .{ .buf = try allocator.alloc(u8, total), .pos = 0 };
    }

    pub fn armAdd(self: *Undo, allocator: std.mem.Allocator, focus: ListKind, t: Task) !void {
        self.clear(allocator);
        var mem = try allocForOne(allocator, t);
        const cloned = cloneTaskInto(mem.buf, &mem.pos, t);
        self.buf = mem.buf;
        self.action = .{ .add = .{ .focus = focus, .id = t.id, .task = cloned } };
        self.mode = .applied;
    }

    pub fn armDelete(self: *Undo, allocator: std.mem.Allocator, focus: ListKind, t: Task) !void {
        self.clear(allocator);
        var mem = try allocForOne(allocator, t);
        const cloned = cloneTaskInto(mem.buf, &mem.pos, t);
        self.buf = mem.buf;
        self.action = .{ .delete = .{ .focus = focus, .id = t.id, .task = cloned } };
        self.mode = .applied;
    }

    pub fn armReplace(self: *Undo, allocator: std.mem.Allocator, focus: ListKind, old: Task, new: Task) !void {
        self.clear(allocator);
        var mem = try allocForTwo(allocator, old, new);
        const oldc = cloneTaskInto(mem.buf, &mem.pos, old);
        const newc = cloneTaskInto(mem.buf, &mem.pos, new);
        self.buf = mem.buf;
        self.action = .{ .replace = .{ .focus = focus, .id = old.id, .old = oldc, .new = newc } };
        self.mode = .applied;
    }

    pub fn armMove(self: *Undo, allocator: std.mem.Allocator, from: ListKind, to: ListKind, old: Task, new: Task) !void {
        self.clear(allocator);
        var mem = try allocForTwo(allocator, old, new);
        const oldc = cloneTaskInto(mem.buf, &mem.pos, old);
        const newc = cloneTaskInto(mem.buf, &mem.pos, new);
        self.buf = mem.buf;
        self.action = .{ .move = .{ .from = from, .to = to, .id = old.id, .old = oldc, .new = newc } };
        self.mode = .applied;
    }

    inline fn findIndexById(tasks: []const Task, id: u64) ?usize {
        var i: usize = 0;
        while (i < tasks.len) : (i += 1) {
            if (tasks[i].id == id) return i;
        }
        return null;
    }

    fn filePtrForFocus(todo_file: *fs.File, done_file: *fs.File, focus: ListKind) *fs.File {
        return switch (focus) {
            .todo => todo_file,
            .done => done_file,
        };
    }

    fn sliceForFocus(index: *const TaskIndex, focus: ListKind) []const Task {
        return switch (focus) {
            .todo => index.todoSlice(),
            .done => index.doneSlice(),
        };
    }

    fn deleteById(
        allocator: std.mem.Allocator,
        index: *const TaskIndex,
        todo_file: *fs.File,
        done_file: *fs.File,
        focus: ListKind,
        id: u64,
    ) !void {
        const tasks = sliceForFocus(index, focus);
        const idx = findIndexById(tasks, id) orelse return;
        var file = filePtrForFocus(todo_file, done_file, focus).*;
        try store.rewriteJsonFileWithoutIndex(allocator, &file, tasks, idx);
        filePtrForFocus(todo_file, done_file, focus).* = file;
    }

    fn replaceById(
        allocator: std.mem.Allocator,
        index: *const TaskIndex,
        todo_file: *fs.File,
        done_file: *fs.File,
        focus: ListKind,
        id: u64,
        t: Task,
    ) !void {
        const tasks = sliceForFocus(index, focus);
        const idx = findIndexById(tasks, id) orelse return;
        var file = filePtrForFocus(todo_file, done_file, focus).*;
        try store.rewriteJsonFileReplacingIndex(allocator, &file, tasks, idx, t);
        filePtrForFocus(todo_file, done_file, focus).* = file;
    }

    fn appendTo(
        allocator: std.mem.Allocator,
        todo_file: *fs.File,
        done_file: *fs.File,
        focus: ListKind,
        t: Task,
    ) !void {
        var file = filePtrForFocus(todo_file, done_file, focus).*;
        try store.appendJsonTaskLine(allocator, &file, t);
        filePtrForFocus(todo_file, done_file, focus).* = file;
    }

    fn applyUndo(self: *Undo, allocator: std.mem.Allocator, index: *TaskIndex, todo_file: *fs.File, done_file: *fs.File) !void {
        switch (self.action) {
            .add => |a| {
                try deleteById(allocator, index, todo_file, done_file, a.focus, a.id);
            },
            .delete => |d| {
                try appendTo(allocator, todo_file, done_file, d.focus, d.task);
            },
            .replace => |r| {
                try replaceById(allocator, index, todo_file, done_file, r.focus, r.id, r.old);
            },
            .move => |m| {
                try deleteById(allocator, index, todo_file, done_file, m.to, m.id);
                try appendTo(allocator, todo_file, done_file, m.from, m.old);
            },
        }
    }

    fn applyRedo(self: *Undo, allocator: std.mem.Allocator, index: *TaskIndex, todo_file: *fs.File, done_file: *fs.File) !void {
        switch (self.action) {
            .add => |a| {
                try appendTo(allocator, todo_file, done_file, a.focus, a.task);
            },
            .delete => |d| {
                try deleteById(allocator, index, todo_file, done_file, d.focus, d.id);
            },
            .replace => |r| {
                try replaceById(allocator, index, todo_file, done_file, r.focus, r.id, r.new);
            },
            .move => |m| {
                try deleteById(allocator, index, todo_file, done_file, m.from, m.id);
                try appendTo(allocator, todo_file, done_file, m.to, m.new);
            },
        }
    }

    /// Toggle last mutation: applied -> undone -> applied ...
    pub fn toggle(
        self: *Undo,
        allocator: std.mem.Allocator,
        index: *TaskIndex,
        todo_file: *fs.File,
        done_file: *fs.File,
    ) !void {
        switch (self.mode) {
            .empty => return,
            .applied => {
                try self.applyUndo(allocator, index, todo_file, done_file);
                try index.reload(allocator, todo_file.*, done_file.*);
                self.mode = .undone;
            },
            .undone => {
                try self.applyRedo(allocator, index, todo_file, done_file);
                try index.reload(allocator, todo_file.*, done_file.*);
                self.mode = .applied;
            },
        }
    }
};
