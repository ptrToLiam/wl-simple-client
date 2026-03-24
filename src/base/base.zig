//-----------------------------------------------------------------------------
// Module Re-Exports
//-----------------------------------------------------------------------------

pub const Arena = @import("Arena.zig");
pub const Thread = @import("Thread.zig");

pub const math = @import("math.zig");
pub const casts = @import("casts.zig");

//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// Module Toplevel Types
//-----------------------------------------------------------------------------

/// Requires backing buffer to be of a power of 2 length.
pub const RingBuffer = struct {
  buf: []u8,
  read: u32 = 0,
  write: u32 = 0,

  /// Assumes provided buffer to be of pow2 length
  pub fn init_backing(bytes: []u8) RingBuffer {
    AssertMsg(
      (bytes.len < MAX_SIZE) and
      math.is_pow2(bytes.len),
      "Buffer size must be power of 2, and fit within 2^31",
    );
    return .{ .buf = bytes };
  }

  pub fn size(rb: *RingBuffer) u32 {
    return rb.write -% rb.read;
  }

  pub fn empty(rb: *RingBuffer) bool {
    return rb.write == rb.read;
  }

  pub fn mask(rb: *RingBuffer, idx: u32) u32 {
    return idx & u32_(rb.buf.len - 1);
  }

  pub fn putBytes(rb: *RingBuffer, bytes: []const u8) void {
    const write_idx = rb.mask(rb.write);
    defer rb.write +%= u32_(bytes.len);

    const contiguous_bytes = rb.buf[write_idx..];
    const copy0_len = @min(contiguous_bytes.len, bytes.len);
    const copy1_len = bytes.len - copy0_len;

    @memcpy(contiguous_bytes[0..copy0_len], bytes[0..copy0_len]);
    @memcpy(rb.buf[0..copy1_len], bytes[copy0_len..]);
  }

  pub fn getNBytesFrom(rb: *RingBuffer, pos: u32, count: usize, out: []u8) void {
    const start = rb.mask(pos);

    const contiguous_bytes = rb.buf[start..];
    const copy0_len = @min(count, contiguous_bytes.len);
    const copy1_len = count - copy0_len;

    @memcpy(out[0..copy0_len], contiguous_bytes[0..copy0_len]);
    @memcpy(out[copy0_len..], rb.buf[0..copy1_len]);
  }

  const MAX_SIZE = math.maxInt(u31);
};

//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// Module Toplevel Functions
//-----------------------------------------------------------------------------

pub inline fn StaticAssert(cond: bool, msg: []const u8) void {
  comptime {
    if (!cond)
      @compileError(msg);
  }
}

pub inline fn Assert(cond: bool) void {
  if (!cond)
    @trap();
}

pub inline fn AssertMsg(cond: bool, msg: []const u8) void {
  if (!cond)
    @panic(msg);
}

pub inline fn DebugAssert(cond: bool, msg: []const u8) void {
  switch (builtin.mode) {
    .Debug, .ReleaseSafe => {
      AssertMsg(cond, msg);
    },
    else => {},
  }
}

//-----------------------------------------------------------------------------
// Value-preserving cast quick helpers
//-----------------------------------------------------------------------------

pub inline fn u8_(v: anytype) u8 {
  return cast(u8, v);
}

pub inline fn i8_(v: anytype) i8 {
  return cast(i8, v);
}

pub inline fn u16_(v: anytype) u16 {
  return cast(u16, v);
}

pub inline fn i16_(v: anytype) i16 {
  return cast(i16, v);
}

pub inline fn u32_(v: anytype) u32 {
  return cast(u32, v);
}

pub inline fn i32_(v: anytype) i32 {
  return cast(i32, v);
}

pub inline fn u64_(v: anytype) u64 {
  return cast(u64, v);
}

pub inline fn i64_(v: anytype) i64 {
  return cast(i64, v);
}

pub inline fn u128_(v: anytype) u128 {
  return cast(u128, v);
}

pub inline fn i128_(v: anytype) i128 {
  return cast(i128, v);
}

pub inline fn usize_(v: anytype) usize {
  return cast(usize, v);
}

pub inline fn isize_(v: anytype) isize {
  return cast(isize, v);
}

pub inline fn f32_(v: anytype) f32 {
  return cast(f32, v);
}

pub inline fn f64_(v: anytype) f64 {
  return cast(f64, v);
}

//-----------------------------------------------------------------------------

const cast = casts.cast;
const transmute = casts.transmute;

const os = @import("os");
const builtin = @import("builtin");