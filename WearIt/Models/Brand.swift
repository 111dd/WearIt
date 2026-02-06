import Foundation
import SwiftData

@Model
final class Brand {
    var name: String = ""
    var normalizedKey: String?
    var createdAt: Date = Foundation.Date()

    init(name: String, normalizedKey: String? = nil, createdAt: Date? = nil) {
        self.name = name
        self.normalizedKey = normalizedKey
        self.createdAt = createdAt ?? Foundation.Date()
    }

    init() {
        self.name = ""
        self.normalizedKey = nil
        self.createdAt = Foundation.Date()
    }
}
