const std = @import("std");

const log = std.log.scoped(.historical_client);

pub const HistoricalClientError = error{
    RequestFailed,
    HttpError,
};

/// OHLCV bar (stocks and options)
pub const Bar = struct {
    t: []const u8, // RFC-3339 timestamp
    o: f64, // open price
    h: f64, // high price
    l: f64, // low price
    c: f64, // close price
    v: u64, // volume
    n: u64, // trade count
    vw: f64, // volume-weighted average price
};

/// Historical trade tick
pub const HistoricalTrade = struct {
    t: []const u8, // RFC-3339 timestamp
    x: []const u8, // exchange code
    p: f64, // price
    s: u64, // size
    c: []const []const u8, // conditions
    z: []const u8, // tape
};

/// Historical quote tick
pub const HistoricalQuote = struct {
    t: []const u8, // RFC-3339 timestamp
    ax: []const u8, // ask exchange
    ap: f64, // ask price
    as: u32, // ask size
    bx: []const u8, // bid exchange
    bp: f64, // bid price
    bs: u32, // bid size
    c: []const []const u8, // conditions
    z: []const u8, // tape
};

/// Aggregation timeframe for bar requests
pub const Timeframe = enum {
    @"1Min",
    @"5Min",
    @"15Min",
    @"30Min",
    @"1Hour",
    @"4Hour",
    @"1Day",
    @"1Week",
    @"1Month",

    pub fn toString(self: Timeframe) []const u8 {
        return switch (self) {
            .@"1Min" => "1Min",
            .@"5Min" => "5Min",
            .@"15Min" => "15Min",
            .@"30Min" => "30Min",
            .@"1Hour" => "1Hour",
            .@"4Hour" => "4Hour",
            .@"1Day" => "1Day",
            .@"1Week" => "1Week",
            .@"1Month" => "1Month",
        };
    }
};

/// Price adjustment applied to stock bars
pub const Adjustment = enum {
    raw,
    split,
    dividend,
    all,
};

/// Stock market data feed source
pub const StockFeed = enum {
    iex,
    sip,
    boats,
    overnight,
};

/// Options market data feed source
pub const OptionFeed = enum {
    indicative,
    opra,
};

/// Sort order for paginated results
pub const Sort = enum {
    asc,
    desc,
};

// ---------------------------------------------------------------------------
// Stock parameter types
// ---------------------------------------------------------------------------

pub const StockBarsParams = struct {
    symbols: []const []const u8,
    timeframe: Timeframe,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    page_token: ?[]const u8 = null,
    sort: ?Sort = null,
    feed: ?StockFeed = null,
    adjustment: ?Adjustment = null,
};

pub const StockTradesParams = struct {
    symbols: []const []const u8,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    page_token: ?[]const u8 = null,
    sort: ?Sort = null,
    feed: ?StockFeed = null,
};

pub const StockQuotesParams = struct {
    symbols: []const []const u8,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    page_token: ?[]const u8 = null,
    sort: ?Sort = null,
    feed: ?StockFeed = null,
};

// ---------------------------------------------------------------------------
// Option parameter types
// ---------------------------------------------------------------------------

pub const OptionBarsParams = struct {
    symbols: []const []const u8,
    timeframe: Timeframe,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    page_token: ?[]const u8 = null,
    sort: ?Sort = null,
    feed: ?OptionFeed = null,
};

pub const OptionTradesParams = struct {
    symbols: []const []const u8,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    page_token: ?[]const u8 = null,
    sort: ?Sort = null,
    feed: ?OptionFeed = null,
};

pub const OptionQuotesParams = struct {
    symbols: []const []const u8,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    limit: ?u32 = null,
    page_token: ?[]const u8 = null,
    sort: ?Sort = null,
    feed: ?OptionFeed = null,
};

// ---------------------------------------------------------------------------
// URL builder helpers
// ---------------------------------------------------------------------------

/// Append `?key=value` or `&key=value` to buf depending on whether params
/// have already been added.
fn appendParam(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, first: *bool, key: []const u8, value: []const u8) !void {
    try buf.append(allocator, if (first.*) '?' else '&');
    first.* = false;
    try buf.appendSlice(allocator, key);
    try buf.append(allocator, '=');
    try buf.appendSlice(allocator, value);
}

fn appendSymbols(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, first: *bool, symbols: []const []const u8) !void {
    try buf.append(allocator, if (first.*) '?' else '&');
    first.* = false;
    try buf.appendSlice(allocator, "symbols=");
    for (symbols, 0..) |sym, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, sym);
    }
}

fn appendOptionalParams(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    first: *bool,
    start: ?[]const u8,
    end: ?[]const u8,
    limit: ?u32,
    page_token: ?[]const u8,
    sort: ?Sort,
) !void {
    if (start) |s| try appendParam(buf, allocator, first, "start", s);
    if (end) |e| try appendParam(buf, allocator, first, "end", e);
    if (limit) |lim| {
        var tmp: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{lim});
        try appendParam(buf, allocator, first, "limit", s);
    }
    if (page_token) |pt| try appendParam(buf, allocator, first, "page_token", pt);
    if (sort) |srt| try appendParam(buf, allocator, first, "sort", @tagName(srt));
}

// ---------------------------------------------------------------------------
// HistoricalStockClient
// ---------------------------------------------------------------------------

/// HTTP client for Alpaca's historical stock market data REST API.
/// Base URL: https://data.alpaca.markets/v2/stocks/...
///
/// All `get*` methods return caller-owned raw JSON bytes.
/// Parse the response with std.json.parseFromSlice; the top-level object has:
///   - "bars" / "trades" / "quotes": a JSON object keyed by symbol
///   - "next_page_token": string or null (use with page_token param for paging)
pub const HistoricalStockClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_secret: []const u8,
    http: std.http.Client,

    const base_url = "https://data.alpaca.markets";

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, api_secret: []const u8) HistoricalStockClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_secret = api_secret,
            .http = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HistoricalStockClient) void {
        self.http.deinit();
    }

    fn authHeaders(self: *HistoricalStockClient) ![]std.http.Header {
        const headers = try self.allocator.alloc(std.http.Header, 2);
        headers[0] = .{ .name = "APCA-API-KEY-ID", .value = self.api_key };
        headers[1] = .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret };
        return headers;
    }

    fn get(self: *HistoricalStockClient, url: []const u8) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();

        const auth_headers = try self.authHeaders();
        defer self.allocator.free(auth_headers);

        log.info("GET {s}", .{url});

        const result = self.http.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .extra_headers = auth_headers,
            .response_writer = &writer.writer,
        }) catch |err| {
            log.err("request failed: {s}", .{@errorName(err)});
            return HistoricalClientError.RequestFailed;
        };

        if (result.status != .ok) {
            log.err("HTTP {any}: {s}", .{ result.status, writer.written() });
            return HistoricalClientError.HttpError;
        }

        return try writer.toOwnedSlice();
    }

    /// Fetch historical bars for one or more stock symbols.
    /// Returns caller-owned raw JSON bytes.
    pub fn getBars(self: *HistoricalStockClient, params: StockBarsParams) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, base_url ++ "/v2/stocks/bars");
        var first = true;
        try appendSymbols(&buf, self.allocator, &first, params.symbols);
        try appendParam(&buf, self.allocator, &first, "timeframe", params.timeframe.toString());
        try appendOptionalParams(&buf, self.allocator, &first, params.start, params.end, params.limit, params.page_token, params.sort);
        if (params.feed) |f| try appendParam(&buf, self.allocator, &first, "feed", @tagName(f));
        if (params.adjustment) |a| try appendParam(&buf, self.allocator, &first, "adjustment", @tagName(a));

        const url = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);
        return self.get(url);
    }

    /// Fetch historical trades for one or more stock symbols.
    /// Returns caller-owned raw JSON bytes.
    pub fn getTrades(self: *HistoricalStockClient, params: StockTradesParams) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, base_url ++ "/v2/stocks/trades");
        var first = true;
        try appendSymbols(&buf, self.allocator, &first, params.symbols);
        try appendOptionalParams(&buf, self.allocator, &first, params.start, params.end, params.limit, params.page_token, params.sort);
        if (params.feed) |f| try appendParam(&buf, self.allocator, &first, "feed", @tagName(f));

        const url = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);
        return self.get(url);
    }

    /// Fetch historical quotes for one or more stock symbols.
    /// Returns caller-owned raw JSON bytes.
    pub fn getQuotes(self: *HistoricalStockClient, params: StockQuotesParams) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, base_url ++ "/v2/stocks/quotes");
        var first = true;
        try appendSymbols(&buf, self.allocator, &first, params.symbols);
        try appendOptionalParams(&buf, self.allocator, &first, params.start, params.end, params.limit, params.page_token, params.sort);
        if (params.feed) |f| try appendParam(&buf, self.allocator, &first, "feed", @tagName(f));

        const url = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);
        return self.get(url);
    }
};

// ---------------------------------------------------------------------------
// HistoricalOptionClient
// ---------------------------------------------------------------------------

/// HTTP client for Alpaca's historical options market data REST API.
/// Base URL: https://data.alpaca.markets/v1beta1/options/...
///
/// All `get*` methods return caller-owned raw JSON bytes.
/// Parse the response with std.json.parseFromSlice; the top-level object has:
///   - "bars" / "trades" / "quotes": a JSON object keyed by option symbol
///   - "next_page_token": string or null
pub const HistoricalOptionClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_secret: []const u8,
    http: std.http.Client,

    const base_url = "https://data.alpaca.markets";

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, api_secret: []const u8) HistoricalOptionClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_secret = api_secret,
            .http = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HistoricalOptionClient) void {
        self.http.deinit();
    }

    fn authHeaders(self: *HistoricalOptionClient) ![]std.http.Header {
        const headers = try self.allocator.alloc(std.http.Header, 2);
        headers[0] = .{ .name = "APCA-API-KEY-ID", .value = self.api_key };
        headers[1] = .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret };
        return headers;
    }

    fn get(self: *HistoricalOptionClient, url: []const u8) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();

        const auth_headers = try self.authHeaders();
        defer self.allocator.free(auth_headers);

        log.info("GET {s}", .{url});

        const result = self.http.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .extra_headers = auth_headers,
            .response_writer = &writer.writer,
        }) catch |err| {
            log.err("request failed: {s}", .{@errorName(err)});
            return HistoricalClientError.RequestFailed;
        };

        if (result.status != .ok) {
            log.err("HTTP {any}: {s}", .{ result.status, writer.written() });
            return HistoricalClientError.HttpError;
        }

        return try writer.toOwnedSlice();
    }

    /// Fetch historical bars for one or more option contract symbols.
    /// Returns caller-owned raw JSON bytes.
    pub fn getBars(self: *HistoricalOptionClient, params: OptionBarsParams) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, base_url ++ "/v1beta1/options/bars");
        var first = true;
        try appendSymbols(&buf, self.allocator, &first, params.symbols);
        try appendParam(&buf, self.allocator, &first, "timeframe", params.timeframe.toString());
        try appendOptionalParams(&buf, self.allocator, &first, params.start, params.end, params.limit, params.page_token, params.sort);
        if (params.feed) |f| try appendParam(&buf, self.allocator, &first, "feed", @tagName(f));

        const url = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);
        return self.get(url);
    }

    /// Fetch historical trades for one or more option contract symbols.
    /// Returns caller-owned raw JSON bytes.
    pub fn getTrades(self: *HistoricalOptionClient, params: OptionTradesParams) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, base_url ++ "/v1beta1/options/trades");
        var first = true;
        try appendSymbols(&buf, self.allocator, &first, params.symbols);
        try appendOptionalParams(&buf, self.allocator, &first, params.start, params.end, params.limit, params.page_token, params.sort);
        if (params.feed) |f| try appendParam(&buf, self.allocator, &first, "feed", @tagName(f));

        const url = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);
        return self.get(url);
    }

    /// Fetch historical quotes for one or more option contract symbols.
    /// Returns caller-owned raw JSON bytes.
    pub fn getQuotes(self: *HistoricalOptionClient, params: OptionQuotesParams) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, base_url ++ "/v1beta1/options/quotes");
        var first = true;
        try appendSymbols(&buf, self.allocator, &first, params.symbols);
        try appendOptionalParams(&buf, self.allocator, &first, params.start, params.end, params.limit, params.page_token, params.sort);
        if (params.feed) |f| try appendParam(&buf, self.allocator, &first, "feed", @tagName(f));

        const url = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);
        return self.get(url);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Bar parses from JSON" {
    const json =
        \\{"t":"2024-01-03T09:30:00Z","o":185.10,"h":186.50,"l":184.90,"c":185.75,"v":8500000,"n":45000,"vw":185.42}
    ;
    const parsed = try std.json.parseFromSlice(Bar, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const bar = parsed.value;
    try std.testing.expectEqualStrings("2024-01-03T09:30:00Z", bar.t);
    try std.testing.expectApproxEqAbs(@as(f64, 185.10), bar.o, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 186.50), bar.h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 184.90), bar.l, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 185.75), bar.c, 0.001);
    try std.testing.expectEqual(@as(u64, 8500000), bar.v);
    try std.testing.expectEqual(@as(u64, 45000), bar.n);
    try std.testing.expectApproxEqAbs(@as(f64, 185.42), bar.vw, 0.001);
}

test "HistoricalTrade parses from JSON" {
    const json =
        \\{"t":"2024-01-03T09:30:01.123456789Z","x":"C","p":185.20,"s":100,"c":["@","I"],"z":"C"}
    ;
    const parsed = try std.json.parseFromSlice(HistoricalTrade, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const trade = parsed.value;
    try std.testing.expectEqualStrings("2024-01-03T09:30:01.123456789Z", trade.t);
    try std.testing.expectEqualStrings("C", trade.x);
    try std.testing.expectApproxEqAbs(@as(f64, 185.20), trade.p, 0.001);
    try std.testing.expectEqual(@as(u64, 100), trade.s);
    try std.testing.expectEqual(@as(usize, 2), trade.c.len);
    try std.testing.expectEqualStrings("C", trade.z);
}

test "HistoricalQuote parses from JSON" {
    const json =
        \\{"t":"2024-01-03T09:30:00Z","ax":"C","ap":185.30,"as":5,"bx":"D","bp":185.25,"bs":10,"c":["R"],"z":"C"}
    ;
    const parsed = try std.json.parseFromSlice(HistoricalQuote, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const quote = parsed.value;
    try std.testing.expectEqualStrings("2024-01-03T09:30:00Z", quote.t);
    try std.testing.expectEqualStrings("C", quote.ax);
    try std.testing.expectApproxEqAbs(@as(f64, 185.30), quote.ap, 0.001);
    try std.testing.expectEqual(@as(u32, 5), quote.as);
    try std.testing.expectEqualStrings("D", quote.bx);
    try std.testing.expectApproxEqAbs(@as(f64, 185.25), quote.bp, 0.001);
    try std.testing.expectEqual(@as(u32, 10), quote.bs);
    try std.testing.expectEqualStrings("C", quote.z);
}

test "Timeframe toString" {
    try std.testing.expectEqualStrings("1Min", Timeframe.@"1Min".toString());
    try std.testing.expectEqualStrings("1Hour", Timeframe.@"1Hour".toString());
    try std.testing.expectEqualStrings("1Day", Timeframe.@"1Day".toString());
    try std.testing.expectEqualStrings("1Month", Timeframe.@"1Month".toString());
}

test "HistoricalStockClient init" {
    var c = HistoricalStockClient.init(std.testing.allocator, "key", "secret");
    defer c.deinit();
    try std.testing.expectEqualStrings("key", c.api_key);
    try std.testing.expectEqualStrings("secret", c.api_secret);
}

test "HistoricalOptionClient init" {
    var c = HistoricalOptionClient.init(std.testing.allocator, "key", "secret");
    defer c.deinit();
    try std.testing.expectEqualStrings("key", c.api_key);
    try std.testing.expectEqualStrings("secret", c.api_secret);
}
