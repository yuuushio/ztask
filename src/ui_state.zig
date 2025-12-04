pub const ListKind = enum {
    todo,
    done,
};

pub const UiState = struct {
    /// Which list is currently focused in the UI.
    focus: ListKind = .todo,

    /// Index of the selected task within the focused list.
    selected_index: usize = 0,

    /// First visible row in the focused list.
    scroll_offset: usize = 0,

    pub fn init() UiState {
        return UiState{};
    }

    /// Switch focus between todo/done and keep selection in a valid range.
    pub fn setFocus(
        self: *UiState,
        focus: ListKind,
        list_len: usize,
        viewport_height: usize,
    ) void {
        self.focus = focus;
        self.ensureValidSelection(list_len, viewport_height);
    }

    /// Move selection by `delta` rows within the current list, updating scroll
    /// so that the selection stays visible.
    pub fn moveSelection(
        self: *UiState,
        list_len: usize,
        viewport_height: usize,
        delta: isize,
    ) void {
        if (list_len == 0) {
            self.selected_index = 0;
            self.scroll_offset = 0;
            return;
        }

        if (delta == 0) {
            self.ensureValidSelection(list_len, viewport_height);
            return;
        }

        var new_index: isize = @intCast(self.selected_index);
        new_index += delta;

        if (new_index < 0) {
            new_index = 0;
        } else {
            const last: isize = @intCast(list_len - 1);
            if (new_index > last) {
                new_index = last;
            }
        }

        self.selected_index = @intCast(new_index);
        self.ensureValidSelection(list_len, viewport_height);
    }

    pub fn ensureValidSelection(
        self: *UiState,
        list_len: usize,
        viewport_height: usize,
    ) void {
        if (list_len == 0) {
            self.selected_index = 0;
            self.scroll_offset = 0;
            return;
        }

        if (self.selected_index >= list_len) {
            self.selected_index = list_len - 1;
        }

        if (viewport_height == 0) {
            self.scroll_offset = 0;
            return;
        }

        // Ensure selection is within the visible window.
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else {
            const max_visible_index = self.scroll_offset + viewport_height - 1;
            if (self.selected_index > max_visible_index) {
                self.scroll_offset = self.selected_index - (viewport_height - 1);
            }
        }

        // Clamp scroll_offset so we do not scroll past the end.
        const max_scroll = if (list_len > viewport_height)
            list_len - viewport_height
        else
            0;

        if (self.scroll_offset > max_scroll) {
            self.scroll_offset = max_scroll;
        }
    }
};
