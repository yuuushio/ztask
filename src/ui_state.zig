pub const ListKind = enum {
    todo,
    done,
};

pub const ListView = struct {
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    last_move: i8 = 0,
};

pub const UiState = struct {
    /// Which list is currently focused in the UI.
    focus: ListKind = .todo,
    todo: ListView = .{},
    done: ListView = .{},

    pub fn init() UiState {
        return .{};
    }

    pub fn activeView(self: *UiState) *ListView {
        return switch (self.focus) {
            .todo => &self.todo,
            .done => &self.done,
        };
    }

    pub fn activeViewConst(self: *const UiState) *const ListView {
        return switch (self.focus) {
            .todo => &self.todo,
            .done => &self.done,
        };
    }

    /// Move selection by `delta` within the active list.
    /// Scrolling is handled in the TUI layer based on wrapping.
    pub fn moveSelection(
        self: *UiState,
        list_len: usize,
        delta: i32,
    ) void {
        var view = self.activeView();

        if (list_len == 0) {
            view.selected_index = 0;
            view.scroll_offset = 0;
            view.last_move = 0;
            return;
        }

        const max_index: i32 = @intCast(list_len - 1);
        var idx: i32 = @intCast(view.selected_index);
        idx += delta;

        if (idx < 0) idx = 0;
        if (idx > max_index) idx = max_index;

        view.selected_index = @intCast(idx);

        if (delta > 0) {
            view.last_move = 1;
        } else if (delta < 0) {
            view.last_move = -1;
        }
    }
};
