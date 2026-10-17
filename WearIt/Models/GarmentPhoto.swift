import Foundation

/// A photo's angle is independent of whether it is used as the wardrobe cover.
enum GarmentPhotoRole: String, Codable, CaseIterable, Identifiable {
    case other, front, back, side, inside, sole, detail, label, onBody, clasp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .other: return String(localized: "garment_photo_role_other")
        case .front: return String(localized: "garment_photo_role_front")
        case .back: return String(localized: "garment_photo_role_back")
        case .side: return String(localized: "garment_photo_role_side")
        case .inside: return String(localized: "garment_photo_role_inside")
        case .sole: return String(localized: "garment_photo_role_sole")
        case .detail: return String(localized: "garment_photo_role_detail")
        case .label: return String(localized: "garment_photo_role_label")
        case .onBody: return String(localized: "garment_photo_role_on_body")
        case .clasp: return String(localized: "garment_photo_role_clasp")
        }
    }

    static func choices(category: Category, itemType: ItemType?) -> [Self] {
        var roles: [Self] = [.front, .back]
        switch category {
        case .shoes:
            roles += [.side, .sole, .inside]
        case .outer:
            roles += [.inside]
        case .accessory:
            switch itemType {
            case .bag: roles += [.side, .inside]
            case .hat, .cap: roles += [.side, .inside]
            case .sunglasses: roles += [.side]
            case .watch, .belt, .jewelry: roles += [.clasp]
            default: break
            }
        case .top, .bottom:
            break
        }
        return roles + [.detail, .label, .onBody, .other]
    }
}

struct GarmentPhotoMetadata: Codable {
    /// Unknown roles from a newer app must not discard the other photos' source paths.
    var roleRaw: String
    var originalPath: String?
    var thumbnailPath: String?

    var role: GarmentPhotoRole {
        get { GarmentPhotoRole(rawValue: roleRaw) ?? .other }
        set { roleRaw = newValue.rawValue }
    }

    init(role: GarmentPhotoRole = .other, originalPath: String? = nil, thumbnailPath: String? = nil) {
        roleRaw = role.rawValue
        self.originalPath = originalPath
        self.thumbnailPath = thumbnailPath
    }
}

extension Garment {
    /// Existing photos need no migration, and paths retain stable UI identities.
    var galleryPhotoPaths: [String] {
        var seen = Set<String>()
        return ([imagePath].compactMap { $0 } + (additionalImagePaths ?? []))
            .filter { seen.insert($0).inserted }
    }

    var photoMetadata: [String: GarmentPhotoMetadata] {
        get {
            guard let data = photoMetadataRaw?.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode([String: GarmentPhotoMetadata].self, from: data)
            else { return [:] }
            return metadata
        }
        set {
            guard !newValue.isEmpty else { photoMetadataRaw = nil; return }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            photoMetadataRaw = String(data: data, encoding: .utf8)
        }
    }

    func photoInfo(for path: String) -> GarmentPhotoMetadata {
        var info = photoMetadata[path] ?? GarmentPhotoMetadata()
        if path == imagePath {
            info.originalPath = originalImagePath ?? info.originalPath
            info.thumbnailPath = thumbnailPath ?? info.thumbnailPath
        }
        return info
    }

    func setPhotoInfo(_ info: GarmentPhotoMetadata, for path: String) {
        var metadata = photoMetadata
        metadata[path] = info
        photoMetadata = metadata
    }

    /// Capture the legacy cover's source before it becomes an additional photo.
    func rememberPrimaryPhoto() {
        guard let path = imagePath else { return }
        setPhotoInfo(photoInfo(for: path), for: path)
    }

    var allPhotoFilePaths: Set<String> {
        var paths = Set(galleryPhotoPaths)
        for path in [originalImagePath, thumbnailPath].compactMap({ $0 }) { paths.insert(path) }
        for info in photoMetadata.values {
            for path in [info.originalPath, info.thumbnailPath].compactMap({ $0 }) { paths.insert(path) }
        }
        return paths
    }
}
