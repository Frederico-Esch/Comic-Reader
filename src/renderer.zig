const std = @import("std");
const Self = @This();
const rl = @import("raygui");


pub fn init(name: []const u8, initialWidth: i32, initialHeight: i32, textSize: i32 ) void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    //rl.SetTraceLogLevel(rl.LOG_NONE);
    //rl.SetConfigFlags(rl.FLAG_WINDOW_HIDDEN);
    rl.InitWindow(initialWidth, initialHeight, name.ptr);
    rl.GuiSetStyle(rl.DEFAULT, rl.BACKGROUND_COLOR, rl.ColorToInt(rl.BLACK));
    rl.GuiSetStyle(rl.DEFAULT, rl.TEXT_SIZE, textSize);
    rl.GuiSetStyle(rl.DEFAULT, rl.ICON_SCALE, 10);

    rl.SetTargetFPS(30);
}
