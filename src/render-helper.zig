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

    //rl.SetTargetFPS(30);
}

pub fn renderMultipleTexts(title: [:0]const u8, width: f32, height: f32, text_size: i32, captions: anytype) void {
    if (@typeInfo(@TypeOf(captions)) != .@"struct") { @compileError("expected tuple"); }

    const typeCaptions = @typeInfo(@TypeOf(captions)).@"struct";
    if (!typeCaptions.is_tuple) { @compileError("expected tuple"); }

    const compTimeErr = "captions have to be a tuple of alternating 0 terminated strings and colors";
    if (@mod(typeCaptions.fields.len, 2) != 0) @compileError(compTimeErr);
    comptime for (typeCaptions.fields, 0..) |caption, i| {
        if (@mod(i, 2) == 0) {
            if (@typeInfo(caption.type) != .pointer) @compileError(compTimeErr);
            if (!@typeInfo(caption.type).pointer.is_const) @compileError(compTimeErr);
            if (@typeInfo(caption.type).pointer.size == .one) {
                if (@typeInfo(@typeInfo(caption.type).pointer.child) != .array) @compileError(compTimeErr);
                if (@typeInfo(@typeInfo(caption.type).pointer.child).array.child != u8) @compileError(compTimeErr);
                if (@typeInfo(@typeInfo(caption.type).pointer.child).array.sentinel().? != 0) @compileError(compTimeErr);
            }
            else {
                if (@typeInfo(caption.type).pointer.sentinel().? != 0) @compileError(compTimeErr);
                if(@typeInfo(caption.type).pointer.size != .slice) @compileError(compTimeErr);
                if(@typeInfo(caption.type).pointer.child != u8) @compileError(compTimeErr);
            }
        }
        else {
            if (caption.type != rl.Color) @compileError(compTimeErr);
        }
    };


    const titleSize: f32 = @floatFromInt(text_size);
    {
        const length: f32 = @floatFromInt(rl.MeasureText(title.ptr, text_size));

        rl.DrawText(title,
            @intFromFloat((width - length) / 2),
            @intFromFloat((height - titleSize) / 2),
            text_size,
            rl.WHITE
        );
    }

    const textFont: f32 = @floatFromInt(text_size - 10);
    inline for (blk: {
        var values: [typeCaptions.fields.len/2]struct { text: [:0]const u8, color: rl.Color } = undefined;
        inline for (0..typeCaptions.fields.len/2) |i| {
            values[i].text = @field(captions, typeCaptions.fields[2*i].name);
            values[i].color = @field(captions, typeCaptions.fields[2*i + 1].name);
        }
        break :blk values;
    }, 1..) |caption, i| {
        const text = caption.text;
        const color = caption.color;
        const length: f32 = @floatFromInt(rl.MeasureText(text, @intFromFloat(textFont)));


        rl.DrawText(text,
            @intFromFloat((width - length) / 2),
            @intFromFloat((height - textFont) / 2 + titleSize*i),
            @intFromFloat(textFont),
            color
        );
    }
}
