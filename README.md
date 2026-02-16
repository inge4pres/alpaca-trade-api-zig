# alpaca-trade-api-zig

A Zig library for the [Alpaca Markets](https://alpaca.markets/) API, providing:

- A **WebSocket client** for the streaming market data feed
- An **HTTP client** for placing and managing orders via the Trading REST API
- An **HTTP client** for fetching historical market data (stocks and options)

## Status

**Alpha.** Core functionality is implemented and covered by unit tests.

## Features

### Streaming market data (`AlpacaClient`)

- TLS WebSocket connection to `wss://stream.data.alpaca.markets/v2/...`
- Authentication via API key + secret
- Channel/symbol subscription (trades, quotes, bars)
- Automatic ping/pong handling
- Typed message structs: `AlpacaTrade`, `AlpacaQuote`, `AlpacaControl`
- Connection state machine (`ConnectionState`)

### Orders (`OrderClient`)

- Submit market and limit orders
- Cancel orders by ID
- Retrieve order status by ID

### Historical market data

#### Stocks (`HistoricalStockClient`) — `https://data.alpaca.markets/v2/stocks/`

| Method | Endpoint | Description |
|---|---|---|
| `getBars` | `GET /v2/stocks/bars` | OHLCV bars for one or more symbols |
| `getTrades` | `GET /v2/stocks/trades` | Trade ticks for one or more symbols |
| `getQuotes` | `GET /v2/stocks/quotes` | NBBO quote ticks for one or more symbols |

Supports `feed` (iex / sip / boats / overnight), `adjustment` (raw / split / dividend / all), and full pagination via `page_token`.

#### Options (`HistoricalOptionClient`) — `https://data.alpaca.markets/v1beta1/options/`

| Method | Endpoint | Description |
|---|---|---|
| `getBars` | `GET /v1beta1/options/bars` | OHLCV bars for one or more OCC contract symbols |
| `getTrades` | `GET /v1beta1/options/trades` | Trade ticks for one or more OCC contract symbols |
| `getQuotes` | `GET /v1beta1/options/quotes` | Quote ticks for one or more OCC contract symbols |

The options endpoints do not accept a `feed` query parameter; data access is controlled by your Alpaca subscription.

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

### Streaming market data

```zig
const alpaca = @import("alpaca-trade-api");

var feed = alpaca.AlpacaClient.init(allocator);
defer feed.deinit();

try feed.connect("wss://stream.data.alpaca.markets/v2/iex");
try feed.authenticate(api_key, api_secret);

var channels = [_][]const u8{"trades"};
var symbols  = [_][]const u8{"AAPL", "TSLA"};
try feed.subscribe(&channels, &symbols);

while (feed.isConnected()) {
    const msg = try feed.readMessage() orelse break;
    defer allocator.free(msg);
    // msg is the raw JSON frame from Alpaca
}
```

### Placing an order

```zig
const alpaca = @import("alpaca-trade-api");

var orders = alpaca.OrderClient.init(allocator, api_key, api_secret);
defer orders.deinit();

const response = try orders.submitOrder(alpaca.OrderRequest.market("AAPL", 1, .buy));
defer allocator.free(response);
// response is the raw JSON order object returned by Alpaca
```

### Historical stock data

All `get*` methods return caller-owned raw JSON bytes. Parse with
`std.json.parseFromSlice`; the top-level object contains a map keyed by symbol
and a `"next_page_token"` field for pagination.

```zig
const alpaca = @import("alpaca-trade-api");

var stocks = alpaca.HistoricalStockClient.init(allocator, api_key, api_secret);
defer stocks.deinit();

// --- Bars ---
const symbols = [_][]const u8{ "AAPL", "MSFT" };
const bars_json = try stocks.getBars(.{
    .symbols    = &symbols,
    .timeframe  = .@"1Day",
    .start      = "2024-01-02",
    .end        = "2024-01-05",
    .feed       = .iex,
    .adjustment = .split,
});
defer allocator.free(bars_json);

// Parse into a dynamic JSON value and iterate over symbols
const root = try std.json.parseFromSlice(std.json.Value, allocator, bars_json, .{});
defer root.deinit();

var it = root.value.object.get("bars").?.object.iterator();
while (it.next()) |entry| {
    for (entry.value_ptr.*.array.items) |bar_val| {
        const bar = try std.json.parseFromValue(alpaca.Bar, allocator, bar_val, .{});
        defer bar.deinit();
        // bar.value.t, .o, .h, .l, .c, .v, .n, .vw
    }
}

// --- Trades ---
const trade_symbols = [_][]const u8{"AAPL"};
const trades_json = try stocks.getTrades(.{
    .symbols = &trade_symbols,
    .start   = "2024-01-02T14:30:00Z",
    .end     = "2024-01-02T14:31:00Z",
    .limit   = 100,
});
defer allocator.free(trades_json);

// --- Quotes ---
const quotes_json = try stocks.getQuotes(.{
    .symbols = &trade_symbols,
    .start   = "2024-01-02T14:30:00Z",
    .end     = "2024-01-02T14:31:00Z",
    .limit   = 100,
});
defer allocator.free(quotes_json);
```

### Historical options data

Option symbols follow OCC format: `AAPL240315C00185000`
(underlying + YYMMDD expiry + C/P + 8-digit strike × 1000).

```zig
var options = alpaca.HistoricalOptionClient.init(allocator, api_key, api_secret);
defer options.deinit();

const symbols = [_][]const u8{"AAPL240315C00185000"};
const bars_json = try options.getBars(.{
    .symbols   = &symbols,
    .timeframe = .@"1Day",
    .start     = "2024-01-02",
    .end       = "2024-01-05",
});
defer allocator.free(bars_json);
```

Available timeframes: `1Min`, `5Min`, `15Min`, `30Min`, `1Hour`, `4Hour`, `1Day`, `1Week`, `1Month`.

## Building and testing

```sh
zig build           # compile library and all examples
zig build test      # run all unit tests
zig build examples  # build and run all examples
```

## Dependencies

- [websocket.zig](https://github.com/karlseguin/websocket.zig) — WebSocket client (streaming only)
