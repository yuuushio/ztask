const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const store = @import("task_store.zig");

pub const Task = store.Task;
pub const Status = store.Status;
pub const FileImage = store.FileImage;

pub const TaskIndex = struct {
    todo_img: FileImage,
    done_img: FileImage,

    pub fn todoSlice(self: *const TaskIndex) []const Task {
        return self.todo_img.tasks;
    }

    pub fn doneSlice(self: *const TaskIndex) []const Task {
        return self.done_img.tasks;
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

        return TaskIndex{
            .todo_img = todo_img,
            .done_img = done_img,
        };
    }

    pub fn reload(
        self: *TaskIndex,
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !void {
        // Drop old images first to avoid leaks.
        self.deinit(allocator);
        self.* = try TaskIndex.load(allocator, todo_file, done_file);
    }

    pub fn deinit(self: *TaskIndex, allocator: mem.Allocator) void {
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);
    }
};
