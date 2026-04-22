const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DiscoverOptions = struct {
    skills_dir_override: ?[]const u8 = null,
};

pub const SkillSummary = struct {
    name: []const u8,
    version: ?[]const u8,
    description: []const u8,
    path: []const u8,

    fn deinit(self: SkillSummary, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.version) |version| alloc.free(version);
        alloc.free(self.description);
        alloc.free(self.path);
    }
};

pub const SkillDocument = struct {
    name: []const u8,
    version: ?[]const u8,
    description: []const u8,
    path: []const u8,
    body: []const u8,

    pub fn deinit(self: *SkillDocument, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.version) |version| alloc.free(version);
        alloc.free(self.description);
        alloc.free(self.path);
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    allocator: Allocator,
    root_dir: []const u8,
    skills: std.ArrayListUnmanaged(SkillSummary) = .{},

    pub fn deinit(self: *Catalog) void {
        for (self.skills.items) |skill| skill.deinit(self.allocator);
        self.skills.deinit(self.allocator);
        self.allocator.free(self.root_dir);
        self.* = undefined;
    }

    pub fn findByName(self: *const Catalog, name: []const u8) ?SkillSummary {
        for (self.skills.items) |skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }
};

pub const DiscoverError = error{
    SkillsRootNotFound,
};

pub const LoadError = anyerror;

pub fn discoverRoot(alloc: Allocator, opts: DiscoverOptions) LoadError![]const u8 {
    if (opts.skills_dir_override) |override| {
        return validateAndDupeRoot(alloc, override);
    }

    if (std.process.getEnvVarOwned(alloc, "VIBECRAFTED_SKILLS_DIR")) |env_path| {
        errdefer alloc.free(env_path);
        return validateAndAdoptRoot(alloc, env_path);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const cwd_abs = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd_abs);

    const exe_dir = std.fs.selfExeDirPathAlloc(alloc) catch null;
    defer if (exe_dir) |dir| alloc.free(dir);

    const candidates = [_][]const []const u8{
        &.{ cwd_abs, "skills" },
        &.{ cwd_abs, "..", "vibecrafted", "skills" },
        &.{ cwd_abs, "..", "vibecrafted-io", "framework", "skills" },
    };

    for (candidates) |parts| {
        const candidate = try std.fs.path.join(alloc, parts);
        defer alloc.free(candidate);
        if (isSkillsRoot(candidate)) {
            return std.fs.realpathAlloc(alloc, candidate);
        }
    }

    if (exe_dir) |dir| {
        const exe_candidates = [_][]const []const u8{
            &.{ dir, "..", "share", "skills" },
            &.{ dir, "..", "Resources", "skills" },
            &.{ dir, "..", "..", "Resources", "skills" },
        };

        for (exe_candidates) |parts| {
            const candidate = try std.fs.path.join(alloc, parts);
            defer alloc.free(candidate);
            if (isSkillsRoot(candidate)) {
                return std.fs.realpathAlloc(alloc, candidate);
            }
        }
    }

    return error.SkillsRootNotFound;
}

pub fn loadCatalog(alloc: Allocator, opts: DiscoverOptions) LoadError!Catalog {
    const root_dir = try discoverRoot(alloc, opts);
    errdefer alloc.free(root_dir);

    var catalog: Catalog = .{
        .allocator = alloc,
        .root_dir = root_dir,
    };
    errdefer catalog.deinit();

    var skills_dir = try std.fs.openDirAbsolute(root_dir, .{ .iterate = true });
    defer skills_dir.close();

    var iter = skills_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const skill_doc_path = try std.fs.path.join(
            alloc,
            &.{ root_dir, entry.name, "SKILL.md" },
        );
        defer alloc.free(skill_doc_path);

        if (!pathExists(skill_doc_path)) continue;

        var document = try loadDocumentAbsolute(alloc, skill_doc_path);
        defer document.deinit(alloc);

        try catalog.skills.append(alloc, .{
            .name = try alloc.dupe(u8, document.name),
            .version = if (document.version) |version| try alloc.dupe(u8, version) else null,
            .description = try alloc.dupe(u8, document.description),
            .path = try alloc.dupe(u8, document.path),
        });
    }

    std.sort.heap(SkillSummary, catalog.skills.items, {}, lessThanByName);
    return catalog;
}

pub fn loadByName(
    alloc: Allocator,
    opts: DiscoverOptions,
    name: []const u8,
) LoadError!SkillDocument {
    var catalog = try loadCatalog(alloc, opts);
    defer catalog.deinit();

    const summary = catalog.findByName(name) orelse return error.FileNotFound;
    return loadDocumentAbsolute(alloc, summary.path);
}

pub fn loadDocumentAbsolute(alloc: Allocator, path: []const u8) LoadError!SkillDocument {
    const content = try std.fs.cwd().readFileAlloc(alloc, path, 512 * 1024);
    defer alloc.free(content);

    return parseDocument(alloc, path, content);
}

fn lessThanByName(_: void, a: SkillSummary, b: SkillSummary) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn validateAndDupeRoot(alloc: Allocator, path: []const u8) LoadError![]const u8 {
    if (!isSkillsRoot(path)) return error.SkillsRootNotFound;
    return std.fs.realpathAlloc(alloc, path);
}

fn validateAndAdoptRoot(alloc: Allocator, adopted: []u8) LoadError![]const u8 {
    if (!isSkillsRoot(adopted)) return error.SkillsRootNotFound;
    defer alloc.free(adopted);
    return std.fs.realpathAlloc(alloc, adopted);
}

fn isSkillsRoot(path: []const u8) bool {
    if (!pathExists(path)) return false;

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return false;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return false) |entry| {
        if (entry.kind != .directory) continue;

        const candidate = std.fs.path.join(std.heap.page_allocator, &.{ path, entry.name, "SKILL.md" }) catch return false;
        defer std.heap.page_allocator.free(candidate);

        if (pathExists(candidate)) return true;
    }

    return false;
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn parseDocument(alloc: Allocator, path: []const u8, content: []const u8) LoadError!SkillDocument {
    const parsed = try parseFrontmatter(alloc, content);
    defer parsed.deinit(alloc);

    const name = parsed.name orelse return error.MissingSkillName;
    return .{
        .name = try alloc.dupe(u8, name),
        .version = if (parsed.version) |version| try alloc.dupe(u8, version) else null,
        .description = try alloc.dupe(u8, parsed.description orelse ""),
        .path = try alloc.dupe(u8, path),
        .body = try alloc.dupe(u8, std.mem.trimLeft(u8, content[parsed.body_start..], "\r\n")),
    };
}

const ParsedFrontmatter = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    body_start: usize = 0,

    fn deinit(self: ParsedFrontmatter, alloc: Allocator) void {
        if (self.name) |name| alloc.free(name);
        if (self.version) |version| alloc.free(version);
        if (self.description) |description| alloc.free(description);
    }
};

fn parseFrontmatter(alloc: Allocator, content: []const u8) LoadError!ParsedFrontmatter {
    if (!std.mem.startsWith(u8, content, "---")) return error.InvalidFrontmatter;

    const newline_after_open = std.mem.indexOfScalar(u8, content, '\n') orelse return error.InvalidFrontmatter;
    const close_marker = std.mem.indexOfPos(u8, content, newline_after_open + 1, "\n---") orelse return error.InvalidFrontmatter;
    const frontmatter = content[newline_after_open + 1 .. close_marker + 1];
    const after_close = close_marker + 4;

    var parsed: ParsedFrontmatter = .{};
    errdefer parsed.deinit(alloc);

    var description_lines = std.ArrayListUnmanaged(u8){};
    defer description_lines.deinit(alloc);

    var iter = std.mem.splitScalar(u8, frontmatter, '\n');
    var capturing_description = false;
    while (iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (capturing_description) {
            if (line.len == 0) {
                if (description_lines.items.len > 0 and description_lines.items[description_lines.items.len - 1] != '\n') {
                    try description_lines.append(alloc, '\n');
                }
                continue;
            }

            if (std.ascii.isWhitespace(line[0])) {
                const value = std.mem.trim(u8, line, " \t");
                if (value.len == 0) continue;
                if (description_lines.items.len > 0) {
                    const last = description_lines.items[description_lines.items.len - 1];
                    if (last != '\n') try description_lines.append(alloc, ' ');
                }
                try description_lines.appendSlice(alloc, value);
                continue;
            }

            capturing_description = false;
        }

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.ascii.isWhitespace(line[0])) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            parsed.name = try alloc.dupe(u8, stripQuotes(value));
            continue;
        }
        if (std.mem.eql(u8, key, "version")) {
            parsed.version = try alloc.dupe(u8, stripQuotes(value));
            continue;
        }
        if (std.mem.eql(u8, key, "description")) {
            if (std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, "|")) {
                capturing_description = true;
            } else {
                parsed.description = try alloc.dupe(u8, stripQuotes(value));
            }
        }
    }

    if (parsed.description == null and description_lines.items.len > 0) {
        parsed.description = try alloc.dupe(u8, std.mem.trim(u8, description_lines.items, " \n"));
    }

    parsed.body_start = skipDelimiterRemainder(content, after_close);
    return parsed;
}

fn skipDelimiterRemainder(content: []const u8, after_close: usize) usize {
    var index = after_close;
    while (index < content.len and (content[index] == '-' or content[index] == '\r')) : (index += 1) {}
    while (index < content.len and (content[index] == '\n' or content[index] == '\r')) : (index += 1) {}
    return index;
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

test "parse frontmatter extracts folded description and body" {
    const sample =
        \\---
        \\name: vc-example
        \\version: 1.2.3
        \\description: >
        \\  First line
        \\  second line
        \\compatibility:
        \\  tools: []
        \\---
        \\
        \\# Example
        \\body
    ;

    var doc = try parseDocument(std.testing.allocator, "/tmp/vc-example/SKILL.md", sample);
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("vc-example", doc.name);
    try std.testing.expectEqualStrings("1.2.3", doc.version.?);
    try std.testing.expectEqualStrings("First line second line", doc.description);
    try std.testing.expectEqualStrings("# Example\nbody", doc.body);
}

test "load catalog scans skill directories and sorts by name" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/zeta");
    try tmp.dir.makePath("skills/alpha");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/zeta/SKILL.md",
        .data =
        \\---
        \\name: zeta
        \\version: 9.0.0
        \\description: Zed last
        \\---
        \\# Zeta
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "skills/alpha/SKILL.md",
        .data =
        \\---
        \\name: alpha
        \\description: A first skill
        \\---
        \\# Alpha
        ,
    });

    const skills_root = try tmp.dir.realpathAlloc(testing.allocator, "skills");
    defer testing.allocator.free(skills_root);

    var catalog = try loadCatalog(testing.allocator, .{ .skills_dir_override = skills_root });
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 2), catalog.skills.items.len);
    try std.testing.expectEqualStrings("alpha", catalog.skills.items[0].name);
    try std.testing.expectEqualStrings("zeta", catalog.skills.items[1].name);
    try std.testing.expectEqualStrings("A first skill", catalog.skills.items[0].description);
}
