const std = @import("std");
const mem = std.mem;

const Task = @import("task_index.zig").Task;

pub const Scratch = struct {
    tmp: std.ArrayListUnmanaged(usize) = .{},

    pub fn deinit(self: *Scratch, allocator: mem.Allocator) void {
        self.tmp.deinit(allocator);
        self.* = undefined;
    }

    fn ensure(self: *Scratch, allocator: mem.Allocator, n: usize) ![]usize {
        try self.tmp.ensureTotalCapacity(allocator, n);
        self.tmp.items.len = n;
        return self.tmp.items[0..n];
    }
};

fn isDueToday(t: Task, today_iso: []const u8) bool {
    return t.due_date.len == 10 and mem.eql(u8, t.due_date, today_iso);
}

fn prioRankDesc(p0: u8) usize {
    // Higher priority first. Treat 0 as lowest. Clamp to 9.
    var p = p0;
    if (p > 9) p = 9;
    return @intCast(9 - p); // 0 is highest bucket
}

/// Stable bucket sort on visible ordinals.
/// Key: due_today first, then priority descending.
/// Stability preserves original scan order, which is your created-ascending tie-break.
pub fn sortVisibleDueTodayPrioCreated(
    allocator: mem.Allocator,
    scratch: *Scratch,
    tasks: []const Task,
    visible: []usize,
    today_iso: []const u8,
) !void {
    if (visible.len <= 1) return;

    const out = try scratch.ensure(allocator, visible.len);

    // 2 * 10 buckets
    var counts: [20]usize = [_]usize{0} ** 20;

    var i: usize = 0;
    while (i < visible.len) : (i += 1) {
        const ord = visible[i];
        const t = tasks[ord];

        const due_group: usize = if (isDueToday(t, today_iso)) 0 else 1;
        const b: usize = due_group * 10 + prioRankDesc(t.priority);
        counts[b] += 1;
    }

    // prefix sums -> starting offsets
    var sum: usize = 0;
    var b: usize = 0;
    while (b < counts.len) : (b += 1) {
        const n = counts[b];
        counts[b] = sum;
        sum += n;
    }

    // stable scatter
    i = 0;
    while (i < visible.len) : (i += 1) {
        const ord = visible[i];
        const t = tasks[ord];

        const due_group: usize = if (isDueToday(t, today_iso)) 0 else 1;
        const bucket: usize = due_group * 10 + prioRankDesc(t.priority);

        const p = counts[bucket];
        out[p] = ord;
        counts[bucket] = p + 1;
    }

    mem.copyForwards(usize, visible, out);
}

pub fn sortVisiblePrioCreated(
    allocator: mem.Allocator,
    scratch: *Scratch,
    tasks: []const Task,
    visible: []usize,
) !void {
    if (visible.len <= 1) return;

    const out = try scratch.ensure(allocator, visible.len);

    var counts: [10]usize = [_]usize{0} ** 10;

    var i: usize = 0;
    while (i < visible.len) : (i += 1) {
        const ord = visible[i];
        const t = tasks[ord];
        counts[prioRankDesc(t.priority)] += 1;
    }

    var sum: usize = 0;
    var r: usize = 0;
    while (r < 10) : (r += 1) {
        const n = counts[r];
        counts[r] = sum;
        sum += n;
    }

    i = 0;
    while (i < visible.len) : (i += 1) {
        const ord = visible[i];
        const t = tasks[ord];
        const bucket = prioRankDesc(t.priority);

        const p = counts[bucket];
        out[p] = ord;
        counts[bucket] = p + 1;
    }

    mem.copyForwards(usize, visible, out);
}
