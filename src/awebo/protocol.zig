const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const client = @import("protocol/client.zig");
pub const server = @import("protocol/server.zig");
pub const media = @import("protocol/media.zig");

test {
    _ = client;
    _ = server;
    _ = media;
}

/// Generic function for serializing protocol messages.
pub fn SerializeAllocFn(T: type) type {
    return fn (msg: T, gpa: Allocator) error{OutOfMemory}![]const u8;
}

pub fn MakeSerializeAllocFn(T: type) SerializeAllocFn(T) {
    const Impl = struct {
        fn serializeAlloc(msg: T, gpa: Allocator) error{OutOfMemory}![]const u8 {
            var aw: Io.Writer.Allocating = .init(gpa);
            MakeSerializeFn(T)(msg, &aw.writer) catch return error.OutOfMemory;
            return aw.toOwnedSlice();
        }
    };

    return Impl.serializeAlloc;
}

pub fn SerializeFn(T: type) type {
    return fn (msg: T, writer: *Io.Writer) error{WriteFailed}!void;
}
pub fn MakeSerializeFn(T: type) SerializeFn(T) {
    const Impl = struct {
        fn serialize(msg: T, w: *Io.Writer) error{WriteFailed}!void {
            comptime assert(@typeInfo(T) == .@"struct"); // messages must be structs
            comptime assert(@hasDecl(T, "protocol")); // messages must define a protocol decl

            try w.writeByte(T.marker);
            try serializeInner(msg, w);
        }

        fn serializeInner(elem: anytype, w: *Io.Writer) error{WriteFailed}!void {
            const E = @TypeOf(elem);
            const info = @typeInfo(E);
            switch (info) {
                else => @compileError("unsupported type: " ++ @typeName(E)),
                .void => {},
                .bool => try w.writeByte(@intFromBool(elem)),
                .int => try w.writeInt(E, elem, .little),
                .@"enum" => |enum_info| try w.writeInt(enum_info.tag_type, @intFromEnum(elem), .little),
                .optional => {
                    if (elem) |e| {
                        try w.writeByte(1);
                        try serializeInner(e, w);
                    } else {
                        try w.writeByte(0);
                    }
                },
                .@"union" => |union_info| {
                    if (union_info.tag_type == null) {
                        @compileError("union tag must have explicit enum in " ++ @typeName(E));
                    }
                    const Int = @typeInfo(union_info.tag_type.?).@"enum".tag_type;
                    switch (elem) {
                        inline else => |value, tag| {
                            try w.writeInt(Int, @intFromEnum(tag), .little);
                            try serializeInner(value, w);
                        },
                    }
                },
                .pointer => |pointer_info| switch (pointer_info.size) {
                    .one => try serializeInner(elem.*, w),
                    .many, .c => @compileError("not supported"),
                    .slice => switch (pointer_info.child) {
                        u8 => try w.writeAll(elem),
                        else => for (elem) |e| {
                            try serializeInner(e, w);
                        },
                    },
                },
                .@"struct" => |struct_info| {
                    comptime assert(@hasDecl(T, "protocol")); // all structs in a message must define a protocol decl
                    if (@hasDecl(E.protocol, "skip") and E.protocol.skip) return;
                    if (@hasDecl(E.protocol, "serialize")) return E.protocol.serialize(elem, serializeInner, w);
                    inline for (struct_info.fields) |f| {
                        switch (@typeInfo(f.type)) {
                            else => try serializeInner(@field(elem, f.name), w),
                            .pointer => |pointer_info| switch (pointer_info.size) {
                                .one => try serializeInner(elem.*, w),
                                .many, .c => @compileError("not supported"),
                                .slice => {
                                    if (!@hasDecl(E.protocol, "sizes") or !@hasDecl(E.protocol.sizes, f.name)) {
                                        @compileError("missing protocol.sizes." ++ f.name ++ " in " ++ @typeName(E));
                                    }
                                    const Int = @field(E.protocol.sizes, f.name);
                                    const slice_field = @field(elem, f.name);

                                    // std.log.debug("serializing {s}.{s} ({s})", .{ @typeName(E), f.name, @typeName(f.type) });
                                    // std.log.debug("size: {s} len: {}", .{ @typeName(Int), slice_field.len });
                                    try w.writeInt(Int, @intCast(slice_field.len), .little);
                                    try serializeInner(slice_field, w);
                                },
                            },
                        }
                    }
                },
            }
        }
    };

    return Impl.serialize;
}

/// Generic functions for deserializing protocol messages
pub const DeserializeError = error{ AweboProtocol, ReadFailed, EndOfStream };
pub fn DeserializeFn(T: type) type {
    return fn (r: *Io.Reader) DeserializeError!T;
}
pub fn MakeDeserializeFn(T: type) DeserializeFn(T) {
    const Impl = struct {
        fn deserializeAlloc(r: *Io.Reader) DeserializeError!T {
            comptime assert(@typeInfo(T) == .@"struct"); // messages must be structs
            comptime assert(@hasDecl(T, "protocol")); // messages must define a protocol decl
            return deserializeInner(T, r);
        }

        fn deserializeInner(E: type, r: *Io.Reader) DeserializeError!E {
            const info = @typeInfo(E);
            switch (info) {
                else => @compileError("unsupported type: " ++ @typeName(E)),
                .pointer => @compileError("message " ++ @typeName(T) ++ " contains pointers, give it `deserializeAlloc`"),
                .void => return {},
                .bool => return (try r.takeByte()) == 1,
                .int => return r.takeInt(E, .little),
                .@"enum" => |enum_info| return @enumFromInt(try r.takeInt(enum_info.tag_type, .little)),
                .@"union" => |union_info| {
                    if (!@hasDecl(E, "protocol")) {
                        @compileError("missing protocol decl in union " ++ @typeName(E));
                    }
                    if (union_info.tag_type == null) {
                        @compileError("union tag must have explicit enum in " ++ @typeName(E));
                    }
                    const tag = r.takeEnum(union_info.tag_type.?, .little) catch |err| switch (err) {
                        error.InvalidEnumTag => return error.AweboProtocol,
                        else => |e| return e,
                    };
                    return switch (tag) {
                        inline else => |t| @unionInit(E, @tagName(t), try deserializeInner(union_info.fields[@intFromEnum(t)].type, r)),
                    };
                },
                .@"struct" => |struct_info| {
                    comptime assert(@hasDecl(E, "protocol")); // all structs in a message must define a protocol decl
                    if (@hasDecl(E.protocol, "skip") and E.protocol.skip) return .{};
                    if (@hasDecl(E.protocol, "deserialize")) return E.protocol.deserialize(deserializeInner, r);

                    var s: E = undefined;
                    inline for (struct_info.fields) |f| {
                        @field(s, f.name) = try deserializeInner(f.type, r);
                    }

                    return s;
                },
            }
        }
    };

    return Impl.deserializeAlloc;
}
pub const DeserializeAllocError = error{OutOfMemory} || DeserializeError;
pub fn DeserializeAllocFn(T: type) type {
    return fn (gpa: Allocator, r: *Io.Reader) DeserializeAllocError!T;
}
pub fn MakeDeserializeAllocFn(T: type) DeserializeAllocFn(T) {
    const Impl = struct {
        fn deserializeAlloc(gpa: Allocator, r: *Io.Reader) DeserializeAllocError!T {
            comptime assert(@typeInfo(T) == .@"struct"); // messages must be structs
            comptime assert(@hasDecl(T, "protocol")); // messages must define a protocol decl

            return deserializeAllocInner(T, gpa, r);
        }

        fn deserializeAllocInner(E: type, gpa: Allocator, r: *Io.Reader) DeserializeAllocError!E {
            const info = @typeInfo(E);
            switch (info) {
                else => @compileError("unsupported type: " ++ @typeName(E)),
                .void => return {},
                .bool => return (try r.takeByte()) == 1,
                .int => return r.takeInt(E, .little),
                .@"enum" => |enum_info| return @enumFromInt(try r.takeInt(enum_info.tag_type, .little)),
                .optional => |opt_info| {
                    const present = try r.takeByte();
                    switch (present) {
                        0 => return null,
                        1 => return try deserializeAllocInner(opt_info.child, gpa, r),
                        else => unreachable,
                    }
                },
                .@"union" => |union_info| {
                    comptime assert(@hasDecl(E, "protocol")); // all unions in a message must define a protocol decl
                    if (union_info.tag_type == null) {
                        @compileError("union tag must have explicit enum in " ++ @typeName(E));
                    }
                    const tag = r.takeEnum(union_info.tag_type.?, .little) catch |err| switch (err) {
                        error.InvalidEnumTag => return error.AweboProtocol,
                        else => |e| return e,
                    };
                    switch (tag) {
                        inline else => |t| {
                            const field_type = union_info.fields[@intFromEnum(t)].type;
                            switch (@typeInfo(field_type)) {
                                else => return @unionInit(E, @tagName(t), try deserializeAllocInner(field_type, gpa, r)),
                                .pointer => |pointer_info| switch (pointer_info.size) {
                                    .one => {},
                                    .many, .c => @compileError("not supported"),
                                    .slice => {
                                        if (!@hasDecl(E.protocol, "sizes") or !@hasDecl(E.protocol.sizes, @tagName(t))) {
                                            @compileError("missing protocol.sizes." ++ @tagName(t) ++ " in " ++ @typeName(E));
                                        }
                                        if (pointer_info.child == u8) {
                                            const Int = @field(E.protocol.sizes, @tagName(t));
                                            const len = try r.takeInt(Int, .little);
                                            const bytes = try gpa.alloc(u8, len);
                                            errdefer gpa.free(bytes);
                                            try r.readSliceAll(@constCast(bytes));
                                            return @unionInit(E, @tagName(t), bytes);
                                        }

                                        return @unionInit(E, @tagName(t), try deserializeAllocInner(field_type, gpa, r));
                                    },
                                },
                            }
                        },
                    }
                },
                .@"struct" => |struct_info| {
                    comptime assert(@hasDecl(T, "protocol")); // all structs in a message must define a protocol decl
                    if (@hasDecl(E.protocol, "skip") and E.protocol.skip) return .{};
                    if (@hasDecl(E.protocol, "deserializeAlloc")) return E.protocol.deserializeAlloc(deserializeAllocInner, gpa, r);

                    var s: E = undefined;
                    // TODO: errdefer :^)
                    inline for (struct_info.fields) |f| switch (@typeInfo(f.type)) {
                        else => @field(s, f.name) = try deserializeAllocInner(f.type, gpa, r),
                        .pointer => |pointer_info| switch (pointer_info.size) {
                            .many, .c => @compileError("not supported"),
                            .one => {
                                const field = &@field(s, f.name);
                                field.* = try gpa.create(f.type);
                                errdefer gpa.destroy(field.*);

                                field.* = try deserializeAllocInner(pointer_info.child, gpa, r);
                            },

                            .slice => {
                                if (!@hasDecl(E.protocol, "sizes") or !@hasDecl(E.protocol.sizes, f.name)) {
                                    @compileError("missing protocol.sizes." ++ f.name ++ " in " ++ @typeName(E));
                                }
                                const Int = @field(E.protocol.sizes, f.name);
                                const len = try r.takeInt(Int, .little);
                                const field = &@field(s, f.name);
                                field.* = try gpa.alloc(pointer_info.child, len);
                                errdefer gpa.free(field.*);

                                if (pointer_info.child == u8) {
                                    try r.readSliceAll(@constCast(field.*));
                                } else {
                                    for (field.*) |*e| {
                                        @constCast(e).* = try deserializeAllocInner(pointer_info.child, gpa, r);
                                    }
                                }
                            },
                        },
                    };

                    return s;
                },
            }
        }
    };

    return Impl.deserializeAlloc;
}
