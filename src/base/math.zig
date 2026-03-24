pub const Units = struct {
  pub inline fn KB(val: anytype) @TypeOf(val) {
    comptime {
      const t_info = @typeInfo(@TypeOf(val));
      if (!(t_info == .int or t_info == .comptime_int)) {
        @compileError("Unit conversion values must be of unsigned integer type");
      }
      if (!(t_info == .comptime_int and val >= 0) and t_info.int.signedness == .signed) {
        @compileError("Unit conversion values must be unsigned integers");
      }

      if ((t_info == .int and t_info.int.bits < 16)) {
        @compileError("Integer too small. Must have at minimum 16 bits");
      }
    }

    return val << 10;
  }

  pub inline fn MB(val: anytype) @TypeOf(val) {
    comptime {
      const t_info = @typeInfo(@TypeOf(val));
      if (!(t_info == .int or t_info == .comptime_int)) {
        @compileError("Unit conversion values must be of unsigned integer type");
      }
      if (!(t_info == .comptime_int and val >= 0) and t_info.int.signedness == .signed) {
        @compileError("Unit conversion values must be unsigned integers");
      }

      if ((t_info == .int and t_info.int.bits < 32)) {
        @compileError("Integer too small. Must have at minimum 32 bits");
      }
    }

    return val << 20;
  }

  pub inline fn GB(val: anytype) @TypeOf(val) {
    comptime {
      const t_info = @typeInfo(@TypeOf(val));
      if (!(t_info == .int or t_info == .comptime_int)) {
        @compileError("Unit conversion values must be of unsigned integer type");
      }
      if (!(t_info == .comptime_int and val >= 0) and t_info.int.signedness == .signed) {
        @compileError("Unit conversion values must be unsigned integers");
      }

      if ((t_info == .int and t_info.int.bits < 64)) {
        @compileError("Integer too small. Must have at minimum 64 bits");
      }
    }

    return val << 30;
  }

  pub inline fn TB(val: anytype) @TypeOf(val) {
    comptime {
      const t_info = @typeInfo(@TypeOf(val));
      if (!(t_info == .int or t_info == .comptime_int)) {
        @compileError("Unit conversion values must be of unsigned integer type");
      }
      if (!(t_info == .comptime_int and val >= 0) and t_info.int.signedness == .signed) {
        @compileError("Unit conversion values must be unsigned integers");
      }

      if ((t_info == .int and t_info.int.bits < 64)) {
        @compileError("Integer too small. Must have at minimum 64 bits");
      }
    }

    return val << 40;
  }
};

pub inline fn div_roundup(n: anytype, size: usize) u32 {
  // TODO: See if there's a better way to do this... am tired
  return base.u32_(size * ((base.u64_(n) + (size-1)) / size));
}

pub fn align_pow2(x: usize, b: usize) usize {
  return @as(usize, (@as(usize, (x + b - 1)) & (~@as(usize, (b - 1)))));
}

pub fn is_pow2(x: anytype) bool {
  base.Assert(x > 0);
  return (x & (x - 1)) == 0;
}

// --- STD CONST ALIASES ---
const math = std.math;
pub const tau = math.tau;
pub const pi = math.pi;

// --- STD FN ALIASES ---
pub const cos = math.cos;
pub const sin = math.sin;
pub const tan = math.tan;
pub const inf = math.inf;
pub const pow = math.pow;
pub const sqrt = math.sqrt;
pub const maxInt = math.maxInt;
pub const maxFloat = math.floatMax;
pub const degToRad = math.degreesToRadians;
pub const radToDeg = math.radiansToDegrees;

const log = std.log.scoped(.Math);

const cpu_arch = builtin.cpu.arch;
const has_avx = if (cpu_arch == .x86_64)
  std.Target.x86.featureSetHas(builtin.cpu.features, .avx)
else false;
const has_avx512f = if (cpu_arch == .x86_64)
  std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f)
else false;
const has_fma = if (cpu_arch == .x86_64)
  std.Target.x86.featureSetHas(builtin.cpu.features, .fma)
else false;

const base = @import("base.zig");

// 3rd-Party Imports
const std = @import("std");
const builtin = @import("builtin");
