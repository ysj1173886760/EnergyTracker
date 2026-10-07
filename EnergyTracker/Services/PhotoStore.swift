import UIKit

enum PhotoStore {
    private static let cache = NSCache<NSString, UIImage>()

    private static var directory: URL {
        let url = URL.documentsDirectory.appending(path: "MealPhotos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(_ image: UIImage) throws -> String {
        let filename = UUID().uuidString + ".jpg"
        guard let data = image.resized(maxDimension: 1600).jpegData(compressionQuality: 0.8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appending(path: filename), options: .atomic)
        return filename
    }

    static func rawData(_ filename: String) -> Data? {
        try? Data(contentsOf: directory.appending(path: filename))
    }

    static func restore(_ data: Data, filename: String) throws {
        try data.write(to: directory.appending(path: filename), options: .atomic)
    }

    static func load(_ filename: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appending(path: filename).path())
    }

    static func thumbnail(_ filename: String, size: CGFloat = 160) -> UIImage? {
        let key = "\(filename)@\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = load(filename)?.resized(maxDimension: size * UIScreen.main.scale) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// JPEG sized for model upload: smaller payload, faster and cheaper inference.
    static func uploadData(_ filename: String) -> Data? {
        load(filename)?.resized(maxDimension: 1024).jpegData(compressionQuality: 0.75)
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: filename))
    }
}

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return normalizedOrientation() }
        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
