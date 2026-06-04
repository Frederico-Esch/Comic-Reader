const std = @import("std");
const builtin = @import("builtin");

const zip = std.zip;
const flate = std.compress.flate;

const is_le = builtin.target.cpu.arch.endian() == .little;
const EndRecord64 = zip.EndRecord64;
const end_record64_sig = zip.end_record64_sig;
const EndLocator64 = zip.EndLocator64;
const end_locator64_sig = zip.end_locator64_sig;
const end_record_sig = zip.end_record_sig;
const CentralDirectoryFileHeader = zip.CentralDirectoryFileHeader;
const central_file_header_sig = zip.central_file_header_sig;
const LocalFileHeader = zip.LocalFileHeader;
const local_file_header_sig = zip.local_file_header_sig;
const ExtraHeader = zip.ExtraHeader;
const CompressionMethod = zip.CompressionMethod;

const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;

const Self = @This();

input: *Reader,

cd_record_count: u64,
cd_zip_offset: u64,
cd_size: u64,

cd_record_index: u64 = 0,
cd_record_offset: u64 = 0,

pub fn init(input: *Reader, size: usize) !Self {
    const end_record = try EndRecord.findFile(input, size);

    if (!isMaxInt(end_record.record_count_disk) and end_record.record_count_disk > end_record.record_count_total)
        return error.ZipDiskRecordCountTooLarge;

    if (end_record.disk_number != 0 or end_record.central_directory_disk_number != 0)
        return error.ZipMultiDiskUnsupported;

    {
        const counts_valid = !isMaxInt(end_record.record_count_disk) and !isMaxInt(end_record.record_count_total);
        if (counts_valid and end_record.record_count_disk != end_record.record_count_total)
            return error.ZipMultiDiskUnsupported;
    }

    var result: Self = .{
        .input = input,
        .cd_record_count = end_record.record_count_total,
        .cd_zip_offset = end_record.central_directory_offset,
        .cd_size = end_record.central_directory_size,
    };
    if (!end_record.need_zip64()) return result;

    const locator_end_offset: u64 = @as(u64, end_record.comment_len) + @sizeOf(EndRecord) + @sizeOf(EndLocator64);
    const stream_len = size;

    if (locator_end_offset > stream_len)
        return error.ZipTruncated;
    input.seek = stream_len - locator_end_offset;
    const locator = try input.takeStruct(EndLocator64, .little);
    if (!std.mem.eql(u8, &locator.signature, &end_locator64_sig))
        return error.ZipBadLocatorSig;
    if (locator.zip64_disk_count != 0)
        return error.ZipUnsupportedZip64DiskCount;
    if (locator.total_disk_count != 1)
        return error.ZipMultiDiskUnsupported;

    input.seek = locator.record_file_offset;

    const record64 = try input.takeStruct(EndRecord64, .little);

    if (!std.mem.eql(u8, &record64.signature, &end_record64_sig))
        return error.ZipBadEndRecord64Sig;

    if (record64.end_record_size < @sizeOf(EndRecord64) - 12)
        return error.ZipEndRecord64SizeTooSmall;
    if (record64.end_record_size > @sizeOf(EndRecord64) - 12)
        return error.ZipEndRecord64UnhandledExtraData;

    if (record64.version_needed_to_extract > 45)
        return error.ZipUnsupportedVersion;

    {
        const is_multidisk = record64.disk_number != 0 or
            record64.central_directory_disk_number != 0 or
            record64.record_count_disk != record64.record_count_total;
        if (is_multidisk)
            return error.ZipMultiDiskUnsupported;
    }

    if (isMaxInt(end_record.record_count_total)) {
        result.cd_record_count = record64.record_count_total;
    } else if (end_record.record_count_total != record64.record_count_total)
        return error.Zip64RecordCountTotalMismatch;

    if (isMaxInt(end_record.central_directory_offset)) {
        result.cd_zip_offset = record64.central_directory_offset;
    } else if (end_record.central_directory_offset != record64.central_directory_offset)
        return error.Zip64CentralDirectoryOffsetMismatch;

    if (isMaxInt(end_record.central_directory_size)) {
        result.cd_size = record64.central_directory_size;
    } else if (end_record.central_directory_size != record64.central_directory_size)
        return error.Zip64CentralDirectorySizeMismatch;

    return result;
}

pub fn next(self: *Self) !?Entry {
    if (self.cd_record_index == self.cd_record_count) {
        if (self.cd_record_offset != self.cd_size)
            return if (self.cd_size > self.cd_record_offset)
                error.ZipCdOversized
            else
                error.ZipCdUndersized;

        return null;
    }

    const header_zip_offset = self.cd_zip_offset + self.cd_record_offset;
    const input = self.input;
    input.seek = header_zip_offset;
    const header = try input.takeStruct(CentralDirectoryFileHeader, .little);
    if (!std.mem.eql(u8, &header.signature, &central_file_header_sig))
        return error.ZipBadCdOffset;

    self.cd_record_index += 1;
    self.cd_record_offset += @sizeOf(CentralDirectoryFileHeader) + header.filename_len + header.extra_len + header.comment_len;

    // Note: checking the version_needed_to_extract doesn't seem to be helpful, i.e. the zip file
    // at https://github.com/ninja-build/ninja/releases/download/v1.12.0/ninja-linux.zip
    // has an undocumented version 788 but extracts just fine.

    if (header.flags.encrypted)
        return error.ZipEncryptionUnsupported;
    // TODO: check/verify more flags
    if (header.disk_number != 0)
        return error.ZipMultiDiskUnsupported;

    var extents: FileExtents = .{
        .uncompressed_size = header.uncompressed_size,
        .compressed_size = header.compressed_size,
        .local_file_header_offset = header.local_file_header_offset,
    };

    if (header.extra_len > 0) {
        var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
        const extra = extra_buf[0..header.extra_len];

        input.seek = header_zip_offset + @sizeOf(CentralDirectoryFileHeader) + header.filename_len;
        try input.readSliceAll(extra);

        var extra_offset: usize = 0;
        while (extra_offset + 4 <= extra.len) {
            const header_id = std.mem.readInt(u16, extra[extra_offset..][0..2], .little);
            const data_size = std.mem.readInt(u16, extra[extra_offset..][2..4], .little);
            const end = extra_offset + 4 + data_size;
            if (end > extra.len)
                return error.ZipBadExtraFieldSize;
            const data = extra[extra_offset + 4 .. end];
            switch (@as(ExtraHeader, @enumFromInt(header_id))) {
                .zip64_info => try readZip64FileExtents(CentralDirectoryFileHeader, header, &extents, data),
                else => {}, // ignore
            }
            extra_offset = end;
        }
    }

    return .{
        .version_needed_to_extract = header.version_needed_to_extract,
        .flags = @bitCast(header.flags),
        .compression_method = header.compression_method,
        .last_modification_time = header.last_modification_time,
        .last_modification_date = header.last_modification_date,
        .header_zip_offset = header_zip_offset,
        .crc32 = header.crc32,
        .filename_len = header.filename_len,
        .compressed_size = extents.compressed_size,
        .uncompressed_size = extents.uncompressed_size,
        .file_offset = extents.local_file_header_offset,
        .stream = self.input
    };
}

pub const Entry = struct {
    version_needed_to_extract: u16,
    flags: GeneralPurposeFlags,
    compression_method: CompressionMethod,
    last_modification_time: u16,
    last_modification_date: u16,
    header_zip_offset: u64,
    crc32: u32,
    filename_len: u32,
    compressed_size: u64,
    uncompressed_size: u64,
    file_offset: u64,
    stream: *Reader,

    pub fn name(self: Entry, filename_buffer: []u8) ![]u8 {
        
        if (filename_buffer.len < self.filename_len)
            return error.BufferTooSmall; //better error name needed
                                         //
        const filename = filename_buffer[0..self.filename_len];
        self.stream.seek = self.header_zip_offset + @sizeOf(CentralDirectoryFileHeader);
        try self.stream.readSliceAll(filename);
        return filename;
    }

    pub fn nameAlloc(self: Entry, allocator: Allocator) ![]u8 {
        self.stream.seek = self.header_zip_offset + @sizeOf(CentralDirectoryFileHeader);
        return try self.stream.readAlloc(allocator, self.filename_len);
    }

    pub fn extractAlloc(
        self: Entry,
        allocator: Allocator
    ) !?[]u8 {

        switch (self.compression_method) {
            .store, .deflate => {},
            else => return error.UnsupportedCompressionMethod,
        }

        const isFolder = blk: {
            var lastByte: [1]u8 = undefined;
            self.stream.seek = self.header_zip_offset + @sizeOf(CentralDirectoryFileHeader) + self.filename_len - 1;
            try self.stream.readSliceAll(&lastByte);
            break :blk lastByte[0] == '/';
        };

        const local_data_header_offset: u64 = local_data_header_offset: {
            const local_header = blk: {
                self.stream.seek = self.file_offset;
                break :blk try self.stream.takeStruct(LocalFileHeader, .little);
            };
            if (!std.mem.eql(u8, &local_header.signature, &local_file_header_sig))
                return error.ZipBadFileOffset;
            if (local_header.version_needed_to_extract != self.version_needed_to_extract)
                return error.ZipMismatchVersionNeeded;
            if (local_header.last_modification_time != self.last_modification_time)
                return error.ZipMismatchModTime;
            if (local_header.last_modification_date != self.last_modification_date)
                return error.ZipMismatchModDate;

            if (@as(u16, @bitCast(local_header.flags)) != @as(u16, @bitCast(self.flags)))
                return error.ZipMismatchFlags;
            if (local_header.crc32 != 0 and local_header.crc32 != self.crc32)
                return error.ZipMismatchCrc32;
            var extents: FileExtents = .{
                .uncompressed_size = local_header.uncompressed_size,
                .compressed_size = local_header.compressed_size,
                .local_file_header_offset = 0,
            };
            if (local_header.extra_len > 0) {
                var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
                const extra = extra_buf[0..local_header.extra_len];

                {
                    self.stream.seek = self.file_offset + @sizeOf(LocalFileHeader) + local_header.filename_len;
                    try self.stream.readSliceAll(extra);
                }

                var extra_offset: usize = 0;
                while (extra_offset + 4 <= local_header.extra_len) {
                    const header_id = std.mem.readInt(u16, extra[extra_offset..][0..2], .little);
                    const data_size = std.mem.readInt(u16, extra[extra_offset..][2..4], .little);
                    const end = extra_offset + 4 + data_size;
                    if (end > local_header.extra_len)
                        return error.ZipBadExtraFieldSize;
                    const data = extra[extra_offset + 4 .. end];
                    switch (@as(ExtraHeader, @enumFromInt(header_id))) {
                        .zip64_info => try readZip64FileExtents(LocalFileHeader, local_header, &extents, data),
                        else => {}, // ignore
                    }
                    extra_offset = end;
                }
            }

            if (extents.compressed_size != 0 and
                extents.compressed_size != self.compressed_size)
                return error.ZipMismatchCompLen;
            if (extents.uncompressed_size != 0 and
                extents.uncompressed_size != self.uncompressed_size)
                return error.ZipMismatchUncompLen;

            if (local_header.filename_len != self.filename_len)
                return error.ZipMismatchFilenameLen;

            break :local_data_header_offset @as(u64, local_header.filename_len) +
                @as(u64, local_header.extra_len);
        };

        // All entries that end in '/' are directories
        if (isFolder) {
            if (self.uncompressed_size != 0)
                return error.ZipBadDirectorySize;
            return null;
        }

        const local_data_file_offset: u64 =
            @as(u64, self.file_offset) +
            @as(u64, @sizeOf(LocalFileHeader)) +
            local_data_header_offset;
        self.stream.seek = local_data_file_offset;

        // TODO limit based on self.compressed_size

        switch (self.compression_method) {
            .store => { return try self.stream.readAlloc(allocator, self.uncompressed_size); },
            .deflate => {
                var flate_buffer: [flate.max_window_len]u8 = undefined;
                var decompress: flate.Decompress = .init(self.stream, .raw, &flate_buffer);
                return try decompress.reader.readAlloc(allocator, self.uncompressed_size);
            },
            else => return error.UnsupportedCompressionMethod,
        }
    }
};

const GeneralPurposeFlags = packed struct(u16) {
    encrypted: bool,
    _: u15,
};

fn isMaxInt(uint: anytype) bool {
    return uint == std.math.maxInt(@TypeOf(uint));
}

const FileExtents = struct {
    uncompressed_size: u64,
    compressed_size: u64,
    local_file_header_offset: u64,
};

fn readZip64FileExtents(comptime T: type, header: T, extents: *FileExtents, data: []u8) !void {
    var data_offset: usize = 0;
    if (isMaxInt(header.uncompressed_size)) {
        if (data_offset + 8 > data.len)
            return error.ZipBadCd64Size;
        extents.uncompressed_size = std.mem.readInt(u64, data[data_offset..][0..8], .little);
        data_offset += 8;
    }
    if (isMaxInt(header.compressed_size)) {
        if (data_offset + 8 > data.len)
            return error.ZipBadCd64Size;
        extents.compressed_size = std.mem.readInt(u64, data[data_offset..][0..8], .little);
        data_offset += 8;
    }

    switch (T) {
        CentralDirectoryFileHeader => {
            if (isMaxInt(header.local_file_header_offset)) {
                if (data_offset + 8 > data.len)
                    return error.ZipBadCd64Size;
                extents.local_file_header_offset = std.mem.readInt(u64, data[data_offset..][0..8], .little);
                data_offset += 8;
            }
            if (isMaxInt(header.disk_number)) {
                if (data_offset + 4 > data.len)
                    return error.ZipInvalid;
                const disk_number = std.mem.readInt(u32, data[data_offset..][0..4], .little);
                if (disk_number != 0)
                    return error.ZipMultiDiskUnsupported;
                data_offset += 4;
            }
            if (data_offset > data.len)
                return error.ZipBadCd64Size;
        },
        else => {},
    }
}

pub const EndRecord = extern struct {
    signature: [4]u8 align(1),
    disk_number: u16 align(1),
    central_directory_disk_number: u16 align(1),
    record_count_disk: u16 align(1),
    record_count_total: u16 align(1),
    central_directory_size: u32 align(1),
    central_directory_offset: u32 align(1),
    comment_len: u16 align(1),

    pub const FindFileError = std.Io.File.Reader.SizeError || std.Io.File.SeekError || std.Io.File.Reader.Error || error{
        ZipNoEndRecord,
        EndOfStream,
        ReadFailed,
    };

    pub fn findFile(fr: *Reader, size: usize) FindFileError!EndRecord {
        const end_pos = size;

        var buf: [@sizeOf(EndRecord) + std.math.maxInt(u16)]u8 = undefined;
        const record_len_max = @min(end_pos, buf.len);
        var loaded_len: u32 = 0;
        var comment_len: u16 = 0;
        while (true) {
            const record_len: u32 = @as(u32, comment_len) + @sizeOf(EndRecord);
            if (record_len > record_len_max)
                return error.ZipNoEndRecord;

            if (record_len > loaded_len) {
                const new_loaded_len = @min(loaded_len + 300, record_len_max);
                const read_len = new_loaded_len - loaded_len;

                fr.seek = end_pos - @as(u64, new_loaded_len);
                const read_buf: []u8 = buf[buf.len - new_loaded_len ..][0..read_len];
                try fr.readSliceAll(read_buf);
                loaded_len = new_loaded_len;
            }

            const record_bytes = buf[buf.len - record_len ..][0..@sizeOf(EndRecord)];
            if (std.mem.eql(u8, record_bytes[0..4], &end_record_sig) and
                std.mem.readInt(u16, record_bytes[20..22], .little) == comment_len)
            {
                const record: *align(1) EndRecord = @ptrCast(record_bytes.ptr);
                if (!is_le) std.mem.byteSwapAllFields(EndRecord, record);
                return record.*;
            }

            if (comment_len == std.math.maxInt(u16))
                return error.ZipNoEndRecord;
            comment_len += 1;
        }
    }

    pub fn need_zip64(self: EndRecord) bool {
        return isMaxInt(self.record_count_disk) or
            isMaxInt(self.record_count_total) or
            isMaxInt(self.central_directory_size) or
            isMaxInt(self.central_directory_offset);
    }

};
