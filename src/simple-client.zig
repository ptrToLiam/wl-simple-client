pub fn main(init: std.process.Init.Minimal) !void {
  // Allocators to use as needed
  var arena: ArenaAllocator = .init(std.heap.page_allocator);
  defer arena.deinit();
  const allocator = arena.allocator(); // persistent allocations

  var temp_arena: ArenaAllocator = .init(std.heap.page_allocator);
  defer temp_arena.deinit();
  const temp_allocator = temp_arena.allocator(); // short-lived allocations

  var stio: std.Io.Threaded = .init_single_threaded;
  defer stio.deinit();
  const io = stio.io();

  var connection: Connection = undefined;
  connection.in = .init_backing(try allocator.alloc(u8, 4096));
  connection.out = .init_backing(try allocator.alloc(u8, 4096));
  connection.fd_in = .init_backing(try allocator.alloc(u8, 2048));
  connection.fd_out = .init_backing(try allocator.alloc(u8, 2048));

  const env = init.environ;

  // Establish Connection
  connection.sock_fd = wl_sock: {
    defer _ = temp_arena.reset(.retain_capacity);

    const xdg_rt_dir = env.getPosix("XDG_RUNTIME_DIR").?;
    const wl_display_sockname = env.getPosix("WAYLAND_DISPLAY")
      orelse "wayland-0";
    const sockpath = try std.mem.join(
      temp_allocator, "/", &.{xdg_rt_dir, wl_display_sockname});

    const fd = i32_(linux.socket(
      linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));

    const sock_addr = sock_addr: {
      var addr: linux.sockaddr.un = .{
        .family = linux.AF.UNIX,
        .path = @splat(0),
      };
      if (sockpath.len >= addr.path.len) return error.SocketPathTooLong;
      @memcpy(addr.path[0..sockpath.len], sockpath);
      break :sock_addr addr;
    };

    const res = linux.connect(
      fd, &sock_addr, u32_(@sizeOf(@TypeOf(sock_addr))));

    if (@as(isize, @bitCast(res)) < 0) return error.FailedToConnectSocket;

    break :wl_sock fd;
  };
  defer _ = linux.close(connection.sock_fd);

  var client_state: ClientState = undefined;
  client_state.wl_display_id = 1; client_state.wl_registry_id = 2;
  client_state.current_id = client_state.wl_registry_id+1;

  // Bind desired interfaces
  {
    defer _ = temp_arena.reset(.retain_capacity);
    const get_registry_msg_size = 12;
    const display_get_registry_msg = [_]u32{
      client_state.wl_display_id,
      (u32_(get_registry_msg_size) << 16) | op_wl_display_get_registry,
      client_state.wl_registry_id,
    };

    connection.out.putBytes(@ptrCast(&display_get_registry_msg));
    write_outgoing(connection.sock_fd, &connection.out, &connection.fd_out);

    try read_incoming(connection.sock_fd, &connection.in, &connection.fd_in);

    const BoundGlobals = packed struct (u8) {
      wl_seat: bool = false,
      wl_compositor: bool = false,
      wl_shm: bool = false,
      xdg_wm_base: bool = false,
      xdg_decoration_manager: bool = false,
      __pad: u3 = 0,

      pub fn match(a: @This(), b: @This()) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
      }
    };

    const all_bound: BoundGlobals = .{
      .wl_seat = true,
      .wl_compositor = true,
      .wl_shm = true,
      .xdg_wm_base = true,
      .xdg_decoration_manager = true,
    };
    var globals_bound: BoundGlobals = .{};

    while (!connection.in.empty()) {
      const size = connection.in.size();
      if (size < @sizeOf(WireHeader)) {
        try read_incoming(connection.sock_fd, &connection.in, &connection.fd_in);
        continue;
      }
      const header_start = connection.in.mask(connection.in.read);
      var header: WireHeader = undefined;
      connection.in.getNBytesFrom(header_start, 8, std.mem.asBytes(&header));

      if (size < header.len) {
        try read_incoming(connection.sock_fd, &connection.in, &connection.fd_in);
        continue;
      }

      defer connection.in.read +%= header.len;
      const data_start: u32 = header_start + @sizeOf(WireHeader);
      const data_len = header.len - @sizeOf(WireHeader);
      const data = try temp_allocator.alloc(u8, data_len);
      connection.in.getNBytesFrom(data_start, data_len, data);

      if (header.id == 0) {
        std.log.warn("Invalid header ID! (ID=0)", .{});
      } else if (header.id == client_state.wl_display_id) {
        std.log.warn(
          "Unexpected wl_display event during binding!", .{});
        continue;
      } else if (header.id == client_state.wl_registry_id) {
        if (header.op != ev_wl_registry_global) {
          std.log.warn(
            "Unexpected wl_registry global remove event during binding!", .{});
          continue;
        }

        const global_name = std.mem.bytesToValue(u32, data[0..4]);
        const global_interface_len = std.mem.bytesToValue(u32, data[4..8]);
        const global_interface = data[8..][0..global_interface_len-1:0];
        const global_interface_aligned_len =
          div_roundup(global_interface_len, 4);
        const global_version = std.mem.bytesToValue(
          u32, data[8+global_interface_aligned_len..][0..4]);
        std.debug.print(
          "wl_registry#{}.global: name={}, interface=\"{s}\", version={}\n",
          .{client_state.wl_registry_id, global_name,
            global_interface, global_version});

        const interface_id = client_state.current_id; // only used on desired interfaces

        if (false) {
        } else if (std.mem.eql(u8, "wl_seat", global_interface)) {
          client_state.wl_seat_id = interface_id;
          globals_bound.wl_seat = true;
          defer client_state.current_id += 1;

          bind_interface(&connection, client_state.wl_registry_id, global_name,
                         global_interface, global_version, interface_id);
        } else if (std.mem.eql(u8, "wl_compositor", global_interface)) {
          client_state.wl_compositor_id = interface_id;
          globals_bound.wl_compositor = true;
          defer client_state.current_id += 1;

          bind_interface(&connection, client_state.wl_registry_id, global_name,
                         global_interface, global_version, interface_id);
        } else if (std.mem.eql(u8, "wl_shm", global_interface)) {
          client_state.wl_shm_id = interface_id;
          globals_bound.wl_shm = true;
          defer client_state.current_id += 1;

          bind_interface(&connection, client_state.wl_registry_id, global_name,
                         global_interface, global_version, interface_id);
        } else if (std.mem.eql(u8, "xdg_wm_base", global_interface)) {
          client_state.xdg_wm_base_id = interface_id;
          globals_bound.xdg_wm_base = true;
          defer client_state.current_id += 1;

          bind_interface(&connection, client_state.wl_registry_id, global_name,
                         global_interface, global_version, interface_id);
        } else if (std.mem.eql(u8, "zxdg_decoration_manager_v1", global_interface)) {
          client_state.xdg_decoration_manager_id = interface_id;
          globals_bound.xdg_decoration_manager = true;
          defer client_state.current_id += 1;

          bind_interface(&connection, client_state.wl_registry_id, global_name,
                         global_interface, global_version, interface_id);
        }
      }
    }
    if (globals_bound.match(all_bound))
      std.log.info("All desired globals bound!", .{});
    write_outgoing(connection.sock_fd, &connection.out, &connection.fd_out);
  }

  const wl_surface_id = client_state.current_id;
  client_state.current_id += 1;
  const xdg_surface_id = client_state.current_id;
  client_state.current_id += 1;
  const xdg_toplevel_id = client_state.current_id;
  client_state.current_id += 1;
  const xdg_decoration_id = client_state.current_id;
  client_state.current_id += 1;

  // Tell compositor to create our surface and associated objects
  {
    // - write wl_compositor.create_surface
    const create_surface_msg = [_]u32{
      client_state.wl_compositor_id,
      (u32_(12) << 16) | op_wl_compositor_create_surface,
      wl_surface_id,
    };
    // - write xdg_wm_base.get_xdg_surface
    const get_xdg_surface_msg = [_]u32{
      client_state.xdg_wm_base_id,
      (u32_(16) << 16) | op_xdg_wm_base_get_xdg_surface,
      xdg_surface_id, wl_surface_id,
    };
    // - write xdg_surface.get_toplevel
    const get_toplevel_msg = [_]u32{
      xdg_surface_id,
      (u32_(12) << 16) | op_xdg_surface_get_toplevel,
      xdg_toplevel_id,
    };
    // - write xdg_decoration_manager.get_toplevel_decoration
    const get_toplevel_decoration_msg = [_]u32{
      client_state.xdg_decoration_manager_id,
      (u32_(16) << 16) | op_xdg_decoration_manager_get_toplevel_decoration,
      xdg_decoration_id, xdg_toplevel_id,
    };
    // - write wl_surface.commit
    const wl_surface_commit_msg = [_]u32{
      wl_surface_id,
      (u32_(8) << 16) | op_wl_surface_commit,
    };

    connection.out.putBytes(@ptrCast(&create_surface_msg));
    connection.out.putBytes(@ptrCast(&get_xdg_surface_msg));
    connection.out.putBytes(@ptrCast(&get_toplevel_msg));
    connection.out.putBytes(@ptrCast(&get_toplevel_decoration_msg));
    connection.out.putBytes(@ptrCast(&wl_surface_commit_msg));
  }

  const window_width = 960;
  const window_height = 540;
  const image_format = wl_shm_format_xrgb8888;
  const stride = window_width * 4;
  const image_size = window_height * stride;
  const shm_fd = i32_(linux.memfd_create("wl-shm", 0));
  _ = linux.ftruncate(shm_fd, image_size);

  const image_bytes: []u32 = img: {
    const rc = linux.mmap(
      null, @intCast(image_size),
      .{ .READ = true, .WRITE = true },
      .{ .TYPE = .SHARED },
      shm_fd, 0);

    const irc = @as(isize, @bitCast(rc));
    if (irc < 0) {
      return error.FailedToMapShmFile;
    }
    const bytes: [*]u8 = @ptrFromInt(rc);
    break :img @ptrCast(@alignCast(bytes[0..image_size]));
  };
  @memset(image_bytes, (u32_(255) << 16) | 0);

  const wl_shm_pool_id = client_state.current_id;
  client_state.current_id += 1;
  const wl_buffer_id = client_state.current_id;
  client_state.current_id += 1;

  // Tell compositor to create our wl_shm_pool object and, from it, the wl_buffer
  {
    // - write wl_shm.create_pool
    const wl_shm_create_pool_msg = [_]u32{
      client_state.wl_shm_id,
      (u32_(16) << 16) | op_wl_shm_create_pool,
      wl_shm_pool_id, u32_(image_size),
    };
    // - write wl_shm_pool.create_buffer
    const wl_shm_pool_create_buffer_msg = [_]u32{
      wl_shm_pool_id,
      (u32_(32) << 16) | op_wl_shm_pool_create_buffer,
      wl_buffer_id, 0, window_width, window_height,
      u32_(stride), image_format,
    };

    connection.out.putBytes(@ptrCast(&wl_shm_create_pool_msg));
    connection.out.putBytes(@ptrCast(&wl_shm_pool_create_buffer_msg));
    connection.fd_out.putBytes(std.mem.asBytes(&shm_fd));

    write_outgoing(connection.sock_fd, &connection.out, &connection.fd_out);
  }

  // Wait for xdg_surface.configure, and ACK on receipt
  while (true) {
    if (!connection.in.empty()) {
      const size = connection.in.size();
      if (size < @sizeOf(WireHeader)) {
        try read_incoming(
          connection.sock_fd, &connection.in, &connection.fd_in);
        continue;
      }
      const header_start = connection.in.mask(connection.in.read);
      var header: WireHeader = undefined;
      connection.in.getNBytesFrom(header_start, 8, std.mem.asBytes(&header));

      if (size < header.len)
      {
        try read_incoming(
          connection.sock_fd, &connection.in, &connection.fd_in);
        continue;
      }

      defer connection.in.read +%= header.len;
      const data_start: u32 = header_start + @sizeOf(WireHeader);
      const data_len = header.len - @sizeOf(WireHeader);
      const data = try temp_allocator.alloc(u8, data_len);
      connection.in.getNBytesFrom(data_start, data_len, data);

      if (false) {
      } else if (header.id == client_state.wl_display_id) {
        const object_id = std.mem.bytesToValue(
          u32, connection.in.buf[data_start..][0..4]);
        const err_code = std.mem.bytesToValue(
          u32, connection.in.buf[data_start+4..][0..4]);
        const strlen = std.mem.bytesToValue(
          u32, connection.in.buf[data_start+8..][0..4]);
        const str = connection.in.buf[data_start+12..][0..strlen-1:0];
        std.log.warn(
          "wl_display#1.error: object#{}, code={}, message=\"{s}\"",
          .{object_id, err_code, str});
      } else if (header.id == xdg_surface_id and
          header.op == ev_xdg_surface_configure)
      {
        const config_serial = std.mem.bytesToValue(
          u32, connection.in.buf[data_start..][0..4]);
        std.log.info("Config serial :: {}", .{config_serial});
        break;
      } else {
        std.log.debug("Unused header :: {}", .{header});
      }
    } else {
      try read_incoming(connection.sock_fd, &connection.in, &connection.fd_in);
    }
  }

  var want_exit = false;
  while (!want_exit){
    defer _ = temp_arena.reset(.retain_capacity);

    while (!connection.in.empty()) {
      const size = connection.in.size();
      if (size < @sizeOf(WireHeader)) { break; }
      const header_start = connection.in.mask(connection.in.read);
      var header: WireHeader = undefined;
      connection.in.getNBytesFrom(header_start, 8, std.mem.asBytes(&header));

      if (size < header.len) { break; }

      defer connection.in.read +%= header.len;

      const data_start: u32 = header_start + @sizeOf(WireHeader);
      const data_len = header.len - @sizeOf(WireHeader);
      const data = try temp_allocator.alloc(u8, data_len);
      connection.in.getNBytesFrom(data_start, data_len, data);

      if (false) {
      } else if (header.id == xdg_toplevel_id) {
        if (header.op == ev_xdg_toplevel_close) { want_exit = true; break; }
      } else if (header.id == client_state.xdg_wm_base_id) {
        if (header.op == ev_xdg_wm_base_ping) {
          const serial = std.mem.bytesToValue(u32, data);
          const pong_msg = [_]u32{
            client_state.xdg_wm_base_id,
            (u32_(12) << 16) | op_xdg_wm_base_pong,
            serial,
          };

          connection.out.putBytes(@ptrCast(&pong_msg));
        }
      } else {
        // std.log.debug("Unused header :: {}", .{header});
      }
    }

    // attach buffer to surface
    {
      const surface_damage_msg = [_]u32{
        wl_surface_id,
        (u32_(24) << 16) | op_wl_surface_damage_buffer,
        0, 0, window_width, window_height,
      };
      const surface_attach_msg = [_]u32{
        wl_surface_id,
        (u32_(20) << 16) | op_wl_surface_attach,
        wl_buffer_id, 0, 0,
      };
      const surface_commit_msg = [_]u32{
        wl_surface_id,
        (u32_(8) << 16) | op_wl_surface_commit,
      };

      connection.out.putBytes(@ptrCast(&surface_damage_msg));
      connection.out.putBytes(@ptrCast(&surface_attach_msg));
      connection.out.putBytes(@ptrCast(&surface_commit_msg));
    }


    write_outgoing(connection.sock_fd, &connection.out, &connection.fd_out);
    try read_incoming(
      connection.sock_fd, &connection.in, &connection.fd_in);

    // sleep for 120fps, avoid burning too much CPU
    const timeout: std.Io.Timeout = .{
      .duration = .{
        .raw = .{ .nanoseconds = std.time.ns_per_ms * 8 },
        .clock = .awake,
      },
    };
    try timeout.sleep(io);
    try std.Thread.yield();
  }
}

inline fn bind_interface(
  connection: *Connection,
  wl_registry_id: u32,
  name: u32,
  interface: [:0]const u8,
  version: u32,
  interface_id: u32,
) void {
  const string_len = u32_(interface.len+1);
  const aligned_string_len = div_roundup(string_len, 4);
  const max_str_padding: [4]u8 = @splat(0);

  const msg_data_len =
  @sizeOf(WireHeader) + 4 // header + name
  + 4 + aligned_string_len // string encoding + 4
  + 4 + 4; // version + id

  const bindmsg_header_bytes = [_]u32{
    wl_registry_id,
    (u32_(msg_data_len) << 16) | op_wl_registry_bind,
  };

  connection.out.putBytes(@ptrCast(&bindmsg_header_bytes));

  connection.out.putBytes(std.mem.asBytes(&name));
  connection.out.putBytes(std.mem.asBytes(&string_len));
  connection.out.putBytes(interface.ptr[0..string_len]);
  const padding_needed =
    aligned_string_len - string_len;
  connection.out.putBytes(max_str_padding[0..padding_needed]);
  connection.out.putBytes(std.mem.asBytes(&version));
  connection.out.putBytes(std.mem.asBytes(&interface_id));
  std.log.debug("bound interface {s} of name {} with id={}",
    .{ interface, name, interface_id });
}

inline fn write_outgoing(
  sock_fd: i32,
  noalias rb: *RingBuffer,
  noalias fd_rb: *RingBuffer,
) void {
  const bytes_to_write = rb.write - rb.read;
  var iov: [2]iovec = undefined;
  const iov_len = if (rb.read != rb.write)
    rb.prep_iovecs_out(&iov)
  else 0;

  defer rb.read +%= bytes_to_write;

  var cmsg_buf: [CMSG_BUF_MAX]u8 = undefined;
  var controllen: usize = 0;

  while (!fd_rb.empty()) {
    const fd_out_read = fd_rb.mask(fd_rb.read);

    const fd_out = std.mem.bytesToValue(i32, fd_rb.buf[fd_out_read..][0..4]);

    const control_msg: fd_cmsg_t = .init(
      linux.SOL.SOCKET, linux.SCM.RIGHTS, fd_out);

    @memcpy(
      cmsg_buf[controllen..][0..@sizeOf(@TypeOf(control_msg))],
      std.mem.asBytes(&control_msg));
    
    fd_rb.read +%= 4;
    controllen += @sizeOf(@TypeOf(control_msg));
  }

  const msg: linux.msghdr_const = .{
    .name = null,
    .namelen = 0,
    .iov = @ptrCast(&iov),
    .iovlen = iov_len,
    .control = &cmsg_buf,
    .controllen = controllen,
    .flags = 0,
  };

  // assuming the write never fails.
  // in-practice, this should have some error checking and rb.read
  // should be incremented by bytes actually written, rather than
  // only what was intended to be written
  _ = linux.sendmsg(sock_fd, &msg, 0);
}

inline fn read_incoming(
  sock_fd: i32,
  noalias rb: *RingBuffer,
  noalias fd_rb: *RingBuffer,
) !void {
  _ = fd_rb;
  var iov: [2]iovec = undefined;
  const iov_len = rb.prep_iovecs_in(&iov);

  var cmsg_buf: [CMSG_BUF_MAX]u8 = undefined;
  var msg: linux.msghdr = .{
    .name = null,
    .namelen = 0,
    .iov = &iov,
    .iovlen = iov_len,
    .control = &cmsg_buf,
    .controllen = cmsg_buf.len,
    .flags = 0,
  };

  var rc: usize = linux.recvmsg(sock_fd, &msg, linux.MSG.DONTWAIT);
  var err: linux.E = linux.errno(rc);
  while (err == .INTR or err == .AGAIN) {
    if (err == .AGAIN) try std.Thread.yield();
    rc = linux.recvmsg(sock_fd, &msg, linux.MSG.DONTWAIT);
    err = linux.errno(rc);
  }

  if (@as(isize, @bitCast(rc)) < 0) return error.SocketReadFailed;

  const bytes_read = u32_(rc);
  defer rb.write +%= bytes_read;
}

inline fn div_roundup(n: u32, size: usize) u32 {
  return u32_(size * ((u64_(n) + (size-1)) / size));
}

// Event opcodes we care about
const ev_wl_registry_global: u16 = 0;
const ev_wl_shm_pool_format: u16 = 0;
const ev_wl_buffer_release: u16 = 0;
const ev_xdg_wm_base_ping: u16 = 0;
const ev_xdg_toplevel_configure: u16 = 0;
const ev_xdg_toplevel_close: u16 = 1;
const ev_xdg_surface_configure: u16 = 0;
const ev_wl_display_error: u16 = 0;

// Request opcodes we care about
const op_wl_display_get_registry: u16 = 1;
const op_wl_registry_bind: u16 = 0;
const op_wl_compositor_create_surface: u16 = 0;
const op_wl_xdg_wm_base_pong: u16 = 3;
const op_xdg_surface_ack_configure: u16 = 4;
const op_wl_shm_create_pool: u16 = 0;
const op_xdg_wm_base_get_xdg_surface: u16 = 2;
const op_xdg_wm_base_pong: u16 = 3;
const op_wl_shm_pool_create_buffer: u16 = 0;
const op_wl_surface_attach: u16 = 1;
const op_wl_surface_damage_buffer: u16 = 9;
const op_wl_surface_commit: u16 = 6;
const op_xdg_surface_get_toplevel: u16 = 1;
const op_xdg_decoration_manager_get_toplevel_decoration: u16 = 1;
const op_xdg_decoration_set_mode: u16 = 1;

// Enum values we care about
const wl_shm_format_argb8888: u32 = 0;
const wl_shm_format_xrgb8888: u32 = 1;
const xdg_decoration_mode_server_size: u32 = 2;

const CMSG_BUF_MAX = @sizeOf(fd_cmsg_t) * 32;
const fd_cmsg_t = cmsg(i32);

const Connection = struct {
  sock_fd: i32,
  in: RingBuffer,
  out: RingBuffer,
  fd_in: RingBuffer,
  fd_out: RingBuffer,
};

const ClientState = struct {
  connection: *Connection,

  wl_display_id: u32,
  wl_registry_id: u32,

  wl_seat_id: u32,
  wl_compositor_id: u32,
  wl_shm_id: u32,
  xdg_wm_base_id: u32,
  xdg_decoration_manager_id: u32,

  current_id: u32,
};

const WireHeader = packed struct (u64) {
  id: u32,
  op: u16,
  len: u16,
};

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

pub const cmsghdr = packed struct {
  /// Data byte count, including header
  len: usize,
  /// Originating protocol
  level: i32,
  /// Protocol-specific type
  type: i32,

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

/// Requires backing buffer to be of a power of 2 length.
pub const RingBuffer = struct {
  buf: []u8,
  read: u32 = 0,
  write: u32 = 0,

  /// Assumes provided buffer to be of pow2 length
  pub fn init_backing(bytes: []u8) RingBuffer {
    std.debug.assert((bytes.len < MAX_SIZE) and is_pow2(bytes.len));
    return .{ .buf = bytes };
  }

  pub fn size(rb: *RingBuffer) u32 {
    return u32_((rb.write -% rb.read) & (rb.buf.len-1));
  }

  pub fn empty(rb: *RingBuffer) bool {
    return rb.write == rb.read;
  }

  pub fn mask(rb: *const RingBuffer, idx: u32) u32 {
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

  pub fn prep_iovecs_out(
    noalias rb: *RingBuffer,
    iov: *[2]iovec,
  ) usize {
    const tail = rb.mask(rb.read);
    const head = rb.mask(rb.write);
    var iov_len: usize = 1;

    if (tail < head) {
      const iov_buf = rb.buf[tail..head];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
    } else if (head == 0) {
      const iov_buf = rb.buf[tail..];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
    } else {
      const iov_buf_0 = rb.buf[tail..];
      iov[0].base = iov_buf_0.ptr;
      iov[0].len = iov_buf_0.len;

      const iov_buf_1 = rb.buf[0..head];
      iov[1].base = iov_buf_1.ptr;
      iov[1].len = iov_buf_1.len;
      iov_len = 2;
    }

    return iov_len;
  }

  pub fn prep_iovecs_in(
    noalias rb: *RingBuffer,
    iov: *[2]iovec,
  ) usize {
    const tail = rb.mask(rb.read);
    const head = rb.mask(rb.write);
    var iov_len: usize = 1;

    if (tail > head) {
      const iov_buf = rb.buf[head..tail];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
    } else if (tail == 0) {
      const iov_buf = rb.buf[head..];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
    } else {
      const iov_buf_0 = rb.buf[head..];
      iov[0].base = iov_buf_0.ptr;
      iov[0].len = iov_buf_0.len;

      const iov_buf_1 = rb.buf[0..tail];
      iov[1].base = iov_buf_1.ptr;
      iov[1].len = iov_buf_1.len;
      iov_len = 2;
    }

    return iov_len;
  }

  const MAX_SIZE = std.math.maxInt(u31);
};

inline fn u16_(x: anytype) u16 {
  return @intCast(x);
}
inline fn u32_(x: anytype) u32 {
  return @intCast(x);
}
inline fn i32_(x: anytype) i32 {
  return @intCast(x);
}
inline fn u64_(x: anytype) u64 {
  return @intCast(x);
}
inline fn is_pow2(x: anytype) bool {
  std.debug.assert(x > 0);
  return (x & (x-1)) == 0;
}

const ArenaAllocator = std.heap.ArenaAllocator;
const linux = std.os.linux;
const iovec = std.posix.iovec;
const std = @import("std");
