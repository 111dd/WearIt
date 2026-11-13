import UIKit

enum LookShareFormat: String, CaseIterable, Identifiable, Sendable {
    case post, story

    var id: String { rawValue }

    var title: String {
        switch self {
        case .post: return String(localized: "look_share_format_post")
        case .story: return String(localized: "look_share_format_story")
        }
    }

    var size: CGSize {
        CGSize(width: 1080, height: self == .post ? 1350 : 1920)
    }
}

/// Serial pixel-only rendering. Requests contain value snapshots, never live models.
/// Only the processed post photo and explicitly selected text reach the share image.
actor LookShareRenderer {
    static let shared = LookShareRenderer()

    struct Request: Hashable, Sendable {
        let photoPath: String
        let format: LookShareFormat
        let identity: [String]
        let caption: String?
        let tags: [String]
        let isRightToLeft: Bool
        let subtitle: String
        let tagsTitle: String
    }

    func render(_ request: Request) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let photo = ImageStore.loadThumbnail(path: request.photoPath, maxPixelSize: 1350),
                  photo.size.width > 0, photo.size.height > 0, !Task.isCancelled else { return nil }

            let size = request.format.size
            let inset: CGFloat = 48
            let width = size.width - inset * 2
            let caption = request.caption.map {
                TextBlock(text: $0, size: 32, weight: .medium, maxLines: 3,
                          rightToLeft: request.isRightToLeft)
            }
            let tags = request.tags.isEmpty ? nil : TextBlock(
                text: request.tags.joined(separator: "   ·   "), size: 28, weight: .regular,
                maxLines: 5, rightToLeft: request.isRightToLeft
            )
            let captionHeight = caption?.height(width: width) ?? 0
            let tagsHeight = tags?.height(width: width) ?? 0
            let captionGap: CGFloat = caption == nil ? 0 : 20
            let tagsHeadingHeight: CGFloat = tags == nil ? 0 : 46
            let footerHeight = captionHeight + captionGap + tagsHeadingHeight + tagsHeight
            let identityHeight: CGFloat = request.identity.isEmpty ? 0 : 104
            let photoTop: CGFloat = 140 + identityHeight
            let availableHeight = size.height - photoTop - inset - footerHeight - 24
            let photoHeight = min(availableHeight, width * 5 / 4)
            let photoRect = CGRect(x: inset, y: photoTop + (availableHeight - photoHeight) / 2,
                                   width: width, height: photoHeight)

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { output in
                let canvas = UIColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1)
                canvas.setFill()
                output.fill(CGRect(origin: .zero, size: size))

                TextBlock(text: "WearIt", size: 46, weight: .semibold, maxLines: 1,
                          rightToLeft: false).draw(
                    in: CGRect(x: inset, y: 50, width: 300, height: 60)
                )
                TextBlock(text: request.subtitle, size: 28, weight: .medium, maxLines: 1,
                          rightToLeft: request.isRightToLeft, alignment: .right).draw(
                    in: CGRect(x: size.width - inset - 600, y: 65, width: 600, height: 42)
                )

                for (index, line) in request.identity.prefix(2).enumerated() {
                    TextBlock(text: line, size: index == 0 ? 34 : 26,
                              weight: index == 0 ? .semibold : .regular, maxLines: 1,
                              rightToLeft: line.hasPrefix("@") ? false : request.isRightToLeft,
                              alignment: request.isRightToLeft ? .right : .left).draw(
                        in: CGRect(x: inset, y: 128 + CGFloat(index) * 44, width: width, height: 44)
                    )
                }

                // Fit the entire saved photo; never undo its crop/face/background edits.
                let scale = min(photoRect.width / photo.size.width, photoRect.height / photo.size.height)
                let imageSize = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                let imageRect = CGRect(x: photoRect.midX - imageSize.width / 2,
                                       y: photoRect.midY - imageSize.height / 2,
                                       width: imageSize.width, height: imageSize.height)
                output.cgContext.saveGState()
                UIBezierPath(roundedRect: imageRect, cornerRadius: 24).addClip()
                photo.draw(in: imageRect)
                output.cgContext.restoreGState()

                var y = photoRect.maxY + 24
                if let caption {
                    caption.draw(in: CGRect(x: inset, y: y, width: width, height: captionHeight))
                    y += captionHeight + captionGap
                }
                if let tags {
                    TextBlock(text: request.tagsTitle, size: 26, weight: .semibold, maxLines: 1,
                              rightToLeft: request.isRightToLeft).draw(
                        in: CGRect(x: inset, y: y, width: width, height: 38)
                    )
                    tags.draw(in: CGRect(x: inset, y: y + tagsHeadingHeight, width: width, height: tagsHeight))
                }
            }
            return Task.isCancelled ? nil : image
        }
    }

    private struct TextBlock {
        let text: String
        let size: CGFloat
        let weight: UIFont.Weight
        let maxLines: Int
        let rightToLeft: Bool
        var alignment: NSTextAlignment? = nil

        private var attributedText: NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            paragraph.alignment = alignment ?? (rightToLeft ? .right : .left)
            paragraph.lineSpacing = 6
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: UIColor(red: 0.10, green: 0.16, blue: 0.16, alpha: 1),
                .paragraphStyle: paragraph
            ])
        }

        func height(width: CGFloat) -> CGFloat {
            let bounds = attributedText.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            )
            let maximum = UIFont.systemFont(ofSize: size, weight: weight).lineHeight * CGFloat(maxLines)
                + CGFloat(maxLines - 1) * 6
            return ceil(min(bounds.height, maximum))
        }

        func draw(in rect: CGRect) {
            attributedText.draw(with: rect, options: [
                .usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine
            ], context: nil)
        }
    }
}
