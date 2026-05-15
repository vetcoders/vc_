const std = @import("std");

pub fn Enum(
    comptime TagInt: type,
    comptime mode: std.builtin.Type.Enum.Mode,
    comptime fields: []const std.builtin.Type.EnumField,
) type {
    var names: [fields.len][]const u8 = undefined;
    var values: [fields.len]TagInt = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        values[i] = @intCast(field.value);
    }

    return @Enum(TagInt, mode, &names, &values);
}

pub fn Struct(
    comptime layout: std.builtin.Type.ContainerLayout,
    comptime BackingInt: ?type,
    comptime fields: []const std.builtin.Type.StructField,
) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{
            .@"align" = if (layout == .@"packed") null else field.alignment,
            .@"comptime" = field.is_comptime,
            .default_value_ptr = field.default_value_ptr,
        };
    }

    return @Struct(layout, BackingInt, &names, &types, &attrs);
}

pub fn Union(
    comptime layout: std.builtin.Type.ContainerLayout,
    comptime ArgType: ?type,
    comptime fields: []const std.builtin.Type.UnionField,
) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{ .@"align" = field.alignment };
    }

    return @Union(layout, ArgType, &names, &types, &attrs);
}
