const std = @import("std");

/// Alpaca trade message (channel "t")
pub const AlpacaTrade = struct {
    T: []const u8, // Message type: "t"
    S: []const u8, // Symbol
    i: u64, // Trade ID
    x: []const u8, // Exchange
    p: f64, // Price
    s: u32, // Size
    c: []const []const u8, // Conditions
    t: []const u8, // Timestamp (RFC-3339 with nanoseconds)
    z: []const u8, // Tape
};

/// Alpaca quote message (channel "q")
pub const AlpacaQuote = struct {
    T: []const u8, // Message type: "q"
    S: []const u8, // Symbol
    ax: []const u8, // Ask exchange
    ap: f64, // Ask price
    as: u32, // Ask size
    bx: []const u8, // Bid exchange
    bp: f64, // Bid price
    bs: u32, // Bid size
    c: []const []const u8, // Conditions
    t: []const u8, // Timestamp (RFC-3339 with nanoseconds)
    z: []const u8, // Tape
};

/// Alpaca control/status message
pub const AlpacaControl = struct {
    T: []const u8, // Message type: "success", "error", "subscription", etc.
    msg: ?[]const u8 = null, // Optional message
    code: ?i64 = null, // Optional error code
    trades: ?[][]const u8 = null, // Optional subscribed trade symbols
    quotes: ?[][]const u8 = null, // Optional subscribed quote symbols
    bars: ?[][]const u8 = null, // Optional subscribed bar symbols
};

/// Unified message type (discriminated union)
pub const AlpacaMessage = union(enum) {
    trade: AlpacaTrade,
    quote: AlpacaQuote,
    control: AlpacaControl,
};

/// WebSocket connection state machine
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    authenticating,
    authenticated,
    subscribed,
    error_state,
};

test "parse AlpacaTrade from JSON" {
    const json =
        \\{"T":"t","S":"AAPL","i":98765,"x":"C","p":183.42,"s":200,"c":["@","I"],"t":"2024-01-15T14:30:00.123456789Z","z":"C"}
    ;
    const parsed = try std.json.parseFromSlice(AlpacaTrade, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const trade = parsed.value;
    try std.testing.expectEqualStrings("t", trade.T);
    try std.testing.expectEqualStrings("AAPL", trade.S);
    try std.testing.expectEqual(@as(u64, 98765), trade.i);
    try std.testing.expectEqualStrings("C", trade.x);
    try std.testing.expectApproxEqAbs(@as(f64, 183.42), trade.p, 0.001);
    try std.testing.expectEqual(@as(u32, 200), trade.s);
    try std.testing.expectEqual(@as(usize, 2), trade.c.len);
    try std.testing.expectEqualStrings("@", trade.c[0]);
    try std.testing.expectEqualStrings("I", trade.c[1]);
    try std.testing.expectEqualStrings("C", trade.z);
}

test "parse AlpacaQuote from JSON" {
    const json =
        \\{"T":"q","S":"TSLA","ax":"C","ap":248.75,"as":5,"bx":"D","bp":248.70,"bs":12,"c":["R"],"t":"2024-01-15T14:30:00.987654321Z","z":"C"}
    ;
    const parsed = try std.json.parseFromSlice(AlpacaQuote, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const quote = parsed.value;
    try std.testing.expectEqualStrings("q", quote.T);
    try std.testing.expectEqualStrings("TSLA", quote.S);
    try std.testing.expectEqualStrings("C", quote.ax);
    try std.testing.expectApproxEqAbs(@as(f64, 248.75), quote.ap, 0.001);
    try std.testing.expectEqual(@as(u32, 5), quote.as);
    try std.testing.expectEqualStrings("D", quote.bx);
    try std.testing.expectApproxEqAbs(@as(f64, 248.70), quote.bp, 0.001);
    try std.testing.expectEqual(@as(u32, 12), quote.bs);
    try std.testing.expectEqualStrings("C", quote.z);
}

test "parse AlpacaControl connected message" {
    const json =
        \\{"T":"success","msg":"connected"}
    ;
    const parsed = try std.json.parseFromSlice(AlpacaControl, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const ctrl = parsed.value;
    try std.testing.expectEqualStrings("success", ctrl.T);
    try std.testing.expectEqualStrings("connected", ctrl.msg.?);
    try std.testing.expectEqual(@as(?i64, null), ctrl.code);
}

test "parse AlpacaControl authenticated message" {
    const json =
        \\{"T":"success","msg":"authenticated"}
    ;
    const parsed = try std.json.parseFromSlice(AlpacaControl, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("authenticated", parsed.value.msg.?);
}

test "parse AlpacaControl subscription confirmation" {
    const json =
        \\{"T":"subscription","trades":["AAPL","TSLA"],"quotes":["AAPL"],"bars":[]}
    ;
    const parsed = try std.json.parseFromSlice(AlpacaControl, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const ctrl = parsed.value;
    try std.testing.expectEqualStrings("subscription", ctrl.T);
    try std.testing.expectEqual(@as(usize, 2), ctrl.trades.?.len);
    try std.testing.expectEqualStrings("AAPL", ctrl.trades.?[0]);
    try std.testing.expectEqualStrings("TSLA", ctrl.trades.?[1]);
    try std.testing.expectEqual(@as(usize, 1), ctrl.quotes.?.len);
    try std.testing.expectEqual(@as(usize, 0), ctrl.bars.?.len);
}

test "parse AlpacaControl error message" {
    const json =
        \\{"T":"error","code":402,"msg":"auth failed"}
    ;
    const parsed = try std.json.parseFromSlice(AlpacaControl, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const ctrl = parsed.value;
    try std.testing.expectEqualStrings("error", ctrl.T);
    try std.testing.expectEqual(@as(?i64, 402), ctrl.code);
    try std.testing.expectEqualStrings("auth failed", ctrl.msg.?);
}
