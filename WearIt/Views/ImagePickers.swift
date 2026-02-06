import SwiftUI
import PhotosUI

// MARK: - Camera Picker with Built-in Editing

/// Camera picker using UIImagePickerController with Apple's built-in crop/edit UI.
struct CameraPickerWrapper: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = true  // Enable Apple's built-in crop UI
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
            // Prefer edited image (cropped), fallback to original
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
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

/// Photo library picker using UIImagePickerController with Apple's built-in crop/edit UI.
/// Note: We use UIImagePickerController instead of PHPickerViewController because
/// PHPicker doesn't support built-in editing. For MVP stability, native editing wins.
struct PhotoLibraryPickerWrapper: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true  // Enable Apple's built-in crop UI
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
            // Prefer edited image (cropped), fallback to original
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let image {
                parent.onImagePicked(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
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
