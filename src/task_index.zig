const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const store = @import("task_store.zig");

pub const Task = store.Task;
pub const Status = store.Status;
pub const FileImage = store.FileImage;

pub const TaskIndex = struct {
    todo: []Task,
    done: []Task,

    todo_text_buf: []u8,
    done_text_buf: []u8,


pub fn load(
    allocator: mem.Allocator,
    todo_file: fs.File,
    done_file: fs.File,
) !TaskIndex {
    const todo_img = try store.loadFile(allocator, todo_file);
    errdefer {
        if (todo_img.tasks.len != 0) allocator.free(todo_img.tasks);
        if (todo_img.text_buf.len != 0) allocator.free(todo_img.text_buf);
    }

    // const done_img = store.loadFile(allocator, done_file) catch |err| {
    //     if (todo_img.tasks.len != 0) allocator.free(todo_img.tasks);
    //     if (todo_img.text_buf.len != 0) allocator.free(todo_img.text_buf);
    //     return err;
    // };
const done_img = try store.loadFile(allocator, done_file);

    return TaskIndex{
        .todo = todo_img.tasks,
        .done = done_img.tasks,
        .todo_text_buf = todo_img.text_buf,
        .done_text_buf = done_img.text_buf,
    };
}

    pub fn reload(
        self: *TaskIndex,
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !void {
        self.deinit(allocator);
        self.* = try TaskIndex.load(allocator, todo_file, done_file);
    }

    pub fn deinit(self: *TaskIndex, allocator: mem.Allocator) void {
        if (self.todo.len != 0) allocator.free(self.todo);
        if (self.done.len != 0) allocator.free(self.done);
        if (self.todo_text_buf.len != 0) allocator.free(self.todo_text_buf);
        if (self.done_text_buf.len != 0) allocator.free(self.done_text_buf);

        self.todo = &[_]Task{};
        self.done = &[_]Task{};
        self.todo_text_buf = &[_]u8{};
        self.done_text_buf = &[_]u8{};
    }
};
