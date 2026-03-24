const std = @import("std");

pub fn build(b: *std.Build) void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const wayland_protocol_specifications = [_]std.Build.LazyPath{
    b.path("src/wayland-protocols/wayland.xml"),
    b.path("src/wayland-protocols/xdg-shell.xml"),
    b.path("src/wayland-protocols/xdg-decoration-unstable-v1.xml"),
  };

  const wayland_protocols = b.dependency("wayland_protocol_codegen", .{
    .protocols = &wayland_protocol_specifications,
  }).module("wayland-protocols");

  const os_mod = b.addModule("os", .{
    .root_source_file = b.path("src/os/os.zig"),
    .target = target,
  });

  const base_mod = b.addModule("base", .{
    .root_source_file = b.path("src/base/base.zig"),
    .target = target,
    .imports = &.{
      .{ .name = "os", .module = os_mod },
    },
  });
  const root = b.createModule(.{
      .root_source_file = b.path("src/client.zig"),
      .target = target,
      .optimize = optimize,
      .imports = &.{
        .{ .name = "base", .module = base_mod },
        .{ .name = "os", .module = os_mod },
        .{ .name = "wayland-protocols", .module = wayland_protocols },
      },
  });

  const simple_root = b.createModule(.{
    .root_source_file = b.path("src/simple-client.zig"),
    .target = target,
    .optimize = optimize,
  });

  const exe = b.addExecutable(.{
    .name = "wl-client",
    .root_module = root,
  });
  b.installArtifact(exe);

  const simple_exe = b.addExecutable(.{
    .name = "wl-simple-client",
    .root_module = simple_root,
  });
  b.installArtifact(simple_exe);

  const run_step = b.step("client", "Run src/client.zig");
  const run_cmd = b.addRunArtifact(exe);
  run_step.dependOn(&run_cmd.step);
  run_cmd.step.dependOn(b.getInstallStep());

  if (b.args) |args| {
    run_cmd.addArgs(args);
  }
  const simple_run_step = b.step("simple-client", "Run src/simple.zig");
  const simple_run_cmd = b.addRunArtifact(simple_exe);
  simple_run_step.dependOn(&simple_run_cmd.step);
  simple_run_cmd.step.dependOn(b.getInstallStep());

  if (b.args) |args| {
    simple_run_cmd.addArgs(args);
  }

  const base_tests = b.addTest(.{
    .root_module = base_mod,
  });
  const run_base_tests = b.addRunArtifact(base_tests);
  const exe_tests = b.addTest(.{
    .root_module = exe.root_module,
  });
  const run_exe_tests = b.addRunArtifact(exe_tests);

  const test_step = b.step("test", "Run tests");
  test_step.dependOn(&run_base_tests.step);
  test_step.dependOn(&run_exe_tests.step);
}
