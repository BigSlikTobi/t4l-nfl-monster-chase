import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Compile with the app's CardPhotoCrop and ScanCardFrame sources. Write only
// derived crops to a new private directory. The input photos stay read-only.
guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("Usage: rectify NEW_OUTPUT_DIR FRONT_IMAGE ...\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])

func rectify(_ source: URL) -> Bool {
    let destination = output.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".jpg")
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1200
    ]
    guard !FileManager.default.fileExists(atPath: destination.path),
          let file = CGImageSourceCreateWithURL(source as CFURL, nil),
          let front = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary),
          let card = CardPhotoCrop.crop(front),
          let encoder = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(encoder, card, nil)
    return CGImageDestinationFinalize(encoder)
}

var skipped = 0
for path in CommandLine.arguments.dropFirst(2) {
    if !autoreleasepool(invoking: { rectify(URL(fileURLWithPath: path)) }) {
        skipped += 1
        FileHandle.standardError.write(Data("No crop for \(URL(fileURLWithPath: path).lastPathComponent)\n".utf8))
    }
}
if skipped > 0 { exit(1) }
