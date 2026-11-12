const std = @import("std");
const vne = @import("vne");
const RuntimeContext = @import("context.zig").Context;
const command = @import("vne").command;

pub const Outcome = struct {
    command: ?[]const u8 = null,
    result: ?command.Code = null,
    suppressed: bool = false,
};

fn commandForCode(code: u16) ?[]const u8 {
    return switch (code) {
        73 => "editor.invert.add",
        89 => "history.redo",
        90 => "history.undo",
        else => null,
    };
}

pub fn dispatch(ctx: *RuntimeContext, event: *const vne.input.Event) Outcome {
    if (event.kind != .key_down or (event.action != .press and event.action != .repeat) or event.mods != 2) return .{};
    const name = commandForCode(event.code) orelse return .{};
    if (event.context & (vne.input.Context.text_input | vne.input.Context.editing_unavailable) != 0) return .{ .command = name, .suppressed = true };
    const result = ctx.command.dispatch(.{ .name = name });
    return .{ .command = name, .result = result.code };
}

test "semantic actions share document commands and respect text context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "resources" });
    defer std.testing.allocator.free(resource);
    const data = try std.fs.path.join(std.testing.allocator, &.{ root, "data" });
    defer std.testing.allocator.free(data);
    var ctx: RuntimeContext = undefined;
    try @import("replay.zig").fixture(&ctx, std.testing.allocator, resource, data);
    defer ctx.deinit();
    const initial = ctx.document.fingerprint();
    const insert = vne.input.Event{ .serial = 1, .time_ns = 1, .kind = .key_down, .action = .press, .code = 73, .mods = 2 };
    const inserted = dispatch(&ctx, &insert);
    try std.testing.expectEqual(command.Code.ok, inserted.result.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.history.cursor);
    try std.testing.expectEqual(@as(usize, 3), ctx.document.count);
    const changed = ctx.document.fingerprint();
    try std.testing.expect(initial != changed);
    const undo = vne.input.Event{ .serial = 2, .time_ns = 2, .kind = .key_down, .action = .press, .code = 90, .mods = 2 };
    var stale_undo = undo;
    stale_undo.context = vne.input.Context.editing_unavailable;
    try std.testing.expect(dispatch(&ctx, &stale_undo).suppressed);
    try std.testing.expectEqual(@as(usize, 1), ctx.history.cursor);
    try std.testing.expectEqual(command.Code.ok, dispatch(&ctx, &undo).result.?);
    try std.testing.expectEqual(@as(usize, 0), ctx.history.cursor);
    try std.testing.expectEqual(initial, ctx.document.fingerprint());
    const redo = vne.input.Event{ .serial = 3, .time_ns = 3, .kind = .key_down, .action = .repeat, .code = 89, .mods = 2 };
    try std.testing.expectEqual(command.Code.ok, dispatch(&ctx, &redo).result.?);
    try std.testing.expectEqual(changed, ctx.document.fingerprint());
    var text_undo = undo;
    text_undo.context = vne.input.Context.text_input;
    const suppressed = dispatch(&ctx, &text_undo);
    try std.testing.expect(suppressed.suppressed);
    try std.testing.expectEqual(@as(usize, 1), ctx.history.cursor);
    var modified = undo;
    modified.mods = 3;
    try std.testing.expect(dispatch(&ctx, &modified).command == null);
    modified = undo;
    modified.action = .release;
    modified.kind = .key_up;
    try std.testing.expect(dispatch(&ctx, &modified).command == null);
    const empty_undo = vne.input.Event{ .serial = 4, .time_ns = 4, .kind = .key_down, .action = .press, .code = 90, .mods = 2 };
    ctx.history.cursor = 0;
    try std.testing.expectEqual(command.Code.invalid_state, dispatch(&ctx, &empty_undo).result.?);
}
