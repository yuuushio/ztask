const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const math = std.math;

pub const Task = struct {
    text: []const u8,
};

pub const TaskIndex = struct {
    // Backing buffers that own the file contents.
    todo_buf: []u8,
    done_buf: []u8,

    // Views into the buffers. Each Task slice points into the buffers above.
    todo: []Task,
    done: []Task,

    pub fn load(
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !TaskIndex {
        var todo_buf: []u8 = undefined;
        var todo_tasks: []Task = undefined;
        try loadOne(allocator, todo_file, &todo_buf, &todo_tasks);
        errdefer {
            allocator.free(todo_buf);
            allocator.free(todo_tasks);
        }

        var done_buf: []u8 = undefined;
        var done_tasks: []Task = undefined;
        try loadOne(allocator, done_file, &done_buf, &done_tasks);
        errdefer {
            allocator.free(done_buf);
            allocator.free(done_tasks);
        }

        return TaskIndex{
            .todo_buf = todo_buf,
            .done_buf = done_buf,
            .todo = todo_tasks,
            .done = done_tasks,
        };
    }

    pub fn deinit(self: *TaskIndex, allocator: mem.Allocator) void {
        allocator.free(self.todo_buf);
        allocator.free(self.done_buf);
        allocator.free(self.todo);
        allocator.free(self.done);
        self.* = undefined;
    }

    fn loadOne(
        allocator: mem.Allocator,
        file: fs.File,
        out_buf: *[]u8,
        out_tasks: *[]Task,
    ) !void {
        const stat = try file.stat();
        const cap = math.cast(usize, stat.size) orelse return error.FileTooBig;

        // Single allocation for file contents. Zero-length is fine.
        var buf = try allocator.alloc(u8, cap);
        errdefer allocator.free(buf);

        try file.seekTo(0);

        const read_len = try file.readAll(buf);
        const slice = buf[0..read_len];

        // First pass: count non-empty lines.
        var line_count: usize = 0;
        var i: usize = 0;
        while (i < slice.len) {
            const start = i;
            while (i < slice.len and slice[i] != '\n') : (i += 1) {}
            const raw = slice[start..i];
            const line = mem.trimRight(u8, raw, " \t\r\n");
            if (line.len != 0) line_count += 1;

            if (i < slice.len and slice[i] == '\n') i += 1;
        }

        // Second pass: build Task slice.
        var tasks = try allocator.alloc(Task, line_count);
        errdefer allocator.free(tasks);

        i = 0;
        var idx: usize = 0;
        while (i < slice.len) {
            const start = i;
            while (i < slice.len and slice[i] != '\n') : (i += 1) {}
            const raw = slice[start..i];
            const line = mem.trimRight(u8, raw, " \t\r\n");

            if (line.len != 0) {
                tasks[idx] = .{ .text = line };
                idx += 1;
            }

            if (i < slice.len and slice[i] == '\n') i += 1;
        }

        // idx should equal line_count unless all lines were empty.
        out_buf.* = buf;
        out_tasks.* = tasks[0..idx];
    }
};
