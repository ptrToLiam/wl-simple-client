//------------------------------------------------------------------------------
//             Memory Management API Surface
//------------------------------------------------------------------------------
pub inline fn mem_reserve(size: usize) []align(page_size_min) u8 {
  const rc = mmap(
    null,
    size,
    .{},
    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
    -1,
    0,
  );

  // intentional crash on failed alloc
  if (errno(rc) != .SUCCESS) unreachable;

  const ptr: [*]align(page_size_min) u8 = @ptrFromInt(rc);
  return ptr[0..size];
}

pub inline fn mem_commit(bytes: []align(page_size_min) u8) bool {
  const rc = mprotect(bytes.ptr, bytes.len, .{ .READ = true, .WRITE = true });

  if (errno(rc) != .SUCCESS) return false;

  return true;
}
pub inline fn mem_decommit(bytes: []align(page_size_min) const u8) void {
  _ = madvise(bytes.ptr, bytes.len, MADV.DONTNEED);
  _ = mprotect(bytes.ptr, bytes.len, PROT.NONE);
}

pub inline fn mem_release(bytes: []align(page_size_min) const u8) void {
  _ = munmap(bytes.ptr, bytes.len);
}

pub inline fn mem_reserve_large(size: usize) ?[]align(page_size_min) u8 {
  const rc = mmap(
    null,
    size,
    .{},
    .{
      .TYPE = .PRIVATE,
      .ANONYMOUS = true,
      .HUGETLB = true,
    },
    -1,
    0,
  );

  if (errno(rc) != .SUCCESS) return null;

  const ptr: [*]align(page_size_min) u8 = @ptrFromInt(rc);
  return ptr[0..size];
}

pub inline fn mem_commit_large(bytes: []align(page_size_min) u8) bool {
  const rc = mprotect(bytes.ptr, bytes.len, .{ .READ = true, .WRITE = true });

  if (errno(rc) != .SUCCESS) return false;

  return true;
}
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
//             Sleep/Time API Surface
//------------------------------------------------------------------------------
pub fn sleep(ns: u64) void {
  const ns_per_s = 1000000000;

  const seconds = ns / ns_per_s;
  const nanoseconds = ns % ns_per_s;

  var req: timespec = .{
    .sec = @intCast(seconds),
    .nsec = @intCast(nanoseconds),
  };
  var rem: timespec = .{ .sec = 0, .nsec = 0 };
  var res: usize = @bitCast(@as(isize, -1));

  while (res != 0) {
    res = nanosleep(&req, &rem);

    if (errno(res) != .INTR) break;

    req = rem;
  }
}
//------------------------------------------------------------------------------

/// Create container type for control messages
pub fn cmsg(comptime T: type) type {
  const msg_len = cmsghdr.msg_len(@sizeOf(T));
  const padded_bit_count = cmsghdr.padding_bits(msg_len, @bitSizeOf(T));

  return packed struct {
    /// Control message header
    header: cmsghdr,
    /// Data we actually want
    data: T,

    /// padding to reach data alignment
    __padding: @Int(.unsigned, padded_bit_count) = 0,

    pub fn init(level: i32, @"type": i32, data: T) cmsg_t {
      return .{
        .header = .{
          .len = msg_len,
          .level = level,
          .type = @"type",
        },
        .data = data,
      };
    }

    pub const Size = @sizeOf(cmsg_t);

    const cmsg_t = @This();
  };
}

const CmsgIterator = struct {
  buf: []const u8,
  idx: usize,

  const Iterator = @This();
  pub fn next(iter: *Iterator) ?*const cmsghdr {
    if (iter.buf[iter.idx..].len < @sizeOf(cmsghdr)) return null;

    const hdr: *const cmsghdr = @ptrCast(@alignCast(iter.buf[iter.idx..].ptr));
    if (hdr.len < @sizeOf(cmsghdr)) return null;

    const aligned_len = cmsghdr.__msg_len(hdr);
    iter.idx += aligned_len;
    if (iter.idx > iter.buf.len) iter.idx = iter.buf.len;

    return hdr;
  }
  pub fn first(iter: *Iterator) ?cmsghdr {
    const result: ?cmsghdr = if (iter.buf[iter.idx..].len > @sizeOf(cmsghdr))
      std.mem.bytesToValue(cmsghdr, iter.buf[iter.idx..][0..@sizeOf(cmsghdr)])
    else
      null;

    return result;
  }

  pub fn reset(iter: *Iterator) void {
    iter.idx = 0;
  }
};

pub const cmsghdr = packed struct {
  /// Data byte count, including header
  len: usize,
  /// Originating protocol
  level: i32,
  /// Protocol-specific type
  type: i32,

  // TODO: Revise. This is prolly a rather unsafe API
  pub fn iter(buf: []const u8) CmsgIterator {
    return .{
      .buf = buf,
      .idx = 0,
    };
  }

  // TODO: Revise. This is prolly a rather unsafe API
  pub fn data(ptr: *const cmsghdr, comptime T: type) *const T {
    const buf: [*]const u8 = @ptrCast(@alignCast(ptr));

    return @ptrCast(@alignCast(buf[Size..][0..@sizeOf(T)].ptr));
  }

  /// Calculate length of control message given data of length `len`
  ///
  /// Port of musl libc's CMSG_LEN macro
  ///
  /// Macro Definition:
  /// #define CMSG_LEN(len)   (CMSG_ALIGN (sizeof (struct cmsghdr)) + (len))
  pub inline fn msg_len(len: usize) usize {
    return msg_align(cmsghdr.Size) + len;
  }

  pub inline fn __msg_len(msg: *const cmsghdr) usize {
    return ((msg.len + @sizeOf(c_ulong) - 1) & ~@as(usize, (@sizeOf(c_ulong) - 1)));
  }

  /// Get the number of bits needed to pad out the message
  pub inline fn padding_bits(len: usize, data_t_size: usize) usize {
    return (8 * len) - (@bitSizeOf(cmsghdr) + data_t_size);
  }

  /// Calculate alignment of control message of length `len` to cmsghdr size
  ///
  /// Port of musl libc's CMSG_ALIGN macro
  ///
  /// Macro Definition:
  /// #define CMSG_ALIGN(len) (((len) + sizeof (size_t) - 1) & (size_t) ~(sizeof (size_t) - 1))
  inline fn msg_align(len: usize) usize {
    return (((len) + @sizeOf(size_t) - 1) & ~@as(usize, (@sizeOf(size_t) - 1)));
  }

  const size_t = usize;
  const Size = @sizeOf(@This());
};

// Types
pub const dev_t = enum(u64) {
  _,

  pub fn toInt(dev: dev_t) u64 {
    return @intFromEnum(dev);
  }
  pub fn fromInt(int: u64) dev_t {
    return @enumFromInt(int);
  }

  pub fn major(dev: dev_t) u64 {
    return ((dev.toInt() >> 8) & 0xfff);
  }
  pub fn minor(dev: dev_t) u64 {
    return ((dev.toInt() & 0xff) | ((dev.toInt() >> 12) & 0xffffff00));
  }
};

// Syscall aliases
pub const recvmsg = linux.recvmsg;
pub const sendmsg = linux.sendmsg;
pub const prctl = linux.prctl;
pub const mmap = linux.mmap;
pub const munmap = linux.munmap;
pub const madvise = linux.madvise;
pub const mprotect = linux.mprotect;
pub const socket = linux.socket;
pub const nanosleep = linux.nanosleep;
pub const pread = linux.pread;
pub const read = linux.read;
pub const close = linux.close;
pub const msync = linux.msync;
pub const lseek = linux.lseek;
pub const open = linux.open;
pub const unlink = linux.unlink;
pub const ftruncate = linux.ftruncate;
pub const connect = linux.connect;
pub const statx = linux.statx;
pub const ioctl = linux.ioctl;
pub const memfd_create = linux.memfd_create;
pub const sockaddr = linux.sockaddr;
pub const errno = std.posix.errno;

// Type aliases
pub const STATX = linux.STATX;
pub const Statx = linux.Statx;
pub const timespec = linux.timespec;
pub const iovec = std.posix.iovec;
pub const msghdr = std.posix.msghdr;
pub const msghdr_const = std.posix.msghdr_const;

// Constant/Namespace aliases
pub const E = linux.E;
pub const PR = linux.PR;
pub const MS = linux.MS;
pub const AT = linux.AT;
pub const AF = linux.AF;
pub const MSG = linux.MSG;
pub const MAP = linux.MAP;
pub const SCM = linux.SCM;
pub const SOL = linux.SOL;
pub const SOCK = linux.SOCK;
pub const PROT = linux.PROT;
pub const MADV = linux.MADV;
pub const SEEK = linux.SEEK;

const linux = std.os.linux;

const page_size_min = std.heap.page_size_min;

const log = std.log.scoped(.Linux);

// 3rd-Party Module Imports
const builtin = @import("builtin");
const std = @import("std");
