//! Virtual-memory operations shared by terminal page owners.
//!
//! Terminal pages use page-aligned, page-multiple mappings. This module can
//! discard the physical pages behind one of those mappings without releasing
//! its virtual address range, then prepare the same range for reuse. It does
//! not allocate memory or decide which terminal pages should be discarded.
//!
//! Decommit releases physical pages only. The address range and its memory
//! accounting stay with the
//! process, so a read after decommit returns zeros or the old contents rather
//! than faulting, and recommit has nothing to acquire that could fail.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.terminal_mem);

/// What guarantee decommit must provide when the OS cannot discard a mapping.
pub const DecommitMode = enum {
    /// The dirty prefix must read as zero after this call, even when physical
    /// reclamation is unavailable. Bytes after the prefix must already be zero.
    zero,

    /// Physical-memory reclamation is required. Do not touch the mapping when
    /// reclamation is unsupported or fails; report the failure to the caller.
    strict,
};

/// Return whether this target can reclaim physical memory for `mode` while
/// retaining the mapping's virtual address range.
///
/// Both modes use macOS retained-mapping reclamation. Tests simulate it by
/// clearing allocator memory rather than discarding shared pages.
pub inline fn canReclaim(comptime mode: DecommitMode) bool {
    return switch (mode) {
        .zero, .strict => true,
    };
}

/// Discard physical pages while retaining a mapping's virtual address range.
///
/// The complete mapping must be page-aligned and a multiple of the minimum
/// system page size. `dirty_len` identifies the prefix whose contents may be
/// nonzero. Strict mode requires the complete mapping to be dirty because a
/// successful discard invalidates all of its contents.
///
/// The return value reports whether the OS accepted the reclamation request.
/// Test builds return true after simulating reclamation by zeroing dirty bytes.
/// In zero mode, the requested bytes are guaranteed to be zero regardless of
/// the return value.
pub fn decommit(
    comptime mode: DecommitMode,
    memory: []align(std.heap.page_size_min) u8,
    dirty_len: usize,
) bool {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);
    assert(dirty_len <= memory.len);
    if (comptime mode == .strict) assert(dirty_len == memory.len);

    // Testing allocator ranges may share an OS mapping with unrelated memory,
    // so madvise is not safe. Zeroing models the only content guarantee callers
    // have after a successful discard.
    if (comptime builtin.is_test) {
        @memset(memory[0..dirty_len], 0);
        return true;
    }

    // FREE_REUSABLE removes the range from the Darwin process footprint while
    // retaining its mapping. Zero mode clears its dirty prefix first because
    // the kernel may preserve the contents. Strict mode avoids that write
    // because its caller will replace the entire mapping after recommit.
    if (comptime builtin.os.tag.isDarwin()) {
        if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);

        if (std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.FREE_REUSABLE,
        )) |_| return true else |err| {
            switch (mode) {
                .strict => {
                    log.warn("madvise(FREE_REUSABLE) failed err={}", .{err});
                    return false;
                },

                .zero => {
                    // Plain FREE can still reclaim the already-zero mapping
                    // under pressure and does not require a reuse pairing.
                    std.posix.madvise(
                        memory.ptr,
                        memory.len,
                        std.posix.MADV.FREE,
                    ) catch {};
                    return false;
                },
            }
        }
    }

    // DiscardVirtualMemory releases the physical pages behind the range but
    // leaves it committed, so the commit charge stays with the process and a
    // later access finds a zero page or the old contents instead of faulting.
    // Zero mode clears its dirty prefix first, as on Darwin: the bytes read
    // as zero afterward whether or not the discard took. Strict mode skips
    // that write because its caller replaces the entire mapping after
    // recommit. The call reports failure through its return value rather
    // than the thread's last error.

    if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);
    return false;
}

/// Prepare a mapping previously passed to decommit for reuse.
///
/// Linux, Windows, and test builds need no explicit operation because their
/// mappings stay committed through decommit. Darwin pairs FREE_REUSABLE with
/// FREE_REUSE so pages touched by the caller are accounted to the process
/// again. Failure does not invalidate the retained mapping, so reuse can
/// continue after logging the accounting failure.
pub fn recommit(memory: []align(std.heap.page_size_min) u8) void {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);

    if (comptime builtin.is_test) return;
    if (comptime builtin.os.tag.isDarwin()) {
        std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.FREE_REUSE,
        ) catch |err| {
            log.warn("madvise(FREE_REUSE) failed err={}", .{err});
        };
    }
}

test "decommit with zero fallback clears the dirty prefix" {
    const testing = std.testing;
    const memory_len = 2 * std.heap.page_size_min;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        memory_len,
    );
    defer testing.allocator.free(memory);

    @memset(memory, 0xAA);
    _ = decommit(.zero, memory, memory.len);
    try testing.expect(std.mem.allEqual(u8, memory, 0));

    // The tail is already zero by contract, so a partially dirty mapping only
    // needs its dirty prefix cleared.
    @memset(memory[0..1024], 0xAA);
    _ = decommit(.zero, memory, 1024);
    try testing.expect(std.mem.allEqual(u8, memory, 0));
}

test "strict decommit retains the mapping for recommit" {
    const testing = std.testing;
    const memory_len = 2 * std.heap.page_size_min;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        memory_len,
    );
    defer testing.allocator.free(memory);
    @memset(memory, 0xAA);

    const original_ptr = memory.ptr;
    const original_len = memory.len;
    try testing.expect(decommit(.strict, memory, memory.len));
    try testing.expectEqual(original_ptr, memory.ptr);
    try testing.expectEqual(original_len, memory.len);
    try testing.expect(std.mem.allEqual(u8, memory, 0));

    recommit(memory);
    @memset(memory, 0xBB);
    try testing.expect(std.mem.allEqual(u8, memory, 0xBB));
}

test "test builds can reclaim retained mappings" {
    const testing = std.testing;
    try testing.expect(canReclaim(.zero));
    try testing.expect(canReclaim(.strict));
}
