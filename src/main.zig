const std = @import("std");
const win = @import("window.zig");
const rl = @import("raygui");
const of = @import("open-file");
const cbz = @import("cbz-decoder.zig");

fn search_comics() ?[] const u8 {

    const filter : [] const u8 = "Comic Books\x00*.cbz\x00\x00";
    var length: usize = 0;
    const path = of.open_file(filter[0..], filter.len, &length);

    if (path == null) return null;
    return path[0..length];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var dbgAlloc = std.heap.DebugAllocator(.{}).init;
    const allocator = dbgAlloc.allocator();
    defer {
        const amount = dbgAlloc.detectLeaks();
        const check = dbgAlloc.deinit();
        std.debug.print("CHECK {}: {}\n", .{ check, amount });
    }

    var window = win.init("Comic", 800, 600, io);
    defer window.deinit(allocator);

    while (!window.shouldClose()) {
        switch (window.processInputs()) {
            .LoadComic => {
                if(search_comics()) |path| {
                    try window.selectComic(path, allocator);
                }
                else {
                    window.error_selecting_comic =  "No comic selected";
                }
            },
            .Close => {
                window.close();
                break;
            },
            .NoEvent => {}
        }
        window.render();
    }
}

//pub fn main(init: std.process.Init) !void {
//    const io = init.io;
//    var debugAllocator : std.heap.DebugAllocator(.{}) = .init;
//    var arena : std.heap.ArenaAllocator = .init(debugAllocator.allocator());
//    const allocator = arena.allocator();
//
//    var ext = std.mem.zeroes([5]u8);
//    const pages = try cbz.open_comic(io, "comic.cbz", allocator);
//    const textures = try allocator.alloc(rl.Texture2D, pages.items.len);
//
//    //rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
//    //rl.SetTraceLogLevel(rl.LOG_NONE);
//    //rl.SetConfigFlags(rl.FLAG_WINDOW_HIDDEN);
//    rl.InitWindow(800, 600, "Comic");
//    rl.GuiSetStyle(rl.DEFAULT, rl.BACKGROUND_COLOR, rl.ColorToInt(rl.BLACK));
//    rl.GuiSetStyle(rl.DEFAULT, rl.TEXT_SIZE, 30);
//    rl.GuiSetStyle(rl.DEFAULT, rl.ICON_SCALE, 10);
//
//
//    var content_width:f32 = 0;
//    var content_height:f32 = 0;
//    var scale: f32 = 1;
//    {
//        std.mem.copyForwards(u8, ext[0..4], pages.items[0].name[pages.items[0].name.len-4..]);
//        const image = rl.LoadImageFromMemory(ext[0..4:0], pages.items[0].data.ptr, @intCast(pages.items[0].data.len));
//        textures[0] = rl.LoadTextureFromImage(image);
//        rl.UnloadImage(image);
//        content_width  = @floatFromInt(textures[0].width);
//        content_height = @floatFromInt(textures[0].height);
//        while (!rl.IsWindowReady()) continue;
//        if (rl.WindowShouldClose()) return;
//        const initial_window_width:f32 = 800;
//        const initial_window_height:f32 = 600;
//
//        scale = @min(initial_window_height / content_height, initial_window_width / content_width);
//
//        const width = content_width * scale;
//        const height = content_height * scale;
//
//        rl.BeginDrawing();
//        rl.ClearBackground(rl.BLACK);
//        rl.DrawTextureEx(textures[0], .{ .x = initial_window_width / 2 - width / 2, .y = initial_window_height / 2 - height / 2 }, 0, scale, .{
//            .r = 128,
//            .g = 128,
//            .b = 128,
//            .a = 100,
//        });
//        const loading_text = "LOADING COMIC...";
//        const fontSize: f32 = 20;
//        const length: f32 = @floatFromInt(rl.MeasureText(loading_text, @intFromFloat(fontSize)));
//        rl.DrawText(loading_text,
//            @intFromFloat(initial_window_width / 2 - length / 2),
//            @intFromFloat(initial_window_height / 2 - fontSize / 2),
//            @intFromFloat(fontSize), rl.WHITE);
//        rl.EndDrawing();
//    }
//
//    if (rl.IsWindowReady()) return;
//
//    for (pages.items, 0..) |page, i| {
//        if (i == 0) continue;
//        if (rl.WindowShouldClose()) break;
//        rl.PollInputEvents();
//
//        std.mem.copyForwards(u8, ext[0..4], page.name[page.name.len-4..]);
//        const image = rl.LoadImageFromMemory(ext[0..4:0], page.data.ptr, @intCast(page.data.len));
//        defer rl.UnloadImage(image);
//
//        textures[i] = rl.LoadTextureFromImage(image);
//        const width: f32 = @floatFromInt(textures[i].width);
//        content_width = if (width < content_width) content_width else width;
//        content_height += @floatFromInt(textures[i].height);
//    }
//
//    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
//
//    var scroll = rl.Vector2{ .x = -content_width * scale / 2, .y = 0};
//    var view = rl.Rectangle{};
//    var current_page: usize = 0;
//    var page_changed = false;
//    var page_changed_timer: f32 = 0;
//    rl.SetTargetFPS(20);
//    while (!rl.WindowShouldClose()) {
//        const bounds = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(rl.GetRenderWidth()), .height = @floatFromInt(rl.GetRenderHeight()) };
//
//        if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) {
//            rl.GuiDisable();
//            const offset = rl.GetMouseWheelMove() / 10;
//            if (scale + offset >= 0.01 and scale + offset <= 2.0) {
//                const sc = rl.Vector2 { .x = bounds.width / 2, .y = bounds.height / 2 };
//                const pic = rl.Vector2 { .x = scroll.x + content_width*scale / 2, .y = scroll.y + content_height*scale / 2 };
//                const d = rl.Vector2{ .x = sc.x - pic.x, .y = sc.y - pic.y };
//
//                scale += offset;
//
//                scroll.x = sc.x - content_width*scale/2 - (d.x + d.x*offset/(scale - offset));
//                scroll.y = sc.y - content_height*scale/2 - (d.y + d.y*offset/(scale - offset));
//            }
//        }
//        else {
//            rl.GuiEnable();
//            if (rl.IsKeyPressed(rl.KEY_SPACE)) {
//                scroll.y -= @as(f32, @floatFromInt(textures[current_page].height)) * scale;
//            }
//        }
//
//        if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
//            const drag = rl.GetMouseDelta();
//            scroll.x += drag.x;
//            scroll.y += drag.y;
//        }
//
//        rl.BeginDrawing();
//        rl.ClearBackground(rl.BLACK);
//        const content = rl.Rectangle{ .width = content_width*scale, .height = content_height*scale };
//        const temp_scroll = scroll;
//        _ = rl.GuiScrollPanel(bounds, null, content, &scroll, &view);
//        if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) scroll = temp_scroll;
//
//        if (content.width < bounds.width) {
//            scroll.x = (bounds.width - content.width) / 2;
//            view.x = (bounds.width - content.width) / 2;
//        }
//        if (content.height < bounds.height) {
//            scroll.y = (bounds.height - content.height) / 2;
//            view.y = (bounds.height - content.height) / 2;
//        }
//
//        rl.BeginScissorMode(@intFromFloat(view.x), @intFromFloat(view.y), @intFromFloat(view.width), @intFromFloat(view.height));
//            var offset = rl.Vector2 { .x = 0, .y = 0 };
//            var cur: usize = 0;
//            for (textures, 0..) |t, i| {
//                const height: f32 = @floatFromInt(t.height);
//                const width: f32 = @floatFromInt(t.width);
//                const x = offset.x + scroll.x + (content_width - width)*scale / 2;
//                const y = offset.y + scroll.y;
//                if (y + height*scale > 0 and y < bounds.height) {
//                    cur = i;
//                    rl.DrawTextureEx(t, .{ .x = x, .y = y }, 0, scale, rl.WHITE);
//                }
//                offset.y += height*scale;
//            }
//        rl.EndScissorMode();
//        if (current_page != cur) {
//            rl.GuiSetStyle(rl.DEFAULT, rl.TEXT_COLOR_NORMAL, rl.ColorToInt(rl.RED));
//            current_page = cur;
//            page_changed_timer = 10;
//            page_changed = true;
//        }
//        const page_format: [*c]const u8 = "#191# %zu";
//        _ = rl.GuiLabel(.{ .x = 5, .y = 0, .width = 150, .height = 50 }, rl.TextFormat(page_format, current_page));
//        if (page_changed) {
//            if (page_changed_timer > 0) {
//                page_changed_timer -= rl.GetFrameTime();
//            }
//            if (page_changed_timer <= 0) {
//                rl.GuiSetStyle(rl.DEFAULT, rl.TEXT_COLOR_NORMAL, rl.ColorToInt(rl.BLACK));
//                page_changed = false;
//            }
//        }
//
//        rl.EndDrawing();
//    }
//}
