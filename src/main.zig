const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const vaxis = @import("vaxis");


const TaskIndex = @import("task_index.zig").TaskIndex;
const ui_mod = @import("ui_state.zig");
const UiState = ui_mod.UiState;
const tui = @import("tui.zig");
const dt = @import("due_datetime.zig");


const App = struct {
    config_dir: []const u8,
    data_dir: []const u8,
    cfg_dir: fs.Dir,
    data_dir_handle: fs.Dir,
    todo: fs.File,
    done: fs.File,
    index: TaskIndex,
    due_cfg: dt.DueFormatConfig,

    pub fn init(allocator: mem.Allocator) !App {
        const config_dir = try determineConfigDir(allocator);
        errdefer allocator.free(config_dir);

        const data_dir = try determineDataDir(allocator);
        errdefer allocator.free(data_dir);

        // Ensure both directory trees exist.
        try fs.cwd().makePath(config_dir);
        try fs.cwd().makePath(data_dir);

        // Open both directory handles once, reuse for files.
        var cfg_dir = try fs.cwd().openDir(config_dir, .{});
        errdefer cfg_dir.close();

        var data_dir_handle = try fs.cwd().openDir(data_dir, .{});
        errdefer data_dir_handle.close();

        // Data files live in app data dir.
        const todo_file = try openOrCreateRw(&data_dir_handle, "todo.txt");
        errdefer todo_file.close();

        const done_file = try openOrCreateRw(&data_dir_handle, "done.txt");
        errdefer done_file.close();

        // Config lives in XDG config dir, file name: "conf" (e.g. ~/.config/ztask/conf).
        const cfg_file = try openOrCreateRw(&cfg_dir, "conf");
        defer cfg_file.close();

        const due_cfg = try dt.loadDueFormatConfigFromFile(allocator, cfg_file);
        errdefer {
            var tmp = due_cfg;
            tmp.deinit(allocator);
        }

        const index = try TaskIndex.load(allocator, todo_file, done_file);

        return App{
            .config_dir = config_dir,
            .data_dir = data_dir,
            .cfg_dir = cfg_dir,
            .data_dir_handle = data_dir_handle,
            .todo = todo_file,
            .done = done_file,
            .index = index,
            .due_cfg = due_cfg,
        };
    }

    pub fn deinit(self: *App, allocator: mem.Allocator) void {
        self.due_cfg.deinit(allocator);
        self.index.deinit(allocator);
        self.todo.close();
        self.done.close();
        self.data_dir_handle.close();
        self.cfg_dir.close();
        allocator.free(self.config_dir);
        allocator.free(self.data_dir);
        self.* = undefined;
    }
};

fn determineConfigDir(allocator: mem.Allocator) ![]u8 {
    // Explicit env override first.
    const env_dir = std.process.getEnvVarOwned(allocator, "ZTASK_CONFIG_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            // XDG_CONFIG_HOME or fallback to ~/.config
            const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |e2| switch (e2) {
                error.EnvironmentVariableNotFound => null,
                else => return e2,
            };
            if (xdg) |base| {
                defer allocator.free(base);
                break :blk try fs.path.join(allocator, &[_][]const u8{ base, "ztask" });
            }

            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            const base = try fs.path.join(allocator, &[_][]const u8{ home, ".config" });
            defer allocator.free(base);
            break :blk try fs.path.join(allocator, &[_][]const u8{ base, "ztask" });
        },
        else => return err,
    };
    return env_dir;
}

fn determineDataDir(allocator: mem.Allocator) ![]u8 {
    // Explicit env override first.
    const env_dir = std.process.getEnvVarOwned(allocator, "ZTASK_DATA_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fs.getAppDataDir(allocator, "ztask"),
        else => return err,
    };
    return env_dir;
}

// Open read+write if it exists, create if missing, never truncate on open.
fn openOrCreateRw(dir: *fs.Dir, name: []const u8) !fs.File {
    return dir.openFile(name, .{
        .mode = .read_write,
    }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(name, .{
            .read = true,
            .truncate = false,
            .exclusive = false,
        }),
        else => err,
    };
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const st = gpa.deinit();
        if (st == .leak) std.log.err("memory leak detected", .{});
    }
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit(allocator);

    var ctx = tui.TuiContext{
        .todo_file = &app.todo,
        .done_file = &app.done,
        .index= &app.index,
        .due_cfg = &app.due_cfg,
    };

    var ui = UiState.init();

    try tui.run(allocator, &ctx, &ui);
}
