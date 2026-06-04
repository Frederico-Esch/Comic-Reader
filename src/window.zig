const std = @import("std");
const cbz = @import("cbz-decoder.zig");
const rl = @import("raygui");
const rend = @import("render-helper.zig");
const Gui = @import("Gui.zig");
const Content = @import("Content.zig");
const Comic = @import("Comic.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Self = @This();

pub const Events = enum {
    NoEvent,
    LoadComic,
    DroppedFile,
    Close
};
const ZOOM_MIN = 0.01;
const ZOOM_MAX = 2.00;
var ComicTitle: [256]u8 = undefined;
var DropFilePathBuffer: [256]u8 = undefined;
//this technically leaks, cause it either comes from windows, or from an unhandled alloc, but it's just a couple of bytes, nobody cares |
// NO IT DOESNT LEAK, both times I use a static buffer, I love static buffer, not having to deallocate is beauty!
error_selecting_comic: ?[:0]const u8,
width: f32,
height: f32,
io: Io,

gui: Gui,
content: Content,
comic: Comic,

const TextSize = 30;

pub fn init(name: []const u8, initialWidth: i32, initialHeight: i32, io: Io) Self {
    rend.init(name, initialWidth, initialHeight, TextSize);
    rl.BeginDrawing();
    defer rl.EndDrawing();
    rl.ClearBackground(rl.BLACK);

    return .{
        .width = @floatFromInt(initialWidth),
        .height = @floatFromInt(initialHeight),
        .error_selecting_comic = null,
        .io = io,
        .gui = .init,
        .content = .init,
        .comic = .init(io, std.Io.Group.init)
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.comic.deinit(allocator);
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
        self.gui.current_page = self.comic.pagesAmount();
        for (self.comic.pages.items, 0..) |page, i| {
            if (!page.loaded) continue;
            const t = page.texture;
            const scroll = self.gui.scroll;

            const height: f32 = @floatFromInt(t.height);
            const width: f32 = @floatFromInt(t.width);
            const x = offset.x + scroll.x + (self.content.width - width)*self.content.scale / 2;
            const y = offset.y + scroll.y;
            if (y + height*self.content.scale > 0 and y < self.height) {
                self.gui.current_page = @min(self.gui.current_page, i);
                rl.DrawTextureEx(t, .{ .x = x, .y = y }, 0, self.content.scale, rl.WHITE);
            }
            offset.y += height*self.content.scale;
        }
    rl.EndScissorMode();

    if (self.gui.showPage) //Doing this every frame doesn't sound smart
    {
        const pageText = rl.TextFormat("%d", self.gui.current_page);
        const textSize = TextSize;
        const textWidth = rl.MeasureText(pageText, textSize);
        const textOffset = 10;
        rl.DrawRectangle(textOffset / 2, textOffset / 2, textWidth + textOffset, textSize + textOffset / 2, rl.BLACK);
        rl.DrawText(pageText, textOffset, textOffset, textSize, rl.WHITE);
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

fn renderLoadingScreen(self: *Self) void {
    const page = self.comic.getCover();
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
    const loaded_pages = self.comic.loaded_pages;
    const loaded_text = rl.TextFormat("%d pages loaded", loaded_pages);
    const length = rl.TextLength(loading_text);
    rend.renderMultipleTexts(loading_text, self.width, self.height, TextSize, .{loaded_text[0..length:0], rl.WHITE});
}

fn applyZoom(self: *Self, offset: f32) void {
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

fn processViewerInput(self: *Self) void {
    const KeyboardScrollSensitivity = 15;
    const zoomSensitivity = 0.1;

    if (rl.IsKeyDown(rl.KEY_LEFT_CONTROL)) {
        rl.GuiDisable();
        const offset = rl.GetMouseWheelMove() / 10;
        self.applyZoom(offset);
    }
    else if(rl.IsKeyDown(rl.KEY_LEFT_SHIFT)) {
        if (rl.IsKeyPressed(rl.KEY_EQUAL)) {
            self.applyZoom(zoomSensitivity);
        }
        if (rl.IsKeyPressed(rl.KEY_MINUS)) {
            self.applyZoom(-zoomSensitivity);
        }
    }
    else {
        rl.GuiEnable();
        if (rl.IsKeyPressed(rl.KEY_EQUAL)) {
            const newScale = self.comic.getFitScale(self.gui.current_page, self.width, self.height);
            self.applyZoom(newScale - self.content.scale);
        }

        if (rl.IsKeyPressed(rl.KEY_SPACE)) {
            self.gui.scroll.y = self.comic.getScanHeight(self.gui.current_page, self.content.scale) - 1;
            //const texture = self.pages.items[self.gui.current_page].texture;
            //self.gui.scroll.y -= @as(f32, @floatFromInt(texture.height)) * self.content.scale;
        }

        if (rl.IsKeyDown(rl.KEY_DOWN) or rl.IsKeyDown(rl.KEY_J)) {
            self.gui.scroll.y -= KeyboardScrollSensitivity;
        }
        if (rl.IsKeyDown(rl.KEY_UP) or rl.IsKeyDown(rl.KEY_K)) {
            self.gui.scroll.y += KeyboardScrollSensitivity;
        }
        if (rl.IsKeyPressed(rl.KEY_ZERO)) {
            self.gui.scroll.y = 0;
        }

        if (rl.IsKeyDown(rl.KEY_RIGHT) or rl.IsKeyDown(rl.KEY_L)) {
            self.gui.scroll.x -= KeyboardScrollSensitivity;
        }
        if (rl.IsKeyDown(rl.KEY_LEFT) or rl.IsKeyDown(rl.KEY_H)) {
            self.gui.scroll.x += KeyboardScrollSensitivity;
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

pub fn selectComic(self: *Self, path: []const u8, allocator: Allocator) void {
    self.comic.select(path, allocator) catch |e| {
        switch (e) {
            error.OpeningComic => {
                self.error_selecting_comic = "Error opening comic";
            },
            error.WrongExtension => {
                self.error_selecting_comic = "Wrong file type selected, only cbz supported";
            },
            error.AllocationFailed => {
                self.error_selecting_comic = "Internal Error";
            }
        }
        return;
    };

    self.gui.current_page = 0;

    const name = self.comic.getName();
    std.mem.copyForwards(u8, ComicTitle[0..name.len], name);
    ComicTitle[name.len] = 0;
    rl.SetWindowTitle(ComicTitle[0..name.len:0]);
    _ = self.comic.loadNextPage();
    self.content.scale = self.comic.getFitScale(0, self.width, self.height);
}

pub fn selectComicMem(self: *Self, name:[] const u8, data: []const u8, allocator: Allocator) void {
    self.comic.selectMem(name, data, allocator) catch |e| {
        switch (e) {
            error.OpeningComic => {
                self.error_selecting_comic = "Error opening comic";
            },
            error.WrongExtension => {
                self.error_selecting_comic = "Wrong file type selected, only cbz supported";
            },
            error.AllocationFailed => {
                self.error_selecting_comic = "Internal Error";
            }
        }
        return;
    };

    self.gui.current_page = 0;

    std.mem.copyForwards(u8, ComicTitle[0..name.len], name);
    ComicTitle[name.len] = 0;
    rl.SetWindowTitle(ComicTitle[0..name.len:0]);
    _ = self.comic.loadNextPage();
    self.content.scale = self.comic.getFitScale(0, self.width, self.height);
}

pub fn setTitle(_: *const Self, name: []const u8) void {
    std.mem.copyForwards(u8, ComicTitle[0..name.len], name);
    ComicTitle[name.len] = 0;
    rl.SetWindowTitle(ComicTitle[0..name.len:0]);
}

pub fn processInputs(self: *Self) Events {

    self.width = @floatFromInt(rl.GetRenderWidth());
    self.height = @floatFromInt(rl.GetRenderHeight());

    switch (self.comic.state()) {
        .Unselected => { },
        .Loading => {
            if (self.comic.loadNextPage()) {
                const size = self.comic.getComicSize();
                self.content.width = size.x;
                self.content.height = size.y;

                self.gui.scroll = .{
                    .x = -self.content.width * self.content.scale / 2,
                    .y = 0
                };
            }
        },
        .Finished => { self.processViewerInput(); }
    }

    if (rl.IsKeyPressed(rl.KEY_P))
        self.gui.showPage = !self.gui.showPage;

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

    switch (self.comic.state()) {
        .Unselected => {
            self.renderUnselectedComic();
        },
        .Loading => {
            self.renderLoadingScreen();
        },
        .Finished => {
            self.renderComic(); //only non const render function ugh
        }
    }
}
