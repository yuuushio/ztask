const std = @import("std");
const builtin = @import("builtin");

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;
const Task = task_mod.Task;

const c = @cImport({
    @cInclude("time.h");
});

pub const DueToday = struct {
    visible: std.ArrayListUnmanaged(usize) = .{},
    cached_key: i64 = std.math.minInt(i64),
    today_iso: [10]u8 = "1970-01-01".*,

    pub fn deinit(self: *DueToday, allocator: std.mem.Allocator) void {
        self.visible.deinit(allocator);
        self.* = .{};
    }

    pub fn todayIso(self: *const DueToday) []const u8 {
        return self.today_iso[0..10];
    }

    pub fn refresh(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex) !void {
        const t = getLocalToday();
        self.cached_key = t.key;
        self.today_iso = t.iso;
        try self.rebuildWithIso(allocator, index, self.todayIso());
    }

    pub fn maybeRefresh(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex) !void {
        const t = getLocalToday();
        if (t.key == self.cached_key) return;

        self.cached_key = t.key;
        self.today_iso = t.iso;
        try self.rebuildWithIso(allocator, index, self.todayIso());
    }

    fn rebuildWithIso(
        self: *DueToday,
        allocator: std.mem.Allocator,
        index: *const TaskIndex,
        today: []const u8,
    ) !void {
        self.visible.clearRetainingCapacity();

        const todos = index.todoSlice();
        if (todos.len == 0) return;

        try self.visible.ensureTotalCapacity(allocator, todos.len);

        for (todos, 0..) |t, ti| {
            if (t.status == .done) continue;
            if (t.due_date.len != 10) continue;
            if (std.mem.eql(u8, t.due_date, today)) {
                try self.visible.append(allocator, ti);
            }
        }
    }

    fn getLocalToday() struct { key: i64, iso: [10]u8 } {
        comptime {
            if (!builtin.link_libc) {
                @compileError("due_today requires libc for local civil date (localtime_r). Build with libc enabled.");
            }
        }

        var out: [10]u8 = undefined;

        var now: c.time_t = @intCast(std.time.timestamp());
        var tm: c.tm = undefined;
        if (c.localtime_r(&now, &tm) == null) {
            return .{ .key = 0, .iso = "1970-01-01".* };
        }

        const year: i32 = @intCast(tm.tm_year + 1900);
        const mon: u8 = @intCast(tm.tm_mon + 1);
        const day: u8 = @intCast(tm.tm_mday);

        write4(out[0..4], year);
        out[4] = '-';
        write2(out[5..7], mon);
        out[7] = '-';
        write2(out[8..10], day);

        // Key that changes once per local calendar day.
        const key: i64 =
            @as(i64, @intCast(tm.tm_year)) * 400 +
            @as(i64, @intCast(tm.tm_yday));

        return .{ .key = key, .iso = out };
    }

    fn write2(dst: []u8, v: u8) void {
        dst[0] = '0' + @as(u8, @intCast(v / 10));
        dst[1] = '0' + @as(u8, @intCast(v % 10));
    }

    fn write4(dst: []u8, y: i32) void {
        var yy: u32 = if (y < 0) 0 else @intCast(y);
        if (yy > 9999) yy = 9999;
        dst[0] = '0' + @as(u8, @intCast((yy / 1000) % 10));
        dst[1] = '0' + @as(u8, @intCast((yy / 100) % 10));
        dst[2] = '0' + @as(u8, @intCast((yy / 10) % 10));
        dst[3] = '0' + @as(u8, @intCast(yy % 10));
    }
};
