const builtin = @import("builtin");

pub const can_pretty_print = switch (builtin.os.tag) {
    .macos => true,
    else => unreachable,
};
