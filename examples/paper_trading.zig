/// Paper trading example.
///
/// Connects to an Alpaca market data feed, waits for one trade message,
/// then places a single paper market-buy order for 1 share.
///
/// Required environment variables:
///   APCA_API_KEY_ID     - Alpaca paper trading API key
///   APCA_API_SECRET_KEY - Alpaca paper trading API secret
///
/// Optional environment variables:
///   ALPACA_FEED - Feed type: "test" (default), "iex", or "sip"
///                Use "test" with symbol FAKEPACA for development outside market hours.
const std = @import("std");
const alpaca = @import("alpaca-trade-api");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const api_key = std.posix.getenv("APCA_API_KEY_ID") orelse {
        std.debug.print("error: APCA_API_KEY_ID environment variable not set\n", .{});
        return error.MissingApiKey;
    };
    const api_secret = std.posix.getenv("APCA_API_SECRET_KEY") orelse {
        std.debug.print("error: APCA_API_SECRET_KEY environment variable not set\n", .{});
        return error.MissingApiSecret;
    };

    // FAKEPACA is the test symbol for the Alpaca test feed (continuous fake data).
    const feed_symbol = "FAKEPACA";
    // Use a real symbol for the paper order.
    const order_symbol = "AAPL";

    // ALPACA_FEED controls which feed endpoint to use.
    // "test" provides continuous fake data and works outside market hours.
    const feed_type = std.posix.getenv("ALPACA_FEED") orelse "test";
    const ws_url = try std.fmt.allocPrint(
        allocator,
        "wss://stream.data.alpaca.markets/v2/{s}",
        .{feed_type},
    );
    defer allocator.free(ws_url);

    // -------------------------------------------------------------------------
    // 1. Market data feed — subscribe and read one trade
    // -------------------------------------------------------------------------
    var feed = alpaca.AlpacaClient.init(allocator);
    defer feed.deinit();

    std.debug.print("Connecting to Alpaca {s} market data feed...\n", .{feed_type});
    try feed.connect(ws_url);
    try feed.authenticate(api_key, api_secret);

    var channels = [_][]const u8{"trades"};
    var symbols = [_][]const u8{feed_symbol};
    try feed.subscribe(&channels, &symbols);

    std.debug.print("Subscribed. Waiting for a {s} trade message...\n", .{feed_symbol});
    const trade_msg = try feed.readMessage() orelse {
        std.debug.print("Connection closed before a trade arrived.\n", .{});
        return;
    };
    defer allocator.free(trade_msg);
    std.debug.print("Market data received: {s}\n\n", .{trade_msg});

    // -------------------------------------------------------------------------
    // 2. Orders — place a paper market buy
    // -------------------------------------------------------------------------
    var orders = alpaca.OrderClient.init(allocator, .paper, api_key, api_secret);
    defer orders.deinit();

    std.debug.print("Placing paper market buy for 1 share of {s}...\n", .{order_symbol});
    const response = try orders.submitOrder(alpaca.OrderRequest.market(order_symbol, 1, .buy));
    defer allocator.free(response);
    std.debug.print("Order response: {s}\n", .{response});
}
