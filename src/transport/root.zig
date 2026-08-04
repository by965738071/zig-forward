pub const tcp = @import("tcp.zig");
pub const ws_client = @import("ws_client.zig");
// 直接 re-export 传输层接口类型，避免调用方写 `transport.tcp.AClient`
pub const AClient = tcp.AClient;
pub const CSender = tcp.CSender;
pub const TcpConn = tcp.TcpConn;
pub const WsConn = ws_client.WsConn;
