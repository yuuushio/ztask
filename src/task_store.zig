const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const time = std.time;

/// Status of a task on disk and in memory.
pub const Status = enum {
    todo,
    ongoing,
    done,
};

/// Span into the shared backing buffer, used for projects/contexts.
const Span = struct {
    start: u32,
    len: u16,
};

/// Single task, all string slices reference FileImage.buf.
pub const Task = struct {
    id: u64,

    /// What user sees and edits.
    text: []const u8,

    /// Projects and contexts are stored as spans into FileImage.buf.
    proj_first: u32,
    proj_count: u16,
    ctx_first: u32,
    ctx_count: u16,

    priority: u8,
    status: Status,

    due: []const u8,     // "" => no due date
    repeat: []const u8,  // "" => no repeat rule

    /// Unix millis since epoch; used for fast sorting, grouping, etc.
    created_ms: i64,
};

/// Loaded view of one file (todo or done).
pub const FileImage = struct {
    buf: []u8,     // entire file contents (owned)
    tasks: []Task, // each task’s slices/spans point into buf
    spans: []Span, // concatenation of all project+context names

    pub fn deinit(self: *FileImage, allocator: mem.Allocator) void {
        if (self.buf.len != 0) allocator.free(self.buf);
        if (self.tasks.len != 0) allocator.free(self.tasks);
        if (self.spans.len != 0) allocator.free(self.spans);
        self.* = .{
            .buf = &[_]u8{},
            .tasks = &[_]Task{},
            .spans = &[_]Span{},
        };
    }
};

const ParseError = error{
    InvalidJson,
};

pub fn loadFile(allocator: mem.Allocator, file: fs.File) !FileImage {
    const stat = try file.stat();
    if (stat.size == 0) {
        return FileImage{
            .tasks = &[_]Task{},
            .text_buf = &[_]u8{},
        };
    }

    const size: usize = @intCast(stat.size);

    // Read whole file in one go.
    var raw = try allocator.alloc(u8, size);
    errdefer allocator.free(raw);

    try file.seekTo(0);
    const got = try file.readAll(raw);
    const raw_slice = raw[0..got];

    if (raw_slice.len == 0) {
        allocator.free(raw);
        return FileImage{
            .tasks = &[_]Task{},
            .text_buf = &[_]u8{},
        };
    }

    // Decide format: JSON-lines (preferred) vs legacy plain text.
    var is_json = false;
    {
        var found = false;
        var idx: usize = 0;
        while (idx < raw_slice.len) : (idx += 1) {
            const b = raw_slice[idx];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') continue;
            is_json = (b == '{');
            found = true;
            break;
        }
        if (!found) {
            allocator.free(raw);
            return FileImage{
                .tasks = &[_]Task{},
                .text_buf = &[_]u8{},
            };
        }
    }

    // Count logical lines.
    var line_count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw_slice.len) : (i += 1) {
        if (raw_slice[i] == '\n') {
            line_count += 1;
            start = i + 1;
        }
    }
    if (start < raw_slice.len) {
        line_count += 1;
    }

    var tasks = try allocator.alloc(Task, line_count);
    var text_buf = try allocator.alloc(u8, raw_slice.len);
    var parse_ok = false;
    defer {
        if (!parse_ok) {
            allocator.free(tasks);
            allocator.free(text_buf);
        }
    }

    var text_cursor: usize = 0;
    var task_index: usize = 0;
    var line_start: usize = 0;

    i = 0;
    while (i < raw_slice.len) : (i += 1) {
        if (raw_slice[i] == '\n') {
            const line = raw_slice[line_start..i];

            if (is_json) {
                const task = try parseTaskFromJsonLine(line, text_buf, &text_cursor);
                tasks[task_index] = task;
            } else {
                const text_slice = copyPlainLine(line, text_buf, &text_cursor);
                const empty = text_buf[text_cursor..text_cursor];
                tasks[task_index] = .{
                    .text = text_slice,
                    .prio = 0,
                    .due = empty,
                    .repeat = empty,
                };
            }

            task_index += 1;
            line_start = i + 1;
        }
    }

    if (line_start < raw_slice.len) {
        const line = raw_slice[line_start..raw_slice.len];

        if (is_json) {
            const task = try parseTaskFromJsonLine(line, text_buf, &text_cursor);
            tasks[task_index] = task;
        } else {
            const text_slice = copyPlainLine(line, text_buf, &text_cursor);
            const empty = text_buf[text_cursor..text_cursor];
            tasks[task_index] = .{
                .text = text_slice,
                .prio = 0,
                .due = empty,
                .repeat = empty,
            };
        }

        task_index += 1;
    }

    parse_ok = true;
    allocator.free(raw);

    return FileImage{
        .tasks = tasks[0..task_index],
        .text_buf = text_buf, // keep full capacity; we free the full slice
    };
}


fn parsePriorityField(line: []const u8) u8 {
    const key = "\"prio\"";
    const len = line.len;
    if (len == 0) return 0;

    var i: usize = 0;
    var key_pos: ?usize = null;
    while (i + key.len <= len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < key.len) : (j += 1) {
            if (line[i + j] != key[j]) {
                ok = false;
                break;
            }
        }
        if (ok) {
            key_pos = i;
            break;
        }
    }
    if (key_pos == null) return 0;

    i = key_pos.? + key.len;

    // Find ':'
    while (i < len and line[i] != ':') : (i += 1) {}
    if (i == len) return 0;
    i += 1;

    while (i < len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == len) return 0;

    var value: u16 = 0;
    var saw_digit = false;
    while (i < len) {
        const b = line[i];
        if (b < '0' or b > '9') break;
        saw_digit = true;
        const digit: u16 = b - '0';
        value = value * 10 + digit;
        if (value > 255) return 0;
        i += 1;
    }
    if (!saw_digit) return 0;

    return @intCast(value);
}

fn parseStringField(
    line: []const u8,
    key: []const u8,
    required: bool,
    text_buf: []u8,
    cursor: *usize,
) ParseError![]const u8 {
    const len = line.len;
    if (len == 0) {
        if (required) return ParseError.InvalidJson;
        return text_buf[cursor.*..cursor.*];
    }

    // Look for "key"
    const quoted_len = key.len + 2;
    var i: usize = 0;
    var key_pos: ?usize = null;
    while (i + quoted_len <= len) : (i += 1) {
        if (line[i] != '"') continue;

        var ok = true;
        var j: usize = 0;
        while (j < key.len) : (j += 1) {
            if (line[i + 1 + j] != key[j]) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;

        if (line[i + 1 + key.len] != '"') continue;

        key_pos = i;
        break;
    }

    if (key_pos == null) {
        if (required) return ParseError.InvalidJson;
        return text_buf[cursor.*..cursor.*];
    }

    i = key_pos.? + quoted_len;

    // Find ':'
    while (i < len and line[i] != ':') : (i += 1) {}
    if (i == len) return ParseError.InvalidJson;
    i += 1;

    // Skip spaces
    while (i < len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == len) return ParseError.InvalidJson;

    if (line[i] != '"') return ParseError.InvalidJson;
    i += 1; // at start of string

    const dst_start = cursor.*;
    var dst = dst_start;

    while (i < len) {
        const b = line[i];
        if (b == '\\') {
            if (i + 1 >= len) return ParseError.InvalidJson;
            const esc = line[i + 1];
            var out: u8 = undefined;
            switch (esc) {
                'n' => out = '\n',
                'r' => out = '\r',
                't' => out = '\t',
                '\\' => out = '\\',
                '"' => out = '"',
                else => out = esc,
            }
            text_buf[dst] = out;
            dst += 1;
            i += 2;
        } else if (b == '"') {
            i += 1;
            break;
        } else {
            text_buf[dst] = b;
            dst += 1;
            i += 1;
        }
    }

    const slice = text_buf[dst_start..dst];
    cursor.* = dst;
    return slice;
}


fn parseTaskFromJsonLine(
    line: []const u8,
    text_buf: []u8,
    cursor: *usize,
) ParseError!Task {
    const text_slice = try parseStringField(line, "text", true, text_buf, cursor);
    const prio = parsePriorityField(line);
    const due_slice = try parseStringField(line, "due", false, text_buf, cursor);
    const repeat_slice = try parseStringField(line, "repeat", false, text_buf, cursor);

    return Task{
        .text = text_slice,
        .prio = prio,
        .due = due_slice,
        .repeat = repeat_slice,
    };
}

pub fn appendJsonTaskLine(
    allocator: mem.Allocator,
    file: *fs.File,
    task: Task,
) !void {
    const stat = try file.stat();
    try file.seekTo(stat.size);
    try writeJsonLineForTask(allocator, file, task);
}

/// Rewrite entire file in JSON-lines format using `tasks`,
/// optionally skipping the element at `skip_index` (used by :d).
///
/// NOTE: this rewrites the entire file on each mutation.
/// For very large files and many state changes the optimal design
/// is to maintain append-only logs and an in-memory “live set” of
/// task indices, and only occasionally rewrite compacted files.
pub fn rewriteJsonFileWithoutIndex(
    allocator: mem.Allocator,
    file: *fs.File,
    tasks: []const Task,
    skip_index: usize,
) !void {
    try file.seekTo(0);
    try file.setEndPos(0);

    var i: usize = 0;
    while (i < tasks.len) : (i += 1) {
        if (i == skip_index) continue;
        try writeJsonLineForTask(allocator, file, tasks[i]);
    }
}



// internal helpers 


fn jsonEscapeInto(buf: []u8, pos: *usize, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        switch (b) {
            '"' => {
                buf[pos.*] = '\\'; pos.* += 1;
                buf[pos.*] = '"'; pos.* += 1;
            },
            '\\' => {
                buf[pos.*] = '\\'; pos.* += 1;
                buf[pos.*] = '\\'; pos.* += 1;
            },
            '\n' => {
                buf[pos.*] = '\\'; pos.* += 1;
                buf[pos.*] = 'n'; pos.* += 1;
            },
            '\r' => {
                buf[pos.*] = '\\'; pos.* += 1;
                buf[pos.*] = 'r'; pos.* += 1;
            },
            '\t' => {
                buf[pos.*] = '\\'; pos.* += 1;
                buf[pos.*] = 't'; pos.* += 1;
            },
            else => {
                buf[pos.*] = b;
                pos.* += 1;
            },
        }
    }
}

fn writeUintInto(buf: []u8, pos: *usize, value: u8) void {
    var tmp: [3]u8 = undefined;
    var n: u8 = value;
    var digits: usize = 0;

    if (n == 0) {
        tmp[0] = '0';
        digits = 1;
    } else {
        while (n != 0) : (n /= 10) {
            const digit: u8 = n % 10;
            tmp[digits] = @as(u8, '0') + digit;
            digits += 1;
        }
    }

    var i: usize = 0;
    while (i < digits) : (i += 1) {
        buf[pos.*] = tmp[digits - 1 - i];
        pos.* += 1;
    }
}

fn encodeTaskIntoBuf(buf: []u8, pos: *usize, task: Task) void {
    // {"text":"...
    buf[pos.*] = '{'; pos.* += 1;

    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = 't'; pos.* += 1;
    buf[pos.*] = 'e'; pos.* += 1;
    buf[pos.*] = 'x'; pos.* += 1;
    buf[pos.*] = 't'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = ':'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;

    jsonEscapeInto(buf, pos, task.text);

    buf[pos.*] = '"'; pos.* += 1;

    // ,"prio":
    buf[pos.*] = ','; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = 'p'; pos.* += 1;
    buf[pos.*] = 'r'; pos.* += 1;
    buf[pos.*] = 'i'; pos.* += 1;
    buf[pos.*] = 'o'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = ':'; pos.* += 1;

    writeUintInto(buf, pos, task.prio);

    // ,"due":"..."
    buf[pos.*] = ','; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = 'd'; pos.* += 1;
    buf[pos.*] = 'u'; pos.* += 1;
    buf[pos.*] = 'e'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = ':'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;

    jsonEscapeInto(buf, pos, task.due);

    buf[pos.*] = '"'; pos.* += 1;

    // ,"repeat":"..."
    buf[pos.*] = ','; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = 'r'; pos.* += 1;
    buf[pos.*] = 'e'; pos.* += 1;
    buf[pos.*] = 'p'; pos.* += 1;
    buf[pos.*] = 'e'; pos.* += 1;
    buf[pos.*] = 'a'; pos.* += 1;
    buf[pos.*] = 't'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = ':'; pos.* += 1;
    buf[pos.*] = '"'; pos.* += 1;

    jsonEscapeInto(buf, pos, task.repeat);

    buf[pos.*] = '"'; pos.* += 1;
    buf[pos.*] = '}'; pos.* += 1;
    buf[pos.*] = '\n'; pos.* += 1;
}

fn writeJsonLineForTask(
    allocator: mem.Allocator,
    file: *fs.File,
    task: Task,
) !void {
    const stack_cap: usize = 1024;
    const overhead: usize = 64;
    const total_input: usize = task.text.len + task.due.len + task.repeat.len;

    if (total_input * 2 + overhead <= stack_cap) {
        var buf: [stack_cap]u8 = undefined;
        var pos: usize = 0;
        encodeTaskIntoBuf(&buf, &pos, task);
        try file.writeAll(buf[0..pos]);
    } else {
        const cap: usize = total_input * 2 + overhead;
        var buf = try allocator.alloc(u8, cap);
        defer allocator.free(buf);
        var pos: usize = 0;
        encodeTaskIntoBuf(buf, &pos, task);
        try file.writeAll(buf[0..pos]);
    }
}

fn copyPlainLine(
    line: []const u8,
    text_buf: []u8,
    cursor: *usize,
) []const u8 {
    var end = line.len;
    // Strip trailing '\r' from CRLF if present.
    if (end > 0 and line[end - 1] == '\r') {
        end -= 1;
    }

    const dst_start = cursor.*;
    const len = end;

    if (len != 0) {
        @memcpy(text_buf[dst_start .. dst_start + len], line[0..len]);
    }

    cursor.* = dst_start + len;
    return text_buf[dst_start .. dst_start + len];
}

fn writeJsonLineForText(
    allocator: mem.Allocator,
    file: *fs.File,
    text: []const u8,
) !void {
    const stack_cap: usize = 1024;
    const overhead: usize = 16; // {"text":""}\n plus escapes

    if (text.len + overhead <= stack_cap) {
        var buf: [stack_cap]u8 = undefined;
        var pos: usize = 0;

        // {"text":"
        buf[pos] = '{'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = 'e'; pos += 1;
        buf[pos] = 'x'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = ':'; pos += 1;
        buf[pos] = '"'; pos += 1;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            switch (b) {
                '"' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '"'; pos += 1;
                },
                '\\' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '\\'; pos += 1;
                },
                '\n' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'n'; pos += 1;
                },
                '\r' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'r'; pos += 1;
                },
                '\t' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 't'; pos += 1;
                },
                else => {
                    buf[pos] = b;
                    pos += 1;
                },
            }
        }

        buf[pos] = '"'; pos += 1;
        buf[pos] = '}'; pos += 1;
        buf[pos] = '\n'; pos += 1;

        try file.writeAll(buf[0..pos]);
    } else {
        const cap: usize = text.len * 2 + overhead;
        var buf = try allocator.alloc(u8, cap);
        defer allocator.free(buf);

        var pos: usize = 0;

        buf[pos] = '{'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = 'e'; pos += 1;
        buf[pos] = 'x'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = ':'; pos += 1;
        buf[pos] = '"'; pos += 1;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            switch (b) {
                '"' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '"'; pos += 1;
                },
                '\\' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '\\'; pos += 1;
                },
                '\n' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'n'; pos += 1;
                },
                '\r' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'r'; pos += 1;
                },
                '\t' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 't'; pos += 1;
                },
                else => {
                    buf[pos] = b;
                    pos += 1;
                },
            }
        }

        buf[pos] = '"'; pos += 1;
        buf[pos] = '}'; pos += 1;
        buf[pos] = '\n'; pos += 1;

        try file.writeAll(buf[0..pos]);
    }
}
