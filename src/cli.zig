//! Utility functions for use in the server and client CLIs

const std = @import("std");
const mem = std.mem;

// Checks if the argument is "--help" or "-h"
pub fn parseHelp(arg: []const u8) bool {
    return mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h");
}

/// Parses an option with a parameter from the argument iterator.
/// Returns `null` if the argument doesn't match, or the parameter value on success.
/// Crashes with `cli.fatal` and an error message if the argument matches, but is missing its parameter,
/// Supports both `--name <value>` and `--name=<value>` forms.
pub fn parseOption(current_arg: []const u8, next_args: *std.process.Args.Iterator, name: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, current_arg, "--")) return null;

    const arg_name = name["--".len..];
    if (mem.eql(u8, arg_name, name)) {
        return next_args.next() orelse fatal("missing argument for --{s}", .{name});
    } else if (arg_name.len > name.len and mem.startsWith(u8, arg_name, name) and arg_name[name.len] == '=') {
        // Allows '--name=', which would mean the value of `name` is the empty string
        return arg_name[name.len + 1 ..];
    }

    return null;
}

/// Parses a switch from the current argument.
/// Returns `true` if the argument matches `--[name]`, `false` if it matches `--no-[name]`, and `null` if it doesn't match.
pub fn parseSwitch(arg: []const u8, name: []const u8) ?bool {
    if (mem.startsWith(u8, arg, "--") and mem.eql(u8, arg["--".len..], name)) {
        return true;
    } else if (mem.startsWith(u8, arg, "--no-") and mem.eql(u8, arg["--no-".len..], name)) {
        return false;
    }

    return null;
}

/// Prints an error message an exits with a non-zero status code
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    if (@import("builtin").mode == .Debug) @breakpoint();
    std.process.exit(1);
}
