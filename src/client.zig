pub fn main(init: std.process.Init.Minimal) !void {
  base.Thread.ctx_init();
  defer base.Thread.ctx_release();

  var arena: *Arena = .init(.default);
  defer arena.release();
  var conn: wayland.Connection = .open(arena, init.environ);
  defer conn.close();
  var proxy = conn.proxy();

  const wl_surface = conn.client_state.compositor.create_surface(&proxy);
  const xdg_surface = conn.client_state.xdg_wm_base.get_xdg_surface(&proxy, wl_surface);
  const xdg_toplevel = xdg_surface.get_toplevel(&proxy);
  const xdg_decoration = conn.client_state.xdg_decoration_manager.get_toplevel_decoration(&proxy, xdg_toplevel);
  xdg_toplevel.set_title(&proxy, "Simple Wayland");
  wl_surface.commit(&proxy);
  xdg_decoration.set_mode(&proxy, .server_side);

  try conn.flush();

  var shm_pool: wayland.ShmPool = .create(&conn, 960, 540);
  const wl_buffer = shm_pool.create_buffer(
    960, 540, .xrgb8888,
  );

  {
    var tmp = arena.temp();
    defer tmp.end();
    var surface_acked = false;
    while (!surface_acked) {
      if (conn.get_event(tmp.arena)) |ev| {
        std.log.debug("ev :: {}", .{ev});
        switch (ev) {
          .xdg_surface_configure => |configure| {
            xdg_surface.ack_configure(&proxy, configure.serial);
            surface_acked = true;
          },
          else => {},
        }
      } else {
        conn.load_events();
      }
    }
  }

  var tmp = arena.temp();
  var want_exit = false;
  while (!want_exit) {
    tmp = arena.temp();
    defer tmp.end();
    conn.load_events();
    while (conn.get_event(tmp.arena)) |ev| {
      switch (ev) {
        .xdg_toplevel_close => { want_exit = true; },
        .xdg_wm_base_ping => |ping| {
          conn.client_state.xdg_wm_base.pong(&proxy, ping.serial);
        },
        else => { std.log.debug("{}", .{ev}); },
      }
    }
    wl_surface.damage_buffer(&proxy, 0, 0, 960, 540);
    wl_surface.attach(&proxy, wl_buffer, 0, 0);
    wl_surface.commit(&proxy);
    try conn.flush();
    Thread.sleep(time.ns_per_ms * 16);
  }
}

const Arena = base.Arena;
const Thread = base.Thread;
const base = @import("base");

const wayland = @import("wayland.zig");
const time = std.time;
const std = @import("std");
