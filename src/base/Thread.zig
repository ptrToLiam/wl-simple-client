pub threadlocal var tctx: *Context = undefined;
pub threadlocal var is_async: bool = false;

pub inline fn ctx_init() void {
  tctx = .init();
}

pub inline fn ctx_release() void {
  tctx.release();
}

pub const sleep = os.sleep;
pub const yield = std.Thread.yield;

pub const Context = struct {
  arenas: [2]*Arena,

  name: [32]u8 = @splat(0),
  name_len: u64 = 0,

  pub fn init() *Context {
    const arena: *Arena = .init(.default);
    const ctx: *Context = arena.create(Context);
    ctx.* = .{
      .arenas = .{
      arena,
      .init(.default),
      },
      .name = undefined,
      .name_len = undefined,
    };

    return ctx;
  }

  pub fn release(ctx: *Context) void {
    ctx.arenas[1].release();
    ctx.arenas[0].release();
  }

  pub fn get_scratch(comptime N: comptime_int, conflicts: [N]*Arena) ?Arena.Temp {
    var result: ?Arena.Temp = null;
    outer: for (tctx.arenas) |arena| {
      result = arena.temp();
      for (conflicts) |conflict| {
        if (arena == conflict) {
          result = null;
          continue :outer;
        }
      }
      if (result != null)
        break;
    }
    return result;
  }
};

const Thread = @This();
const ThreadHandle = std.Thread;

const log = std.log.scoped(.Thread);

// File Imports
const Arena = @import("Arena.zig");

// Internal Module Imports
const os = @import("os");

// 3rd-Party Module Imports
const builtin = @import("builtin");
const std = @import("std");
