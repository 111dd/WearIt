import SwiftUI
import PhotosUI

// MARK: - Camera Picker with Built-in Editing

/// Camera picker. Cropping is handled by `ImageCropperView` after capture.
struct CameraPickerWrapper: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerWrapper

        init(_ parent: CameraPickerWrapper) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
            if let image {
                parent.onImagePicked(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Photo Library Picker with Built-in Editing

/// Photo library picker. Cropping is handled by `ImageCropperView` after selection.
struct PhotoLibraryPickerWrapper: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhotoLibraryPickerWrapper

        init(_ parent: PhotoLibraryPickerWrapper) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
            if let image {
                parent.onImagePicked(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Multi-Selection Photo Picker (Batch Upload)

/// PHPicker allowing multiple selections for batch garment upload.
/// Delivers all picked images at once, in selection order.
struct MultiPhotoPickerWrapper: UIViewControllerRepresentable {
    var selectionLimit: Int = 10
    var onImagesPicked: ([UIImage]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiPhotoPickerWrapper

        init(_ parent: MultiPhotoPickerWrapper) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            let providers = results.map(\.itemProvider)
            Task {
                var images: [UIImage?] = Array(repeating: nil, count: providers.count)
                await withTaskGroup(of: (Int, UIImage?).self) { group in
                    for (index, provider) in providers.enumerated() {
                        group.addTask {
                            await withCheckedContinuation { continuation in
                                guard provider.canLoadObject(ofClass: UIImage.self) else {
                                    continuation.resume(returning: (index, nil))
                                    return
                                }
                                provider.loadObject(ofClass: UIImage.self) { image, _ in
                                    continuation.resume(returning: (index, image as? UIImage))
                                }
                            }
                        }
                    }
                    for await (index, image) in group {
                        images[index] = image
                    }
                }
                let loaded = images.compactMap { $0 }
                guard !loaded.isEmpty else { return }
                await MainActor.run {
                    self.parent.onImagesPicked(loaded)
                }
            }
        }
    }
}

// MARK: - PHPicker (No Editing - kept for reference)

/// PHPickerViewController wrapper. Does NOT include editing.
/// Use PhotoLibraryPickerWrapper instead if you need built-in crop.
struct PHPickerWrapper: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PHPickerWrapper

        init(_ parent: PHPickerWrapper) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                if let uiImage = image as? UIImage {
                    DispatchQueue.main.async {
                        self.parent.onImagePicked(uiImage)
                    }
                }
            }
        }
    }
}
