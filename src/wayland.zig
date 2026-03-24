pub const Connection = struct {
  fd: i32 = 0,
  want_flush: u32 = 0,

  /// Inbound event queue
  in: RingBuffer,
  /// Outbound event queue
  out: RingBuffer,
  /// Inbound fd queue
  fd_in: RingBuffer,
  /// Outbound fd queue
  fd_out: RingBuffer,

  /// Client-side state
  client_state: *ClientState,

  /// Open client connection to host wayland compositor
  pub fn open(arena: *Arena, env: os.Environ) Connection {
    //-------------------------------------------------------------------------
    // Allocate & Initialize Ring Buffers
    //-------------------------------------------------------------------------

    // Allocating 3 pages -- 1 each for standard in/out, 1/2 each for fd in/out
    var ringbuffers: [4]RingBuffer = undefined;
    const ringbuffer_bytes = os.mem_reserve(ring_buffers_mmap_size);

    if (!os.mem_commit(ringbuffer_bytes))
      @panic("Failed to map pages for ring buffers!");

    inline for (0..2) |i| {
      const backing_bytes_rng_start = (i * ring_buffer_size);
      const backing_bytes =
        ringbuffer_bytes[backing_bytes_rng_start..][0..ring_buffer_size];

      @memset(backing_bytes, 0);
      ringbuffers[i] = .init_backing(backing_bytes);

      const fd_backing_bytes_rng_start = (2 * ring_buffer_size) +
                                            (i * fd_ring_buffer_size);
      const fd_backing_bytes =
        ringbuffer_bytes[fd_backing_bytes_rng_start..][0..fd_ring_buffer_size];
      @memset(fd_backing_bytes, 0);
      ringbuffers[i+2] = .init_backing(fd_backing_bytes);
    }

    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Retrieve Path & Connect to Socket
    //-------------------------------------------------------------------------

    const scratch = Thread.Context.get_scratch(0, .{}).?;
    const scratch_arena = scratch.arena;
    defer scratch.end();

    const xdg_runtime_dir = env.getPosix("XDG_RUNTIME_DIR").?;
    const wayland_display = env.getPosix("WAYLAND_DISPLAY")
      orelse "wayland-0";
    const socket_path = socket_path: {
      const socket_path_len = xdg_runtime_dir.len + wayland_display.len + 1;
      var joint_path_bytes = scratch_arena.push(u8, socket_path_len);
      var joint_path_offset: usize = 0;
      @memcpy(
        joint_path_bytes[joint_path_offset..][0..xdg_runtime_dir.len],
        xdg_runtime_dir,
      );
      joint_path_offset += xdg_runtime_dir.len;
      joint_path_bytes[joint_path_offset] = '/';
      joint_path_offset += 1;
      @memcpy(
        joint_path_bytes[joint_path_offset..][0..wayland_display.len],
        wayland_display,
      );
      break :socket_path joint_path_bytes;
    };

    const socket_fd = i32_(linux.socket(
      linux.AF.UNIX,
      linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
      0,
    ));

    const socket_addr = socket_addr: {
      var addr: linux.sockaddr.un = .{
        .family = linux.AF.UNIX,
        .path = @splat(0),
      };

      if (socket_path.len + 1 > addr.path.len) @panic("Socket Path Too Long");
      @memcpy(addr.path[0..socket_path.len], socket_path);
      break :socket_addr addr;
    };

    const connect_rc = linux.connect(
      socket_fd,
      &socket_addr,
      u32_(@sizeOf(@TypeOf(socket_addr))),
    );
    if (transmute(isize, connect_rc) < 0) {
      @panic("Failed to connec to wayland socket!");
    }

    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Bind Registry & Globals, Initialize Client-Side Registry
    //-------------------------------------------------------------------------

    const client_state = arena.create(ClientState);
    const client_objects = arena.push(Object, 512);
    const client_object_indices = arena.push(u32, 512);
    const client_object_index_list: FreeIdxList = .init_backing(client_object_indices);
    client_state.object_pool = .{
      .objects = client_objects,
      .free_idx_list = client_object_index_list,
    };

    var connection: Connection = .{
      // Base Wayland Connection
      .fd = socket_fd,

      // Base Wayland Connection I/O Management
      .in = ringbuffers[0],
      .out = ringbuffers[1],
      .fd_in = ringbuffers[2],
      .fd_out = ringbuffers[3],

      // Wayland State Management
      .client_state = client_state,
    };
    var conn_proxy = connection.proxy();

    client_state.display = .fromInt(client_state.object_pool.next_object_id());
    client_state.object_pool.push_object(client_state.display.object());
    client_state.registry = client_state.display.get_registry(&conn_proxy);

    connection.flush() catch @panic("failed to write to wayland socket");

    const GlobalsBound = packed struct (u8) {
      wl_seat: bool = false,
      wl_compositor: bool = false,
      xdg_wm_base: bool = false,
      wl_shm: bool = false,
      xdg_decoration_manager: bool = false,
      __reserved_bits: u3 = 0,

      pub fn match(a: @This(), b: @This()) bool {
        return transmute(u8, a) == transmute(u8, b);
      }

      pub const desired: @This() = .{
        .wl_seat = true,
        .wl_compositor = true,
        .xdg_wm_base = true,
        .wl_shm = true,
        .xdg_decoration_manager = true,
      };
    };

    var globals_bound: GlobalsBound = .{};
    // Loop until all desired globals are bound OR no more globals are available
    while (true) {
      const event = connection.peek_event(scratch_arena) orelse {
        if (globals_bound.match(.desired))
          break;

        connection.flush() catch unreachable;
        connection.load_events();

        continue;
      };
      switch (event) {
        .wl_registry_global => |registry_global| {
          defer connection.consume_event();

          if (std.mem.eql(u8, Seat.Name, registry_global.interface)) {
            connection.client_state.seat = connection.client_state.registry.bind(
              &conn_proxy,
              registry_global.name,
              Seat,
              registry_global.version,
            );
            globals_bound.wl_seat = true;
          } else if (std.mem.eql(u8, Compositor.Name, registry_global.interface)) {
            connection.client_state.compositor = connection.client_state.registry.bind(
              &conn_proxy,
              registry_global.name,
              Compositor,
              registry_global.version,
            );
            globals_bound.wl_compositor = true;
          } else if (std.mem.eql(u8, Shm.Name, registry_global.interface)) {
            connection.client_state.wl_shm = connection.client_state.registry.bind(
              &conn_proxy,
              registry_global.name,
              Shm,
              registry_global.version,
            );
            globals_bound.wl_shm = true;
          } else if (std.mem.eql(u8, XdgWmBase.Name, registry_global.interface)) {
            connection.client_state.xdg_wm_base = connection.client_state.registry.bind(
              &conn_proxy,
              registry_global.name,
              XdgWmBase,
              registry_global.version,
            );
            globals_bound.xdg_wm_base = true;
          } else if (std.mem.eql(u8, XdgDecorationManager.Name, registry_global.interface)) {
            connection.client_state.xdg_decoration_manager = connection.client_state.registry.bind(
              &conn_proxy,
              registry_global.name,
              XdgDecorationManager,
              registry_global.version,
            );
            globals_bound.xdg_decoration_manager = true;
          }
        },
        .wl_display_error => |display_error| {
          defer connection.consume_event();
          log.err(
            "display error :: {{ obj_id={}, code={}, message=\"{s}\" }}",
            .{ display_error.object_id, display_error.code, display_error.message },
          );
        },
        .wl_display_delete_id => |delete_id| {
          defer connection.consume_event();
          log.debug("display requested delete_id :: {{ id={} }} ", .{delete_id.id});
        },
        else => { break; },
      }
    }

    //-------------------------------------------------------------------------

    return connection;
  }

  /// Close connection to host compositor and free ringbuffer memory
  pub fn close(conn: *Connection) void {
    //-------------------------------------------------------------------------
    //  Retrieve & Free Ring Buffer Backing Pages
    //-------------------------------------------------------------------------

    const ring_buffer_bytes_len = ring_buffers_mmap_size;
    const ring_buffer_bytes = transmute(
      []align(os.page_size_min) u8,
      conn.in.buf.ptr[0..ring_buffer_bytes_len]
    );

    os.mem_release(ring_buffer_bytes);

    //-------------------------------------------------------------------------

    // Disconnect from compositor
    _ = linux.close(conn.fd);
  }

  pub fn load_events(conn: *Connection) void {
    const read = conn.in.mask(conn.in.read);
    const write = conn.in.mask(conn.in.write);

    //-------------------------------------------------------------------------
    // Prepare IOV Buffer(s) For Read
    //-------------------------------------------------------------------------

    var iov: [2]linux.iovec = undefined;
    var iov_len: usize = 1;
    if (write < read) {
      const iov_buf = conn.in.buf[write..read];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
    } else if (read == 0) {
      const iov_buf = conn.in.buf[write..];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
    } else {
      const iov_buf_0 = conn.in.buf[write..];
      iov[0].base = iov_buf_0.ptr;
      iov[0].len = iov_buf_0.len;
      const iov_buf_1 = conn.in.buf[0..read];
      iov[1].base = iov_buf_1.ptr;
      iov[1].len = iov_buf_1.len;
      iov_len = 2;
    }

    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Read Into Buffer(s)
    //-------------------------------------------------------------------------

    var cmsg_buf: [cmsg_buf_len] u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    var msg: linux.msghdr = .{
      .name = null,
      .namelen = 0,
      .iov = &iov,
      .iovlen = iov_len,
      .control = &cmsg_buf,
      .controllen = cmsg_buf.len,
      .flags = 0,
    };

    var rc: usize = linux.recvmsg(
      conn.fd,
      &msg,
      linux.MSG.DONTWAIT,
    );

    while (linux.errno(rc) == .INTR) {
      rc = linux.recvmsg(
        conn.fd,
        &msg,
        linux.MSG.DONTWAIT,
      );
    }

    const err = linux.errno(rc);
    const bytes_read = if (transmute(isize, rc) < 0)
      switch (err) {
        .SUCCESS => return,
        .AGAIN => return,
        .INVAL => { log.err("EINVAL on socket read!", .{}); return; },
        .PIPE, .CONNRESET => @panic("Socket connection lost!"),
        else => |e| {log.err("socket read failed with err :: {s}", .{@tagName(e)}); @panic("unknown err"); },
      }
    else
      u32_(rc);

    defer conn.in.write +%= bytes_read;

    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Parse Control Messages
    //-------------------------------------------------------------------------

    var cmsg_iter = linux.cmsghdr.iter(cmsg_buf[0..msg.controllen]);
    while (cmsg_iter.next()) |cmsg_header| {
      if (cmsg_header.level == linux.SOL.SOCKET and cmsg_header.type == linux.SCM.RIGHTS) {
        const fd = cmsg_header.data(c_int).*;
        conn.fd_in.putBytes(std.mem.asBytes(&fd));
      }
    }

    //-------------------------------------------------------------------------
  }

  pub fn peek_event(noalias conn: *Connection, noalias arena: *Arena) ?Event {
    var conn_proxy = conn.proxy();

    const event = if (!conn.in.empty()) wayland_event: {
      const size = conn.in.size();

      // not enough data for header
      if (size < @sizeOf(WireEventHeader))
        break :wayland_event null;

      //-----------------------------------------------------------------------
      // Parse Event Header
      //-----------------------------------------------------------------------

      var header: WireEventHeader = .{
        .id = 0,
        .op = 0,
        .len = 0,
      };
      const header_read_idx = conn.in.mask(conn.in.read);

      conn.in.getNBytesFrom(header_read_idx, @sizeOf(WireEventHeader),
                            std.mem.asBytes(&header));

      //-----------------------------------------------------------------------

      //-----------------------------------------------------------------------
      // Parse Event Body
      //-----------------------------------------------------------------------

      // not enough data for whole event
      if (size < header.len)
        break :wayland_event null;

      const data_read_idx = conn.in.mask(
        header_read_idx + @sizeOf(WireEventHeader));
      const data_len = header.len - @sizeOf(WireEventHeader);

      const scratch = Thread.Context.get_scratch(1, .{arena}).?;
      const scratch_arena = scratch.arena;
      defer scratch.end();

      const data_bytes = scratch_arena.push(u8, data_len);
      conn.in.getNBytesFrom(
        data_read_idx, data_len, data_bytes);

      const relevant_object = conn.client_state.object_pool.get(header.id);
      const wayland_event = relevant_object.message_decode(
        &conn_proxy,
        header.op,
        data_bytes,
      );

      if (wayland_event == .wl_callback_done)
        log.debug(
          "received response on callback object of id: {}",
          .{transmute(*const u32, relevant_object).*},
        );

      break :wayland_event wayland_event;
    } else null;

    return event;
  }

  pub fn get_event(noalias conn: *Connection, noalias arena: *Arena) ?Event {
    const event = conn.peek_event(arena) orelse return null;
    conn.consume_event();
    return event;
  }

  pub fn consume_event(conn: *Connection) void {
    var header: WireEventHeader = .{
       .id = 0,
       .op = 0,
       .len = 0,
     };

     const header_read_idx = conn.in.mask(conn.in.read);
     conn.in.getNBytesFrom(header_read_idx, @sizeOf(WireEventHeader),
                            std.mem.asBytes(&header));

     conn.in.read +%= header.len;
  }

  pub fn flush(conn: *Connection) !void {
    const out_read_start = conn.out.read;
    const out_read = conn.out.mask(conn.out.read);
    const out_write = conn.out.mask(conn.out.write);

    //-------------------------------------------------------------------------
    // Prepare outgoing iovecs
    //-------------------------------------------------------------------------

    var iov: [2]linux.iovec = undefined;
    var iov_len: usize = 1;

    if (conn.out.read == conn.out.write) {
      iov_len = 0;
    } else if (out_read < out_write) {
      const iov_buf = conn.out.buf[out_read..out_write];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
      conn.out.read +%= u32_(iov_buf.len);
    } else if (out_write == 0) {
      const iov_buf = conn.out.buf[out_read..];
      iov[0].base = iov_buf.ptr;
      iov[0].len = iov_buf.len;
      conn.out.read +%= u32_(iov_buf.len);
    } else {
      const iov_buf_0 = conn.out.buf[out_read..];
      iov[0].base = iov_buf_0.ptr;
      iov[0].len = iov_buf_0.len;

      const iov_buf_1 = conn.out.buf[0..out_write];
      iov[1].base = iov_buf_1.ptr;
      iov[1].len = iov_buf_1.len;
      iov_len = 2;

      conn.out.read +%= u32_(iov_buf_0.len + iov_buf_1.len);
    }

    const bytes_to_write = conn.out.read - out_read_start;

    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Prepare outgoing control messages
    //-------------------------------------------------------------------------

    var cmsg: [cmsg_buf_len]u8 = undefined;
    var cmsg_len: usize = 0;

    const c_int_size = @sizeOf(c_int);
    const fd_cmsg_t = linux.cmsg(c_int);
    const ctrlmsg_size = @sizeOf(fd_cmsg_t);

    while (!conn.fd_out.empty()) {
      const fd_out_read = conn.fd_out.mask(conn.fd_out.read);

      var fd_out: c_int = -1;
      conn.fd_out.getNBytesFrom(fd_out_read, @sizeOf(c_int),
                                std.mem.asBytes(&fd_out));

      const control_msg: fd_cmsg_t = .init(
        linux.SOL.SOCKET,
        linux.SCM.RIGHTS,
        fd_out,
      );

      @memcpy(
        cmsg[cmsg_len..][0..ctrlmsg_size],
        std.mem.asBytes(&control_msg),
      );

      conn.fd_out.read +%= u32_(c_int_size);
      cmsg_len += ctrlmsg_size;
    }

    //-------------------------------------------------------------------------

    //-------------------------------------------------------------------------
    // Construct and send message
    //-------------------------------------------------------------------------

    const msg: linux.msghdr_const = .{
      .name = null,
      .namelen = 0,
      .iov = @ptrCast(&iov),
      .iovlen = iov_len,
      .control = &cmsg,
      .controllen = cmsg_len,
      .flags = 0,
    };

    var written: usize = 0;
    var rc: isize = -1;
    var errno: linux.E = .AGAIN;
    read: while (rc < 0 and (errno == .AGAIN or errno == .INTR)) {
      const val = linux.sendmsg(
        conn.fd,
        &msg,
        0,
      );

      rc = transmute(isize, val);

      if (rc < 0) {
        errno = linux.errno(@bitCast(rc));
        if (errno == .INTR) written += cast(usize, -rc);
        continue :read;
      }
    }


    if (rc < 0) {
      log.err(
        "Failed to write to socket! :: {s}",
        .{ @tagName(linux.errno(u32_(-rc))) },
      );
    }

    written += cast(usize, rc);

    base.DebugAssert(
      written == bytes_to_write,
      "bytes_written should match bytes_to_write!",
    );

    //-------------------------------------------------------------------------
  }

  pub fn proxy(conn: *Connection) Proxy {
    return .{
      .ctx = conn,
      .vtable = .{
        .message_decode = msg_decode,
        .message_encode = msg_encode,
        .get_id = next_id,
        .put_object = obj_push,
        .destroy_object = obj_destroy,
      },
    };
  }

  fn msg_decode(noalias ctx: *anyopaque, args_out: []MessageArg, noalias data: []const u8) void {
    const connection = transmute(*Connection, ctx);
    var offset: u32 = 0;

    for (args_out) |*arg| {
      switch (arg.*) {
        .fd => |*arg_fd| {
          arg_fd.* = connection.next_fd();
        },
        .uint, .object, .new_id => |*uint_arg| {
          uint_arg.* = std.mem.bytesToValue(u32, data[offset..][0..4]);
          offset += 4;
        },
        .int => |*int_arg| {
          int_arg.* = std.mem.bytesToValue(i32, data[offset..][0..4]);
          offset += 4;
        },
        .@"enum" => |*enum_arg| {
          const int_ptr = transmute(*u32, enum_arg);
          int_ptr.* = std.mem.bytesToValue(u32, data[offset..][0..4]);
          offset += 4;
        },
        .fixed => |*fixed_arg| {
          const int_val = std.mem.bytesToValue(i32, data[offset..][0..4]);
          offset += 4;
          fixed_arg.* = f32_(int_val) / 256;
        },
        .string => |*string_arg| {
          const str_len = std.mem.bytesToValue(u32, data[offset..][0..4]);
          offset += 4;
          string_arg.* = @ptrCast(data[offset..][0..(str_len - 1):0]);

          const rounded_len = math.div_roundup(str_len, 4);
          offset += rounded_len;
        },
        .array => |*array_arg| {
          const arr_len = std.mem.bytesToValue(u32, data[offset..][0..4]);
          offset += 4;
          const rounded_len = math.div_roundup(arr_len, 4);
          array_arg.* = data[offset..][0..arr_len];
          offset += rounded_len;
        },
      }
    }
  }

  fn msg_encode(noalias ctx: *anyopaque, id: u32, op: u16, noalias args: []const ?MessageArg) void {
    const connection = transmute(*Connection, ctx);

    var msg_len: u16 = @sizeOf(WireEventHeader);
    for (args) |arg_opt| {
      if (arg_opt) |arg| switch (arg) {
        .int, .uint, .fixed, .object, .new_id, .@"enum" => msg_len += @sizeOf(u32),
        .string => |string_arg| msg_len += msg_str_len(string_arg),
        .array => |array_arg| msg_len += msg_arr_len(array_arg),
        .fd => {},
      } else {
        msg_len += @sizeOf(u32);
      }
    }
    if (!connection.out.empty() and connection.out.size() < msg_len) {
      connection.flush() catch |err| {
        log.err("Connection flush failed due to err :: {s}", .{@errorName(err)});
      };
    }

    const header: WireEventHeader = .{
      .id = id,
      .op = op,
      .len = msg_len,
    };
    connection.out.putBytes(std.mem.asBytes(&header));

    for (args) |arg_opt| {
      if (arg_opt) |arg| arg: switch (arg) {
        .uint, .new_id, .object => |uint_arg| {
          connection.out.putBytes(std.mem.asBytes(&uint_arg));
        },
        .int => |int_arg| {
          continue :arg .{ .uint = transmute(u32, int_arg) };
        },
        .@"enum" => |*enum_arg| {
          const u32_val = transmute(*const u32, enum_arg);
          continue :arg .{ .uint = u32_val.* };
        },
        .fixed => |float_arg| {
          const val = transmute(i32, float_arg * 256);
          continue :arg .{ .uint = transmute(u32, val) };
        },
        .string => |string_arg| {
          continue :arg .{ .array = string_arg[0 .. string_arg.len + 1] };
        },
        .array => |array_arg| {
          const padding_bytes: [4]u8 = @splat(0);

          const write_len = u32_(msg_arr_len(array_arg));
          const len = u32_(array_arg.len);
          const padding_bytes_needed = (write_len - @sizeOf(u32)) - len;

          connection.out.putBytes(std.mem.asBytes(&len));
          connection.out.putBytes(array_arg);
          connection.out.putBytes(padding_bytes[0..padding_bytes_needed]);
        },
        .fd => |fd_arg| {
          connection.fd_out.putBytes(std.mem.asBytes(&fd_arg));
        },
      } else {
        const null_value: u32 = 0;
        connection.out.putBytes(std.mem.asBytes(&null_value));
      }
    }
  }

  fn next_id(noalias ctx: *anyopaque) u32 {
    const conn = transmute(*Connection, ctx);
    const idx = conn.client_state.object_pool.next_object_id();
    return idx;
  }

  fn next_fd(conn: *Connection) i32 {
    var fd: i32 = -1;
    const read = conn.fd_in.mask(conn.fd_in.read);
    @memcpy(
      std.mem.asBytes(&fd),
      conn.fd_in.buf[read..][0..@sizeOf(i32)],
    );
    conn.fd_in.read +%= @sizeOf(i32);

    return fd;
  }

  fn obj_destroy(noalias ctx: *anyopaque, object_id: u32) void {
    const conn = transmute(*Connection, ctx);
    conn.client_state.object_pool.release_object(object_id);
  }

  fn obj_push(noalias ctx: *anyopaque, object: Object) void {
    const conn = transmute(*Connection, ctx);
    conn.client_state.object_pool.push_object(object);
  }

  inline fn msg_str_len(str: [:0]const u8) u16 {
    return msg_arr_len(str[0 .. str.len + 1]);
  }

  inline fn msg_arr_len(arr: []const u8) u16 {
    return u16_(math.div_roundup(@sizeOf(u32) + arr.len, @sizeOf(u32)));
  }

  const cmsg_buf_len = 32 * linux.cmsghdr.msg_len(@sizeOf(c_int));
  const ring_buffers_mmap_size: usize = (2 * default_ring_buffer_size +
                                         2 * default_fd_ring_buffer_size);
  const ring_buffer_size: usize = default_ring_buffer_size;
  const fd_ring_buffer_size: usize = default_fd_ring_buffer_size;
  const default_ring_buffer_size = 4096;
  const default_fd_ring_buffer_size = 2048;
};

pub const ClientState = struct {
  // Base Wayland Connection
  display: Display,
  registry: Registry,

  // Globals
  seat: Seat,
  compositor: Compositor,
  wl_shm: Shm,
  xdg_wm_base: XdgWmBase,
  xdg_decoration_manager: XdgDecorationManager,

  // Wayland Objects
  object_pool: ObjectPool,

  // Runtime Compositor Information
  seat_info: SeatInfo = .{},

  const SeatInfo = struct {
    name: [512]u8 = undefined,
    capabilities: Seat.Capability = .{},
  };
};

pub const ObjectPool = struct {
  objects: []Object,
  free_idx_list: FreeIdxList,

  fn id_to_idx(id: u32) u32 {
    return id-1;
  }
  pub fn next_object_id(op: *ObjectPool) u32 {
    return op.free_idx_list.pull();
  }

  pub fn push_object(op: *ObjectPool, object: Object) void {
    const idx = transmute(*const u32, &object);

    op.objects[ id_to_idx(idx.*) ] = object;
  }

  pub fn release_object(op: *ObjectPool, object_id: u32) void {
    op.objects[ id_to_idx(object_id) ] = undefined;
    op.free_idx_list.push(object_id);
  }

  pub fn get(op: *ObjectPool, object_id: u32) *Object {
    return &op.objects[id_to_idx(object_id)];
  }
};

const FreeIdxList = struct {
  indices: []u32,
  index_available: u32,

  pub fn init_backing(buf: []u32) FreeIdxList {
    for (buf, 0..) |*index, i| {
      index.* = u32_(buf.len - i);
    }

    return .{
      .indices = buf,
      .index_available = u32_(buf.len),
    };
  }

  pub fn pull(fil: *FreeIdxList) u32 {
    fil.index_available -= 1;
    return fil.indices[fil.index_available];
  }

  pub fn push(fil: *FreeIdxList, index: u32) void {
    base.DebugAssert(
      fil.index_available < fil.indices.len,
      "Index Queue Already Full",
    );

    fil.indices[fil.index_available] = index;
    fil.index_available += 1;
  }
};

pub const ShmPool = struct {
  proxy: Proxy,
  wl_shm_pool: WaylandShmPool,
  buffer: []u32,
  fd: c_int,

  pub fn create(
    conn: *Connection,
    width: i32,
    height:i32,
  ) ShmPool {
    const shm = conn.client_state.wl_shm;

    const shm_fd = i32_(linux.memfd_create("wl-shm", 0));
    var proxy = conn.proxy();

    const img_stride = width * 4;
    const img_size = height * img_stride;
    _ = linux.ftruncate(
      shm_fd,
      img_size,
    );

    const rc = linux.mmap(
      null,
      base.usize_(img_size),
      .{ .READ = true, .WRITE = true },
      .{ .TYPE = .SHARED },
      shm_fd,
      0
    );

    const irc = transmute(isize, rc);
    if (irc < 0) {
      log.err("failed to map in shmfile memory!", .{});
    }

    const ptr: []u8 = transmute([*]u8, rc)[0..base.usize_(img_size)];
    const img_buffer = transmute([]u32, ptr);

    const shm_pool = shm.create_pool(
      &proxy,
      shm_fd,
      img_size,
    );

    return .{
      .proxy = proxy,
      .fd = shm_fd,
      .buffer = img_buffer,
      .wl_shm_pool = shm_pool,
    };
  }

  pub fn create_buffer(
    pool: *ShmPool,
    width: i32,
    height: i32,
    format: Shm.Format,
  ) WaylandBuffer {
    @memset(pool.buffer, 0xefefefef);
    return pool.wl_shm_pool.create_buffer(
      &pool.proxy,
      0,
      width,
      height,
      width*4,
      format,
    );
  }
};

const WireEventHeader = packed struct (u64) {
  id: u32,
  op: u16,
  len: u16,
};

// Object Aliases
pub const WaylandBuffer = wl_protocols.wl_buffer;
pub const WaylandSurface = wl_protocols.wl_surface;
pub const XdgSurface = wl_protocols.xdg_surface;
pub const XdgToplevel = wl_protocols.xdg_toplevel;
pub const WaylandShmPool = wl_protocols.wl_shm_pool;
pub const LinuxDmabufFeedback = wl_protocols.zwp_linux_dmabuf_feedback_v1;

pub const Display = wl_protocols.wl_display;
pub const Registry = wl_protocols.wl_registry;
pub const XdgDecoration = wl_protocols.zxdg_toplevel_decoration_v1;

// Registry Global Aliases
pub const Shm = wl_protocols.wl_shm;
pub const Seat = wl_protocols.wl_seat;
pub const XdgWmBase = wl_protocols.xdg_wm_base;
pub const Compositor = wl_protocols.wl_compositor;
pub const XdgDecorationManager = wl_protocols.zxdg_decoration_manager_v1;


// Wayland Base Type Aliases
pub const Proxy = wl_protocols.Proxy;
pub const Object = wl_protocols.Object;
pub const Event = wl_protocols.Event;
pub const MessageArg = wl_protocols.MessageArg;

const wl_protocols = @import("wayland-protocols");

const log = std.log.scoped(.wayland);

const Arena = base.Arena;
const Thread = base.Thread;
const RingBuffer = base.RingBuffer;

const u16_ = base.u16_;
const u32_ = base.u32_;
const i32_ = base.i32_;
const f32_ = base.f32_;

const cast = base.casts.cast;
const transmute = base.casts.transmute;

const math = base.math;
const linux = os.linux;

const os = @import("os");
const base = @import("base");
const std = @import("std");
