import Foundation

/// A CIDR block, parsed far enough to answer "do these two overlap?".
///
/// The TUN inbound keeps the private ranges off the tunnel, which is right
/// until a rule sends one address inside such a range through a tunnel
/// outbound — a WireGuard peer reaching a private network, say. Those packets
/// never reach the core at all, so the rule reads as broken. Deciding that
/// needs the ranges compared, not string-matched: `172.16.4.0/24` and
/// `172.16.0.0/12` are the same conflict spelled two ways.
struct IPRange: Equatable {

    /// Network address, big-endian, as a plain integer.
    let network: UInt32
    /// Prefix length in bits.
    let prefix: UInt8

    /// Parses `a.b.c.d/len`, or a bare `a.b.c.d` (treated as `/32`).
    /// IPv6 and anything else returns nil: the callers only reason about v4,
    /// and a wrong answer there is worse than no answer.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(":") else { return nil }
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        guard let address = IPRange.address(String(parts[0])) else { return nil }
        var length: UInt8 = 32
        if parts.count == 2 {
            guard let value = UInt8(parts[1]), value <= 32 else { return nil }
            length = value
        }
        prefix = length
        network = address & IPRange.mask(length)
    }

    /// True when the two blocks share at least one address — which, for CIDR,
    /// means one contains the other.
    func overlaps(_ other: IPRange) -> Bool {
        let shared = IPRange.mask(min(prefix, other.prefix))
        return network & shared == other.network & shared
    }

    /// True when every address of `other` is inside this block.
    func contains(_ other: IPRange) -> Bool {
        prefix <= other.prefix && overlaps(other)
    }

    private init(network: UInt32, prefix: UInt8) {
        self.network = network & IPRange.mask(prefix)
        self.prefix = prefix
    }

    /// `a.b.c.d/len`.
    var cidr: String {
        let octets = [24, 16, 8, 0].map { String((network >> UInt32($0)) & 0xff) }
        return octets.joined(separator: ".") + "/\(prefix)"
    }

    /// This block with `hole` cut out, as the fewest CIDR blocks that cover
    /// the rest. A hole that does not overlap leaves the block whole; one that
    /// covers it leaves nothing.
    func subtracting(_ hole: IPRange) -> [IPRange] {
        guard overlaps(hole) else { return [self] }
        guard prefix < hole.prefix else { return [] }
        // Walk down from this block to the hole, keeping at each step the
        // half the hole is not in.
        var result: [IPRange] = []
        var current = self
        while current.prefix < hole.prefix {
            let next = current.prefix + 1
            let bit = UInt32(1) << (32 - UInt32(next))
            let low = IPRange(network: current.network, prefix: next)
            let high = IPRange(network: current.network | bit, prefix: next)
            if low.overlaps(hole) {
                result.append(high)
                current = low
            } else {
                result.append(low)
                current = high
            }
        }
        return result
    }

    private static func mask(_ length: UInt8) -> UInt32 {
        length == 0 ? 0 : UInt32.max << (32 - UInt32(length))
    }

    private static func address(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
