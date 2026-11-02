import Foundation

/// How the server list measures latency.
///
/// The direct modes time a connection to the server itself, which says the
/// host is up and how far away it is. The proxy modes send a real request
/// through the node and time the answer — the only number that says the node
/// actually carries traffic, and the one other clients call "real delay".
enum PingMode: String, Codable, CaseIterable, Identifiable {
    /// TCP connect for TCP protocols, a QUIC handshake for Hysteria2/TUIC,
    /// ICMP for WireGuard.
    case tcp
    /// ICMP echo to every server.
    case icmp
    /// HEAD request to the test URL through the node.
    case proxyHead
    /// GET request to the test URL through the node.
    case proxyGet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tcp:       return "TCP"
        case .icmp:      return "ICMP"
        case .proxyHead: return "Proxy HEAD"
        case .proxyGet:  return "Proxy GET"
        }
    }

    var detail: String {
        switch self {
        case .tcp:       return "Time to open a connection to the server"
        case .icmp:      return "Round trip of an ICMP echo to the server"
        case .proxyHead: return "Time for a HEAD request through the server"
        case .proxyGet:  return "Time for a GET request through the server"
        }
    }

    /// Whether this mode sends a request through the node.
    var usesProxy: Bool { self == .proxyHead || self == .proxyGet }

    var httpMethod: String { self == .proxyHead ? "HEAD" : "GET" }

    static let defaultURL = "https://www.gstatic.com/generate_204"
}
