const std = @import("std");
const NitreDb = @import("nitredb.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var nitreDb = try NitreDb.openDatabase("/temp/test.nitredb", io, init.gpa);
    var buffer: [256]u8 = undefined;
    const seed: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    var rand = std.Random.DefaultPrng.init(seed);
    //max is 233 records per page

    var id_count: u32 = 0;

    const t1: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    for (1..10_000) |_| {
        const rand_idx = rand.next() % 100;
        id_count += 1;
        const fmt_buffer = try std.fmt.bufPrint(&buffer, "This is record: {:0>2}", .{rand_idx});
        try nitreDb.insertRecord(fmt_buffer, rand_idx);
    }
    const t2: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());

    const count = try nitreDb.walkRecordsTest();
    std.debug.print("Inserted: {}, Count: {}\n", .{ id_count, count });
    std.debug.print("Insertion Time: {}ms\n", .{t2 - t1});
    //try nitreDb.splitPageTest(50);
    try nitreDb.flushDatabase();
    defer nitreDb.closeDatabase();

    //    const file = try Io.Dir.createFileAbsolute(io, "/temp/zigout", .{ .truncate = false, .read = true });
    //    defer file.close(io);
    //    var writeBuffer: [1024]u8 = undefined;
    //    var writer = file.writer(io, &writeBuffer);
    //    const fileLength = try file.length(io);
    //    std.debug.print("File size: {}", .{fileLength});
    //    try writer.seekTo(fileLength);
    //    try writer.interface.writeAll("This is a test file!");
    //    try writer.interface.flush();

    // Prints to stderr, unbuffered, ignoring potential errors.
    //std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.flush(); // Don't forget to flush!
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
