const std = @import("std");
const mem = std.mem;
const fs = std.fs;

/// Status of a task on disk and in memory.
pub const Status = enum {
    todo,
    ongoing,
    done,
};

/// Span into the shared backing buffer, used for projects/contexts.
/// We keep this in place for later, although we are not populating it yet.
const Span = struct {
    start: u32,
    len: u16,
};

/// Single task, all string slices reference FileImage.buf.
pub const Task = struct {
    id: u64,

    /// What the user sees and edits.
    text: []const u8,

    /// Projects and contexts are stored as spans into FileImage.buf.
    /// For now these are left empty; we will later populate them by
    /// scanning `text` for +project and #context markers.
    proj_first: u32,
    proj_count: u16,
    ctx_first: u32,
    ctx_count: u16,

    priority: u8,
    status: Status,

    /// "" => no due date rule
    due: []const u8,
    repeat: []const u8,

    /// Unix milliseconds since epoch, for sorting/grouping.
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

/// Load a JSON-lines file into a FileImage.
/// Accepts both the new rich format and older minimal lines
/// (e.g. {"text":"...","prio":0,"due":"","repeat":""}).
pub fn loadFile(allocator: mem.Allocator, file: fs.File) !FileImage {
    const stat = try file.stat();
    if (stat.size == 0) {
        return FileImage{
            .buf = &[_]u8{},
            .tasks = &[_]Task{},
            .spans = &[_]Span{},
        };
    }

    const size: usize = @intCast(stat.size);

    // Read whole file.
    var raw = try allocator.alloc(u8, size);
    errdefer allocator.free(raw);

    try file.seekTo(0);
    const got = try file.readAll(raw);
    const raw_slice = raw[0..got];

    if (raw_slice.len == 0) {
        allocator.free(raw);
        return FileImage{
            .buf = &[_]u8{},
            .tasks = &[_]Task{},
            .spans = &[_]Span{},
        };
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
    var buf = try allocator.alloc(u8, raw_slice.len);
    var parse_ok = false;
    defer {
        if (!parse_ok) {
            allocator.free(tasks);
            allocator.free(buf);
        }
    }

    var text_cursor: usize = 0;
    var task_index: usize = 0;
    var line_start: usize = 0;

    i = 0;
    while (i < raw_slice.len) : (i += 1) {
        if (raw_slice[i] == '\n') {
            const raw_line = raw_slice[line_start..i];
            const line = trimLine(raw_line);

            if (line.len != 0) {
                if (line[0] == '{') {
                    // JSON task
                    const task = try parseTaskFromJsonLine(line, buf, &text_cursor);
                    tasks[task_index] = task;
                } else {
                    // Legacy plain-text task
                    const text_slice = copyPlainLine(line, buf, &text_cursor);
                    const empty = buf[text_cursor..text_cursor];
                    tasks[task_index] = .{
                        .id = 0,
                        .text = text_slice,
                        .proj_first = 0,
                        .proj_count = 0,
                        .ctx_first = 0,
                        .ctx_count = 0,
                        .priority = 0,
                        .status = .todo,
                        .due = empty,
                        .repeat = empty,
                        .created_ms = 0,
                    };
                }
                task_index += 1;
            }

            line_start = i + 1;
        }
    }

    if (line_start < raw_slice.len) {
        const raw_line = raw_slice[line_start..raw_slice.len];
        const line = trimLine(raw_line);

        if (line.len != 0) {
            if (line[0] == '{') {
                const task = try parseTaskFromJsonLine(line, buf, &text_cursor);
                tasks[task_index] = task;
            } else {
                const text_slice = copyPlainLine(line, buf, &text_cursor);
                const empty = buf[text_cursor..text_cursor];
                tasks[task_index] = .{
                    .id = 0,
                    .text = text_slice,
                    .proj_first = 0,
                    .proj_count = 0,
                    .ctx_first = 0,
                    .ctx_count = 0,
                    .priority = 0,
                    .status = .todo,
                    .due = empty,
                    .repeat = empty,
                    .created_ms = 0,
                };
            }
            task_index += 1;
        }
    }

    parse_ok = true;
    allocator.free(raw);

    return FileImage{
        .buf = buf,
        .tasks = tasks[0..task_index],
        .spans = &[_]Span{},
    };
}


fn trimLine(line: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = line.len;

    while (start < end and
        (line[start] == ' ' or line[start] == '\t' or line[start] == '\r'))
    {
        start += 1;
    }
    while (end > start and
        (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r'))
    {
        end -= 1;
    }
    return line[start..end];
}

fn copyPlainLine(
    line: []const u8,
    text_buf: []u8,
    cursor: *usize,
) []const u8 {
    // No JSON, no escape parsing. Just copy the bytes and trim trailing '\r'.
    var end = line.len;
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


fn parsePriorityField(line: []const u8) u8 {
    const key = "\"priority\""; // was "\"prio\""
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

/// Parse `"text"`, `"due"`, `"repeat"` style string fields.
/// When `required == false` this also accepts `null` and treats it
/// as an empty slice.
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
    const quoted_len = key.len + 2; // " + key + "
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

    // Optional fields can be `null`.
    if (line[i] != '"') {
        if (!required and i + 4 <= len and
            line[i] == 'n' and line[i + 1] == 'u' and
            line[i + 2] == 'l' and line[i + 3] == 'l')
        {
            return text_buf[cursor.*..cursor.*];
        }
        return ParseError.InvalidJson;
    }
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

fn parseUnsignedField(line: []const u8, key: []const u8) ?u64 {
    const len = line.len;
    if (len == 0) return null;

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
    if (key_pos == null) return null;

    i = key_pos.? + quoted_len;

    while (i < len and line[i] != ':') : (i += 1) {}
    if (i == len) return null;
    i += 1;

    while (i < len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == len) return null;

    var value: u64 = 0;
    var saw_digit = false;
    while (i < len) {
        const b = line[i];
        if (b < '0' or b > '9') break;
        saw_digit = true;
        const digit: u64 = b - '0';
        value = value * 10 + digit;
        i += 1;
    }
    if (!saw_digit) return null;
    return value;
}

fn parseSignedField(line: []const u8, key: []const u8) ?i64 {
    const len = line.len;
    if (len == 0) return null;

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
    if (key_pos == null) return null;

    i = key_pos.? + quoted_len;

    while (i < len and line[i] != ':') : (i += 1) {}
    if (i == len) return null;
    i += 1;

    while (i < len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == len) return null;

    var negative = false;
    if (line[i] == '-') {
        negative = true;
        i += 1;
    }

    var value: i64 = 0;
    var saw_digit = false;
    while (i < len) {
        const b = line[i];
        if (b < '0' or b > '9') break;
        saw_digit = true;
        const digit: i64 = @intCast(b - '0');
        value = value * 10 + digit;
        i += 1;
    }
    if (!saw_digit) return null;

    return if (negative) -value else value;
}

fn parseStatusField(line: []const u8) ParseError!Status {
    const key = "\"status\"";
    const len = line.len;
    if (len == 0) return Status.todo;

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
    if (key_pos == null) return Status.todo;

    i = key_pos.? + key.len;

    // Find ':'
    while (i < len and line[i] != ':') : (i += 1) {}
    if (i == len) return ParseError.InvalidJson;
    i += 1;

    // Skip spaces
    while (i < len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == len) return ParseError.InvalidJson;

    if (line[i] != '"') return ParseError.InvalidJson;
    i += 1;
    const start = i;
    while (i < len and line[i] != '"') : (i += 1) {}
    if (i == len) return ParseError.InvalidJson;

    const s = line[start..i];

    if (std.mem.eql(u8, s, "todo")) return Status.todo;
    if (std.mem.eql(u8, s, "ongoing")) return Status.ongoing;
    if (std.mem.eql(u8, s, "done")) return Status.done;

    return ParseError.InvalidJson;
}


fn isTagBoundaryChar(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or
           b == '(' or b == ')' or b == '[' or b == ']' or
           b == '{' or b == '}' or b == ',' or b == '.' or
           b == ':' or b == ';' or b == '"' or b == '\'';
}

fn isTagStartChar(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or
           (b >= 'a' and b <= 'z');
}

fn isTagWordChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
           (b >= 'A' and b <= 'Z') or
           (b >= '0' and b <= '9') or
           (b == '_') or (b == '-') or (b=='/');
}

/// Scan `text` and emit a JSON array of tag names into `w`.
/// `marker` is '+' for projects, '#' for contexts.
fn writeTagsFromText(
    w: anytype,
    text: []const u8,
    marker: u8,
) !void {
    var first = true;
    var i: usize = 0;
    const n = text.len;

    while (i < n) {
        const b = text[i];

        if (b == marker and (i == 0 or isTagBoundary(text[i - 1]))) {
            const start = i + 1;
            if (start >= n) {
                i += 1;
                continue;
            }

            // require a letter after '+' / '#'
            if (!isTagStartChar(text[start])) {
                i += 1;
                continue;
            }

            var j = start + 1;
            while (j < n and isTagChar(text[j])) : (j += 1) {}

            const name = text[start..j];

            if (!first) try w.writeByte(',');
            try writeJsonString(w, name);
            first = false;

            i = j;
        } else {
            i += 1;
        }
    }
}

/// Parse one JSON-line into a Task whose slices point into `text_buf`.
fn parseTaskFromJsonLine(
    line: []const u8,
    text_buf: []u8,
    cursor: *usize,
) ParseError!Task {
    // Core string fields
    const text_slice   = try parseStringField(line, "text",   true,  text_buf, cursor);
    const due_slice    = try parseStringField(line, "due",    false, text_buf, cursor);
    const repeat_slice = try parseStringField(line, "repeat", false, text_buf, cursor);

    // Scalars
    const prio_val     = parsePriorityField(line);
    const id_opt       = parseUnsignedField(line, "id");
    const created_opt  = parseSignedField(line, "created");

    // Status; if field is malformed or absent, fall back to .todo
    const status_val = parseStatusField(line) catch Status.todo;

    // Shared empty slice sentinel out of text_buf
    const empty = text_buf[cursor.*..cursor.*];

    return Task{
        .id         = id_opt orelse 0,
        .text       = text_slice,
        .proj_first = 0,
        .proj_count = 0,
        .ctx_first  = 0,
        .ctx_count  = 0,
        .priority   = prio_val,
        .status     = status_val,
        .due        = if (due_slice.len != 0) due_slice else empty,
        .repeat     = if (repeat_slice.len != 0) repeat_slice else empty,
        .created_ms = created_opt orelse 0,
    };
}


/// Append a single task as one JSON line to `file`.
/// Schema:
/// {"id":..., "text":"...", "projects":[], "contexts":[], "priority":0,
///  "due":null|"...", "repeat":null|"...", "created":123, "status":"todo"}
pub fn appendJsonTaskLine(
    allocator: mem.Allocator,
    file: *fs.File,
    task: Task,
) !void {
    const stat = try file.stat();
    try file.seekTo(stat.size);
    try writeJsonLineForTask(allocator, file, task);
}

fn writeJsonLineForTask(
    allocator: mem.Allocator,
    file: *fs.File,
    task: Task,
) !void {
    // Worst case we escape the whole text twice (projects+contexts),
    // plus due/repeat. Just over-allocate a bit.
    const overhead: usize = 256;
    const approx_len =
        task.text.len * 4 +
        task.due.len * 2 +
        task.repeat.len * 2 +
        overhead;

    var buf = try allocator.alloc(u8, approx_len);
    defer allocator.free(buf);

    var fbs = std.io.fixedBufferStream(buf);
    var w = fbs.writer();

    // fixed field order
    try w.writeAll("{\"id\":");
    try w.print("{d}", .{task.id});

    try w.writeAll(",\"text\":");
    try writeJsonString(w, task.text);

    // projects from +tags
    try w.writeAll(",\"projects\":[");
    try writeTagsFromText(w, task.text, '+');
    try w.writeAll("]");

    // contexts from #tags
    try w.writeAll(",\"contexts\":[");
    try writeTagsFromText(w, task.text, '#');
    try w.writeAll("]");

    try w.writeAll(",\"priority\":");
    try w.print("{d}", .{task.priority});

    try w.writeAll(",\"due\":");
    if (task.due.len == 0) {
        try w.writeAll("null");
    } else {
        try writeJsonString(w, task.due);
    }

    try w.writeAll(",\"repeat\":");
    if (task.repeat.len == 0) {
        try w.writeAll("null");
    } else {
        try writeJsonString(w, task.repeat);
    }

    // created_ms stays as integer for now; fast to sort on.
    try w.writeAll(",\"created\":");
    try w.print("{d}", .{task.created_ms});

    try w.writeAll(",\"status\":\"");
    switch (task.status) {
        .todo => try w.writeAll("todo"),
        .ongoing => try w.writeAll("ongoing"),
        .done => try w.writeAll("done"),
    }
    try w.writeAll("\"}\n");

    const used = fbs.pos;
    try file.writeAll(buf[0..used]);
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            else => {
                if (b < 0x20) {
                    try w.print("\\u00{x:0>2}", .{b});
                } else {
                    try w.writeByte(b);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Rewrite entire file in JSON-lines format using `tasks`,
/// skipping the element at `skip_index` (used by :d).
///
/// This still rewrites the entire file on each mutation; for very
/// large files the more optimal design is append-only logs plus
/// a compacting pass.
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
