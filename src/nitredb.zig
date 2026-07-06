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
const MinPagePoolSize = 3;
const MaxAcquiredPages = MinPagePoolSize;
const MaxPrimaryIndexSlotsPerPage = 600;

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

const PrimaryIndexSlot = packed struct {
    const Size = @bitSizeOf(PrimaryIndexSlot) / 8;
    //The largest id that this slot spans in the data structure
    upper_limit: u64 = 0,
    //The page that this slot points to in the next level of the data structure
    page_number: u32 = 0,
    flags: packed struct(u8) {
        _: u8 = 0,
    } = .{},
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
    PrimaryIndex = 1,
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
    data_interface: DataPageInterface,
    pindex_interface: PIndexPageInterface,
    page_number: u32 = 0,
    last_used: u32 = 0,
    internal_flags: packed struct(u8) {
        resident: bool = false,
        dirty: bool = false,
        acquired: bool = false,
        _: u5 = 0,
    } = .{},
    data: [PageSize]u8 = undefined,

    fn initInterface(page: *NitreDbPage) void {
        page.data_interface = .{ .data = &page.data };
        page.pindex_interface = .{ .data = &page.data };
    }

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

const PIndexPageInterface = struct {
    data: []u8,

    //Finds the slot in the page that defines the range that id would fall into. Returns the slot number.
    fn findSlot(interface: *const PIndexPageInterface, page: *const NitreDbPage, id: u64) u16 {
        std.debug.assert(page.header.slot_count > 0);
        var reader = std.Io.Reader.fixed(interface.data);
        var slot_number: u16 = 0;
        var start: u16 = 0;
        var end: u16 = page.header.slot_count - 1;

        while (true) {
            slot_number = (start + end) / 2;
            reader.seek = PageSize - PrimaryIndexSlot.Size * (slot_number + 1);
            const slot = reader.takeStruct(PrimaryIndexSlot, .little) catch unreachable;
            if (id == slot.upper_limit or start == end) {
                break;
            }
            if (id > slot.upper_limit) {
                start = slot_number + 1;
            } else {
                if (end == start + 1) {
                    end = start;
                } else {
                    end = slot_number - 1;
                }
            }
        }

        //It's possible that after the binary search, we end up on the slot 1 less than where we need to be
        //because the slots represent an upper limit. Adjust for this.
        reader.seek = PageSize - PrimaryIndexSlot.Size * (slot_number + 1);
        var slot = reader.takeStruct(PrimaryIndexSlot, .little) catch unreachable;
        if (id > slot.upper_limit) {
            slot_number += 1;
            reader.seek = PageSize - PrimaryIndexSlot.Size * (slot_number + 1);
            slot = reader.takeStruct(PrimaryIndexSlot, .little) catch unreachable;
        }

        std.debug.assert(slot_number <= page.header.slot_count);
        std.debug.assert(id <= slot.upper_limit);

        return slot_number;
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
    split_results: [3]struct {
        page_number: u32 = std.math.maxInt(u32),
        id_upper_limit: u64 = 0,
    },
};

fn insertDataWithId(nitreDb: *NitreDb, data: []const u8, data_id: u64) !u32 {
    const page_number = nitreDb.db_header.first_data_page;
    const result = try insertDataRecursive(nitreDb, page_number, data, data_id);
    if (result.split_count == 0) {
        return page_number;
    }

    std.debug.assert(result.split_count == 1);

    var new_root_page = try nitreDb.db_page_pool.acquirePageNew(nitreDb);
    defer nitreDb.db_page_pool.releasePage(new_root_page);
    new_root_page.header.content_type = .PrimaryIndex;
    new_root_page.internal_flags.dirty = true;
    new_root_page.header.slot_count = 2;

    const lesser_slot: PrimaryIndexSlot = .{
        .page_number = result.split_results[0].page_number,
        .upper_limit = result.split_results[0].id_upper_limit,
    };
    const greater_slot: PrimaryIndexSlot = .{
        .page_number = result.split_results[1].page_number,
        .upper_limit = result.split_results[1].id_upper_limit,
    };

    var writer = std.Io.Writer.fixed(&new_root_page.data);
    writer.end = PageSize - PrimaryIndexSlot.Size * 2;
    writer.writeStruct(greater_slot, .little) catch unreachable;
    writer.writeStruct(lesser_slot, .little) catch unreachable;

    return new_root_page.page_number;
}

//TODO: Finish implementing this. It needs to handle the root and intermediate index pages. When calling it
//from another function, it should be called on the root page of a table.
fn insertDataRecursive(nitreDb: *NitreDb, page_number: u32, data: []const u8, data_id: u64) !InsertResult {
    var original_page = try nitreDb.db_page_pool.acquirePageExisting(nitreDb, page_number);
    const data_len: u16 = @intCast(data.len);

    if (original_page.header.content_type == .PrimaryIndex) {

        //Generate a new data page if the primary index page is empty
        if (original_page.header.slot_count == 0) {
            var new_page = try nitreDb.db_page_pool.acquirePageNew(nitreDb);
            new_page.internal_flags.dirty = true;
            new_page.header.content_type = .Data;
            const new_slot: PrimaryIndexSlot = .{
                .page_number = new_page.page_number,
                .upper_limit = std.math.maxInt(u64),
            };
            var writer = std.Io.Writer.fixed(&original_page.data);
            writer.end = PageSize - PrimaryIndexSlot.Size;
            writer.writeStruct(new_slot, .little) catch unreachable;
            original_page.header.slot_count += 1;
            original_page.internal_flags.dirty = true;
            nitreDb.db_page_pool.releasePage(original_page);
            const new_page_number = new_page.page_number;
            nitreDb.db_page_pool.releasePage(new_page);
            _ = try insertDataRecursive(nitreDb, new_page_number, data, data_id);
            return .{ .split_count = 0, .split_results = undefined };
        }

        const slot_number = original_page.pindex_interface.findSlot(original_page, data_id);
        var reader = std.Io.Reader.fixed(&original_page.data);
        reader.seek = PageSize - PrimaryIndexSlot.Size * (slot_number + 1);
        const original_slot = reader.takeStruct(PrimaryIndexSlot, .little) catch unreachable;
        nitreDb.db_page_pool.releasePage(original_page);
        const result = try insertDataRecursive(nitreDb, original_slot.page_number, data, data_id);
        if (result.split_count == 0) {
            return .{ .split_count = 0, .split_results = undefined };
        }

        //Update the original slot with the new upper limit
        original_page = try nitreDb.db_page_pool.acquirePageExisting(nitreDb, page_number);
        defer nitreDb.db_page_pool.releasePage(original_page);
        original_page.internal_flags.dirty = true;
        reader = std.Io.Reader.fixed(&original_page.data);
        var writer = std.Io.Writer.fixed(&original_page.data);
        writer.end = PageSize - PrimaryIndexSlot.Size * (slot_number + 1);
        var updated_slot = original_slot;
        updated_slot.upper_limit = result.split_results[0].id_upper_limit;
        writer.writeStruct(updated_slot, .little) catch unreachable;

        var slot_buffer: [PrimaryIndexSlot.Size * (MaxPrimaryIndexSlotsPerPage + 2)]u8 = undefined;
        var slot_buffer_count = result.split_count;
        var slot_buffer_writer = std.Io.Writer.fixed(&slot_buffer);

        if (result.split_count == 2) {
            slot_buffer_writer.end = slot_buffer.len - PrimaryIndexSlot.Size * 2;
            const split_slot_1: PrimaryIndexSlot = .{
                .page_number = result.split_results[1].page_number,
                .upper_limit = result.split_results[1].id_upper_limit,
            };
            var split_slot_2: PrimaryIndexSlot = .{
                .page_number = result.split_results[2].page_number,
                .upper_limit = result.split_results[2].id_upper_limit,
            };
            //Ensure we don't limit the range of the largest slot if it is unbounded
            if (original_slot.upper_limit == std.math.maxInt(u64)) {
                split_slot_2.upper_limit = std.math.maxInt(u64);
            }
            slot_buffer_writer.writeStruct(split_slot_2, .little) catch unreachable;
            slot_buffer_writer.writeStruct(split_slot_1, .little) catch unreachable;
        } else {
            slot_buffer_writer.end = slot_buffer.len - PrimaryIndexSlot.Size;
            var split_slot_1: PrimaryIndexSlot = .{
                .page_number = result.split_results[1].page_number,
                .upper_limit = result.split_results[1].id_upper_limit,
            };
            //Ensure we don't limit the range of the largest slot if it is unbounded
            if (original_slot.upper_limit == std.math.maxInt(u64)) {
                split_slot_1.upper_limit = std.math.maxInt(u64);
            }
            slot_buffer_writer.writeStruct(split_slot_1, .little) catch unreachable;
        }

        //Get the number of slots in the page above the original slot
        const slot_move_count = original_page.header.slot_count - slot_number - 1;

        if (slot_move_count > 0) {
            const src_start = PageSize - PrimaryIndexSlot.Size * (original_page.header.slot_count);
            const src_end = src_start + PrimaryIndexSlot.Size * slot_move_count;
            const dst_start = slot_buffer.len - PrimaryIndexSlot.Size * (slot_buffer_count + slot_move_count);
            const dst_end = dst_start + PrimaryIndexSlot.Size * slot_move_count;
            @memcpy(slot_buffer[dst_start..dst_end], original_page.data[src_start..src_end]);
            slot_buffer_count += slot_move_count;
        }

        original_page.header.slot_count -= slot_move_count;
        const original_page_capacity = MaxPrimaryIndexSlotsPerPage - original_page.header.slot_count;
        var slots_moved_original_page: u16 = 0;

        if (original_page_capacity > 0) {
            var slots_to_move: u16 = @intCast(slot_buffer_count);
            if (original_page_capacity < slots_to_move) {
                slots_to_move = original_page_capacity;
            }
            const src_start = slot_buffer.len - PrimaryIndexSlot.Size * slots_to_move;
            const src_end = src_start + PrimaryIndexSlot.Size * slots_to_move;
            const dst_start = PageSize - PrimaryIndexSlot.Size * (original_page.header.slot_count + slots_to_move);
            const dst_end = dst_start + PrimaryIndexSlot.Size * slots_to_move;
            @memcpy(original_page.data[dst_start..dst_end], slot_buffer[src_start..src_end]);
            original_page.header.slot_count += slots_to_move;
            slots_moved_original_page = slots_to_move;
        }

        const new_page_slots: u16 = @intCast(slot_buffer_count - slots_moved_original_page);

        //If all slots ended up in the original page, we can return early without allocating a new page
        if (new_page_slots == 0) {
            return .{ .split_count = 0, .split_results = undefined };
        } else {
            //TODO: This branch is not thoroughly tested!
            var new_page = try nitreDb.db_page_pool.acquirePageNew(nitreDb);
            defer nitreDb.db_page_pool.releasePage(new_page);
            new_page.internal_flags.dirty = true;
            new_page.header.content_type = .PrimaryIndex;
            new_page.header.slot_count = new_page_slots;

            const src_start = slot_buffer.len - PrimaryIndexSlot.Size * slot_buffer_count;
            const src_end = src_start + PrimaryIndexSlot.Size * new_page_slots;
            const dst_start = PageSize - PrimaryIndexSlot.Size * new_page_slots;
            const dst_end = dst_start + PrimaryIndexSlot.Size * new_page_slots;
            @memcpy(new_page.data[dst_start..dst_end], slot_buffer[src_start..src_end]);

            reader.seek = PageSize - PrimaryIndexSlot.Size * original_page.header.slot_count;
            const original_page_largest_slot = reader.takeStruct(PrimaryIndexSlot, .little) catch unreachable;

            var new_page_reader = std.Io.Reader.fixed(&new_page.data);
            new_page_reader.seek = PageSize - PrimaryIndexSlot.Size * new_page.header.slot_count;
            const new_page_largest_slot = new_page_reader.takeStruct(PrimaryIndexSlot, .little) catch unreachable;

            return .{
                .split_count = 1,
                .split_results = .{
                    .{
                        .page_number = original_page.page_number,
                        .id_upper_limit = original_page_largest_slot.upper_limit,
                    },
                    .{
                        .page_number = new_page.page_number,
                        .id_upper_limit = new_page_largest_slot.upper_limit,
                    },
                    undefined,
                },
            };
        }
    }

    defer nitreDb.db_page_pool.releasePage(original_page);

    if (original_page.header.content_type == .Data) {
        //Return early if we can fit the data into the requested page without splitting
        if (original_page.canFitRow(data_len)) {
            original_page.data_interface.insertData(data, data_id, original_page);
            return .{ .split_count = 0, .split_results = undefined };
        }

        //Split the page and check if the row will now fit into the original page
        var first_split = try splitDataPage(original_page, nitreDb, data_id);
        defer nitreDb.db_page_pool.releasePage(first_split);
        var first_split_max_id = first_split.data_interface.getLargestId(first_split.header.slot_count) orelse std.math.maxInt(u64);
        if (original_page.canFitRow(data_len)) {
            original_page.data_interface.insertData(data, data_id, original_page);
            return .{
                .split_count = 1,
                .split_results = .{
                    .{
                        .page_number = original_page.page_number,
                        .id_upper_limit = data_id,
                    },
                    .{
                        .page_number = first_split.page_number,
                        .id_upper_limit = first_split_max_id,
                    },
                    undefined,
                },
            };
        }

        const original_page_max_id = original_page.data_interface.getLargestId(original_page.header.slot_count) orelse std.math.maxInt(u64);

        //Check if the data can fit into the page created by the split
        if (first_split.canFitRow(data_len)) {
            first_split.data_interface.insertData(data, data_id, first_split);
            first_split_max_id = first_split.data_interface.getLargestId(first_split.header.slot_count) orelse std.math.maxInt(u64);
            return .{
                .split_count = 1,
                .split_results = .{
                    .{
                        .page_number = original_page.page_number,
                        .id_upper_limit = original_page_max_id,
                    },
                    .{
                        .page_number = first_split.page_number,
                        .id_upper_limit = first_split_max_id,
                    },
                    undefined,
                },
            };
        }

        //At this point, the record doesn't fit into either the original page or the new page created by the split
        //It will have to go in its own page
        const second_split = try splitDataPage(first_split, nitreDb, 0);
        defer nitreDb.db_page_pool.releasePage(second_split);
        first_split.data_interface.insertData(data, data_id, first_split);
        //return .{ .split_count = 2, .id_limit_1 = original_page_max_id, .id_limit_2 = data_id, .id_limit_3 = first_split_max_id };
        return .{
            .split_count = 2,
            .split_results = .{
                .{
                    .page_number = original_page.page_number,
                    .id_upper_limit = original_page_max_id,
                },
                .{
                    .page_number = first_split.page_number,
                    .id_upper_limit = data_id,
                },
                .{
                    .page_number = second_split.page_number,
                    .id_upper_limit = first_split_max_id,
                },
            },
        };
    }

    //TODO: Implement handling the root and intermediate index pages
    return error.Unimplemented;
}

//Splits a data page by moving all the records with a primary key >= to the upper bound to a new page.
//Returns the new page
fn splitDataPage(page: *NitreDbPage, nitreDb: *NitreDb, upper_bound_id: u64) !*NitreDbPage {
    const slot_count = page.header.slot_count;
    page.header.slot_count = 0;
    page.header.data_length = 0;
    page.internal_flags.dirty = true;
    var temp_data: [PageSize]u8 = undefined;
    @memcpy(&temp_data, &page.data);

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

    var new_page = try nitreDb.db_page_pool.acquirePageNew(nitreDb);
    if (new_page.page_number == page.page_number) {
        std.debug.print("Invalid new page number: {}\n", .{new_page.page_number});
        std.debug.assert(new_page.page_number != page.page_number);
    }
    new_page.internal_flags.dirty = true;
    new_page.header.content_type = .Data;
    address_counter = PageHeaderSize;

    //Copy the slot and row data from temp into the new page
    for (next_slot_idx..slot_count) |slot_idx| {
        const slot_number: u16 = @intCast(slot_idx);
        var slot = temp_page_if.readSlot(slot_number);
        new_page.data_interface.writeRaw(temp_data[slot.offset..][0..slot.length], address_counter);
        slot.offset = address_counter;
        new_page.data_interface.writeSlot(new_page.header.slot_count, &slot);
        address_counter += slot.length;
        new_page.header.slot_count += 1;
        new_page.header.data_length += slot.length;
    }

    //We need to update the next and prev ptrs
    new_page.header.prev_page = page.page_number;
    new_page.header.next_page = page.header.next_page;
    page.header.next_page = new_page.page_number;

    if (new_page.header.next_page != null) {
        var next_page = try nitreDb.db_page_pool.acquirePageExisting(nitreDb, new_page.header.next_page.?);
        next_page.header.prev_page = new_page.page_number;
        next_page.internal_flags.dirty = true;
        nitreDb.db_page_pool.releasePage(next_page);
    }

    return new_page;
}

pub fn insertRecord(nitreDb: *NitreDb, record: []const u8, id: u64) !void {
    var page_opt: ?*NitreDbPage = null;
    if (nitreDb.db_header.page_count == 0) {
        page_opt = try nitreDb.db_page_pool.acquirePageNew(nitreDb);
        page_opt.?.header.content_type = .PrimaryIndex;
        nitreDb.db_header.first_data_page = page_opt.?.page_number;
    } else {
        page_opt = try nitreDb.db_page_pool.acquirePageExisting(nitreDb, nitreDb.db_header.first_data_page);
    }
    var page = page_opt.?;
    page.internal_flags.dirty = true;
    nitreDb.db_page_pool.releasePage(page);

    const record_len: u32 = @intCast(record.len);
    var data_buffer: [1024]u8 = undefined;
    var io_writer = std.Io.Writer.fixed(&data_buffer);
    try io_writer.writeInt(u64, id, .little);
    try io_writer.writeInt(u32, record_len, .little);
    try io_writer.writeAll(record);

    const new_root = try insertDataWithId(nitreDb, data_buffer[0 .. record_len + 12], id);
    nitreDb.db_header.first_data_page = new_root;
}

pub fn walkRecordsTest(nitreDb: *NitreDb) !u64 {
    var print_buffer: [128]u8 = undefined;
    var page_number: u32 = nitreDb.db_header.first_data_page;

    while (true) {
        const index_page = try nitreDb.db_page_pool.acquirePageExisting(nitreDb, page_number);
        defer nitreDb.db_page_pool.releasePage(index_page);
        if (index_page.header.content_type == .Data) {
            break;
        }
        var index_reader = std.Io.Reader.fixed(&index_page.data);
        index_reader.seek = PageSize - PrimaryIndexSlot.Size;
        const first_slot = try index_reader.takeStruct(PrimaryIndexSlot, .little);
        page_number = first_slot.page_number;
    }

    var count: u64 = 0;
    var largest_id: u64 = 0;

    while (page_number != std.math.maxInt(u32)) {
        var page = try nitreDb.db_page_pool.acquirePageExisting(nitreDb, page_number);
        defer nitreDb.db_page_pool.releasePage(page);
        var reader = std.Io.Reader.fixed(&page.data);
        for (0..page.header.slot_count) |idx| {
            const slot_idx: u16 = @intCast(idx);
            const slot = page.data_interface.readSlot(slot_idx);
            reader.seek = slot.offset;
            const id = try reader.takeInt(u64, .little);
            const len = try reader.takeInt(u32, .little);
            try reader.readSliceAll(print_buffer[0..len]);
            std.debug.print("{s} (Page number: {})\n", .{ print_buffer[0..len], page_number });
            count += 1;
            std.debug.assert(id >= largest_id);
            largest_id = id;
        }
        page_number = page.header.next_page orelse std.math.maxInt(u32);
    }

    return count;
}

pub fn flushDatabase(nitreDb: *NitreDb) !void {
    try writeHeader(nitreDb.db_file, &nitreDb.db_header, nitreDb.db_io);
    try flushAllPages(nitreDb);
}

pub fn closeDatabase(nitreDb: *NitreDb) void {
    nitreDb.db_file.close(nitreDb.db_io);
    nitreDb.db_page_pool.deinit(nitreDb.db_allocator);
}

pub fn openDatabase(filepath: []const u8, io: std.Io, allocator: std.mem.Allocator) !NitreDb {
    comptime std.debug.assert((PageSize - PageHeaderSize) / PrimaryIndexSlot.Size > MaxPrimaryIndexSlotsPerPage);

    const file = try std.Io.Dir.createFileAbsolute(io, filepath, .{ .truncate = false, .read = true });
    errdefer file.close(io);
    var page_pool = try PagePool.init(MinPagePoolSize, allocator);
    //var page_pool = try PagePool.init(1000, allocator);
    errdefer page_pool.deinit(allocator);
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
    pages: []NitreDbPage,
    last_used_counter: u32,
    active_page_count: u32,

    fn init(size: u32, allocator: std.mem.Allocator) !PagePool {
        const pool = try allocator.alloc(NitreDbPage, size);
        for (pool) |*page| {
            page.* = .{
                .data_interface = .{
                    .data = &page.data,
                },
                .pindex_interface = .{
                    .data = &page.data,
                },
            };
            page.initInterface();
        }

        return .{
            .pages = pool,
            .active_page_count = 0,
            .last_used_counter = 0,
        };
    }

    fn deinit(pool: *PagePool, allocator: std.mem.Allocator) void {
        allocator.free(pool.pages);
    }

    //Gets a page from the pool, freeing the oldest if none are available
    fn getFreePage(pool: *PagePool, nitreDb: *NitreDb) !*NitreDbPage {
        var oldest_unacquired: *NitreDbPage = &pool.pages[0];

        for (pool.pages) |*page| {
            if (!page.internal_flags.acquired) {
                oldest_unacquired = page;
                break;
            }
        }

        if (oldest_unacquired.internal_flags.acquired) {
            return error.AllPagesAcquired;
        }

        for (pool.pages) |*page| {
            if (!page.internal_flags.resident) {
                return page;
            }

            if (page.last_used < oldest_unacquired.last_used and !page.internal_flags.acquired)
                oldest_unacquired = page;
        }

        //Evict page from the pool because it's the oldest and the pool is full
        if (oldest_unacquired.internal_flags.dirty) {
            try writePageToDisk(nitreDb, oldest_unacquired);
            oldest_unacquired.internal_flags.dirty = false;
        }

        std.debug.assert(oldest_unacquired.internal_flags.acquired == false);
        return oldest_unacquired;
    }

    //Finds a page already loaded into the pool by its number
    fn findPage(pool: *const PagePool, page_number: u32) ?*NitreDbPage {
        for (pool.pages) |*page| {
            if (page.page_number == page_number and page.internal_flags.resident) {
                return page;
            }
        }
        return null;
    }

    fn acquirePageNew(pool: *PagePool, nitreDb: *NitreDb) !*NitreDbPage {
        if (pool.active_page_count >= MaxAcquiredPages) {
            return error.MaxAcquisitionsReached;
        }
        const page = try pool.getFreePage(nitreDb);
        page.* = .{
            .page_number = nitreDb.db_header.page_count,
            .last_used = pool.last_used_counter,
            .internal_flags = .{ .dirty = true, .resident = true, .acquired = true },
            .data_interface = .{
                .data = &page.data,
            },
            .pindex_interface = .{
                .data = &page.data,
            },
        };
        page.initInterface();
        pool.last_used_counter += 1;
        pool.active_page_count += 1;
        nitreDb.db_header.page_count += 1;

        std.debug.print("Acquiring new page: {*} (Page number: {})\n", .{ page, page.page_number });
        return page;
    }

    //Gets a free page from the pool and loads the contents from disk
    fn acquirePageExisting(pool: *PagePool, nitreDb: *NitreDb, page_number: u32) !*NitreDbPage {
        std.debug.assert(page_number < nitreDb.db_header.page_count);
        if (pool.active_page_count >= MaxAcquiredPages) {
            return error.MaxAcquisitionsReached;
        }
        const found_page = pool.findPage(page_number);
        if (found_page != null) {
            if (found_page.?.internal_flags.acquired) {
                return error.PageAlreadyAcquired;
            }
            pool.active_page_count += 1;
            found_page.?.internal_flags.acquired = true;
            return found_page.?;
        }

        var page = try pool.getFreePage(nitreDb);
        try loadPageFromDisk(nitreDb, page, page_number);
        page.initInterface();
        page.internal_flags.resident = true;
        page.internal_flags.acquired = true;
        page.last_used = pool.last_used_counter;
        pool.last_used_counter += 1;
        pool.active_page_count += 1;

        std.debug.print("Acquiring page: {*} (Page number: {})\n", .{ page, page.page_number });
        return page;
    }

    //Returns a page to the pool
    fn releasePage(pool: *PagePool, page: *NitreDbPage) void {
        page.internal_flags.acquired = false;
        pool.active_page_count -= 1;
    }
};

//Loads page contents from the disk
fn loadPageFromDisk(nitreDb: *NitreDb, page: *NitreDbPage, page_number: u32) !void {
    page.page_number = page_number;
    var reader = nitreDb.db_file.reader(nitreDb.db_io, &page.data);
    try reader.seekTo(NitreDbHeaderSize + page.page_number * PageSize);
    try reader.interface.fill(page.data.len);
    var header_reader = std.Io.Reader.fixed(&page.data);
    try page.header.read(&header_reader);
}

//Writes the contents of a page to disk, reglardless of the dirty flag
fn writePageToDisk(nitreDb: *NitreDb, page: *NitreDbPage) !void {
    std.debug.print("Flushing page: {*} (Page number: {})\n", .{ page, page.page_number });
    var writer = std.Io.Writer.fixed(&page.data);
    try page.header.write(&writer);
    var file_writer = nitreDb.db_file.writer(nitreDb.db_io, &[0]u8{});
    try file_writer.seekTo(NitreDbHeaderSize + page.page_number * PageSize);
    try file_writer.interface.writeAll(&page.data);
}

//Flushes all loaded back to the disk if they are dirty
fn flushAllPages(nitreDb: *NitreDb) !void {
    for (nitreDb.db_page_pool.pages) |*page| {
        if (page.internal_flags.dirty) {
            try writePageToDisk(nitreDb, page);
            page.internal_flags.dirty = false;
        }
    }
}
