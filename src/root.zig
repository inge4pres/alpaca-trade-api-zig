pub const types = @import("types.zig");
pub const client = @import("client.zig");
pub const order_client = @import("order_client.zig");
pub const historical_client = @import("historical_client.zig");

/// WebSocket market data client
pub const AlpacaClient = client.TradingWebSocketClient;

// Market data message types
pub const AlpacaMessage = types.AlpacaMessage;
pub const AlpacaTrade = types.AlpacaTrade;
pub const AlpacaQuote = types.AlpacaQuote;
pub const AlpacaControl = types.AlpacaControl;
pub const ConnectionState = types.ConnectionState;

// Order types and HTTP client
pub const OrderClient = order_client.OrderClient;
pub const OrderRequest = order_client.OrderRequest;
pub const OrderSide = order_client.OrderSide;
pub const OrderType = order_client.OrderType;
pub const TimeInForce = order_client.TimeInForce;

// Historical market data clients
pub const HistoricalStockClient = historical_client.HistoricalStockClient;
pub const HistoricalOptionClient = historical_client.HistoricalOptionClient;

// Historical data types
pub const Bar = historical_client.Bar;
pub const HistoricalTrade = historical_client.HistoricalTrade;
pub const HistoricalQuote = historical_client.HistoricalQuote;
pub const Timeframe = historical_client.Timeframe;
pub const Adjustment = historical_client.Adjustment;
pub const StockFeed = historical_client.StockFeed;
pub const OptionFeed = historical_client.OptionFeed;
pub const Sort = historical_client.Sort;

// Historical data request parameter types
pub const StockBarsParams = historical_client.StockBarsParams;
pub const StockTradesParams = historical_client.StockTradesParams;
pub const StockQuotesParams = historical_client.StockQuotesParams;
pub const OptionBarsParams = historical_client.OptionBarsParams;
pub const OptionTradesParams = historical_client.OptionTradesParams;
pub const OptionQuotesParams = historical_client.OptionQuotesParams;

test {
    _ = @import("types.zig");
    _ = @import("client.zig");
    _ = @import("order_client.zig");
    _ = @import("historical_client.zig");
}
