const NitreDb = @This();

db_file: std.Io.File,
db_io: std.Io,
db_header: NitreDbHeader,
db_page_pool: PagePool,
db_allocator: std.mem.Allocator,

const std = @import("std");
const NitreDbHeaderSize = 512;
const NitreDbHeaderMagic = "NITREDB!";
const PageSize = 8192;
const PageHeaderSize = 64;
const MaxRecordSize = PageSize - PageHeaderSize - DataPageSlot.Size;

const NitreDbHeader = struct {
    version: u32 = 1,
    page_count: u32 = 0,
    first_data_page: u32 = 0,
    first_index_page: u32 = 0,
};

const DbEntry = struct {
    id: u64,
    filename: []const u8,
    archive_name: []const u8,
    created_time: u64,
    modified_time: u64,
};

const DataPageSlot = packed struct {
    const Size = @bitSizeOf(DataPageSlot) / 8;

    //Offset from the start of the page where the row data starts
    offset: u16 = 0,
    //The length of the slot
    length: u16 = 0,
    flags: packed struct(u8) {
        deleted: bool = false,
        _: u7 = 0,
    } = .{},
};

const NitreDbPageContentType = enum(u32) {
    Data = 0,
    Index = 1,
    ClusteredIndex = 2,
};

//Page header will be stored on disk as content_type(u8), slot_count(u16), next_page(u32), prev_page(u32), data_length(u16)
const NitreDbPageHeader = struct {
    next_page: ?u32 = null,
    prev_page: ?u32 = null,
    slot_count: u16 = 0,
    data_length: u16 = 0,
    content_type: NitreDbPageContentType = .Data,

    fn read(header: *NitreDbPageHeader, reader: *std.Io.Reader) !void {
        const content_type: u32 = @intCast(try reader.takeByte());
        header.content_type = @enumFromInt(content_type);
        header.slot_count = try reader.takeInt(u16, .little);
        header.next_page = try reader.takeInt(u32, .little);
        header.prev_page = try reader.takeInt(u32, .little);
        header.data_length = try reader.takeInt(u16, .little);

        if (header.next_page == std.math.maxInt(u32))
            header.next_page = null;
        if (header.prev_page == std.math.maxInt(u32))
            header.prev_page = null;
    }

    fn write(header: *NitreDbPageHeader, writer: *std.Io.Writer) !void {
        const content_type: u8 = @intCast(@intFromEnum(header.content_type));
        try writer.writeByte(content_type);
        try writer.writeInt(u16, header.slot_count, .little);

        var next_page: u32 = std.math.maxInt(u32);
        if (header.next_page != null)
            next_page = header.next_page.?;
        var prev_page: u32 = std.math.maxInt(u32);
        if (header.prev_page != null)
            prev_page = header.prev_page.?;

        try writer.writeInt(u32, next_page, .little);
        try writer.writeInt(u32, prev_page, .little);
        try writer.writeInt(u16, header.data_length, .little);

        //Pad the header to reserver space for future use
        try writer.splatByteAll(0, PageHeaderSize - 13);
    }
};

const NitreDbPage = struct {
    header: NitreDbPageHeader = .{},
    page_number: u32 = 0,
    last_used: u32 = 0,
    internal_flags: packed struct(u8) {
        resident: bool = false,
        dirty: bool = false,
        _: u6 = 0,
    } = .{},
    data: [PageSize]u8 = undefined,

    fn loadFromDisk(page: *NitreDbPage, db_file: std.Io.File, page_number: u32, io: std.Io) !void {
        page.page_number = page_number;
        var reader = db_file.reader(io, &page.data);
        try reader.seekTo(NitreDbHeaderSize + page.page_number * PageSize);
        try reader.interface.fill(page.data.len);

        var header_reader = std.Io.Reader.fixed(&page.data);
        try page.header.read(&header_reader);
    }

    fn writeToDisk(page: *NitreDbPage, db_file: std.Io.File, io: std.Io) !void {
        var writer = std.Io.Writer.fixed(&page.data);
        try page.header.write(&writer);

        var file_writer = db_file.writer(io, &[0]u8{});
        try file_writer.seekTo(NitreDbHeaderSize + page.page_number * PageSize);
        try file_writer.interface.writeAll(&page.data);
    }

    //Checks if a data page can fit a row of size
    fn canFitRow(page: *const NitreDbPage, size: u16) bool {
        const free_space = PageSize - (page.header.data_length + PageHeaderSize + page.header.slot_count * DataPageSlot.Size);
        const required_space = size + DataPageSlot.Size;
        return required_space <= free_space;
    }
};

const DataPageInterface = struct {
    data: []u8,

    fn readSlot(interface: *DataPageInterface, slot_number: u16) DataPageSlot {
        const address = PageSize - (slot_number + 1) * DataPageSlot.Size;
        var reader = std.Io.Reader.fixed(interface.data);
        reader.seek = address;
        const slot = reader.takeStruct(DataPageSlot, .little) catch unreachable;
        return slot;
    }

    fn writeSlot(interface: *const DataPageInterface, slot_number: u16, slot: *const DataPageSlot) void {
        const address = PageSize - (slot_number + 1) * DataPageSlot.Size;
        var writer = std.Io.Writer.fixed(interface.data);
        writer.end = address;
        writer.writeStruct(slot.*, .little) catch unreachable;
    }

    fn writeRaw(interface: *DataPageInterface, data: []u8, address: u16) void {
        var writer = std.Io.Writer.fixed(interface.data);
        writer.end = address;
        writer.writeAll(data) catch unreachable;
    }

    //Gets the largest id found in the page, or null if the page is empty
    fn getLargestId(interface: *const DataPageInterface, page_slot_count: u16) ?u64 {
        if (page_slot_count == 0)
            return null;
        var reader = std.Io.Reader.fixed(interface.data);
        reader.seek = PageSize - DataPageSlot.Size * page_slot_count;
        const slot = reader.takeStruct(DataPageSlot, .little) catch unreachable;
        reader.seek = slot.offset;
        const id = reader.takeInt(u64, .little) catch unreachable;
        return id;
    }

    //Inserts data into the page and creates a slot. Assumes there is room for the data and slot.
    fn insertData(interface: *const DataPageInterface, data: []const u8, id: u64, page: *NitreDbPage) void {
        const data_len: u16 = @intCast(data.len);
        const address = PageHeaderSize + page.header.data_length;
        var writer = std.Io.Writer.fixed(interface.data);
        writer.end = address;
        writer.writeAll(data) catch unreachable;
        const slot: DataPageSlot = .{ .length = data_len, .offset = address };
        interface.insertSlotFast(id, &slot, page.header.slot_count);
        page.header.data_length += data_len;
        page.header.slot_count += 1;
        page.internal_flags.dirty = true;
    }

    //Inserts a slot into a page in sorted order given the id of the data inserted. Assumes the page has room to fit the slot
    fn insertSlotFast(interface: *const DataPageInterface, data_id: u64, slot: *const DataPageSlot, slot_count: u16) void {
        var page_reader = std.Io.Reader.fixed(interface.data);
        page_reader.seek = PageSize - slot_count * DataPageSlot.Size;

        var slot_move_count: u32 = 0;
        var id_reader = std.Io.Reader.fixed(interface.data);
        while (page_reader.seek < PageSize) {
            const moved_slot = page_reader.takeStruct(DataPageSlot, .little) catch unreachable;
            id_reader.seek = moved_slot.offset;
            const id = id_reader.takeInt(u64, .little) catch unreachable;
            if (id > data_id) {
                slot_move_count += 1;
                continue;
            }
            break;
        }

        const start = PageSize - DataPageSlot.Size * slot_count;
        const end = start + DataPageSlot.Size * slot_move_count;
        if (slot_move_count > 0) {
            @memmove(interface.data[start - DataPageSlot.Size .. end - DataPageSlot.Size], interface.data[start..end]);
        }

        var page_writer = std.Io.Writer.fixed(interface.data);
        page_writer.end = end - DataPageSlot.Size;
        page_writer.writeStruct(slot.*, .little) catch unreachable;
    }
};

const InsertResult = struct {
    split_count: u32,
    //The largest id in each of the pages involved in the insert if the insert involved a split.
    id_limit_1: u64 = 0,
    id_limit_2: u64 = 0,
    id_limit_3: u64 = 0,
};

//TODO: Finish implementing this. It needs to handle the root and intermediate index pages. When calling it
//from another function, it should be called on the root page of a table.
fn insertDataWithId(nitreDb: *NitreDb, page_number: u32, data: []const u8, data_id: u64) !InsertResult {
    var page = try nitreDb.db_page_pool.acquirePageExisting(page_number, nitreDb.db_file, nitreDb.db_io);
    const data_len: u16 = @intCast(data.len);
    var page_if: DataPageInterface = .{ .data = &page.data };

    if (page.header.content_type == .Data) {
        //Return early if we can fit the data into the requested page without splitting
        if (page.canFitRow(data_len)) {
            page_if.insertData(data, data_id, page);
            nitreDb.db_page_pool.releasePage(page);
            return .{ .split_count = 0 };
        }

        //Split the page and check if the row will now fit into the original page
        page = try splitDataPage(page, nitreDb, data_id);
        page_if = .{ .data = &page.data };
        var id_limit_2 = page_if.getLargestId(page.header.slot_count) orelse std.math.maxInt(u64);
        const split_page_number_1 = page.page_number;
        nitreDb.db_page_pool.releasePage(page);
        page = try nitreDb.db_page_pool.acquirePageExisting(page_number, nitreDb.db_file, nitreDb.db_io);
        if (page.canFitRow(data_len)) {
            page_if = .{ .data = &page.data };
            page_if.insertData(data, data_id, page);
            nitreDb.db_page_pool.releasePage(page);
            return .{ .split_count = 1, .id_limit_1 = data_id, .id_limit_2 = id_limit_2 };
        }

        page_if = .{ .data = &page.data };
        const id_limit_1 = page_if.getLargestId(page.header.slot_count) orelse std.math.maxInt(u64);

        //Check if the data can fit into the page created by the split
        nitreDb.db_page_pool.releasePage(page);
        page = try nitreDb.db_page_pool.acquirePageExisting(split_page_number_1, nitreDb.db_file, nitreDb.db_io);
        if (page.canFitRow(data_len)) {
            page_if = .{ .data = &page.data };
            page_if.insertData(data, data_id, page);
            id_limit_2 = page_if.getLargestId(page.header.slot_count) orelse std.math.maxInt(u64);
            nitreDb.db_page_pool.releasePage(page);
            return .{ .split_count = 1, .id_limit_1 = id_limit_1, .id_limit_2 = id_limit_2 };
        }

        //At this point, the record doesn't fit into either the original page or the new page created by the split
        //It will have to go in its own page
        page = try splitDataPage(page, nitreDb, 0);
        page_if = .{ .data = &page.data };
        const id_limit_3 = page_if.getLargestId(page.header.slot_count) orelse std.math.maxInt(u64);
        nitreDb.db_page_pool.releasePage(page);
        page = try nitreDb.db_page_pool.acquirePageExisting(split_page_number_1, nitreDb.db_file, nitreDb.db_io);
        page_if = .{ .data = &page.data };
        page_if.insertData(data, data_id, page);
        nitreDb.db_page_pool.releasePage(page);
        return .{ .split_count = 2, .id_limit_1 = id_limit_1, .id_limit_2 = data_id, .id_limit_3 = id_limit_3 };
    }

    //TODO: Implement handling the root and intermediate index pages
    return error.Unimplemented;
}

//Splits a data page by moving all the records with a primary key >= to the upper bound to a new page.
//Returns the new page.
fn splitDataPage(page: *NitreDbPage, nitreDb: *NitreDb, upper_bound_id: u64) !*NitreDbPage {
    const original_page_number = page.page_number;
    const original_page_next = page.header.next_page;
    const slot_count = page.header.slot_count;
    page.header.slot_count = 0;
    page.header.data_length = 0;
    page.internal_flags.dirty = true;
    var temp_data: [PageSize]u8 = undefined;
    std.mem.copyForwards(u8, &temp_data, &page.data);

    var temp_page_if: DataPageInterface = .{ .data = &temp_data };
    var original_page_if: DataPageInterface = .{ .data = &page.data };

    var address_counter: u16 = PageHeaderSize;
    var next_slot_idx: usize = 0;

    //Copy the slot and row data from temp back to the original page
    for (0..slot_count) |slot_idx| {
        const slot_number: u16 = @intCast(slot_idx);
        var slot = temp_page_if.readSlot(slot_number);
        var reader = std.Io.Reader.fixed(&temp_data);
        reader.seek = slot.offset;
        const record_id = reader.takeInt(u64, .little) catch unreachable;
        if (record_id >= upper_bound_id) {
            break;
        } else {
            next_slot_idx += 1;
        }

        original_page_if.writeRaw(temp_data[slot.offset..][0..slot.length], address_counter);
        slot.offset = address_counter;
        original_page_if.writeSlot(slot_number, &slot);
        address_counter += slot.length;
        page.header.slot_count += 1;
        page.header.data_length += slot.length;
    }

    //Release the original page and acquire the new one we're splitting into
    nitreDb.db_page_pool.releasePage(page);
    var new_page = try nitreDb.db_page_pool.acquirePageNew(nitreDb, null, null, .Data);
    new_page.internal_flags.dirty = true;
    address_counter = PageHeaderSize;
    var new_page_if: DataPageInterface = .{ .data = &new_page.data };

    //Copy the slot and row data from temp into the new page
    for (next_slot_idx..slot_count) |slot_idx| {
        const slot_number: u16 = @intCast(slot_idx);
        var slot = temp_page_if.readSlot(slot_number);
        new_page_if.writeRaw(temp_data[slot.offset..][0..slot.length], address_counter);
        slot.offset = address_counter;
        new_page_if.writeSlot(new_page.header.slot_count, &slot);
        address_counter += slot.length;
        new_page.header.slot_count += 1;
        new_page.header.data_length += slot.length;
    }

    //We need to update the next ptr of the original page to point to the new page. This could be optimized but the current
    //implementation of the page pool limits us to only having 1 page checked out at a time. TODO: Optimize this nonsense
    const new_page_number = new_page.page_number;
    new_page.header.prev_page = original_page_number;
    new_page.header.next_page = original_page_next;
    new_page.internal_flags.dirty = true;
    nitreDb.db_page_pool.releasePage(new_page);
    var original_page = try nitreDb.db_page_pool.acquirePageExisting(original_page_number, nitreDb.db_file, nitreDb.db_io);
    original_page.header.next_page = new_page_number;
    original_page.internal_flags.dirty = true;
    nitreDb.db_page_pool.releasePage(original_page);
    new_page = try nitreDb.db_page_pool.acquirePageExisting(new_page_number, nitreDb.db_file, nitreDb.db_io);

    return new_page;
}

pub fn insertRecord(nitreDb: *NitreDb, record: []const u8, id: u64) !void {
    var page_opt: ?*NitreDbPage = null;
    if (nitreDb.db_header.page_count == 0) {
        page_opt = try nitreDb.db_page_pool.acquirePageNew(nitreDb, null, null, .Data);
        nitreDb.db_header.first_data_page += page_opt.?.page_number;
    } else {
        page_opt = try nitreDb.db_page_pool.acquirePageExisting(nitreDb.db_header.first_data_page, nitreDb.db_file, nitreDb.db_io);
    }
    var page = page_opt.?;
    page.internal_flags.dirty = true;
    const page_number = page.page_number;
    nitreDb.db_page_pool.releasePage(page);
    const record_len: u32 = @intCast(record.len);

    var data_buffer: [1024]u8 = undefined;
    var io_writer = std.Io.Writer.fixed(&data_buffer);
    try io_writer.writeInt(u64, id, .little);
    try io_writer.writeInt(u32, record_len, .little);
    try io_writer.writeAll(record);

    _ = try insertDataWithId(nitreDb, page_number, data_buffer[0 .. record_len + 12], id);
}

pub fn walkRecordsTest(nitreDb: *NitreDb) !void {
    var page_opt: ?*NitreDbPage = null;
    if (nitreDb.db_header.page_count == 0) {
        page_opt = try nitreDb.db_page_pool.acquirePageNew(nitreDb, null, null, .Data);
        nitreDb.db_header.first_data_page += page_opt.?.page_number;
    } else {
        page_opt = try nitreDb.db_page_pool.acquirePageExisting(nitreDb.db_header.first_data_page, nitreDb.db_file, nitreDb.db_io);
    }
    var page = page_opt.?;
    var page_if: DataPageInterface = .{ .data = &page.data };
    var reader = std.Io.Reader.fixed(&page.data);
    var print_buffer: [128]u8 = undefined;
    for (0..page.header.slot_count) |idx| {
        const slot_idx: u16 = @intCast(idx);
        const slot = page_if.readSlot(slot_idx);
        reader.seek = slot.offset + 8;
        const len = try reader.takeInt(u32, .little);
        try reader.readSliceAll(print_buffer[0..len]);
        std.debug.print("{s}\n", .{print_buffer[0..len]});
    }

    if (page.header.next_page == null) {
        nitreDb.db_page_pool.releasePage(page);
        return;
    }

    const next_page = page.header.next_page orelse unreachable;
    nitreDb.db_page_pool.releasePage(page);

    page = try nitreDb.db_page_pool.acquirePageExisting(next_page, nitreDb.db_file, nitreDb.db_io);
    page_if = .{ .data = &page.data };
    for (0..page.header.slot_count) |idx| {
        const slot_idx: u16 = @intCast(idx);
        const slot = page_if.readSlot(slot_idx);
        reader.seek = slot.offset + 8;
        const len = try reader.takeInt(u32, .little);
        try reader.readSliceAll(print_buffer[0..len]);
        std.debug.print("{s}\n", .{print_buffer[0..len]});
    }
}

pub fn splitPageTest(nitreDb: *NitreDb, boundary: u64) !void {
    var page_opt: ?*NitreDbPage = null;
    if (nitreDb.db_header.page_count == 0) {
        page_opt = try nitreDb.db_page_pool.acquirePageNew(nitreDb, null, null, .Data);
        nitreDb.db_header.first_data_page += page_opt.?.page_number;
    } else {
        page_opt = try nitreDb.db_page_pool.acquirePageExisting(nitreDb.db_header.first_data_page, nitreDb.db_file, nitreDb.db_io);
    }
    var page = page_opt.?;

    page = try splitDataPage(page, nitreDb, boundary);
    nitreDb.db_page_pool.releasePage(page);
}

pub fn flushDatabase(nitreDb: *NitreDb) !void {
    try nitreDb.db_page_pool.flushAll(nitreDb.db_file, nitreDb.db_io);
    try writeHeader(nitreDb.db_file, &nitreDb.db_header, nitreDb.db_io);
}

pub fn closeDatabase(nitreDb: *NitreDb) void {
    nitreDb.db_file.close(nitreDb.db_io);
    nitreDb.db_page_pool.deinit();
}

pub fn openDatabase(filepath: []const u8, io: std.Io, allocator: std.mem.Allocator) !NitreDb {
    const file = try std.Io.Dir.createFileAbsolute(io, filepath, .{ .truncate = false, .read = true });
    errdefer file.close(io);
    var page_pool = try PagePool.init(1, allocator);
    errdefer page_pool.deinit();
    const file_length = try file.length(io);
    var header: NitreDbHeader = .{};

    //Validate the database
    if (file_length > 0) {
        try readHeader(file, &header, io);
    } else {
        try initDatabase(file, &header, io);
    }

    return .{
        .db_file = file,
        .db_io = io,
        .db_header = header,
        .db_page_pool = page_pool,
        .db_allocator = allocator,
    };
}

//Initializes a new database file
fn initDatabase(file: std.Io.File, header: *const NitreDbHeader, io: std.Io) !void {
    try writeHeader(file, header, io);
}

//Writes the database header
fn writeHeader(file: std.Io.File, header: *const NitreDbHeader, io: std.Io) !void {
    var write_buffer: [NitreDbHeaderSize]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(NitreDbHeaderMagic);
    try writer.interface.writeInt(u32, header.version, .little);
    try writer.interface.writeInt(u32, header.page_count, .little);
    try writer.interface.writeInt(u32, header.first_data_page, .little);
    try writer.interface.writeInt(u32, header.first_index_page, .little);

    try writer.flush();

    const padding = NitreDbHeaderSize - writer.pos;
    try writer.interface.splatByteAll(0, padding);

    try writer.flush();
}

//Reads and validates the database header
fn readHeader(file: std.Io.File, header: *NitreDbHeader, io: std.Io) !void {
    const file_length = try file.length(io);
    if (file_length < NitreDbHeaderSize) {
        return error.InvalidHeader;
    }

    var read_buffer: [NitreDbHeaderSize]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var magic_buffer: [NitreDbHeaderMagic.len]u8 = undefined;
    try reader.interface.readSliceAll(&magic_buffer);
    if (!std.mem.eql(u8, &magic_buffer, NitreDbHeaderMagic)) {
        return error.InvalidDatabase;
    }
    header.version = try reader.interface.takeInt(u32, .little);
    if (header.version != 1) {
        return error.InvalidVersion;
    }

    header.page_count = try reader.interface.takeInt(u32, .little);
    header.first_data_page = try reader.interface.takeInt(u32, .little);
    header.first_index_page = try reader.interface.takeInt(u32, .little);
}

//Implements a pool of pages used to store page data loaded from the disk
const PagePool = struct {
    allocator: std.mem.Allocator,
    page_pool: []NitreDbPage,
    active_page: ?*NitreDbPage,
    last_used_counter: u32,

    fn init(size: u32, allocator: std.mem.Allocator) !PagePool {
        const pool = try allocator.alloc(NitreDbPage, size);
        for (pool) |*page| {
            page.* = .{};
        }

        return .{ .allocator = allocator, .page_pool = pool, .active_page = null, .last_used_counter = 0 };
    }

    fn flushPage(page: *NitreDbPage, db_file: std.Io.File, io: std.Io) !void {
        std.debug.print("Flushing page: {*} ({})\n", .{ page, page.page_number });
        try page.writeToDisk(db_file, io);
        page.internal_flags.dirty = false;
    }

    fn flushAll(pool: *PagePool, db_file: std.Io.File, io: std.Io) !void {
        for (pool.page_pool) |*page| {
            if (page.internal_flags.dirty and page.internal_flags.resident) {
                try flushPage(page, db_file, io);
                page.internal_flags.dirty = false;
                page.internal_flags.resident = false;
            }
        }
    }

    fn deinit(pool: *PagePool) void {
        pool.allocator.free(pool.page_pool);
    }

    //Gets a page from the pool, freeing the oldest if none are available
    fn getFreePage(pool: *PagePool, db_file: std.Io.File, io: std.Io) !*NitreDbPage {
        var oldest_page: *NitreDbPage = &pool.page_pool[0];

        for (pool.page_pool) |*page| {
            if (!page.internal_flags.resident) {
                return page;
            }

            if (page.last_used < oldest_page.last_used)
                oldest_page = page;
        }

        //Evict page from the pool because it's the oldest and the pool is full
        if (oldest_page.internal_flags.dirty) {
            try flushPage(oldest_page, db_file, io);
        }

        return oldest_page;
    }

    fn acquirePageNew(pool: *PagePool, nitreDb: *NitreDb, next_page: ?u32, prev_page: ?u32, content_type: NitreDbPageContentType) !*NitreDbPage {
        if (pool.active_page != null) {
            return error.PageAlreadyAcquired;
        }
        const page = try pool.getFreePage(nitreDb.db_file, nitreDb.db_io);
        page.* = .{
            .header = .{
                .content_type = content_type,
                .next_page = next_page,
                .prev_page = prev_page,
                .slot_count = 0,
            },
            .page_number = nitreDb.db_header.page_count,
            .last_used = pool.last_used_counter,
            .internal_flags = .{ .dirty = true, .resident = true },
            .data = undefined,
        };
        pool.last_used_counter += 1;
        nitreDb.db_header.page_count += 1;

        std.debug.print("Acquiring page: {*}\n", .{page});
        return page;
    }

    //Gets a free page from the pool and loads the contents from disk
    fn acquirePageExisting(pool: *PagePool, page_number: u32, db_file: std.Io.File, io: std.Io) !*NitreDbPage {
        if (pool.active_page != null) {
            return error.PageAlreadyAcquired;
        }

        for (pool.page_pool) |*page| {
            if (page.page_number == page_number and page.internal_flags.resident)
                return page;
        }

        var page = try pool.getFreePage(db_file, io);
        try page.loadFromDisk(db_file, page_number, io);
        page.internal_flags.resident = true;
        page.last_used = pool.last_used_counter;
        pool.last_used_counter += 1;

        std.debug.print("Acquiring page: {*}\n", .{page});
        return page;
    }

    //Returns a page to the pool
    fn releasePage(pool: *PagePool, page: *NitreDbPage) void {
        if (pool.active_page == null) {
            return;
        }

        const active_page = pool.active_page.?;

        if (active_page != page) {
            return;
        }

        pool.active_page = null;
    }
};
