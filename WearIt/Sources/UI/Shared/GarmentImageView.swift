//
//  GarmentImageView.swift
//  WearIt
//
//  Displays a garment image from local path/data, with optional remote URL support.
//

import SwiftUI

struct GarmentImageView: View {
    let garment: Garment
    var cornerRadius: CGFloat = 12
    var height: CGFloat = 110
    var padding: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(.secondarySystemBackground))
            .overlay { contentImage }
            .frame(height: height)
            .task(id: garment.imagePath) {
                guard let path = garment.imagePath else { return }
                if !ImageStore.fileExists(path: path) {
                    CloudKitImageSyncService.shared.ensureLocalMainImage(
                        garmentID: garment.id,
                        imagePath: path,
                        thumbnailPath: garment.thumbnailPath,
                        updateThumbnail: { newPath in
                            if let newPath {
                                garment.thumbnailPath = newPath
                            }
                        }
                    )
                }
            }
    }

    @ViewBuilder
    private var contentImage: some View {
        if let ui = garment.resolvedImage {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .padding(padding)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "tshirt")
            .resizable()
            .scaledToFit()
            .padding(padding + 6)
            .foregroundStyle(.secondary)
    }
}


