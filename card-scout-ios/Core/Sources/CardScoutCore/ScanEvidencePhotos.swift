import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic transport derivatives. Full-resolution originals remain on the device.
public enum ScanEvidencePhotos {
    public static func front(_ data: Data, fast: Bool) -> Data {
        guard fast, let image = thumbnail(data, maximum: 1800) else { return data }
        return jpeg(image, quality: 0.86) ?? data
    }

    public static func surface(_ data: Data) -> Data? {
        guard let front = thumbnail(data, maximum: 1200), let crop = CardPhotoCrop.crop(front) else { return nil }
        return jpeg(crop, quality: 0.91)
    }

    public static func angle(_ data: Data) -> Data? {
        guard let image = thumbnail(data, maximum: 1400) else { return nil }
        return jpeg(image, quality: 0.86)
    }

    private static func thumbnail(_ data: Data, maximum: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ] as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(writer) ? bytes as Data : nil
    }
}
