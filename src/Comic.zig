const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cbz = @import("cbz-decoder.zig");
const rl = @import("raygui");

pub const Page = struct {
    page: cbz.PageData,
    texture: rl.Texture,
    image: ?rl.Image, //this should only be used for multithreading
    loaded: bool,
};

pub const Direction = enum(u8) {
    Vertical = 0,
    Horizontal
};

const Self = @This();

selected: ?[] const u8,
direction: Direction,
finished_loading: bool,
loaded_pages: usize,
pages: std.ArrayList(Page),
io: Io,
io_group: Io.Group,

pub fn init(io: Io, io_group: Io.Group) Self {
    return .{
        .selected = null,
        .direction = .Vertical,
        .finished_loading = false,
        .loaded_pages = 0,
        .pages = .empty,
        .io = io,
        .io_group = io_group
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

pub const SelectComicErrors = error{
    OpeningComic,
    WrongExtension,
    AllocationFailed
};
pub fn select(self: *Self, path: []const u8, allocator: Allocator) SelectComicErrors!void {
    if (!std.mem.eql(u8, path[path.len-3..], "cbz")) return SelectComicErrors.WrongExtension;

    var comic = cbz.open_comic(self.io, path, allocator) catch { return SelectComicErrors.OpeningComic; }; //FIX: Should load comic async
    defer comic.deinit(allocator);

    self.selected = path;
    self.finished_loading = false;
    self.loaded_pages = 0;

    self.io_group.cancel(self.io); //If I'm loading pages I should cancel it;
    for (self.pages.items) |*page| { //free old pages
        allocator.free(page.page.name);
        allocator.free(page.page.data);
        if (page.texture.IsTextureValid()){
            page.texture.UnloadTexture();
        }
        page.loaded = false;
    }
    self.pages.resize(allocator, comic.items.len) catch {
        return SelectComicErrors.AllocationFailed;
    };
    for (comic.items, 0..) |page, i| {
        self.pages.items[i].page = page;
    }
}
pub fn selectMem(self: *Self, name: []const u8, data: []const u8, allocator: Allocator) SelectComicErrors!void { //TODO: should be loaded asynchronously
    
    var comic = cbz.open_comic_mem(data, allocator) catch { return SelectComicErrors.OpeningComic; };
    defer comic.deinit(allocator);

    self.selected = name;
    self.finished_loading = false;
    self.loaded_pages = 0;

    self.io_group.cancel(self.io); //If I'm loading pages I should cancel it;
    for (self.pages.items) |*page| { //free old pages
        allocator.free(page.page.name);
        allocator.free(page.page.data);
        if (page.texture.IsTextureValid()){
            page.texture.UnloadTexture();
        }
        page.loaded = false;
    }
    self.pages.resize(allocator, comic.items.len) catch {
        return SelectComicErrors.AllocationFailed;
    };
    for (comic.items, 0..) |page, i| {
        self.pages.items[i].page = page;
    }
}

pub fn getName(self: *Self) []const u8 {
    if (self.selected) |path| {
        return std.fs.path.basename(path);
    }
    return "Comic";
}

fn finishLoading(self: *Self) void {
    self.finished_loading = true;
    //self.calculateContentSize();
    //self.content.scale = self.calculateFitScreenScale(0);
}

fn loadNextPageImmediatly(self: *Self) bool {
    if (self.finished_loading) return true;
    //std.Io.Mutex.State
    var idx:usize = 0;
    for (self.pages.items, 0..) |page, i| {
        idx = i;
        if (!page.loaded) break;
    }
    if (self.pages.items[idx].loaded) { //loaded everyone
        self.finishLoading();
        return true;
    }

    var ext = std.mem.zeroes([5]u8);
    const page = self.pages.items[idx].page;
    std.mem.copyForwards(u8, ext[0..4], page.name[page.name.len-4..]);
    const image = rl.LoadImageFromMemory(ext[0..4:0], page.data.ptr, @intCast(page.data.len));
    defer image.UnloadImage();

    self.pages.items[idx].texture = rl.LoadTextureFromImage(image);
    self.pages.items[idx].loaded = true;
    self.loaded_pages += 1;
    if (self.pages.items.len - 1 == idx) {
        self.finishLoading();
        return true;
    }
    return false;
}

fn threadProcess_loadPages(page: *Page) void {
    var ext = std.mem.zeroes([5]u8);
    std.mem.copyForwards(u8, ext[0..4], page.page.name[page.page.name.len-4..]);
    page.image = rl.LoadImageFromMemory(ext[0..4:0], page.page.data.ptr, @intCast(page.page.data.len));
    page.loaded = true;
}

fn loadNextPagesAsync(self: *Self) bool {
    if (self.pages.items.len <= 1) return true; //IDK what to do in this case

    if (self.io_group.token.load(.acquire) != null) return false;
    self.io_group.await(self.io) catch {
        std.debug.print("Canceled load", .{});
        return false;
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
                self.loaded_pages += 1;
            }
        }
    }
    if (first >= self.pages.items.len) {
        self.finishLoading();
        return true;
    }
    for (first..self.pages.items.len) |i| {
        if (self.pages.items[i].loaded or i - first >= threadGroups) break;

        self.io_group.concurrent(self.io, threadProcess_loadPages, .{ &self.pages.items[i] }) catch {
            std.debug.print("SOMEHOW NO MULTITHREADING AVAILABLE | Loading synchronously like it's the 18th century", .{});
            return self.loadNextPageImmediatly();
        };
    }
    return false;
}

pub const ComicState = enum {
    Unselected,
    Loading,
    Finished
};

pub fn state(self: *const Self) ComicState {
    if (self.selected == null) return .Unselected;
    if (self.finished_loading) return .Finished;
    return .Loading;
}

pub fn getComicSize(self: *Self) rl.Vector2 {
    if (!self.finished_loading) return .{};

    var width:  f32 = 0;
    var height: f32 = 0;
    for (self.pages.items) |page| {
        if (!page.loaded) continue;
        const w: f32 = @floatFromInt(page.texture.width);
        const h: f32 = @floatFromInt(page.texture.height);
        if (self.direction == .Vertical) {
            width = @max(width, w);
            height += h;
        }
        else {
            height = @max(height, h);
            width += w;
        }
    }

    return .{ .x = width, .y = height };
}

pub fn loadNextPage(self: *Self) bool {
    if (!self.pages.items[0].loaded) return self.loadNextPageImmediatly(); //load first page for loading screen
    return self.loadNextPagesAsync();
}

pub fn getFitScale(self: *const Self, pageId: usize, width: f32, height: f32) f32 {
    const page = self.pages.items[pageId];
    const content_width:  f32 = @floatFromInt(page.texture.width);
    const content_height: f32 = @floatFromInt(page.texture.height);
    return @min(height / content_height, width / content_width);
}

pub fn getScanHeight(self: *const Self, pageId: usize, scale: f32) f32 {
    if (pageId >= self.pages.items.len - 1) return 0;

    var height : f32 = 0;
    const next = pageId + 1;
    for (0..next) |i| {
        const temph: f32 = @floatFromInt(self.pages.items[i].texture.height);
        height -=  temph * scale;
    }
    return height;
}

pub fn getScanWidth(self: *const Self, pageId: usize, scale: f32) f32 {
    if (pageId >= self.pages.items.len - 1) return 0;

    var width : f32 = 0;
    const next = pageId + 1;
    for (0..next) |i| {
        const tempw: f32 = @floatFromInt(self.pages.items[i].texture.width);
        width -=  tempw * scale;
    }
    return width;
}

pub fn getCover(self: *Self) Page {
    if (!self.pages.items[0].loaded) {
        _ = self.loadNextPageImmediatly();
    }
    return self.pages.items[0];
}

pub fn pagesAmount(self: *const Self) usize {
    return self.pages.items.len;
}

