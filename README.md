# alpaca-trade-api-zig

A Zig library providing a WebSocket client for the [Alpaca Markets](https://alpaca.markets/) streaming data API.

## Status

**Early / alpha.** The core connection lifecycle (connect → authenticate → subscribe → read) is implemented and functional. No tests exist yet.

## Features

- TLS WebSocket connection to Alpaca streaming endpoints (`wss://stream.data.alpaca.markets/v2/...`)
- Authentication via API key + secret
- Channel/symbol subscription (trades, quotes, bars)
- Automatic ping/pong handling to keep the connection alive
- Typed message structs: `AlpacaTrade`, `AlpacaQuote`, `AlpacaControl`
- Connection state machine (`ConnectionState` enum)

## Adding as a dependency

In your `build.zig.zon`:

```zig
.dependencies = .{
    .alpaca_trade_api = .{
        .url = "https://github.com/inge4pres/alpaca-trade-api-zig/archive/refs/heads/main.tar.gz",
        .hash = "<hash>",
    },
},
```

In your `build.zig`:

```zig
const alpaca = b.dependency("alpaca_trade_api", .{
    .target = target,
    .optimize = optimize,
});

your_module.addImport("alpaca-trade-api", alpaca.module("alpaca-trade-api"));
```

## Usage

```zig
const alpaca = @import("alpaca-trade-api");

var client = alpaca.AlpacaClient.init(allocator);
defer client.deinit();

try client.connect("wss://stream.data.alpaca.markets/v2/iex");
try client.authenticate(api_key, api_secret);

var channels = [_][]const u8{"trades"};
var symbols  = [_][]const u8{"AAPL", "TSLA"};
try client.subscribe(&channels, &symbols);

while (client.isConnected()) {
    const msg = try client.readMessage() orelse break;
    defer allocator.free(msg);
    // msg is the raw JSON frame from Alpaca
}
```

## Building / testing

```sh
zig build
zig build test
```

## Dependencies

- [websocket.zig](https://github.com/karlseguin/websocket.zig) — WebSocket client
