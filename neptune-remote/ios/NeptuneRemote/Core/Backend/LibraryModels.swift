import Foundation

// Mirrors raspberry-pi/app/library/models.py

struct LibraryGCode: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let itemID: String
    let filename: String
    let path: String
    let moonrakerPath: String?
    let material: String
    let quality: String
    let layerHeight: Double?
    let estimatedSeconds: Double?
    let filamentGrams: Double?
    let layerCount: Int?
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, filename, path, material, quality
        case itemID = "item_id"
        case moonrakerPath = "moonraker_path"
        case layerHeight = "layer_height"
        case estimatedSeconds = "estimated_seconds"
        case filamentGrams = "filament_g"
        case layerCount = "layer_count"
        case createdAt = "created_at"
    }
}

struct LibraryPhoto: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let itemID: String
    let path: String
    let caption: String
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, path, caption
        case itemID = "item_id"
        case createdAt = "created_at"
    }
}

/// One model in the library. This is what the app shows a *picture* of.
struct LibraryItem: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let nameAR: String
    let nameEN: String
    let aliases: [String]
    let tags: [String]
    let category: String
    let notes: String

    let thumbnail: String?
    let heroImage: String?

    let modelPath: String?
    let modelFilename: String
    let modelSize: Int

    let dimensionsX: Double?
    let dimensionsY: Double?
    let dimensionsZ: Double?
    let triangleCount: Int?

    let recommendedMaterial: String
    let estimatedSeconds: Double?
    let estimatedFilamentGrams: Double?

    let favourite: Bool
    let printCount: Int
    let lastPrinted: Double?
    let isProduct: Bool

    let createdAt: Double
    let updatedAt: Double

    let gcodes: [LibraryGCode]
    let photos: [LibraryPhoto]
    let collections: [String]

    enum CodingKeys: String, CodingKey {
        case id, aliases, tags, category, notes, thumbnail, favourite
        case gcodes, photos, collections
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case heroImage = "hero_image"
        case modelPath = "model_path"
        case modelFilename = "model_filename"
        case modelSize = "model_size"
        case dimensionsX = "dimensions_x"
        case dimensionsY = "dimensions_y"
        case dimensionsZ = "dimensions_z"
        case triangleCount = "triangle_count"
        case recommendedMaterial = "recommended_material"
        case estimatedSeconds = "estimated_seconds"
        case estimatedFilamentGrams = "estimated_filament_g"
        case printCount = "print_count"
        case lastPrinted = "last_printed"
        case isProduct = "is_product"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        nameAR = try container.decodeIfPresent(String.self, forKey: .nameAR) ?? ""
        nameEN = try container.decodeIfPresent(String.self, forKey: .nameEN) ?? ""
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "other"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        heroImage = try container.decodeIfPresent(String.self, forKey: .heroImage)
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
        modelFilename = try container.decodeIfPresent(String.self, forKey: .modelFilename) ?? ""
        modelSize = try container.decodeIfPresent(Int.self, forKey: .modelSize) ?? 0
        dimensionsX = try container.decodeIfPresent(Double.self, forKey: .dimensionsX)
        dimensionsY = try container.decodeIfPresent(Double.self, forKey: .dimensionsY)
        dimensionsZ = try container.decodeIfPresent(Double.self, forKey: .dimensionsZ)
        triangleCount = try container.decodeIfPresent(Int.self, forKey: .triangleCount)
        recommendedMaterial = try container.decodeIfPresent(String.self, forKey: .recommendedMaterial) ?? ""
        estimatedSeconds = try container.decodeIfPresent(Double.self, forKey: .estimatedSeconds)
        estimatedFilamentGrams = try container.decodeIfPresent(Double.self, forKey: .estimatedFilamentGrams)
        favourite = try container.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        printCount = try container.decodeIfPresent(Int.self, forKey: .printCount) ?? 0
        lastPrinted = try container.decodeIfPresent(Double.self, forKey: .lastPrinted)
        isProduct = try container.decodeIfPresent(Bool.self, forKey: .isProduct) ?? false
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        gcodes = try container.decodeIfPresent([LibraryGCode].self, forKey: .gcodes) ?? []
        photos = try container.decodeIfPresent([LibraryPhoto].self, forKey: .photos) ?? []
        collections = try container.decodeIfPresent([String].self, forKey: .collections) ?? []
    }

    init(
        id: String,
        nameAR: String = "",
        nameEN: String = "",
        aliases: [String] = [],
        tags: [String] = [],
        category: String = "other",
        notes: String = "",
        thumbnail: String? = nil,
        heroImage: String? = nil,
        modelPath: String? = nil,
        modelFilename: String = "",
        modelSize: Int = 0,
        dimensionsX: Double? = nil,
        dimensionsY: Double? = nil,
        dimensionsZ: Double? = nil,
        triangleCount: Int? = nil,
        recommendedMaterial: String = "",
        estimatedSeconds: Double? = nil,
        estimatedFilamentGrams: Double? = nil,
        favourite: Bool = false,
        printCount: Int = 0,
        lastPrinted: Double? = nil,
        isProduct: Bool = false,
        createdAt: Double = 0,
        updatedAt: Double = 0,
        gcodes: [LibraryGCode] = [],
        photos: [LibraryPhoto] = [],
        collections: [String] = []
    ) {
        self.id = id
        self.nameAR = nameAR
        self.nameEN = nameEN
        self.aliases = aliases
        self.tags = tags
        self.category = category
        self.notes = notes
        self.thumbnail = thumbnail
        self.heroImage = heroImage
        self.modelPath = modelPath
        self.modelFilename = modelFilename
        self.modelSize = modelSize
        self.dimensionsX = dimensionsX
        self.dimensionsY = dimensionsY
        self.dimensionsZ = dimensionsZ
        self.triangleCount = triangleCount
        self.recommendedMaterial = recommendedMaterial
        self.estimatedSeconds = estimatedSeconds
        self.estimatedFilamentGrams = estimatedFilamentGrams
        self.favourite = favourite
        self.printCount = printCount
        self.lastPrinted = lastPrinted
        self.isProduct = isProduct
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.gcodes = gcodes
        self.photos = photos
        self.collections = collections
    }

    /// The name to show. Arabic first, exactly as the product brief asks.
    var displayName: String {
        if !nameAR.isEmpty { return nameAR }
        if !nameEN.isEmpty { return nameEN }
        return modelFilename.isEmpty ? id : modelFilename
    }

    var secondaryName: String? {
        guard !nameAR.isEmpty, !nameEN.isEmpty else { return nil }
        return nameEN
    }

    var dimensionsDescription: String? {
        guard let x = dimensionsX, let y = dimensionsY, let z = dimensionsZ else { return nil }
        return String(format: "%.0f × %.0f × %.0f mm", x, y, z)
    }

    var latestGCode: LibraryGCode? { gcodes.first }
}

struct LibraryCollection: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let nameAR: String
    let nameEN: String
    let builtin: Bool
    let icon: String
    let itemCount: Int

    var displayName: String { nameAR.isEmpty ? nameEN : nameAR }

    enum CodingKeys: String, CodingKey {
        case id, builtin, icon
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case itemCount = "item_count"
    }
}

struct LibraryCategory: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let nameAR: String
    let nameEN: String
    let icon: String
    let itemCount: Int

    var displayName: String { nameAR.isEmpty ? nameEN : nameAR }

    enum CodingKeys: String, CodingKey {
        case id, icon
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case itemCount = "item_count"
    }
}

struct SearchResultEntry: Decodable, Identifiable, Equatable {
    let item: LibraryItem
    let score: Double
    let reasons: [String]

    var id: String { item.id }
}

struct SearchResponse: Decodable, Equatable {
    let query: String
    let normalizedQuery: String
    let results: [SearchResultEntry]
    let total: Int
    let suggestions: [String]

    enum CodingKeys: String, CodingKey {
        case query, results, total, suggestions
        case normalizedQuery = "normalized_query"
    }

    static let empty = SearchResponse(
        query: "", normalizedQuery: "", results: [], total: 0, suggestions: []
    )
}

struct LibraryItemUpdatePayload: Encodable {
    var nameAR: String?
    var nameEN: String?
    var aliases: [String]?
    var tags: [String]?
    var category: String?
    var notes: String?
    var recommendedMaterial: String?
    var favourite: Bool?
    var isProduct: Bool?

    enum CodingKeys: String, CodingKey {
        case aliases, tags, category, notes, favourite
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case recommendedMaterial = "recommended_material"
        case isProduct = "is_product"
    }
}

struct IdeaRequestPayload: Encodable {
    var room: String?
    var maxSeconds: Double?
    var material: String?
    var limit: Int = 12

    enum CodingKeys: String, CodingKey {
        case room, material, limit
        case maxSeconds = "max_seconds"
    }
}

struct PrintRatingPayload: Encodable {
    let historyID: Int
    let itemID: String?
    let rating: String          // excellent | good | problem
    let profile: [String: String]
    let note: String

    enum CodingKeys: String, CodingKey {
        case rating, profile, note
        case historyID = "history_id"
        case itemID = "item_id"
    }
}

/// Categories the app knows about, with their SF Symbols.
enum LibraryCategoryCatalog {
    static let icons: [String: String] = [
        "office": "briefcase.fill",
        "home": "house.fill",
        "kitchen": "fork.knife",
        "toys": "gamecontroller.fill",
        "robotics": "cpu.fill",
        "electronics": "bolt.circle.fill",
        "keychains": "key.fill",
        "stands": "iphone.gen3",
        "organizers": "tray.2.fill",
        "decor": "sparkles",
        "spare_parts": "wrench.and.screwdriver.fill",
        "projects": "lightbulb.fill",
        "other": "square.grid.2x2.fill"
    ]

    static func icon(for category: String) -> String {
        icons[category] ?? "square.grid.2x2.fill"
    }

    /// Rooms offered by the "أفكار للطباعة" finder.
    static let ideaRooms: [(id: String, labelKey: String, icon: String)] = [
        ("desk", "ideas.room.desk", "briefcase"),
        ("car", "ideas.room.car", "car"),
        ("kitchen", "ideas.room.kitchen", "fork.knife"),
        ("room", "ideas.room.room", "house"),
        ("phone", "ideas.room.phone", "iphone"),
        ("computer", "ideas.room.computer", "desktopcomputer"),
        ("robotics", "ideas.room.robotics", "cpu"),
        ("organization", "ideas.room.organization", "tray.2"),
        ("gifts", "ideas.room.gifts", "gift"),
        ("projects", "ideas.room.projects", "lightbulb"),
        ("spare_parts", "ideas.room.spare_parts", "wrench.and.screwdriver")
    ]
}
