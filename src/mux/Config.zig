const std = @import("std");

pub const Config = struct {
    socket_path: []const u8,
    cmd_name: []const u8,
    cmd_args: [][]const u8,
    max_active_clients: usize = 5,

    pub fn parse(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Config {
        var socket_path: ?[]const u8 = null;
        var cmd_name: ?[]const u8 = null;
        var cmd_args: std.ArrayList([]const u8) = .empty;
        var max_active_clients: usize = 5;

        _ = args.next(); // Skip executable name

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--socket")) {
                if (args.next()) |val| {
                    socket_path = val;
                } else return error.MissingArgument;
            } else if (std.mem.eql(u8, arg, "--max-active-clients")) {
                if (args.next()) |val| {
                    max_active_clients = try std.fmt.parseInt(usize, val, 10);
                } else return error.MissingArgument;
            } else if (std.mem.eql(u8, arg, "--cmd")) {
                if (args.next()) |val| {
                    cmd_name = val;
                    // The rest of the arguments belong to the command
                    while (args.next()) |cmd_arg| {
                        try cmd_args.append(allocator, cmd_arg);
                    }
                } else return error.MissingArgument;
                break;
            } else {
                return error.UnknownOption;
            }
        }

        if (socket_path == null or cmd_name == null) {
            return error.MissingRequiredOptions;
        }

        return Config{
            .socket_path = socket_path.?,
            .cmd_name = cmd_name.?,
            .cmd_args = try cmd_args.toOwnedSlice(allocator),
            .max_active_clients = max_active_clients,
        };
    }
};
