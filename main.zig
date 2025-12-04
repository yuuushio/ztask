const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const App = struct {
    config_dir: []const u8,
    dir: fs.Dir,
    todo: fs.File,
    done: fs.File,

    pub fn init(allocator: mem.Allocator) !App {
        const config_dir = try determineConfigDir(allocator);
        errdefer allocator.free(config_dir);

        // Create config directory tree if it does not exist yet.
        try fs.cwd().makePath(config_dir);

        // Open the directory handle once, reuse for files.
        var dir = try fs.cwd().openDir(config_dir, .{ .iterate = false });
        errdefer dir.close();

        const todo_file = try openOrCreateRw(&dir, "todo.txt");
        errdefer todo_file.close();

        const done_file = try openOrCreateRw(&dir, "done.txt");
        errdefer done_file.close();

        return App{
            .config_dir = config_dir,
            .dir = dir,
            .todo = todo_file,
            .done = done_file,
        };
    }

    pub fn deinit(self: *App, allocator: mem.Allocator) void {
        self.todo.close();
        self.done.close();
        self.dir.close();
        allocator.free(self.config_dir);
        self.* = undefined;
    }
};

fn determineConfigDir(allocator: mem.Allocator) ![]u8 {
    // Prefer explicit env override, else fall back to per user app data dir.
    const env_dir = std.process.getEnvVarOwned(allocator, "ZTASK_CONFIG_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fs.getAppDataDir(allocator, "ztask"),
        else => return err,
    };
    return env_dir;
}

// Create if missing, open read write if present, never truncate.
fn openOrCreateRw(dir: *fs.Dir, name: []const u8) !fs.File {
    return dir.createFile(name, .{
        .read = true,
        .truncate = false,
        .exclusive = false,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = try App.init(allocator);
    defer app.deinit(allocator);

    std.debug.print("config dir: {s}\n", .{app.config_dir});
}
