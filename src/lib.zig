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

//var const_path: [std.fs.max_path_bytes]u8 = undefined;
pub export fn DisplayComic(name: [*c]const u8, name_length: usize, path:[*c]const u8, path_length: usize) void {
    //var dbgAlloc = std.heap.DebugAllocator(.{}).init;
    //const allocator = dbgAlloc.allocator();
    const background_alloc = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(background_alloc, .{});
    var arena = std.heap.ArenaAllocator.init(background_alloc);
    const allocator = arena.allocator();
    const io = threaded.io();

    defer {
        arena.deinit();
        //const amount = dbgAlloc.detectLeaks();
        //const check = dbgAlloc.deinit();
        //std.debug.print("CHECK {}: {}\n", .{ check, amount });
    }

    var window = win.init("Comic", 800, 600, io);
    defer window.deinit(allocator);

    window.selectComic(path[0..path_length], allocator);
    window.setTitle(name[0..name_length]);

    while (!window.shouldClose()) {
        switch (window.processInputs()) {
            .LoadComic => {},
            .Close => {
                break;
            },
            .DroppedFile => {
                _ = window.getDroppedFile() catch { return; };
                //if (comic.isValid) {
                //    std.debug.print("PATH: {s}\n", .{ comic.path });
                //    window.selectComic(comic.path, allocator) catch { return; };
                //}
            },
            .NoEvent => {}
        }
        window.render();
    }
    window.close();
}

