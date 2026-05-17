const std = @import("std");
const win = @import("window.zig");
const rl = @import("raygui");
const of = @import("open-file");
const cbz = @import("cbz-decoder.zig");

fn search_comics() ?[] const u8 {

    const filter: [] const u8 = "Comic Books\x00*.cbz\x00\x00";
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
            .DroppedFile => {
                const comic = try window.getDroppedFile();
                if (comic.isValid) {
                    try window.selectComic(comic.path, allocator);
                }
            },
            .NoEvent => {}
        }
        window.render();
    }
}

