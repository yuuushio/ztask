const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("time.h");
});

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const store = @import("task_store.zig");
const Task = store.Task;

pub const DueToday = struct {
    visible: std.ArrayListUnmanaged(usize) = .{},

    today_buf: [10]u8 = [_]u8{'0'} ** 10,
    today_valid: bool = false,

    pub fn deinit(self: *DueToday, allocator: std.mem.Allocator) void {
        self.visible.deinit(allocator);
        self.* = .{};
    }

    pub fn todayIso(self: *const DueToday) []const u8 {
        return self.today_buf[0..];
    }

    pub fn refresh(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex) !void {
        try self.ensureTodayLocal();

        const today = self.today_buf[0..];

        self.visible.clearRetainingCapacity();

        const todos = index.todoSlice();
        try self.visible.ensureTotalCapacity(allocator, todos.len);

        for (todos, 0..) |t, i| {
            // Defensive: only canonical ISO dates qualify.
            if (t.due_date.len != 10) continue;
            if (std.mem.eql(u8, t.due_date, today)) {
                try self.visible.append(allocator, i); // index into todoSlice()
            }
        }
    }

    pub fn maybeRefresh(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex) !void {
        var tmp: [10]u8 = undefined;
        if (!fillTodayLocalIso(&tmp)) return;

        if (!self.today_valid or !std.mem.eql(u8, self.today_buf[0..], tmp[0..])) {
            self.today_buf = tmp;
            self.today_valid = true;
            try self.refreshNoRecalc(allocator, index, self.today_buf[0..]);
        }
    }

    fn refreshNoRecalc(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex, today: []const u8) !void {
        self.visible.clearRetainingCapacity();

        const todos = index.todoSlice();
        try self.visible.ensureTotalCapacity(allocator, todos.len);

        for (todos, 0..) |t, i| {
            if (t.due_date.len != 10) continue;
            if (std.mem.eql(u8, t.due_date, today)) {
                try self.visible.append(allocator, i);
            }
        }
    }

    fn ensureTodayLocal(self: *DueToday) !void {
        if (self.today_valid) return;

        var tmp: [10]u8 = undefined;
        if (!fillTodayLocalIso(&tmp)) {
            // Fail closed: keep a stable sentinel instead of returning a dangling slice.
            self.today_buf = [_]u8{'0'} ** 10;
            self.today_valid = true;
            return;
        }

        self.today_buf = tmp;
        self.today_valid = true;
    }
};

fn fillTodayLocalIso(out: *[10]u8) bool {
    comptime {
        if (@hasDecl(builtin, "link_libc") and !builtin.link_libc) {
            @compileError("due_today requires libc for local civil date (localtime_r). Build with libc enabled.");
        }
    }

    var now: c.time_t = @intCast(std.time.timestamp());

    var tm: c.struct_tm = undefined;

    // If this fails, you can either return false (your current behavior)
    // or fall back to UTC via gmtime_r. Returning false is fine because
    // ensureTodayLocal fails closed.
    if (c.localtime_r(&now, &tm) == null) {
        if (c.gmtime_r(&now, &tm) == null) return false;
    }

    const year: i32 = tm.tm_year + 1900;
    const mon:  i32 = tm.tm_mon + 1;
    const mday: i32 = tm.tm_mday;

    const s = std.fmt.bufPrint(out.*[0..], "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, mon, mday }) catch return false;
    return s.len == 10;
}
