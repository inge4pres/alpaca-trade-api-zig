/// Historical market data example.
///
/// Fetches historical bars and trades for stocks, then historical bars for an
/// option contract, using Alpaca's REST market data API.
///
/// Required environment variables:
///   APCA_API_KEY_ID     - Alpaca API key
///   APCA_API_SECRET_KEY - Alpaca API secret
///
/// Optional environment variables:
///   ALPACA_FEED - Stock feed source: "iex" (default, free) or "sip"
///
/// The example uses dates well in the past so it works regardless of whether
/// markets are currently open.
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

    const feed_name = std.posix.getenv("ALPACA_FEED") orelse "iex";
    const stock_feed: alpaca.StockFeed = if (std.mem.eql(u8, feed_name, "sip")) .sip else .iex;

    // -------------------------------------------------------------------------
    // 1. Historical stock bars — daily OHLCV for AAPL and MSFT
    // -------------------------------------------------------------------------
    var stocks = alpaca.HistoricalStockClient.init(allocator, api_key, api_secret);
    defer stocks.deinit();

    std.debug.print("=== Stock daily bars (AAPL, MSFT) ===\n", .{});

    const symbols = [_][]const u8{ "AAPL", "MSFT" };
    const bars_json = try stocks.getBars(.{
        .symbols = &symbols,
        .timeframe = .@"1Day",
        .start = "2024-01-02",
        .end = "2024-01-05",
        .limit = 10,
        .feed = stock_feed,
        .adjustment = .split,
    });
    defer allocator.free(bars_json);

    // Parse the response.  The top-level shape is:
    //   { "bars": { "<symbol>": [ {t,o,h,l,c,v,n,vw}, ... ] }, "next_page_token": null }
    const bars_value = try std.json.parseFromSlice(std.json.Value, allocator, bars_json, .{});
    defer bars_value.deinit();

    const bars_map = bars_value.value.object.get("bars") orelse {
        std.debug.print("unexpected response: {s}\n", .{bars_json});
        return error.UnexpectedResponse;
    };

    var bar_it = bars_map.object.iterator();
    while (bar_it.next()) |entry| {
        const sym = entry.key_ptr.*;
        const bar_array = entry.value_ptr.*.array.items;
        std.debug.print("{s}: {} bar(s)\n", .{ sym, bar_array.len });
        for (bar_array) |bar_val| {
            const bar = try std.json.parseFromValue(alpaca.Bar, allocator, bar_val, .{});
            defer bar.deinit();
            std.debug.print("  {s}  o={d:.2}  h={d:.2}  l={d:.2}  c={d:.2}  v={d}\n", .{
                bar.value.t,
                bar.value.o,
                bar.value.h,
                bar.value.l,
                bar.value.c,
                bar.value.v,
            });
        }
    }

    // -------------------------------------------------------------------------
    // 2. Historical stock trades — first few AAPL trades on 2024-01-02
    // -------------------------------------------------------------------------
    std.debug.print("\n=== Stock trades (AAPL) ===\n", .{});

    const trade_symbols = [_][]const u8{"AAPL"};
    const trades_json = try stocks.getTrades(.{
        .symbols = &trade_symbols,
        .start = "2024-01-02T14:30:00Z",
        .end = "2024-01-02T14:30:10Z",
        .limit = 5,
        .feed = stock_feed,
    });
    defer allocator.free(trades_json);

    const trades_value = try std.json.parseFromSlice(std.json.Value, allocator, trades_json, .{});
    defer trades_value.deinit();

    const trades_map = trades_value.value.object.get("trades") orelse {
        std.debug.print("unexpected response: {s}\n", .{trades_json});
        return error.UnexpectedResponse;
    };

    var trade_it = trades_map.object.iterator();
    while (trade_it.next()) |entry| {
        const sym = entry.key_ptr.*;
        const trade_array = entry.value_ptr.*.array.items;
        std.debug.print("{s}: {} trade(s)\n", .{ sym, trade_array.len });
        for (trade_array) |trade_val| {
            const trade = try std.json.parseFromValue(alpaca.HistoricalTrade, allocator, trade_val, .{});
            defer trade.deinit();
            std.debug.print("  {s}  price={d:.2}  size={d}\n", .{
                trade.value.t,
                trade.value.p,
                trade.value.s,
            });
        }
    }

    // -------------------------------------------------------------------------
    // 3. Historical stock quotes — TSLA NBBO on 2024-01-02
    // -------------------------------------------------------------------------
    std.debug.print("\n=== Stock quotes (TSLA) ===\n", .{});

    const quote_symbols = [_][]const u8{"TSLA"};
    const quotes_json = try stocks.getQuotes(.{
        .symbols = &quote_symbols,
        .start = "2024-01-02T14:30:00Z",
        .end = "2024-01-02T14:30:05Z",
        .limit = 5,
        .feed = stock_feed,
    });
    defer allocator.free(quotes_json);

    const quotes_value = try std.json.parseFromSlice(std.json.Value, allocator, quotes_json, .{});
    defer quotes_value.deinit();

    const quotes_map = quotes_value.value.object.get("quotes") orelse {
        std.debug.print("unexpected response: {s}\n", .{quotes_json});
        return error.UnexpectedResponse;
    };

    var quote_it = quotes_map.object.iterator();
    while (quote_it.next()) |entry| {
        const sym = entry.key_ptr.*;
        const quote_array = entry.value_ptr.*.array.items;
        std.debug.print("{s}: {} quote(s)\n", .{ sym, quote_array.len });
        for (quote_array) |quote_val| {
            const quote = try std.json.parseFromValue(alpaca.HistoricalQuote, allocator, quote_val, .{});
            defer quote.deinit();
            std.debug.print("  {s}  bid={d:.2}x{d}  ask={d:.2}x{d}\n", .{
                quote.value.t,
                quote.value.bp,
                quote.value.bs,
                quote.value.ap,
                quote.value.as,
            });
        }
    }

    // -------------------------------------------------------------------------
    // 4. Historical option bars — daily bars for an AAPL call option
    //    Symbol format (OCC): AAPL240315C00185000
    //      AAPL  = underlying
    //      240315 = expiry YYMMDD
    //      C      = call
    //      00185000 = strike $185.00 (multiplied by 1000)
    // -------------------------------------------------------------------------
    std.debug.print("\n=== Option daily bars (AAPL 185C Mar-2024) ===\n", .{});

    var options = alpaca.HistoricalOptionClient.init(allocator, api_key, api_secret);
    defer options.deinit();

    const option_symbols = [_][]const u8{"AAPL240315C00185000"};
    const opt_bars_json = try options.getBars(.{
        .symbols = &option_symbols,
        .timeframe = .@"1Day",
        .start = "2024-01-02",
        .end = "2024-01-05",
        .limit = 10,
        .feed = .indicative,
    });
    defer allocator.free(opt_bars_json);

    const opt_bars_value = try std.json.parseFromSlice(std.json.Value, allocator, opt_bars_json, .{});
    defer opt_bars_value.deinit();

    const opt_bars_map = opt_bars_value.value.object.get("bars") orelse {
        std.debug.print("unexpected response: {s}\n", .{opt_bars_json});
        return error.UnexpectedResponse;
    };

    var opt_it = opt_bars_map.object.iterator();
    while (opt_it.next()) |entry| {
        const sym = entry.key_ptr.*;
        const bar_array = entry.value_ptr.*.array.items;
        std.debug.print("{s}: {} bar(s)\n", .{ sym, bar_array.len });
        for (bar_array) |bar_val| {
            const bar = try std.json.parseFromValue(alpaca.Bar, allocator, bar_val, .{});
            defer bar.deinit();
            std.debug.print("  {s}  o={d:.2}  h={d:.2}  l={d:.2}  c={d:.2}  v={d}\n", .{
                bar.value.t,
                bar.value.o,
                bar.value.h,
                bar.value.l,
                bar.value.c,
                bar.value.v,
            });
        }
    }
}
