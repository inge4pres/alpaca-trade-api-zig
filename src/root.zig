pub const types = @import("types.zig");
pub const client = @import("client.zig");
pub const order_client = @import("order_client.zig");

// WebSocket market data client
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

test {
    _ = @import("types.zig");
    _ = @import("client.zig");
    _ = @import("order_client.zig");
}
