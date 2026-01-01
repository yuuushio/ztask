const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const math = std.math;
const store = @import("task_store.zig");

pub const Task = store.Task;
pub const Status = store.Status;
pub const FileImage = store.FileImage;

pub const TextSpanKind = enum(u8) {
    project,
    context,
};

/// Byte-span into Task.text.
pub const TextSpan = packed struct {
    start: u32, // inclusive byte index
    end:   u32, // exclusive byte index
    kind:  TextSpanKind,
};

/// Span range for one task, referencing into a pool slice.
pub const TextSpanRef = packed struct {
    first: u32,
    count: u16,
};


const ProjectAgg = struct {
    count_todo: usize,
    count_done: usize,
};


const ProjectMap = std.StringHashMap(ProjectAgg);

pub const ProjectEntry = struct {
    name: []const u8,   // slice into existing task.text storage
    count_todo: usize,
    count_done: usize,
};

fn maxProjectLabelLen(entries: []const ProjectEntry) u16 {
    if (entries.len == 0) return 0;

    // Rendered labels in tui:
    //   idx 0: "all"
    //   idx >0: "+" ++ name
    var max_len: usize = entries[0].name.len;
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const n = entries[i].name.len + 1;
        if (n > max_len) max_len = n;
    }
    return if (max_len > math.maxInt(u16)) math.maxInt(u16) else @intCast(max_len);
}

fn sortSpansByStart(spans: []TextSpan) void {
    // Insertion sort. Span counts are tiny; O(n^2) stays trivial and allocation-free.
    var i: usize = 1;
    while (i < spans.len) : (i += 1) {
        const key = spans[i];
        var j: usize = i;
        while (j > 0 and spans[j - 1].start > key.start) : (j -= 1) {
            spans[j] = spans[j - 1];
        }
        spans[j] = key;
    }
}

const SpanIndex = struct {
    refs: []TextSpanRef,
    pool: []TextSpan,
};

fn buildSpanIndexForTasks(
    allocator: mem.Allocator,
    tasks: []const store.Task,
) !SpanIndex {
    const refs = try allocator.alloc(TextSpanRef, tasks.len);
    errdefer allocator.free(refs);

    var pool_list: std.ArrayListUnmanaged(TextSpan) = .{};
    errdefer pool_list.deinit(allocator);

    // Heuristic: most tasks have 0–4 tags worth styling.
    try pool_list.ensureTotalCapacity(allocator, tasks.len * 4);

    var ti: usize = 0;
    while (ti < tasks.len) : (ti += 1) {
        const t = tasks[ti];

        const first_u32: u32 = @intCast(pool_list.items.len);
        var count_u16: u16 = 0;

        // +projects
        {
            var tags: [16][]const u8 = undefined;
            var n: usize = 0;
            store.collectTags(t.text, '+', &tags, &n);

            var k: usize = 0;
            while (k < n) : (k += 1) {
                const name = tags[k];
                if (name.len == 0) continue;

                const off_usize: usize =
                    @intFromPtr(name.ptr) - @intFromPtr(t.text.ptr);
                if (off_usize == 0) continue;
                if (t.text[off_usize - 1] != '+') continue;

                const start_usize = off_usize - 1;
                const end_usize = off_usize + name.len;

                // u32 range is ample for a task line.
                try pool_list.append(allocator, .{
                    .start = @intCast(start_usize),
                    .end   = @intCast(end_usize),
                    .kind  = .project,
                });
                if (count_u16 != std.math.maxInt(u16)) count_u16 += 1;
            }
        }

        // #contexts
        {
            var tags: [16][]const u8 = undefined;
            var n: usize = 0;
            store.collectTags(t.text, '#', &tags, &n);

            var k: usize = 0;
            while (k < n) : (k += 1) {
                const name = tags[k];
                if (name.len == 0) continue;

                const off_usize: usize =
                    @intFromPtr(name.ptr) - @intFromPtr(t.text.ptr);
                if (off_usize == 0) continue;
                if (t.text[off_usize - 1] != '#') continue;

                const start_usize = off_usize - 1;
                const end_usize = off_usize + name.len;

                try pool_list.append(allocator, .{
                    .start = @intCast(start_usize),
                    .end   = @intCast(end_usize),
                    .kind  = .context,
                });
                if (count_u16 != std.math.maxInt(u16)) count_u16 += 1;
            }
        }

        // Ensure sorted spans for monotone scan in the renderer.
        const span_count: usize = @intCast(count_u16);
        if (span_count > 1) {
            const first = @as(usize, @intCast(first_u32));
            sortSpansByStart(pool_list.items[first .. first + span_count]);
        }

        refs[ti] = .{
            .first = first_u32,
            .count = count_u16,
        };
    }

    const pool = try pool_list.toOwnedSlice(allocator);
    errdefer allocator.free(pool);

    return .{ .refs = refs, .pool = pool };
}


fn buildProjectsIndexForTasks(
    allocator: std.mem.Allocator,
    tasks: []const store.Task,
) ![]ProjectEntry {
    var project_map = ProjectMap.init(allocator);
    defer project_map.deinit();

    var all_todo: usize = 0;
    var all_done: usize = 0;

    var ti: usize = 0;
    while (ti < tasks.len) : (ti += 1) {
        const t = tasks[ti];
        if (t.status == .done) all_done += 1 else all_todo += 1;

        var proj_tags: [16][]const u8 = undefined;
        var proj_count: usize = 0;
        store.collectTags(t.text, '+', &proj_tags, &proj_count);

        var k: usize = 0;
        while (k < proj_count) : (k += 1) {
            const name = proj_tags[k];
            if (name.len == 0) continue;

            const gop = try project_map.getOrPut(name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .count_todo = 0, .count_done = 0 };
            }
            if (t.status == .done) gop.value_ptr.count_done += 1 else gop.value_ptr.count_todo += 1;
        }
    }

    const entries = try allocator.alloc(ProjectEntry, project_map.count() + 1);

    // index 0 = ALL (no filter)
    entries[0] = .{
        .name = "all",
        .count_todo = all_todo,
        .count_done = all_done,
    };

    var it = project_map.iterator();
    var i: usize = 1;
    while (it.next()) |e| {
        entries[i] = .{
            .name = e.key_ptr.*,
            .count_todo = e.value_ptr.count_todo,
            .count_done = e.value_ptr.count_done,
        };
        i += 1;
    }

    return entries;
}

pub const TaskIndex = struct {
    todo_img: FileImage,
    done_img: FileImage,

    // Views
    todo: []const Task,
    done: []const Task,

    projects_todo: []ProjectEntry,
    projects_done: []ProjectEntry,

    projects_todo_max_label: u16,
    projects_done_max_label: u16,

    // Precomputed styling spans for Task.text, keyed by task ordinal.
    todo_span_refs: []TextSpanRef,
    done_span_refs: []TextSpanRef,
    todo_span_pool: []TextSpan,
    done_span_pool: []TextSpan,

    inline fn freeIfNonEmpty(allocator: mem.Allocator, s: anytype) void {
        if (s.len != 0) allocator.free(s);
    }

    pub fn todoSlice(self: *const TaskIndex) []const Task {
        return self.todo_img.tasks;
    }

    pub fn doneSlice(self: *const TaskIndex) []const Task {
        return self.done_img.tasks;
    }

    pub fn projectsTodoSlice(self: *const TaskIndex) []const ProjectEntry {
        return self.projects_todo;
    }
    pub fn projectsDoneSlice(self: *const TaskIndex) []const ProjectEntry {
        return self.projects_done;
    }

    pub fn projectsTodoMaxLabelLen(self: *const TaskIndex) usize {
        return self.projects_todo_max_label;
    }
    pub fn projectsDoneMaxLabelLen(self: *const TaskIndex) usize {
        return self.projects_done_max_label;
    }

    pub fn todoSpanRefs(self: *const TaskIndex) []const TextSpanRef {
        return self.todo_span_refs;
    }
    pub fn doneSpanRefs(self: *const TaskIndex) []const TextSpanRef {
        return self.done_span_refs;
    }
    pub fn todoSpanPool(self: *const TaskIndex) []const TextSpan {
        return self.todo_span_pool;
    }
    pub fn doneSpanPool(self: *const TaskIndex) []const TextSpan {
        return self.done_span_pool;
    }

    pub fn load(
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !TaskIndex {
        const todo_img = try store.loadFile(allocator, todo_file);
        errdefer {
            var tmp = todo_img;
            tmp.deinit(allocator);
        }

        const done_img = try store.loadFile(allocator, done_file);
        errdefer {
            var tmp = done_img;
            tmp.deinit(allocator);
        }


        const projects_todo = try buildProjectsIndexForTasks(allocator, todo_img.tasks);
        errdefer allocator.free(projects_todo);

        const projects_done = try buildProjectsIndexForTasks(allocator, done_img.tasks);
        errdefer allocator.free(projects_done);

        const todo_spans = try buildSpanIndexForTasks(allocator, todo_img.tasks);
        errdefer {
            allocator.free(todo_spans.refs);
            allocator.free(todo_spans.pool);
        }

        const done_spans = try buildSpanIndexForTasks(allocator, done_img.tasks);
        errdefer {
            allocator.free(done_spans.refs);
            allocator.free(done_spans.pool);
        }

        const todo_max = maxProjectLabelLen(projects_todo);
        const done_max = maxProjectLabelLen(projects_done);

        return TaskIndex{
            .todo_img = todo_img,
            .done_img = done_img,
            .todo = todo_img.tasks,
            .done = done_img.tasks,
            .projects_todo = projects_todo,
            .projects_done = projects_done,
            .projects_todo_max_label = todo_max,
            .projects_done_max_label = done_max,
            .todo_span_refs = todo_spans.refs,
            .done_span_refs = done_spans.refs,
            .todo_span_pool = todo_spans.pool,
            .done_span_pool = done_spans.pool,
        };
    }

    pub fn reload(
        self: *TaskIndex,
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !void {
        // Build new state first. If anything fails, `self` remains valid.
        var todo_img_new = try store.loadFile(allocator, todo_file);
        errdefer todo_img_new.deinit(allocator);

        var done_img_new = try store.loadFile(allocator, done_file);
        errdefer done_img_new.deinit(allocator);

        const projects_todo_new = try buildProjectsIndexForTasks(allocator, todo_img_new.tasks);
        errdefer allocator.free(projects_todo_new);

        const projects_done_new = try buildProjectsIndexForTasks(allocator, done_img_new.tasks);
        errdefer allocator.free(projects_done_new);

        const todo_spans_new = try buildSpanIndexForTasks(allocator, todo_img_new.tasks);
        errdefer {
            freeIfNonEmpty(allocator, todo_spans_new.refs);
            freeIfNonEmpty(allocator, todo_spans_new.pool);
        }

        const done_spans_new = try buildSpanIndexForTasks(allocator, done_img_new.tasks);
        errdefer {
            freeIfNonEmpty(allocator, done_spans_new.refs);
            freeIfNonEmpty(allocator, done_spans_new.pool);
        }

        const todo_max = maxProjectLabelLen(projects_todo_new);
        const done_max = maxProjectLabelLen(projects_done_new);

        // Stash old resources for disposal after swap.
        const old_projects_todo = self.projects_todo;
        const old_projects_done = self.projects_done;
        const old_todo_span_refs = self.todo_span_refs;
        const old_done_span_refs = self.done_span_refs;
        const old_todo_span_pool = self.todo_span_pool;
        const old_done_span_pool = self.done_span_pool;
        var old_todo_img = self.todo_img;
        var old_done_img = self.done_img;

        // Swap in new.
        self.todo_img = todo_img_new;
        self.done_img = done_img_new;
        self.todo = self.todo_img.tasks;
        self.done = self.done_img.tasks;

        self.projects_todo = projects_todo_new;
        self.projects_done = projects_done_new;
        self.projects_todo_max_label = todo_max;
        self.projects_done_max_label = done_max;

        self.todo_span_refs = todo_spans_new.refs;
        self.todo_span_pool = todo_spans_new.pool;
        self.done_span_refs = done_spans_new.refs;
        self.done_span_pool = done_spans_new.pool;

        // Dispose old.
        allocator.free(old_projects_todo);
        allocator.free(old_projects_done);
        freeIfNonEmpty(allocator, old_todo_span_refs);
        freeIfNonEmpty(allocator, old_done_span_refs);
        freeIfNonEmpty(allocator, old_todo_span_pool);
        freeIfNonEmpty(allocator, old_done_span_pool);
        old_todo_img.deinit(allocator);
        old_done_img.deinit(allocator);
    }

    pub fn deinit(self: *TaskIndex, allocator: mem.Allocator) void {
        allocator.free(self.projects_todo);
        allocator.free(self.projects_done);
        freeIfNonEmpty(allocator, self.todo_span_refs);
        freeIfNonEmpty(allocator, self.done_span_refs);
        freeIfNonEmpty(allocator, self.todo_span_pool);
        freeIfNonEmpty(allocator, self.done_span_pool);
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);
        self.* = undefined;
    }

};
