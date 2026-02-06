//
//  ImageEditingService.swift
//  WearIt
//
//  Single source of truth for image picking, cropping, and saving.
//  Used by both AddGarmentView and EditGarmentView for consistent behavior.

import SwiftUI
import UIKit

// MARK: - Image Editing Result

struct ImageEditingResult {
    let image: UIImage
    let imagePath: String?
    let thumbnailPath: String?
    let originalPath: String?
    
    /// Convenience: the edited image as JPEG data
    var jpegData: Data? {
        image.jpegData(compressionQuality: 0.9)
    }
}

// MARK: - Image Editing Service

@MainActor
final class ImageEditingService: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isShowingCamera = false
    @Published var isShowingPhotoLibrary = false
    @Published var isProcessing = false
    @Published var errorMessage: String?
    
    // MARK: - Callbacks
    
    private var onImageSelected: ((ImageEditingResult) -> Void)?
    
    // MARK: - Public API
    
    /// Start the image selection flow with camera
    func selectFromCamera(completion: @escaping (ImageEditingResult) -> Void) {
        onImageSelected = completion
        updateIfChanged(&isShowingCamera, true)
    }
    
    /// Start the image selection flow with photo library
    func selectFromLibrary(completion: @escaping (ImageEditingResult) -> Void) {
        onImageSelected = completion
        updateIfChanged(&isShowingPhotoLibrary, true)
    }
    
    /// Handle the selected image (called from picker wrappers)
    func handleSelectedImage(_ image: UIImage) {
        updateIfChanged(&isProcessing, true)
        
        // Save the edited image
        var imagePath: String?
        if let jpeg = image.jpegData(compressionQuality: 0.9) {
            imagePath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
        }
        let thumbnailPath = imagePath.flatMap {
            ImageStore.generateAndSaveThumbnail(for: $0, maxPixelSize: ImageStore.thumbnailMaxPixelSize)
        }
        
        let result = ImageEditingResult(
            image: image,
            imagePath: imagePath,
            thumbnailPath: thumbnailPath,
            originalPath: nil
        )
        
        updateIfChanged(&isProcessing, false)
        onImageSelected?(result)
        onImageSelected = nil
    }
    
    /// Handle image selection with original preservation (for AI reprocessing later)
    func handleSelectedImageWithOriginal(_ editedImage: UIImage, original: UIImage?) {
        updateIfChanged(&isProcessing, true)
        
        // Save the edited image
        var imagePath: String?
        if let jpeg = editedImage.jpegData(compressionQuality: 0.9) {
            imagePath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
        }
        let thumbnailPath = imagePath.flatMap {
            ImageStore.generateAndSaveThumbnail(for: $0, maxPixelSize: ImageStore.thumbnailMaxPixelSize)
        }
        
        // Save original if provided
        var originalPath: String?
        if let original, let jpeg = original.jpegData(compressionQuality: 0.8) {
            originalPath = try? ImageStore.save(data: jpeg, preferredExt: "jpg")
        }
        
        let result = ImageEditingResult(
            image: editedImage,
            imagePath: imagePath,
            thumbnailPath: thumbnailPath,
            originalPath: originalPath
        )
        
        updateIfChanged(&isProcessing, false)
        onImageSelected?(result)
        onImageSelected = nil
    }
    
    /// Clear any error message
    func clearError() {
        updateIfChanged(&errorMessage, nil)
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T, _ newValue: T) {
        if target != newValue {
            target = newValue
        }
    }

    private func updateIfChanged<T: Equatable>(_ target: inout T?, _ newValue: T?) {
        if target != newValue {
            target = newValue
        }
    }
}

// MARK: - Image Editing View Modifier

/// Attach this modifier to any view that needs image picking capability
struct ImageEditingModifier: ViewModifier {
    @ObservedObject var service: ImageEditingService
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $service.isShowingPhotoLibrary) {
                PhotoLibraryPickerWrapper { image in
                    service.handleSelectedImage(image)
                }
            }
            .sheet(isPresented: $service.isShowingCamera) {
                CameraPickerWrapper { image in
                    service.handleSelectedImage(image)
                }
            }
            .alert("Error", isPresented: .init(
                get: { service.errorMessage != nil },
                set: { if !$0 { service.clearError() } }
            )) {
                Button("OK") { service.clearError() }
            } message: {
                Text(service.errorMessage ?? "Something went wrong.")
            }
    }
}

extension View {
    /// Adds image editing capability to a view
    func imageEditing(service: ImageEditingService) -> some View {
        modifier(ImageEditingModifier(service: service))
    }
}
