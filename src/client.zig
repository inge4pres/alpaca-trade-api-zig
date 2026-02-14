const std = @import("std");
const websocket = @import("websocket");
const types = @import("types.zig");

const log = std.log.scoped(.alpaca_client);

pub const AlpacaClient = struct {
    allocator: std.mem.Allocator,
    client: websocket.Client,
    state: types.ConnectionState,

    pub fn init(allocator: std.mem.Allocator) AlpacaClient {
        return .{
            .allocator = allocator,
            .client = undefined,
            .state = .disconnected,
        };
    }

    pub fn deinit(self: *AlpacaClient) void {
        if (self.state != .disconnected) {
            self.client.close(.{}) catch {};
        }
    }

    /// Connect to WebSocket URL
    pub fn connect(self: *AlpacaClient, url: []const u8) !void {
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
    pub fn authenticate(self: *AlpacaClient, api_key: []const u8, api_secret: []const u8) !void {
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
    pub fn subscribe(self: *AlpacaClient, channels: [][]const u8, symbols: [][]const u8) !void {
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
    pub fn readMessage(self: *AlpacaClient) !?[]u8 {
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
                // Handle different message types
                switch (m.type) {
                    .text => {
                        // Return owned copy of text data
                        return try self.allocator.dupe(u8, m.data);
                    },
                    .ping => {
                        // Respond to ping with pong to keep connection alive
                        log.debug("Received ping, responding with pong", .{});
                        try self.client.writePong(@constCast(m.data));
                        // Continue loop to read next message
                    },
                    .pong => {
                        // Server responded to our ping (not used currently)
                        log.debug("Received pong from server", .{});
                        // Continue loop to read next message
                    },
                    .close => {
                        // Server closed connection gracefully
                        log.warn("Server sent close frame", .{});
                        self.state = .disconnected;
                        return null;
                    },
                    .binary => {
                        // Alpaca doesn't use binary frames, but handle it just in case
                        log.warn("Received unexpected binary frame", .{});
                        // Continue loop to read next message
                    },
                }
            } else {
                return null;
            }
        }
    }

    /// Check if connection is active
    pub fn isConnected(self: *const AlpacaClient) bool {
        return self.state == .subscribed or self.state == .authenticated;
    }
};

test "init sets disconnected state" {
    const client = AlpacaClient.init(std.testing.allocator);
    try std.testing.expectEqual(types.ConnectionState.disconnected, client.state);
}

test "isConnected returns false when disconnected" {
    const client = AlpacaClient.init(std.testing.allocator);
    try std.testing.expect(!client.isConnected());
}

test "isConnected returns false when connecting" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .connecting;
    try std.testing.expect(!client.isConnected());
}

test "isConnected returns false when authenticating" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .authenticating;
    try std.testing.expect(!client.isConnected());
}

test "isConnected returns true when authenticated" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .authenticated;
    try std.testing.expect(client.isConnected());
}

test "isConnected returns true when subscribed" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .subscribed;
    try std.testing.expect(client.isConnected());
}

test "isConnected returns false on error_state" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .error_state;
    try std.testing.expect(!client.isConnected());
}

test "authenticate returns NotConnected when disconnected" {
    var client = AlpacaClient.init(std.testing.allocator);
    try std.testing.expectError(error.NotConnected, client.authenticate("key", "secret"));
    // state must not change
    try std.testing.expectEqual(types.ConnectionState.disconnected, client.state);
}

test "authenticate returns NotConnected when already authenticating" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .authenticating;
    try std.testing.expectError(error.NotConnected, client.authenticate("key", "secret"));
}

test "subscribe returns NotAuthenticated when disconnected" {
    var client = AlpacaClient.init(std.testing.allocator);
    var channels = [_][]const u8{"trades"};
    var symbols = [_][]const u8{"AAPL"};
    try std.testing.expectError(error.NotAuthenticated, client.subscribe(&channels, &symbols));
}

test "subscribe returns NotAuthenticated when only connected" {
    var client = AlpacaClient.init(std.testing.allocator);
    client.state = .connected;
    var channels = [_][]const u8{"trades"};
    var symbols = [_][]const u8{"AAPL"};
    try std.testing.expectError(error.NotAuthenticated, client.subscribe(&channels, &symbols));
}
