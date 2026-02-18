const std = @import("std");
const websocket = @import("websocket");
const types = @import("types.zig");

const log = std.log.scoped(.alpaca_client);

/// A WebSocket client for connecting to Alpaca's streaming API.
/// It allows authenticating, subscribing to channels, and reading messages.
///
/// Thread-safety: this client is NOT thread-safe. When readMessage() is
/// running on a dedicated thread, use the following shutdown sequence to
/// avoid a data race between deinit() freeing the read buffer and fill()
/// still writing into it:
///
///   1. Call client.close() from the main thread.
///      This sends a WebSocket close frame and shuts down the underlying
///      TCP socket, which causes the blocking readMessage() call to return
///      null (or an error) on the reader thread.
///   2. Join (wait for) the reader thread to exit.
///   3. Call client.deinit() — now safe because no other thread is using
///      the client.
///
/// Calling deinit() while readMessage() is blocked in another thread will
/// free the internal read buffer mid-read and trigger an assert in the
/// websocket library (proto.zig: assert(self.buf.data.len > pos)).
pub const TradingWebSocketClient = struct {
    allocator: std.mem.Allocator,
    client: websocket.Client,
    state: types.ConnectionState,

    pub fn init(allocator: std.mem.Allocator) TradingWebSocketClient {
        return .{
            .allocator = allocator,
            .client = undefined,
            .state = .disconnected,
        };
    }

    /// Send a WebSocket close frame and shut down the underlying socket.
    ///
    /// After close() returns, any concurrent readMessage() call will
    /// unblock and return null. This is the correct first step of the
    /// threaded shutdown sequence described on TradingWebSocketClient.
    ///
    /// close() is idempotent: calling it more than once is safe.
    pub fn close(self: *TradingWebSocketClient) void {
        if (self.state == .disconnected) return;
        self.client.close(.{}) catch {};
        self.state = .disconnected;
    }

    /// Free all resources held by this client.
    ///
    /// WARNING: do NOT call deinit() while readMessage() is running on
    /// another thread. Call close() first, join the reader thread, then
    /// call deinit(). See the struct-level doc comment for details.
    pub fn deinit(self: *TradingWebSocketClient) void {
        self.close();
        self.client.deinit();
    }

    /// Connect to WebSocket URL
    pub fn connect(self: *TradingWebSocketClient, url: []const u8) !void {
        self.state = .connecting;

        // Parse URL to extract host and path
        // Format: wss://stream.data.alpaca.markets/v2/iex
        const uri = try std.Uri.parse(url);

        const host_component = uri.host orelse return error.InvalidUrl;
        const host = switch (host_component) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };

        const path = switch (uri.path) {
            .raw => |p| if (p.len > 0) p else "/",
            .percent_encoded => |p| if (p.len > 0) p else "/",
        };
        const port: u16 = uri.port orelse 443;

        // Connect using websocket.zig Client
        const client = try websocket.Client.init(self.allocator, .{
            .host = host,
            .port = port,
            .tls = true,
        });

        self.client = client;

        // Perform WebSocket handshake
        try self.client.handshake(path, .{
            .headers = "host: stream.data.alpaca.markets\r\n",
        });

        self.state = .connected;
    }

    /// Authenticate with Alpaca API
    /// CRITICAL: Must be called within 10 seconds of connecting
    pub fn authenticate(self: *TradingWebSocketClient, api_key: []const u8, api_secret: []const u8) !void {
        if (self.state != .connected) {
            return error.NotConnected;
        }

        self.state = .authenticating;

        // First, read and discard the initial "connected" message
        const connected_msg = try self.readMessage();
        if (connected_msg) |msg| {
            self.allocator.free(msg);
        }

        // Build authentication message
        const auth_msg = try std.fmt.allocPrint(
            self.allocator,
            \\{{"action":"auth","key":"{s}","secret":"{s}"}}
        ,
            .{ api_key, api_secret },
        );
        defer self.allocator.free(auth_msg);

        // Send authentication message
        try self.client.write(auth_msg);

        // Wait for authentication response
        const response = try self.readMessage();
        if (response) |r| {
            defer self.allocator.free(r);

            // Parse response to verify authentication success
            // Expected: [{"T":"success","msg":"authenticated"}]
            if (std.mem.indexOf(u8, r, "authenticated") == null) {
                log.err("Authentication failed: {s}", .{r});
                self.state = .error_state;
                return error.AuthenticationFailed;
            }
            self.state = .authenticated;
        }
    }

    /// Subscribe to channels and symbols
    pub fn subscribe(self: *TradingWebSocketClient, channels: [][]const u8, symbols: [][]const u8) !void {
        if (self.state != .authenticated) {
            return error.NotAuthenticated;
        }

        // Build subscription message
        var msg: std.ArrayList(u8) = .{};
        defer msg.deinit(self.allocator);

        try msg.appendSlice(self.allocator, "{\"action\":\"subscribe\",");

        // Add channels
        for (channels, 0..) |channel, i| {
            if (i == 0) {
                try msg.appendSlice(self.allocator, "\"");
                try msg.appendSlice(self.allocator, channel);
                try msg.appendSlice(self.allocator, "\":[");
            } else {
                try msg.appendSlice(self.allocator, ",\"");
                try msg.appendSlice(self.allocator, channel);
                try msg.appendSlice(self.allocator, "\":[");
            }

            // Add symbols for this channel
            for (symbols, 0..) |symbol, j| {
                if (j > 0) try msg.append(self.allocator, ',');
                try msg.append(self.allocator, '"');
                try msg.appendSlice(self.allocator, symbol);
                try msg.append(self.allocator, '"');
            }
            try msg.append(self.allocator, ']');
        }

        try msg.append(self.allocator, '}');

        // Send subscription message
        try self.client.write(msg.items);

        // Wait for subscription confirmation
        const response = try self.readMessage();
        if (response) |r| {
            defer self.allocator.free(r);

            // Verify subscription success
            if (std.mem.indexOf(u8, r, "subscription") == null) {
                log.err("Subscription failed: {s}", .{r});
                self.state = .error_state;
                return error.SubscriptionFailed;
            }

            self.state = .subscribed;
        }
    }

    /// Read next message from WebSocket (blocking)
    /// Handles ping/pong automatically and only returns text messages
    pub fn readMessage(self: *TradingWebSocketClient) !?[]u8 {
        while (true) {
            const msg = self.client.read() catch |err| {
                switch (err) {
                    error.Closed, error.EndOfStream => {
                        log.warn("WebSocket connection closed by server", .{});
                        self.state = .disconnected;
                        return null;
                    },
                    else => {
                        log.err("Error reading message: {s}", .{@errorName(err)});
                        return error.ReadFailed;
                    },
                }
            };

            if (msg) |m| {
                // Handle different message types.
                // IMPORTANT: client.done(m) must be called for every message
                // returned by client.read(), in every branch. It signals to the
                // websocket library that we are finished with m.data, allowing it
                // to release any large dynamic buffer and restore the static read
                // buffer. Omitting done() causes the dynamic buffer to be retained
                // indefinitely; once its space is exhausted fill() asserts
                // (data.len > pos fails) and the process panics.
                switch (m.type) {
                    .text => {
                        // Copy data before done() invalidates the buffer slice.
                        const copy = try self.allocator.dupe(u8, m.data);
                        self.client.done(m);
                        return copy;
                    },
                    .ping => {
                        log.debug("Received ping, responding with pong", .{});
                        try self.client.writePong(@constCast(m.data));
                        self.client.done(m);
                    },
                    .pong => {
                        log.debug("Received pong from server", .{});
                        self.client.done(m);
                    },
                    .close => {
                        log.warn("Server sent close frame", .{});
                        self.client.done(m);
                        self.state = .disconnected;
                        return null;
                    },
                    .binary => {
                        log.warn("Received unexpected binary frame", .{});
                        self.client.done(m);
                    },
                }
            } else {
                return null;
            }
        }
    }

    /// Check if connection is active
    pub fn isConnected(self: *const TradingWebSocketClient) bool {
        return self.state == .subscribed or self.state == .authenticated;
    }
};

test "init sets disconnected state" {
    const client = TradingWebSocketClient.init(std.testing.allocator);
    try std.testing.expectEqual(types.ConnectionState.disconnected, client.state);
}

test "isConnected returns false when disconnected" {
    const client = TradingWebSocketClient.init(std.testing.allocator);
    try std.testing.expect(!client.isConnected());
}

test "isConnected returns false when connecting" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .connecting;
    try std.testing.expect(!client.isConnected());
}

test "isConnected returns false when authenticating" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .authenticating;
    try std.testing.expect(!client.isConnected());
}

test "isConnected returns true when authenticated" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .authenticated;
    try std.testing.expect(client.isConnected());
}

test "isConnected returns true when subscribed" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .subscribed;
    try std.testing.expect(client.isConnected());
}

test "isConnected returns false on error_state" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .error_state;
    try std.testing.expect(!client.isConnected());
}

test "authenticate returns NotConnected when disconnected" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    try std.testing.expectError(error.NotConnected, client.authenticate("key", "secret"));
    // state must not change
    try std.testing.expectEqual(types.ConnectionState.disconnected, client.state);
}

test "authenticate returns NotConnected when already authenticating" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .authenticating;
    try std.testing.expectError(error.NotConnected, client.authenticate("key", "secret"));
}

test "subscribe returns NotAuthenticated when disconnected" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    var channels = [_][]const u8{"trades"};
    var symbols = [_][]const u8{"AAPL"};
    try std.testing.expectError(error.NotAuthenticated, client.subscribe(&channels, &symbols));
}

test "subscribe returns NotAuthenticated when only connected" {
    var client = TradingWebSocketClient.init(std.testing.allocator);
    client.state = .connected;
    var channels = [_][]const u8{"trades"};
    var symbols = [_][]const u8{"AAPL"};
    try std.testing.expectError(error.NotAuthenticated, client.subscribe(&channels, &symbols));
}
