pub const mem_reserve = linux.mem_reserve;
pub const mem_commit = linux.mem_commit;
pub const mem_decommit = linux.mem_decommit;
pub const mem_release = linux.mem_release;
pub const mem_reserve_large = linux.mem_reserve_large;
pub const mem_commit_large = linux.mem_commit_large;

pub const sleep = linux.sleep;

pub const page_size_min = std.heap.page_size_min;
pub const page_size_max = std.heap.page_size_max;

pub const Environ = std.process.Environ;
pub const Target = builtin.target.os;

// File Imports
pub const linux = @import("linux.zig");

// 3rd-Party Modules
const std = @import("std");
const builtin = @import("builtin");
