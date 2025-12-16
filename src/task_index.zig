const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const store = @import("task_store.zig");

pub const Task = store.Task;
pub const Status = store.Status;
pub const FileImage = store.FileImage;

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

        return TaskIndex{
            .todo_img = todo_img,
            .done_img = done_img,
            .todo = todo_img.tasks,
            .done = done_img.tasks,
            .projects_todo = projects_todo,
            .projects_done = projects_done,
        };
    }

    pub fn reload(
        self: *TaskIndex,
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !void {
        // free old project lists first
        allocator.free(self.projects_todo);
        allocator.free(self.projects_done);

        // free old images
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);

        // reload
        var todo_img = try store.loadFile(allocator, todo_file);
        errdefer todo_img.deinit(allocator);

        var done_img = try store.loadFile(allocator, done_file);
        errdefer done_img.deinit(allocator);

        const projects_todo = try buildProjectsIndexForTasks(allocator, todo_img.tasks);
        errdefer allocator.free(projects_todo);

        const projects_done = try buildProjectsIndexForTasks(allocator, done_img.tasks);
        errdefer allocator.free(projects_done);

        self.todo_img = todo_img;
        self.done_img = done_img;
        self.todo = todo_img.tasks;
        self.done = done_img.tasks;
        self.projects_todo = projects_todo;
        self.projects_done = projects_done;
    }

    pub fn deinit(self: *TaskIndex, allocator: mem.Allocator) void {
        allocator.free(self.projects_todo);
        allocator.free(self.projects_done);
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);
        self.* = undefined;
    }

};
