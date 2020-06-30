const std = @import("std");

pub const Mustache = struct {
    // TODO allow custom tags outside of {{}}
    const Self = @This();
    pub const Error = error{
        CouldNotFindFile,
        FileError,
        ArgsMustBeStruct,
        FileNotFound,
        MalformedFile,
        ExpectedOpenCurlyBrace,
        ExpectedCloseCurlyBrace,
        ExpectedEndSection,
        UnexpectedEOF,
        UnexpectedEndSection,
        UnexpectedNewline,
        MemoryError,
    };

    const Value = struct {
        name: []const u8,
    };

    const Section = struct {
        exists: bool,
        name: []const u8,
        contents: []const u8,
        pieces: Pieces,
    };

    const Text = struct {
        contents: []const u8,
    };

    const Include = struct {
        file: []const u8,
    };

    const Piece = union(enum) {
        Text: Text,
        Value: Value,
        Section: Section,
        Include: Include,
    };

    const Pieces = std.TailQueue(Piece);

    const File = struct {
        contents: []const u8,
        pieces: Pieces,
    };

    allocator: *std.mem.Allocator,
    files: std.StringHashMap(File),
    line: usize = 1,
    column: usize = 0,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .files = std.StringHashMap(File).init(allocator),
            .line = 1,
            .column = 0,
        };
    }

    pub fn deinit(self: Self) void {
        var it = self.files.iterator();
        while (it.next()) |file| {
            self.deinitPieces(&file.value.pieces);
            self.allocator.free(file.value.contents);
        }
        self.files.deinit();
    }

    fn deinitPieces(self: Self, pieces: *Pieces) void {
        var it = pieces.first;
        while (it) |node| {
            var next = node.next;

            if (node.data == .Section) {
                self.deinitPieces(&node.data.Section.pieces);
            }
            pieces.destroyNode(node, self.allocator);

            it = next;
        }
    }

    fn errToString(err: anyerror) []const u8 {
        return switch (err) {
            Self.Error.ExpectedOpenCurlyBrace => "expected open curly brace",
            Self.Error.ExpectedCloseCurlyBrace => "expected close curly brace",
            Self.Error.ExpectedEndSection => "expected end of a section",
            Self.Error.UnexpectedEOF => "unexpected end of file",
            Self.Error.UnexpectedEndSection => "unexpected end of a section",
            Self.Error.UnexpectedNewline => "unexpected newline",
            else => @errorName(err),
        };
    }

    pub fn printError(self: *Self, comptime OutStream: type, out: OutStream, err: anyerror) !void {
        try out.print("[{}:{}] {}\n", .{ self.line, self.column, Self.errToString(err) });
    }

    pub fn render(self: *Self, comptime OutStream: type, out: OutStream, template: []const u8, args: var) Mustache.Error!void {
        var file = try self.retrieveFile(template);

        if (@typeInfo(@TypeOf(args)) != .Struct) {
            return Mustache.Error.ArgsMustBeStruct;
        }

        try self.renderPieces(OutStream, out, file.pieces, args);
    }

    fn renderPiece(self: *Self, comptime OutStream: type, out: OutStream, section: Section, global: var, value: var) Mustache.Error!void {
        const FieldInfo = @typeInfo(@TypeOf(value));
        switch (FieldInfo) {
            .Pointer => |pointer| {
                if (pointer.size == .Slice) {
                    if (pointer.child != u8) {
                        for (value) |child| {
                            const ChildInfo = @typeInfo(@TypeOf(child));
                            if (ChildInfo == .Struct) {
                                try self.renderPieces(OutStream, out, section.pieces, child);
                            } else {
                                try self.renderPiece(OutStream, out, section.pieces, child);
                            }
                        }
                    } else {
                        // Assume a []u8 is a string
                        try self.renderPieces(OutStream, out, section.pieces, global);
                    }
                } else {
                    try self.renderPiece(OutStream, out, section, global, value.*);
                }
            },
            .Array => |array| {
                if (array.child != u8) {
                    for (value) |child| {
                        const ChildInfo = @typeInfo(@TypeOf(child));
                        if (ChildInfo == .Struct) {
                            try self.renderPieces(OutStream, out, section.pieces, child);
                        } else {
                            try self.renderPiece(OutStream, out, section.pieces, child);
                        }
                    }
                } else {
                    // Assume a []u8 is a string
                    try self.renderPieces(OutStream, out, section.pieces, global);
                }
            },
            .Fn => {
                try self.renderPieces(OutStream, out, section.pieces, field(section.contents));
            },
            .Bool => {
                if (value) {
                    try self.renderPieces(OutStream, out, section.pieces, global);
                }
            },
            .Optional => |opt| {
                if (value) |val| {
                    const OptInfo = @typeInfo(opt.child);
                    if (OptInfo == .Struct) {
                        try self.renderPieces(OutStream, out, section.pieces, val);
                    } else if ((OptInfo == .Pointer and OptInfo.Pointer.size == .Slice) or (OptInfo == .Array)) {
                        try self.renderPiece(OutStream, out, section, global, val);
                    } else {
                        try self.renderPiece(OutStream, out, section, global, global);
                    }
                }
            },
            else => {
                try self.renderPieces(OutStream, out, section.pieces, value);
            },
        }
    }

    fn renderPieces(self: *Self, comptime OutStream: type, out: OutStream, pieces: Pieces, args: var) Mustache.Error!void {
        // if (@typeInfo(@TypeOf(args)) != .Struct) {
        //     return Mustache.Error.ArgsMustBeStruct;
        // }
        var it = pieces.first;
        piece_loop: while (it) |piece| : (it = piece.next) {
            switch (piece.data) {
                .Value => |value| {
                    const ArgsInfo = @typeInfo(@TypeOf(args));
                    switch (ArgsInfo) {
                        .Struct => {
                            inline for (ArgsInfo.Struct.fields) |field| {
                                if (std.mem.eql(u8, field.name, value.name)) {
                                    const field_value = @field(args, field.name);
                                    const field_type = @TypeOf(field_value);
                                    const field_info = @typeInfo(field_type);
                                    switch (field_info) {
                                        .Optional => {
                                            if (field_value) |data| {
                                                out.print("{}", .{data}) catch return Mustache.Error.FileError;
                                            }
                                        },
                                        else => {
                                            out.print("{}", .{field_value}) catch return Mustache.Error.FileError;
                                        },
                                    }
                                    // FIXME uncommenting this segfaults the compiler
                                    // continue :piece_loop;
                                }
                            }
                        },
                        else => {
                            out.print("{}", .{args}) catch return Mustache.Error.FileError;
                        },
                    }
                },
                .Text => |text| {
                    out.writeAll(text.contents) catch return Mustache.Error.FileError;
                },
                .Include => |include| {
                    try self.render(OutStream, out, include.file, args);
                },
                .Section => |section| {
                    // Sections only work for structs
                    const ArgsInfo = @typeInfo(@TypeOf(args));
                    if (ArgsInfo == .Struct) {
                        var has_field = false;
                        inline for (ArgsInfo.Struct.fields) |field| {
                            if (std.mem.eql(u8, field.name, section.name)) {
                                has_field = true;
                            }
                        }

                        if (!section.exists) {
                            if (!has_field) {
                                try self.renderPieces(OutStream, out, section.pieces, args);
                            } else {
                                // Render if the field exists and is a false bool
                                inline for (ArgsInfo.Struct.fields) |field| {
                                    if (std.mem.eql(u8, field.name, section.name)) {
                                        const field_info = @typeInfo(field.field_type);
                                        switch (field_info) {
                                            .Bool => {
                                                if (!@field(args, field.name)) {
                                                    try self.renderPieces(OutStream, out, section.pieces, args);
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                }
                            }
                        } else if (section.exists and has_field) {
                            inline for (ArgsInfo.Struct.fields) |_field| {
                                if (std.mem.eql(u8, _field.name, section.name)) {
                                    const field = @field(args, _field.name);
                                    try self.renderPiece(OutStream, out, section, args, field);
                                }
                            }
                        }
                    }
                },
            }
        }
    }

    fn retrieveFile(self: *Self, template: []const u8) Mustache.Error!Mustache.File {
        var file: Mustache.File = undefined;
        if (self.files.get(template)) |parsed_file| {
            file = parsed_file.value;
        } else {
            var files = [_][]const u8{template};
            try self.parse(files[0..]);
            var parsed_file = self.files.get(template).?;
            file = parsed_file.value;
        }
        return file;
    }

    // Parses all specified files and saves them in the object's cache
    // Useful for parsing all files before server is initialized to catch any syntax errors
    pub fn parse(self: *Self, files: [][]const u8) Mustache.Error!void {
        var line: usize = 1;
        var column: usize = 0;
        for (files) |file_name| {
            var file = std.fs.cwd().openFile(file_name, .{}) catch return Mustache.Error.CouldNotFindFile;
            defer file.close();

            const contents = file.inStream().readAllAlloc(self.allocator, 1024 * 1024) catch return Mustache.Error.MemoryError;

            var pieces = try Mustache.innerParse(self.allocator, contents[0..], &line, &column);
            var parsed_file = File{
                .contents = contents[0..],
                .pieces = pieces,
            };
            _ = self.files.put(file_name, parsed_file) catch return Mustache.Error.MemoryError;
        }
    }

    fn innerParse(allocator: *std.mem.Allocator, contents: []const u8, line: *usize, column: *usize) Mustache.Error!Mustache.Pieces {
        var pieces = Mustache.Pieces.init();
        var i: usize = 0;
        var start: usize = i;
        var end: usize = 0;
        while (i < contents.len) {
            if (contents[i] == '{') {
                end = i;
                i += 1;
                if (i < contents.len and contents[i] == '{') {
                    column.* += 2;
                    if (end - start > 0) {
                        var part = pieces.createNode(Piece{
                            .Text = .{
                                .contents = contents[start..end],
                            },
                        }, allocator) catch return Mustache.Error.MemoryError;

                        pieces.append(part);

                        for (contents[start..end]) |c| {
                            if (c == '\n') {
                                line.* += 1;
                                column.* = 0;
                            }
                            column.* += 1;
                        }
                    }

                    i += 1;
                    if (i >= contents.len) {
                        return Mustache.Error.UnexpectedEOF;
                    }

                    if (contents[i] == '#' or contents[i] == '^') {
                        var exists: bool = contents[i] == '#';
                        i += 1;
                        column.* += 1;

                        var end_tag: usize = 0;
                        var identifier = getIdentifier(contents[i..], 2, &end_tag) catch |err| {
                            column.* += end_tag;
                            return err;
                        };
                        i += end_tag;
                        column.* += end_tag;

                        if (i < contents.len and (contents[i] == '\n' or contents[i] == '\r')) {
                            if (contents[i] == '\r') {
                                i += 1;
                            }
                            i += 1;
                            line.* += 1;
                            column.* = 1;

                            if (i >= contents.len) {
                                return Mustache.Error.UnexpectedEOF;
                            }
                        }

                        start = i;
                        var end_section: usize = 0;
                        end = getSectionEnd(identifier, contents[start..], &end_section) catch |err| {
                            column.* += end;
                            return err;
                        };
                        end += start;

                        var parsed_section = innerParse(allocator, contents[start..end], line, column) catch |err| {
                            return err;
                        };
                        var new_section = Piece{
                            .Section = .{
                                .exists = exists,
                                .name = identifier,
                                .contents = contents[start..end],
                                .pieces = parsed_section,
                            },
                        };
                        var new_node = pieces.createNode(new_section, allocator) catch return Mustache.Error.MemoryError;
                        pieces.append(new_node);

                        i += end_section;
                        if (i < contents.len and (contents[i] == '\n' or contents[i] == '\r')) {
                            if (contents[i] == '\r') {
                                i += 1;
                            }
                            i += 1;
                            line.* += 1;
                            column.* = 1;
                        }
                        start = i;
                        continue;
                    } else if (contents[i] == '!') {
                        // Parse comment until it reaches }}
                        var has_curly = false;
                        i += 1;
                        column.* += 1;
                        while (i < contents.len) {
                            if (contents[i] == '}') {
                                i += 1;
                                if (i < contents.len and contents[i] == '}') {
                                    i += 1;
                                    column.* += 1;
                                    has_curly = true;
                                    break;
                                }
                            } else if (contents[i] == '\n') {
                                line.* += 1;
                                column.* = 0;
                            }
                            i += 1;
                            column.* += 1;
                        }
                        if (!has_curly) {
                            return Mustache.Error.ExpectedCloseCurlyBrace;
                        }
                        start = i;
                    } else if (contents[i] == '/') {
                        column.* += 1;
                        return Mustache.Error.UnexpectedEndSection;
                    } else if (contents[i] == '>') {
                        i += 1;
                        column.* += 1;
                        var end_tag: usize = 0;
                        var identifier = getIdentifier(contents[i..], 2, &end_tag) catch |err| {
                            column.* += end_tag;
                            return err;
                        };
                        column.* += end_tag;

                        var file = Piece{ .Include = .{ .file = identifier } };
                        var node = pieces.createNode(file, allocator) catch return Mustache.Error.MemoryError;
                        pieces.append(node);

                        if (i < contents.len and (contents[i] == '\n' or contents[i] == '\r')) {
                            if (contents[i] == '\r') {
                                i += 1;
                            }
                            i += 1;
                            line.* += 1;
                            column.* = 1;
                        }
                        start = i + end_tag;
                    } else {
                        var end_tag: usize = 0;
                        var identifier = getIdentifier(contents[i..], 2, &end_tag) catch |err| {
                            column.* += end_tag;
                            return err;
                        };
                        column.* += end_tag;

                        var value = Piece{ .Value = .{ .name = identifier } };
                        var node = pieces.createNode(value, allocator) catch return Mustache.Error.MemoryError;
                        pieces.append(node);
                        if (i < contents.len and (contents[i] == '\n' or contents[i] == '\r')) {
                            if (contents[i] == '\r') {
                                i += 1;
                            }
                            i += 1;
                            line.* += 1;
                            column.* = 1;
                        }
                        start = i + end_tag;
                    }
                } else {
                    column.* += 1;
                    return Mustache.Error.ExpectedOpenCurlyBrace;
                }
            }
            column.* += 1;
            i += 1;
        }
        if (end == 0 or end != contents.len) {
            var part = Piece{ .Text = .{ .contents = contents[start..] } };
            var node = pieces.createNode(part, allocator) catch return Mustache.Error.MemoryError;
            pieces.append(node);
        }

        return pieces;
    }
};

fn getIdentifier(content: []const u8, amount_of_closing: usize, ending: ?*usize) Mustache.Error![]const u8 {
    var num: usize = 0;
    var start: usize = 0;
    var has_ident = false;
    var end: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '}') {
            if (end == 0) {
                end = i;
            }
            num = 0;
            while (num != amount_of_closing) : (num += 1) {
                if (i + num >= content.len or content[i + num] != '}') {
                    if (ending) |val| {
                        val.* = i + num;
                    }
                    return Mustache.Error.ExpectedCloseCurlyBrace;
                }
            }
            break;
        } else if (content[i] == '\n') {
            if (ending) |val| {
                val.* = i + num;
            }
            return Mustache.Error.UnexpectedNewline;
        } else if (content[i] == ' ') {
            if (has_ident and end == 0) {
                end = i;
            }
        } else if (!has_ident) {
            has_ident = true;
            start = i;
        }
    }
    if (i >= content.len and num != amount_of_closing) {
        return Mustache.Error.ExpectedCloseCurlyBrace;
    }
    if (ending) |val| {
        val.* = i + num;
    }
    return content[start..end];
}

test "getIdentifier" {
    var ident = try getIdentifier("foo }}", 2, null);
    std.testing.expect(std.mem.eql(u8, ident, "foo"));

    var ident2 = try getIdentifier("foo}}", 2, null);
    std.testing.expect(std.mem.eql(u8, ident2, "foo"));
}

fn getSectionEnd(identifier: []const u8, content: []const u8, end: *usize) Mustache.Error!usize {
    var needed: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '{') {
            start = i;
            if (i + 1 >= content.len or content[i + 1] != '{') {
                end.* = i + 1;
                return Mustache.Error.ExpectedOpenCurlyBrace;
            }
            i += 1;
            if (i + 1 >= content.len) {
                end.* = i;
                return Mustache.Error.UnexpectedEOF;
            }
            i += 1;
            if (content[i] == '#') {
                i += 1;
                var end_tag: usize = i;
                var ident = try getIdentifier(content[i..], 2, &end_tag);
                i += end_tag;
                if (std.mem.eql(u8, ident, identifier)) {
                    needed += 1;
                }
                continue;
            } else if (content[i] == '/') {
                i += 1;
                var end_tag: usize = 0;
                var ident = try getIdentifier(content[i..], 2, &end_tag);
                i += end_tag;
                if (std.mem.eql(u8, ident, identifier)) {
                    needed -= 1;
                    if (needed == 0) {
                        end.* = i;
                        return start;
                    }
                }
                continue;
            }
        }
        i += 1;
    }
    return Mustache.Error.ExpectedEndSection;
}

test "Mustache" {
    std.meta.refAllDecls(Mustache);

    var result = std.ArrayList(u8).init(std.testing.allocator);
    defer result.deinit();
    var out_stream = result.outStream();

    var mustache = Mustache.init(std.testing.allocator);
    defer mustache.deinit();
    try mustache.render(@TypeOf(out_stream), out_stream, "tests/test1.must", .{ .foo = 69, .bar = .{ .thing = 10 }, .not_bar = false });

    var expect =
        \\foo
        \\69
        \\42
        \\30
        \\
    ;

    std.testing.expect(std.mem.eql(u8, result.items[0..], expect));
}
