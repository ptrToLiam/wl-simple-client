prev: ?*Arena,
cur: *Arena,
flags: Flags,
cmt_size: usize,
res_size: usize,
base_pos: usize,
_pos: usize,
cmt: usize,
res: usize,

pub const HeaderSize = @sizeOf(Arena);

pub fn init(params: InitParams) *Arena {
  var reserve_size: usize = params.reserve_size;
  var commit_size: usize = params.commit_size;
  var flags: Flags = params.flags;
  if (params.flags.large_pages) {
    reserve_size = align_pow2(reserve_size, math.Units.MB(2));
    commit_size = align_pow2(commit_size, math.Units.MB(2));
  } else {
    reserve_size = align_pow2(reserve_size, std.heap.page_size_min);
    commit_size = align_pow2(commit_size, std.heap.page_size_min);
  }

  const base = if (params.backing_buffer) |buf|
    buf
  else if (params.flags.large_pages) base: {
    const ptr = os.mem_reserve_large(reserve_size) orelse ptr: {
      // Fallback to standard page sizes if large pages not working
      flags.large_pages = false;
      reserve_size = align_pow2(reserve_size, std.heap.page_size_min);
      commit_size = align_pow2(commit_size, std.heap.page_size_min);

      log.warn("Arena :: Mem_Reserve :: Large pages not supported, falling back to standard page sizes", .{});
      break :ptr os.mem_reserve(reserve_size);
    };

    if (flags.large_pages) {
      if (!os.mem_commit_large(ptr[0..commit_size]))
        std.debug.print("Failed Large ({d} Bytes) Page Commit\n", .{commit_size});
    } else {
      if (!os.mem_commit(ptr[0..commit_size]))
        std.debug.print("Failed {d}KB Page(s) Commit\n", .{std.heap.page_size_min});
    }

    break :base ptr;
  } else base: {
    const ptr = os.mem_reserve(reserve_size);
    if (!os.mem_commit(ptr[0..commit_size]))
        std.debug.print("Failed {d}KB Page(s) Commit\n", .{std.heap.page_size_min});

    break :base ptr;
  };

  const arena = transmute(*Arena, base);

  arena.* = .{
    .flags = flags,
    .prev = null,
    .cur = arena,
    .cmt_size = commit_size,
    .res_size = reserve_size,
    .base_pos = 0,
    ._pos = Arena.HeaderSize,
    .cmt = commit_size,
    .res = reserve_size,
  };

  return arena;
}

pub fn push_no_zero(arena: *Arena, comptime T: type, count: usize) []T {
  const data: []u8 = arena._push_impl((@sizeOf(T) * count), @max(8, @alignOf(T)));
  const res = transmute([*]T, data);

  return (res[0..count]);
}

pub inline fn push(arena: *Arena, comptime T: type, count: usize) []T {
  const bytes = arena.push_no_zero(T, count);
  const raw_bytes = transmute([]u8, bytes);
  @memset(raw_bytes[0 .. count * @sizeOf(T)], 0);

  return bytes;
}

pub fn create(arena: *Arena, comptime T: type) *T {
  const data = arena.push(T, 1);

  return transmute(*T, data);
}

pub fn release(arena: *Arena) void {
  var next: ?*Arena = arena.cur;
  var prev: ?*Arena = null;
  while (next) |n| : (next = prev) {
    prev = n.prev;
    const ptr = transmute(
      [*]align(std.heap.page_size_min) u8,
      n,
    );
    os.mem_release(ptr[0..n.res]);
  }
}

pub fn pos(arena: *Arena) usize {
  const cur = arena.cur;
  const _pos = cur.base_pos + cur._pos;

  return _pos;
}

pub fn pop_to(arena: *Arena, _pos: usize) void {
  const big_pos = if (Arena.HeaderSize < _pos) _pos else Arena.HeaderSize;
  var cur: *Arena = arena.cur;
  var prev_opt: ?*Arena = null;

  while (cur.base_pos >= big_pos) {
    prev_opt = cur.prev;
    const ptr = transmute(
      [*]align(std.heap.page_size_min) const u8,
      cur,
    );
    os.mem_release(ptr[0..cur.res]);

    if (prev_opt) |prev| {
      cur = prev;
    }
  }

  arena.cur = cur;
  const new_pos = big_pos - cur.base_pos;
  cur._pos = new_pos;
}

pub fn temp(arena: *Arena) Temp {
  return .{
    .arena = arena,
    .pos = arena.pos(),
  };
}

pub fn end(tmp: *Temp) void {
  tmp.arena.pop_to(tmp.pos);
}

pub fn clear(arena: *Arena) void {
  arena.pop_to(0);
}

pub fn _push_impl(arena: *Arena, size: usize, @"align": usize) []u8 {
  var cur: *Arena = arena.cur;
  var pos_pre = cast(usize, align_pow2(cur._pos, @"align"));
  var pos_pst: usize = pos_pre + size;

  // chain if needed
  if (cur.res < pos_pst and !(arena.flags.no_chain)) {
    var new_block: *Arena = new_block: {
      var res_size: usize = cur.res_size;
      var cmt_size: usize = cur.cmt_size;

      if (size + Arena.HeaderSize > res_size) {
        res_size = align_pow2(size + Arena.HeaderSize, @"align");
        cmt_size = align_pow2(size + Arena.HeaderSize, @"align");
      }

      break :new_block .init(.{
        .flags = cur.flags,
        .reserve_size = res_size,
        .commit_size = cmt_size,
        .backing_buffer = null,
      });
    };

    new_block.base_pos = cur.base_pos + cur.res;
    new_block.prev = arena.cur;
    arena.cur = new_block;

    cur = new_block;
    pos_pre = align_pow2(cur._pos, @"align");
    pos_pst = pos_pre + size;
  }

  // commit new pages if needed
  if (cur.cmt < pos_pst) {
    var cmt_pst_aligned: usize = pos_pst + cur.cmt_size - 1;
    cmt_pst_aligned -= cmt_pst_aligned % cur.cmt_size;

    const cmt_pst_clamped: usize = @min(cmt_pst_aligned, cur.res);
    const cmt_size = cmt_pst_clamped - cur.cmt;

    const ptr = transmute(
      [*]align(std.heap.page_size_min) u8,
      cur,
    );

    const cmt_range = ptr[cur.cmt .. cur.cmt + cmt_size];
    if (cur.flags.large_pages) {
      if (!os.mem_commit_large(@alignCast(cmt_range)))
        std.debug.print("Failed to commit large page of mem: [{d}..{d}]\n", .{
          cur.cmt,
          cur.cmt + cmt_size,
        });
    } else {
      if (!os.mem_commit(@alignCast(cmt_range)))
        std.debug.print("Failed to commit page of mem: [{d}..{d}]\n", .{
          cur.cmt,
          cur.cmt + cmt_size,
        });
    }

    cur.cmt = cmt_pst_aligned;
  }

  const result: []u8 = if (cur.cmt >= pos_pst) result: {
    cur._pos = pos_pst;
    const ptr = transmute(
      [*]u8,
      cur,
    );
    break :result ptr[pos_pre .. pos_pre + pos_pst];
  } else unreachable;

  return result;
}

pub const Temp = packed struct {
  arena: *Arena,
  pos: usize,

  pub fn end(tmp: *const Temp) void {
    tmp.arena.pop_to(tmp.pos);
  }
};

pub const Flags = packed struct {
  no_chain: bool,
  large_pages: bool,

  pub const default: Flags = .{
    .no_chain = false,
    .large_pages = false,
  };

  pub const largepage: Flags = .{
    .no_chain = false,
    .large_pages = true,
  };

  pub const nochain: Flags = .{
    .no_chain = true,
    .large_pages = false,
  };

  pub const large_nochain: Flags = .{
    .no_chain = true,
    .large_pages = true,
  };
};

pub const InitParams = struct {
  flags: Flags,
  reserve_size: usize,
  commit_size: usize,
  backing_buffer: ?[]align(std.heap.page_size_min) u8,

  pub const default: InitParams = .{
    .flags = .default,
    .reserve_size = std.heap.page_size_min,
    .commit_size = std.heap.page_size_min,
    .backing_buffer = null,
  };

  pub const large_pages: InitParams = .{
    .flags = .largepage,
    .reserve_size = math.Units.MB(2),
    .commit_size = math.Units.MB(2),
    .backing_buffer = null,
  };
};

//-----------------------------------------------------------------------------
// Zig Allocator Interface Implementation
//-----------------------------------------------------------------------------
pub fn allocator(arena: *Arena) std.mem.Allocator {
  return .{
    .ptr = @ptrCast(arena),
    .vtable = &.{
      .alloc = alloc,
      .resize = resize,
      .remap = remap,
      .free = free,
    },
  };
}

fn alloc(ctx: *anyopaque, n: usize, @"align": mem.Alignment, ret_addr: usize) ?[*]u8 {
  const arena = transmute(*Arena, ctx);
  _ = ret_addr;
  const ptr_align = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(@"align".toByteUnits()));
  return @ptrCast(arena._push_impl(n, ptr_align));
}

fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
  const arena = transmute(*Arena, ctx);
  const current = arena.cur;
  _ = log2_buf_align;
  _ = ret_addr;

  if (cast(usize, buf.ptr) != (cast(usize, current) + current.pos()) - buf.len) {
    return new_len <= buf.len;
  }

  if (buf.len >= new_len) {
    current._pos = @max(Arena.HeaderSize, current.pos() - (buf.len - new_len));
    return true;
  } else if (current.res - current.pos() >= new_len - buf.len) {
    current._pos += (new_len - buf.len);
    return true;
  } else {
    return false;
  }
}

fn remap(
  context: *anyopaque,
  memory: []u8,
  alignment: mem.Alignment,
  new_len: usize,
  return_address: usize,
) ?[*]u8 {
  return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

fn free(ctx: *anyopaque, buf: []u8, pow2_buf_align: mem.Alignment, ret_addr: usize) void {
  _ = ctx;
  _ = pow2_buf_align;
  _ = ret_addr;
  _ = buf;
}

//-----------------------------------------------------------------------------

const Arena = @This();

const align_pow2 = math.align_pow2;

const log = std.log.scoped(.Arena);
const TargetOs = builtin.target.os;

const mem = std.mem;
const posix = std.posix;

const cast = casts.cast;
const transmute = casts.transmute;

// File Imports
const math = @import("math.zig");
const casts = @import("casts.zig");

// Internal Module Imports
const os = @import("os");

// 3rd-Party Module Imports
const std = @import("std");
const builtin = @import("builtin");
