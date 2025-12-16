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


fn buildProjectsIndex(
    allocator: std.mem.Allocator,
    todo_img: *const store.FileImage,
    done_img: *const store.FileImage,
) ![]ProjectEntry {
    var project_map = ProjectMap.init(allocator);
    defer project_map.deinit();

    const Helper = struct {
        fn addImage(
            pm: *ProjectMap,
            img: *const store.FileImage,
            is_todo: bool,
        ) !void {
            const tasks = img.tasks;

            var ti: usize = 0;
            while (ti < tasks.len) : (ti += 1) {
                const t = tasks[ti];

                // Collect unique "+project" tags for this task
                var proj_tags: [16][]const u8 = undefined;
                var proj_count: usize = 0;
                store.collectTags(t.text, '+', &proj_tags, &proj_count);

                var k: usize = 0;
                while (k < proj_count) : (k += 1) {
                    const name = proj_tags[k]; // slice into FileImage.buf
                    if (name.len == 0) continue;

                    const gop = try pm.getOrPut(name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{
                            .count_todo = 0,
                            .count_done = 0,
                        };
                    }

                    if (is_todo) {
                        gop.value_ptr.count_todo += 1;
                    } else {
                        gop.value_ptr.count_done += 1;
                    }
                }
            }
        }
    };

    try Helper.addImage(&project_map, todo_img, true);
    try Helper.addImage(&project_map, done_img, false);

    const count = project_map.count();
    const entries = try allocator.alloc(ProjectEntry, count);

    var it = project_map.iterator();
    var i: usize = 0;
    while (it.next()) |e| {

        const name = e.key_ptr.*;
        const agg = e.value_ptr.*;
        std.debug.print("project[{d}] = '{s}'  todo={d} done={d}\n",
            .{ i, name, agg.count_todo, agg.count_done });
        entries[i] = .{
            .name = e.key_ptr.*,          // slice into FileImage.buf
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


        const projects = try buildProjectsIndex(allocator, &todo_img, &done_img);

        // DEBUG: verify projects just before TaskIndex is constructed
        std.debug.print("TaskIndex.load: projects from indexer:\n", .{});
        for (projects, 0..) |p, idx| {
            std.debug.print(
                "  [{d}] name='{s}'  todo={d} done={d}\n",
                .{ idx, p.name, p.count_todo, p.count_done },
            );
        }

        return TaskIndex{
            .todo_img = todo_img,
            .done_img = done_img,
            .todo = todo_img.tasks,
            .done = done_img.tasks,
            .projects = projects,
        };
    }

    pub fn reload(
        self: *TaskIndex,
        allocator: mem.Allocator,
        todo_file: fs.File,
        done_file: fs.File,
    ) !void {
        // free old images + project list
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);
        allocator.free(self.projects);

        // reload from disk using the *same* loader as in .load
        var todo_img = try store.loadFile(allocator, todo_file);
        errdefer todo_img.deinit(allocator);

        var done_img = try store.loadFile(allocator, done_file);
        errdefer done_img.deinit(allocator);

        const projects = try buildProjectsIndex(allocator, &todo_img, &done_img);

        self.todo_img = todo_img;
        self.done_img = done_img;
        self.todo = todo_img.tasks;
        self.done = done_img.tasks;
        self.projects = projects;
    }

    pub fn deinit(self: *TaskIndex, allocator: mem.Allocator) void {
        allocator.free(self.projects);
        self.todo_img.deinit(allocator);
        self.done_img.deinit(allocator);
        self.* = undefined;
    }

};
