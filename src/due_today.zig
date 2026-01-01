const builtin = @import("builtin");
const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

const task_mod = @import("task_index.zig");
const TaskIndex = task_mod.TaskIndex;

const store = @import("task_store.zig");
const Task = store.Task;


fn dbg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args); // stderr; your 2>trace.log captures it
}

pub const DueToday = struct {
    visible: std.ArrayListUnmanaged(usize) = .{},

    today_buf: [10]u8 = "0000-00-00".*,
    today_valid: bool = false,

    pub fn deinit(self: *DueToday, allocator: std.mem.Allocator) void {
        self.visible.deinit(allocator);
        self.* = .{};
    }

    pub fn todayIso(self: *const DueToday) []const u8 {
        return self.today_buf[0..];
    }

    pub fn refresh(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex) !void {
        self.ensureTodayLocal();
        const today = self.today_buf[0..];

        self.visible.clearRetainingCapacity();

        const todos = index.todoSlice();
        try self.visible.ensureTotalCapacity(allocator, todos.len);

        for (todos, 0..) |t, i| {
            if (t.due_date.len != 10) continue;
            if (std.mem.eql(u8, t.due_date, today)) try self.visible.append(allocator, i);
        }
    }


    pub fn maybeRefresh(self: *DueToday, allocator: std.mem.Allocator, index: *const TaskIndex) !bool {
        var tmp: [10]u8 = undefined;
        if (!fillTodayLocalIso(&tmp)) return false;

        if (!self.today_valid or !std.mem.eql(u8, self.today_buf[0..], tmp[0..])) {
            self.today_buf = tmp;
            self.today_valid = true;
            try self.refreshNoRecalc(allocator, index, self.today_buf[0..]);
            return true;
        }
        return false;
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

    fn ensureTodayLocal(self: *DueToday) void {
        // Recompute if we have never computed, or if we are holding the sentinel.
        if (self.today_valid and !std.mem.eql(u8, self.today_buf[0..], "0000-00-00")) return;

        var tmp: [10]u8 = undefined;
        if (!fillTodayLocalIso(&tmp)) {
            self.today_buf = "0000-00-00".*;
            self.today_valid = true;
            dbg("due_today: fillTodayLocalIso failed, keeping sentinel\n", .{});
            return;
        }

        self.today_buf = tmp;
        self.today_valid = true;
    }
};



fn writeIso10(out: *[10]u8, year_in: i32, mon_in: i32, day_in: i32) bool {
    var year: i32 = year_in;
    if (year < 0) year = 0;
    if (year > 9999) year = 9999;

    var mon: i32 = mon_in;
    if (mon < 1) mon = 1;
    if (mon > 12) mon = 12;

    var day: i32 = day_in;
    if (day < 1) day = 1;
    if (day > 31) day = 31;

    const yy: u32 = @intCast(year);
    out.*[0] = '0' + @as(u8, @intCast((yy / 1000) % 10));
    out.*[1] = '0' + @as(u8, @intCast((yy / 100) % 10));
    out.*[2] = '0' + @as(u8, @intCast((yy / 10) % 10));
    out.*[3] = '0' + @as(u8, @intCast(yy % 10));
    out.*[4] = '-';

    const mm: u8 = @intCast(mon);
    out.*[5] = '0' + (mm / 10);
    out.*[6] = '0' + (mm % 10);
    out.*[7] = '-';

    const dd: u8 = @intCast(day);
    out.*[8] = '0' + (dd / 10);
    out.*[9] = '0' + (dd % 10);
    return true;
}

fn fillTodayLocalIso(out: *[10]u8) bool {
    c.tzset();

    const now: c.time_t = c.time(null);
    if (now == @as(c.time_t, -1)) {
        dbg("due_today: c.time(null) returned -1\n", .{});
        return false;
    }

    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&now, &tm) == null) {
        dbg("due_today: localtime_r returned null\n", .{});
        return false;
    }

    const year: i32 = @intCast(tm.tm_year + 1900);
    const mon:  i32 = @intCast(tm.tm_mon + 1);
    const mday: i32 = @intCast(tm.tm_mday);

    if (!writeIso10(out, year, mon, mday)) {
        dbg("due_today: writeIso10 failed y={d} m={d} d={d}\n", .{ year, mon, mday });
        return false;
    }
    return true;
}
