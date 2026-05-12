const std = @import("std");
const zip = std.zip;
const Allocator = std.mem.Allocator;
const FileReader = std.Io.File.Reader;

fn is_image_ext(ext: []u8) bool {
    return
        std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "JPG") or
        std.mem.eql(u8, ext, "jpeg") or std.mem.eql(u8, ext, "JPEG") or
        std.mem.eql(u8, ext, "png") or std.mem.eql(u8, ext, "PNG");
}

fn get_file_data(allocator: Allocator, entry: zip.Iterator.Entry, reader: *FileReader) ![]u8 {

    const local_data_header_offset: u64 = local_data_header_offset: {
        const local_header = blk: {
            try reader.seekTo(entry.file_offset);
            break :blk try reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        };
        if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig))
            return error.ZipBadFileOffset;
        if (local_header.version_needed_to_extract != entry.version_needed_to_extract)
            return error.ZipMismatchVersionNeeded;
        if (local_header.last_modification_time != entry.last_modification_time)
            return error.ZipMismatchModTime;
        if (local_header.last_modification_date != entry.last_modification_date)
            return error.ZipMismatchModDate;

        if (@as(u16, @bitCast(local_header.flags)) != @as(u16, @bitCast(entry.flags)))
            return error.ZipMismatchFlags;
        if (local_header.crc32 != 0 and local_header.crc32 != entry.crc32)
            return error.ZipMismatchCrc32;
        //const extents: std.zip.FileExtents = .{
        //    .uncompressed_size = local_header.uncompressed_size,
        //    .compressed_size = local_header.compressed_size,
        //    .local_file_header_offset = 0,
        //};
        if (local_header.extra_len > 0) {
            var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
            const extra = extra_buf[0..local_header.extra_len];

            {
                try reader.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len);
                try reader.interface.readSliceAll(extra);
            }

            var extra_offset: usize = 0;
            while (extra_offset + 4 <= local_header.extra_len) {
                const header_id = std.mem.readInt(u16, extra[extra_offset..][0..2], .little);
                const data_size = std.mem.readInt(u16, extra[extra_offset..][2..4], .little);
                const end = extra_offset + 4 + data_size;
                if (end > local_header.extra_len)
                    return error.ZipBadExtraFieldSize;
                const data = extra[extra_offset + 4 .. end];
                _ = data;
                switch (@as(std.zip.ExtraHeader, @enumFromInt(header_id))) {
                    .zip64_info => return error.Unimplemented,// try readZip64FileExtents(LocalFileHeader, local_header, &extents, data),
                    else => {}, // ignore
                }
                extra_offset = end;
            }
        }

        //if (extents.compressed_size != 0 and
        //    extents.compressed_size != entry.compressed_size)
        //    return error.ZipMismatchCompLen;
        //if (extents.uncompressed_size != 0 and
        //    extents.uncompressed_size != entry.uncompressed_size)
        //    return error.ZipMismatchUncompLen;

        //if (local_header.filename_len != entry.filename_len)
        //    return error.ZipMismatchFilenameLen;

        break :local_data_header_offset @as(u64, local_header.filename_len) +
            @as(u64, local_header.extra_len);
    };

    const local_data_file_offset: u64 =
        @as(u64, entry.file_offset) +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        local_data_header_offset;

    try reader.seekTo(local_data_file_offset);
    
    const data = try allocator.alloc(u8, entry.uncompressed_size);

    switch (entry.compression_method) {
        .store => {
            reader.interface.readSliceAll(data) catch |err| switch (err) {
                error.ReadFailed => return reader.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        .deflate => {
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&reader.interface, .raw, &flate_buffer);
            decompress.reader.readSliceAll(data) catch |err| switch (err) {
                error.ReadFailed => return reader.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        else => return error.UnsupportedCompressionMethod,
    }

    return data;
}

pub const PageData = struct {
    name: []u8,
    data: []u8,
};
const Comic = std.ArrayList(PageData);

pub fn open_comic (io: std.Io, file_path: []const u8, allocator: Allocator) !Comic {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_reader = file.reader(io, &[0]u8{});

    var iterator = try zip.Iterator.init(&file_reader);
    var file_name: [std.fs.max_path_bytes]u8 = undefined;

    var pages: std.ArrayList(PageData) = try .initCapacity(allocator, 0);

    while (try iterator.next()) |entry| {
        const filename = file_name[0..entry.filename_len];
        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try file_reader.interface.readSliceAll(filename);

        if (!is_image_ext(filename[filename.len-3..]))
            continue;

        const name = std.fs.path.basename(filename);
        try pages.append(allocator, .{
            .name = try allocator.alloc(u8, name.len),
            .data = try get_file_data(allocator, entry, &file_reader)
        });
        std.mem.copyForwards(u8, pages.getLast().name, name);
    }
    return pages;
}
