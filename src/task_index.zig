const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const store = @import("task_store.zig");

pub const Task = store.Task;
pub const Status = store.Status;
pub const FileImage = store.FileImage;

pub const ProjectEntry = struct {
    /// Slice into FileImage.buf
    name: []const u8,
    /// Number of TODO tasks that mention this project at least once
    count_todo: u32,
};

fn buildProjectIndex(
    allocator: mem.Allocator,
    img: *const FileImage,
) ![]ProjectEntry {
    var list = std.ArrayList(ProjectEntry).init(allocator);
    errdefer list.deinit();

    var i: usize = 0;
    while (i < img.tasks.len) : (i += 1) {
        const t = img.tasks[i];

        // Collect distinct +tags for this single task.
        var tags: [16][]const u8 = undefined;
        var tag_count: usize = 0;
        store.collectTags(t.text, '+', &tags, &tag_count);

        var ti: usize = 0;
        while (ti < tag_count) : (ti += 1) {
            const tag = tags[ti];

            var found = false;
            var pj: usize = 0;
            while (pj < list.items.len) : (pj += 1) {
                if (std.mem.eql(u8, list.items[pj].name, tag)) {
                    list.items[pj].count_todo += 1;
                    found = true;
                    break;
                }
            }

            if (!found) {
                try list.append(.{
                    .name = tag,
                    .count_todo = 1,
                });
            }
        }
    }

    // Stable order: lexicographic by project name.
    std.sort.pdq(ProjectEntry, list.items, {}, struct {
        fn lessThan(ctx: void, a: ProjectEntry, b: ProjectEntry) bool {
            _ = ctx;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return try list.toOwnedSlice();
}

pub const TaskIndex = struct {
    todo_img: FileImage,
    done_img: FileImage,
    projects: []ProjectEntry,

    pub fn todoSlice(self: *const TaskIndex) []const Task {
        return self.todo_img.tasks;
    }

    pub fn doneSlice(self: *const TaskIndex) []const Task {
        return self.done_img.tasks;
    }

    pub fn projectsSlice(self: *const TaskIndex) []const ProjectEntry {
        return self.projects;
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

        const projects = try buildProjectIndex(allocator, &todo_img);

        return TaskIndex{
            .todo_img = todo_img,
            .done_img = done_img,
            .projects = projects,
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
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);
        if (self.projects.len != 0) allocator.free(self.projects);
    }
};
