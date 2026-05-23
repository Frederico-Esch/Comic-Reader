const std = @import("std");
const cbz = @import("cbz-decoder.zig");
const rl = @import("raygui");
const rend = @import("render-helper.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Self = @This();

pub const Events = enum {
    NoEvent,
    LoadComic,
    DroppedFile,
    Close
};
const Page = struct {
    page: cbz.PageData,
    texture: rl.Texture,
    image: ?rl.Image, //this should only be used for multithreading
    loaded: bool,
};
const ZOOM_MIN = 0.01;
const ZOOM_MAX = 2.00;
var ComicTitle: [256]u8 = undefined;
var DropFilePathBuffer: [256]u8 = undefined;
//this technically leaks, cause it either comes from windows, or from an unhandled alloc, but it's just a couple of bytes, nobody cares |
// NO IT DOESNT LEAK, both times I use a static buffer, I love static buffer, not having to deallocate is beauty!
comic_selected: ?[] const u8,
comic_finished_loading: bool,
error_selecting_comic: ?[:0]const u8,
pages: std.ArrayList(Page),
width: f32,
height: f32,
io: Io,
io_group: Io.Group,

gui: struct {
    scroll: rl.Vector2,
    view: rl.Rectangle,
    current_page: usize,
},

content: struct {
    scale: f32,
    height: f32,
    width: f32
},

const TextSize = 30;

pub fn init(name: []const u8, initialWidth: i32, initialHeight: i32, io: Io) Self {
    rend.init(name, initialWidth, initialHeight, TextSize);
    rl.BeginDrawing();
    defer rl.EndDrawing();
    rl.ClearBackground(rl.BLACK);

    return .{
        .comic_selected = null,
        .comic_finished_loading = false,
        .width = @floatFromInt(initialWidth),
        .height = @floatFromInt(initialHeight),
        .error_selecting_comic = null,
        .pages = .empty,
        .io = io,
        .io_group = std.Io.Group.init,
        .gui = .{
            .view = .{},
            .scroll = .{ .x = 0, .y = 0 },
            .current_page = 0,
        },
        .content = .{
            .scale =  1,
            .width = 0,
            .height = 0,
        }
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    defer self.pages.deinit(allocator);
    self.io_group.cancel(self.io);

    for (self.pages.items) |page| {
        if (page.texture.IsTextureValid()) {
            page.texture.UnloadTexture();
        }
        allocator.free(page.page.data);
        allocator.free(page.page.name);
    }
}

pub fn shouldClose(self: *const Self) bool {
    _ = self;
    return rl.WindowShouldClose();
}

pub fn close(self: *const Self) void {
    _ = self;
    rl.CloseWindow();
}

fn renderComic(self: *Self) void {
    const content = rl.Rectangle{ .width = self.content.width*self.content.scale, .height = self.content.height*self.content.scale };
    const temp_scroll = self.gui.scroll;
    _ = rl.GuiScrollPanel(.{
        .x = 0, .y = 0,
        .width = self.width, .height = self.height
    }, null, content, &self.gui.scroll, &self.gui.view);
    if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) self.gui.scroll = temp_scroll;

    if (content.width < self.width) {
        self.gui.scroll.x = (self.width - content.width) / 2;
        self.gui.view.x = (self.width - content.width) / 2;
    }
    if (content.height < self.height) {
        self.gui.scroll.y = (self.height - content.height) / 2;
        self.gui.view.y = (self.height - content.height) / 2;
    }

    const view = self.gui.view;
    rl.BeginScissorMode(@intFromFloat(view.x), @intFromFloat(view.y), @intFromFloat(view.width), @intFromFloat(view.height));
        var offset = rl.Vector2 { .x = 0, .y = 0 };
        var cur: usize = 0;
        for (self.pages.items, 0..) |page, i| {
            if (!page.loaded) continue;
            const t = page.texture;
            const scroll = self.gui.scroll;

            const height: f32 = @floatFromInt(t.height);
            const width: f32 = @floatFromInt(t.width);
            const x = offset.x + scroll.x + (self.content.width - width)*self.content.scale / 2;
            const y = offset.y + scroll.y;
            if (y + height*self.content.scale > 0 and y < self.height) {
                cur = i;
                rl.DrawTextureEx(t, .{ .x = x, .y = y }, 0, self.content.scale, rl.WHITE);
            }
            offset.y += height*self.content.scale;
        }
    rl.EndScissorMode();
}

fn loadNextPageImmediatly(self: *Self) void {
    if (self.comic_finished_loading) return;
    //std.Io.Mutex.State
    var idx:usize = 0;
    for (self.pages.items, 0..) |page, i| {
        idx = i;
        if (!page.loaded) break;
    }
    if (self.pages.items[idx].loaded) { //loaded everyone
        self.comic_finished_loading = true;
        self.calculateContentSize();
    }

    var ext = std.mem.zeroes([5]u8);
    const page = self.pages.items[idx].page;
    std.mem.copyForwards(u8, ext[0..4], page.name[page.name.len-4..]);
    const image = rl.LoadImageFromMemory(ext[0..4:0], page.data.ptr, @intCast(page.data.len));
    defer image.UnloadImage();

    self.pages.items[idx].texture = rl.LoadTextureFromImage(image);
    self.pages.items[idx].loaded = true;
    if (self.pages.items.len - 1 == idx) {
        self.comic_finished_loading = true;
        self.calculateContentSize();
    }
}

fn threadProcess_loadPages(page: *Page) void {
    var ext = std.mem.zeroes([5]u8);
    std.mem.copyForwards(u8, ext[0..4], page.page.name[page.page.name.len-4..]);
    page.image = rl.LoadImageFromMemory(ext[0..4:0], page.page.data.ptr, @intCast(page.page.data.len));
    page.loaded = true;
}

fn loadNextPagesAsync(self: *Self) void {
    if (self.pages.items.len <= 1) return; //IDK what to do in this case

    if (self.io_group.token.load(.acquire) != null) return;
    self.io_group.await(self.io) catch {
        std.debug.print("Canceled load", .{});
    };

    const threadGroups = 7;
    var first: usize = 1; //zeroth is going to be loaded instantly
    while (first < self.pages.items.len) : (first += 1) {
        if (!self.pages.items[first].loaded) {
            break;
        }
        else {
            if (self.pages.items[first].image) |image| {
                self.pages.items[first].texture = rl.LoadTextureFromImage(image);
                image.UnloadImage();
                self.pages.items[first].image = null;
            }
        }
    }
    if (first >= self.pages.items.len) {
        self.comic_finished_loading = true;
        self.calculateContentSize();
        return;
    }
    for (first..self.pages.items.len) |i| {
        if (self.pages.items[i].loaded or i - first >= threadGroups) break;

        self.io_group.concurrent(self.io, threadProcess_loadPages, .{ &self.pages.items[i] }) catch {
            std.debug.print("SOMEHOW NO MULTITHREADING AVAILABLE | Loading synchronously like it's the 1700", .{});
            self.loadNextPageImmediatly();
        };
    }
}

fn renderUnselectedComic(self: *const Self) void {
    if (self.error_selecting_comic) |err| {
        rend.renderMultipleTexts("No comic selected", self.width, self.height, TextSize, .{ "Press O to open a comic", rl.GRAY, err, rl.RED });
    }
    else {
        rend.renderMultipleTexts("No comic selected", self.width, self.height, TextSize, .{ "Press O to open a comic", rl.GRAY });
    }
}

fn renderLoadingScreen(self: *const Self) void {
    const page = self.pages.items[0];
    const content_width:  f32 = @floatFromInt(page.texture.width);
    const content_height: f32 = @floatFromInt(page.texture.height);

    const scale = @min(self.height / content_height, self.width / content_width);
    const width = content_width * scale;
    const height = content_height * scale;
    page.texture.DrawTextureEx(.{ .x = self.width / 2 - width / 2, .y = self.height / 2 - height / 2 }, 0, scale, .{
        .r = 128,
        .g = 128,
        .b = 128,
        .a = 100,
    });

    const loading_text = "LOADING COMIC...";
    var loaded_pages: i32 = 0;
    for (self.pages.items) |p| {
        if (!p.loaded) break;
        loaded_pages += 1;
    }
    const loaded_text = rl.TextFormat("%d pages loaded", loaded_pages);
    const length = rl.TextLength(loading_text);
    rend.renderMultipleTexts(loading_text, self.width, self.height, TextSize, .{loaded_text[0..length:0], rl.WHITE});
}

fn calculateFitScreenScale(self: *const Self, pageId: usize) f32 {
    const page = self.pages.items[pageId];
    const content_width:  f32 = @floatFromInt(page.texture.width);
    const content_height: f32 = @floatFromInt(page.texture.height);
    return @min(self.height / content_height, self.width / content_width);
}

fn calculateContentSize(self: *Self) void {
    self.content.width = 0;
    self.content.height = 0;
    for (self.pages.items) |page| {
        if (!page.loaded) continue;
        const width:  f32 = @floatFromInt(page.texture.width);
        const height: f32 = @floatFromInt(page.texture.height);
        self.content.width = @max(self.content.width, width);
        self.content.height += height;
    }
    self.gui.scroll = .{
        .x = -self.content.width * self.content.scale / 2,
        .y = 0
    };
}

fn processViewerInput(self: *Self) void {
    if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) {
        rl.GuiDisable();
        const offset = rl.GetMouseWheelMove() / 10;
        if (self.content.scale + offset >= ZOOM_MIN and self.content.scale + offset <= ZOOM_MAX) {
            const scroll = &self.gui.scroll;
            const scale = &self.content.scale;

            const sc = rl.Vector2 { .x = self.width / 2, .y = self.height / 2 };
            const pic = rl.Vector2 {
                .x = scroll.x + self.content.width*scale.* / 2,
                .y = scroll.y + self.content.height*scale.* / 2
            };
            const d = rl.Vector2{ .x = sc.x - pic.x, .y = sc.y - pic.y };

            scale.* += offset;

            scroll.x = sc.x - self.content.width*scale.*/2 - (d.x + d.x*offset/(scale.* - offset));
            scroll.y = sc.y - self.content.height*scale.*/2 - (d.y + d.y*offset/(scale.* - offset));
        }
    }
    else {
        rl.GuiEnable();
        if (rl.IsKeyPressed(rl.KEY_SPACE)) {
            const texture = self.pages.items[self.gui.current_page].texture;
            self.gui.scroll.y -= @as(f32, @floatFromInt(texture.height)) * self.content.scale;
        }
    }

    if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)){
        const drag = rl.GetMouseDelta();
        self.gui.scroll.x += drag.x;
        self.gui.scroll.y += drag.y;
    }
}

pub fn getDroppedFile(self: *Self) !struct {
    path: [:0]const u8,
    isValid: bool,
} {

    const files = rl.LoadDroppedFiles();

    if (files.count > 1) {
        self.error_selecting_comic = "Can't select more than one comic at a time";
        files.UnloadDroppedFiles();
        return .{ .path = "", .isValid = false };
    }

    const path = files.paths[0];
    const length = rl.TextLength(path);
    if (!std.mem.eql(u8, path[length-3..length], "cbz")) {
        self.error_selecting_comic = "Invalid file type, only *.cbz allowed";
        files.UnloadDroppedFiles();
        return .{ .path = "", .isValid = false };
    }

    std.mem.copyForwards(u8, DropFilePathBuffer[0..length], path[0..length]);
    DropFilePathBuffer[length] = 0;
    files.UnloadDroppedFiles();
    return .{
        .path = DropFilePathBuffer[0..length:0],
        .isValid = true,
    };
}

//pub fn selectComicBytes(self: *Self, name:[]const u8, data: []const u8, allocator: Allocator) !void {
//    var comic = cbz.open_comic_bytes(self.io, data, allocator) catch {
//        self.error_selecting_comic = "Error opening comic";
//        return;
//    };
//    defer comic.deinit(allocator);
//
//    self.comic_selected = name;
//    self.comic_finished_loading = false;
//    self.gui.current_page = 0;
//
//    self.io_group.cancel(self.io); //If I'm loading pages I should cancel it;
//    for (self.pages.items) |*page| { //free old pages
//        allocator.free(page.page.name);
//        allocator.free(page.page.data);
//        if (page.texture.IsTextureValid()){
//            page.texture.UnloadTexture();
//        }
//        page.loaded = false;
//    }
//    try self.pages.resize(allocator, comic.items.len);
//    for (comic.items, 0..) |page, i| {
//        self.pages.items[i].page = page;
//    }
//    const basename = name;
//    std.mem.copyForwards(u8, ComicTitle[0..basename.len], basename);
//    ComicTitle[basename.len] = 0;
//    rl.SetWindowTitle(ComicTitle[0..basename.len:0]);
//    self.loadNextPageImmediatly(); //load first page for loading screen
//    self.content.scale = self.calculateFitScreenScale(0);
//}

pub fn selectComic(self: *Self, path: []const u8, allocator: Allocator) !void {
    if (std.mem.eql(u8, path[path.len-3..], "cbz")) {

        var comic = cbz.open_comic(self.io, path, allocator) catch {
            self.error_selecting_comic = "Error opening comic";
            return;
        };
        defer comic.deinit(allocator);

        self.comic_selected = path;
        self.comic_finished_loading = false;
        self.gui.current_page = 0;

        self.io_group.cancel(self.io); //If I'm loading pages I should cancel it;
        for (self.pages.items) |*page| { //free old pages
            allocator.free(page.page.name);
            allocator.free(page.page.data);
            if (page.texture.IsTextureValid()){
                page.texture.UnloadTexture();
            }
            page.loaded = false;
        }
        try self.pages.resize(allocator, comic.items.len);
        for (comic.items, 0..) |page, i| {
            self.pages.items[i].page = page;
        }
        const basename = std.fs.path.basename(path);
        std.mem.copyForwards(u8, ComicTitle[0..basename.len], basename);
        ComicTitle[basename.len] = 0;
        rl.SetWindowTitle(ComicTitle[0..basename.len:0]);
        self.loadNextPageImmediatly(); //load first page for loading screen
        self.content.scale = self.calculateFitScreenScale(0);
    }
    else {
        self.error_selecting_comic = "Wrong type of file selected, only cbz supported";
    }
}

pub fn setTitle(_: *const Self, name: []const u8) void {
    std.mem.copyForwards(u8, ComicTitle[0..name.len], name);
    ComicTitle[name.len] = 0;
    rl.SetWindowTitle(ComicTitle[0..name.len:0]);
}

pub fn processInputs(self: *Self) Events {

    self.width = @floatFromInt(rl.GetRenderWidth());
    self.height = @floatFromInt(rl.GetRenderHeight());

    if (self.pages.items.len > 0) {
        if (!self.comic_finished_loading) {
            self.loadNextPagesAsync();
        }
        else {
            self.processViewerInput();
        }
    }

    if (rl.IsFileDropped()) return .DroppedFile;
    if (rl.IsKeyPressed(rl.KEY_Q)) return .Close;
    if (rl.IsKeyPressed(rl.KEY_O)) return .LoadComic;
    return .NoEvent;
}

pub fn render(self: *Self) void {
    rl.BeginDrawing();
    defer {
        rl.EndDrawing();
        rl.WaitTime(0.05);
    }

    rl.ClearBackground(rl.BLACK);

    if (self.comic_selected != null) {
        if (self.comic_finished_loading) {
            self.renderComic(); //only non const render function ugh
        }
        else {
            self.renderLoadingScreen();
        }
    }
    else {
        self.renderUnselectedComic();
    }
}
