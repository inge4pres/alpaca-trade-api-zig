const std = @import("std");

const log = std.log.scoped(.order_client);

pub const OrderClientError = error{
    OrderFailedHTTPStatus,
    OrderFailedSend,
};

pub const OrderSide = enum {
    buy,
    sell,
};

pub const OrderType = enum {
    market,
    limit,
    stop,
    stop_limit,
    trailing_stop,

    pub fn toString(self: OrderType) []const u8 {
        return switch (self) {
            .market => "market",
            .limit => "limit",
            .stop => "stop",
            .stop_limit => "stop_limit",
            .trailing_stop => "trailing_stop",
        };
    }
};

pub const TimeInForce = enum {
    day,
    gtc,
    ioc,
    fok,

    pub fn toString(self: TimeInForce) []const u8 {
        return switch (self) {
            .day => "day",
            .gtc => "gtc",
            .ioc => "ioc",
            .fok => "fok",
        };
    }
};

pub const OrderRequest = struct {
    symbol: []const u8,
    qty: u32,
    side: OrderSide,
    order_type: OrderType,
    time_in_force: TimeInForce,
    limit_price: ?f64 = null,
    stop_price: ?f64 = null,
    client_order_id: ?[]const u8 = null,

    pub fn market(symbol: []const u8, qty: u32, side: OrderSide) OrderRequest {
        return .{
            .symbol = symbol,
            .qty = qty,
            .side = side,
            .order_type = .market,
            .time_in_force = .day,
        };
    }

    pub fn limit(symbol: []const u8, qty: u32, side: OrderSide, limit_price: f64) OrderRequest {
        return .{
            .symbol = symbol,
            .qty = qty,
            .side = side,
            .order_type = .limit,
            .time_in_force = .day,
            .limit_price = limit_price,
        };
    }
};

pub const TradingAPIURL = union(enum) {
    paper: []const u8,
    live: []const u8,

    pub fn getURL(self: TradingAPIURL) []const u8 {
        return switch (self) {
            .paper => "https://paper-api.alpaca.markets",
            .live => "https://api.alpaca.markets",
        };
    }
};

/// HTTP client for submitting and managing orders via the Alpaca Trading REST API.
/// Targets paper-api.alpaca.markets by default.
pub const OrderClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_secret: []const u8,
    base_url: []const u8,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, url: TradingAPIURL, api_key: []const u8, api_secret: []const u8) OrderClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_secret = api_secret,
            .base_url = url.getURL(),
            .client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *OrderClient) void {
        self.client.deinit();
    }

    fn authHeaders(self: *OrderClient) ![]std.http.Header {
        const headers = try self.allocator.alloc(std.http.Header, 2);
        headers[0] = .{ .name = "APCA-API-KEY-ID", .value = self.api_key };
        headers[1] = .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret };
        return headers;
    }

    /// Submit an order. Caller owns the returned JSON response slice.
    pub fn submitOrder(self: *OrderClient, request: OrderRequest) ![]u8 {
        const body = try self.buildOrderBody(request);
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/orders", .{self.base_url});
        defer self.allocator.free(url);

        log.info("POST {s}", .{url});
        log.debug("request body: {s}", .{body});

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();

        const auth_headers = try self.authHeaders();
        defer self.allocator.free(auth_headers);

        const result = self.client.fetch(.{
            .method = .POST,
            .location = .{ .url = url },
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = auth_headers,
            .payload = body,
            .response_writer = &writer.writer,
        }) catch |err| {
            log.err("failed to send order: {s}", .{@errorName(err)});
            return OrderClientError.OrderFailedSend;
        };

        if (result.status != .ok and result.status != .created) {
            log.err("order failed with HTTP status {any}: {s}", .{ result.status, writer.written() });
            return OrderClientError.OrderFailedHTTPStatus;
        }

        return try writer.toOwnedSlice();
    }

    /// Cancel an order by ID.
    pub fn cancelOrder(self: *OrderClient, order_id: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/orders/{s}", .{ self.base_url, order_id });
        defer self.allocator.free(url);

        const auth_headers = try self.authHeaders();
        defer self.allocator.free(auth_headers);

        const result = self.client.fetch(.{
            .method = .DELETE,
            .location = .{ .url = url },
            .extra_headers = auth_headers,
        }) catch |err| {
            log.err("failed to cancel order: {s}", .{@errorName(err)});
            return OrderClientError.OrderFailedSend;
        };

        if (result.status != .ok and result.status != .no_content) {
            log.err("cancel order failed with HTTP status {any}", .{result.status});
            return OrderClientError.OrderFailedHTTPStatus;
        }
    }

    /// Get an order by ID. Caller owns the returned JSON response slice.
    pub fn getOrder(self: *OrderClient, order_id: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v2/orders/{s}", .{ self.base_url, order_id });
        defer self.allocator.free(url);

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();

        const auth_headers = try self.authHeaders();
        defer self.allocator.free(auth_headers);

        const result = self.client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .extra_headers = auth_headers,
            .response_writer = &writer.writer,
        }) catch |err| {
            log.err("failed to get order: {s}", .{@errorName(err)});
            return OrderClientError.OrderFailedSend;
        };

        if (result.status != .ok) {
            log.err("get order failed with HTTP status {any}", .{result.status});
            return OrderClientError.OrderFailedHTTPStatus;
        }

        return try writer.toOwnedSlice();
    }

    fn buildOrderBody(self: *OrderClient, request: OrderRequest) ![]const u8 {
        var parts: std.ArrayList([]const u8) = .{};
        defer {
            for (parts.items) |part| self.allocator.free(part);
            parts.deinit(self.allocator);
        }

        try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"symbol\":\"{s}\"", .{request.symbol}));
        try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"qty\":\"{d}\"", .{request.qty}));
        try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"side\":\"{s}\"", .{@tagName(request.side)}));
        try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"type\":\"{s}\"", .{request.order_type.toString()}));
        try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"time_in_force\":\"{s}\"", .{request.time_in_force.toString()}));

        if (request.limit_price) |lp| {
            try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"limit_price\":\"{d:.2}\"", .{lp}));
        }
        if (request.stop_price) |sp| {
            try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"stop_price\":\"{d:.2}\"", .{sp}));
        }
        if (request.client_order_id) |cid| {
            try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\"client_order_id\":\"{s}\"", .{cid}));
        }

        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{");
        for (parts.items, 0..) |part, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, part);
        }
        try buf.appendSlice(self.allocator, "}");

        return buf.toOwnedSlice(self.allocator);
    }
};
