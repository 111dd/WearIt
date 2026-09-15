import Foundation

/// Pluggable handlers for product-page / DPID URLs that need more than HTML scrape.
protocol ProductURLResolver {
    static func canHandle(_ url: URL) -> Bool
    static func fetch(from url: URL) async throws -> BarcodeProduct
}

enum ProductURLResolverRegistry {
    /// Order matters — first match wins. Digimarc/RL before generic scrape.
    static let resolvers: [ProductURLResolver.Type] = [
        DigimarcProductIDService.self
    ]

    static func resolver(for url: URL) -> ProductURLResolver.Type? {
        resolvers.first { $0.canHandle(url) }
    }
}
