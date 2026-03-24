/// Reinterpret the bytes of `src` as type `T`.
/// This WILL cast const -> non-const if `T` is non_const.
pub fn transmute(comptime T: type, src: anytype) T {
  const SourceType = @TypeOf(src);

  const TargetTypeInfo = @typeInfo(T);
  const TargetTypeName = @typeName(T);
  const SourceTypeInfo = @typeInfo(SourceType);
  const SourceTypeName = @typeName(SourceType);

  const result: T = if (T == SourceType)
    src
  else res: {
    switch (TargetTypeInfo) {
      .array => {
        if (SourceTypeInfo != .array)
          @compileError("Cannot transmute non-array type to array type");

        break :res @bitCast(src);
      },
      .pointer => {
        if (SourceTypeInfo == .pointer) {
          break :res if (TargetTypeInfo.pointer.is_const)
            @ptrCast(@alignCast(src))
          else
            @constCast(@ptrCast(@alignCast(src)));
        } else if (SourceTypeInfo == .array) {
          break :res if (TargetTypeInfo.pointer.is_const)
            @ptrCast(@alignCast(&src))
          else
            @constCast(@ptrCast(@alignCast(&src)));

        } else if (SourceTypeInfo == .int) {
          if (@sizeOf(SourceType) != @sizeOf(T)) {
            @compileError(
              "Cannot transmute type " ++
              SourceTypeName ++
              "to type " ++
              TargetTypeName ++
              ". Type sizes do not match!"
            );
          }
          break :res @ptrFromInt(src);
        } else {
          @compileError(
            "Cannot transmute non-pointer, non-int type to pointer type."
          );
        }
      },
      .optional => {
        @compileError("Transmute to optional types not yet implemented");
      },
      .@"struct" => |struct_t| {
        if (struct_t.layout == .@"packed") {
          if (SourceTypeInfo == .@"struct" and
              SourceTypeInfo.@"struct".layout == .@"packed")
          {
            @compileError(
              "Cannot transmute from non-packed struct type " ++
              SourceTypeName ++
              "."
            );
          } else if (@sizeOf(SourceType) != @sizeOf(T)) {
            @compileError(
              "Cannot transmute type " ++
              SourceTypeName ++
              "to type " ++
              TargetTypeName ++
              ". Type sizes do not match!"
            );
          }
          break :res @bitCast(src);
        }
        @compileError(
          "Cannot transmute to non-packed struct type " ++
          TargetTypeName ++
          "."
        );
      },
      .int, .float => {
        if (@sizeOf(SourceType) != @sizeOf(T))
          @compileError(
            "Cannot transmute type " ++
            SourceTypeName ++
            "to type " ++
            TargetTypeName ++
            ". Type sizes do not match!"
          );
        break :res @bitCast(src);
      },
      else => @compileError(
        "Unsupported transmute target type: " ++
        TargetTypeName
      ),
    }
  };
  return result;
}

/// Cast the value of `src` to the same value of type `T`
/// Will invoke `transmute` if
/// - `T` is a pointer type.
/// - `T` is an integer type and `src` is a packed struct or vice versa.
/// - `T` is a packed struct and `src` is an enum type or vice versa.
pub fn cast(comptime T: type, src: anytype) T {
  const SourceType = @TypeOf(src);

  const TargetTypeInfo = @typeInfo(T);
  const TargetTypeName = @typeName(T);
  const SourceTypeInfo = @typeInfo(SourceType);
  const SourceTypeName = @typeName(SourceType);

  const result: T = if (T == SourceType)
    src
  else res: {
    switch (TargetTypeInfo) {
      .int => {
        if (SourceTypeInfo == .int or SourceTypeInfo == .comptime_int)
          break :res @intCast(src);
        if (SourceTypeInfo == .float or SourceTypeInfo == .comptime_float)
          break :res @intFromFloat(src);
        if (SourceTypeInfo == .@"struct") break :res transmute(T, src);
        if (SourceTypeInfo == .@"enum") break :res @intFromEnum(src);
        if (SourceTypeInfo == .pointer) break :res @intFromPtr(src);
      },
      .float => {
        if (SourceTypeInfo == .int or SourceTypeInfo == .comptime_int)
          break :res @floatFromInt(src);
        if (SourceTypeInfo == .float or SourceTypeInfo == .comptime_float)
          break :res @floatCast(src);
      },
      .@"enum" => {
        if (SourceTypeInfo == .int) break :res @enumFromInt(src);
        if (SourceTypeInfo == .@"enum") break :res @enumFromInt(@intFromEnum(src));
        if (SourceTypeInfo == .@"struct")
          if (SourceTypeInfo.@"struct".backing_integer) |int_t|
            break :res @enumFromInt(transmute(int_t, src));
      },
      .pointer => {
        break :res transmute(T, src);
      },
      .@"struct" => |struct_t| {
        if (struct_t.layout == .@"packed") {
          if (SourceTypeInfo == .int) break :res transmute(T, src);
          if (SourceTypeInfo == .@"enum") break :res transmute(T, @intFromEnum(src));
          if (SourceTypeInfo == .@"struct") break :res transmute(T, src);
        }
      },
      .bool => {
        if (SourceTypeInfo == .int) break :res src != 0;
      },
      else => @compileError(
        "Unsupported cast target type: " ++
        TargetTypeName ++ "."
      ),
    }
    @compileError(
      "No cast available from source type " ++
      SourceTypeName ++ " to target type " ++
      TargetTypeName ++ "."
    );
  };

  return result;
}
