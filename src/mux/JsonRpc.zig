const std = @import("std");

pub const Message = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Message) void {
        self.parsed.deinit();
    }
};

pub const Codec = struct {
    pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?Message {
        var len: ?usize = null;

        while (true) {
            const line_result = reader.takeDelimiter('\n') catch |err| {
                if (err == error.EndOfStream) return null;
                return err;
            };
            const actual_line = line_result orelse return null;

            if (actual_line.len == 0 or (actual_line.len == 1 and actual_line[0] == '\r')) {
                break; // End of headers
            }

            const clean_line = if (actual_line[actual_line.len - 1] == '\r')
                actual_line[0 .. actual_line.len - 1]
            else
                actual_line;

            var iter = std.mem.splitScalar(u8, clean_line, ':');
            const key = iter.next() orelse continue;
            if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
                const val = iter.next() orelse continue;
                const trimmed = std.mem.trim(u8, val, " \t");
                len = try std.fmt.parseInt(usize, trimmed, 10);
            }
        }

        const payload_len = len orelse return error.MissingContentLength;
        const payload = try allocator.alloc(u8, payload_len);
        defer allocator.free(payload);

        try reader.readSliceAll(payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        return Message{
            .parsed = parsed,
        };
    }

    pub fn writeMessage(writer: anytype, value: std.json.Value) !void {
        var string_buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer string_buf.deinit();
        try std.json.stringify(value, .{}, string_buf.writer());
        const payload = string_buf.items;

        try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    }
};
