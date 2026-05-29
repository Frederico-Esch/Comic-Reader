const rl = @import("raygui");

scroll: rl.Vector2,
view: rl.Rectangle,
showPage: bool,
current_page: usize,

const Self = @This();

pub const init: Self = .{
    .view = .{},
    .scroll = .{ .x = 0, .y = 0 },
    .current_page = 0,
    .showPage = false
};
