import Foundation
import CoreImage

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

/// QR-code generation and decoding helpers built on CoreImage.
enum QRCode {

    /// Renders `string` into a crisp QR-code image of roughly `size` points.
    static func image(from string: String, size: CGFloat = 240) -> PlatformImage? {
        guard let cg = cgImage(from: string, size: size) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    /// The raw CGImage behind `image(from:size:)`, handy when the caller wants
    /// the bitmap itself rather than a view-ready image.
    static func cgImage(from string: String, size: CGFloat = 240) -> CGImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // "H" = high error correction, robust when displayed/printed small.
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Scale the (small) generated image up to the requested point size.
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        return sharedContext.createCGImage(scaled, from: scaled.extent)
    }

    /// The code's modules, row by row, `true` for dark — for callers that draw
    /// the code themselves instead of scaling up a bitmap. The quiet zone the
    /// generator adds is trimmed off.
    ///
    /// - Parameter correction: "L", "M", "Q" or "H". "Q" survives a logo over
    ///   the centre and keeps a long share link from turning into a dense grid.
    static func matrix(from string: String, correction: String = "Q") -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue(correction, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let cg = sharedContext.createCGImage(output, from: output.extent) else { return nil }

        // One pixel per module at this scale; read it back as grey bytes.
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        while rows.first?.contains(true) == false { rows.removeFirst() }
        while rows.last?.contains(true) == false { rows.removeLast() }
        guard let first = rows.first else { return nil }
        let columns = first.indices.filter { x in rows.contains { $0[x] } }
        guard let left = columns.first, let right = columns.last else { return nil }
        return rows.map { Array($0[left...right]) }
    }

    /// Creating a CIContext is the expensive part of a render; one will do.
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Detects and returns the first QR-code payload found in an image, if any.
    static func decode(from image: PlatformImage) -> String? {
        #if canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        #else
        guard let cg = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        #endif
        return decode(ciImage: ci)
    }

    /// Decodes a QR payload from raw image data (e.g. a dropped/opened file).
    static func decode(fileURL: URL) -> String? {
        guard let ci = CIImage(contentsOf: fileURL) else { return nil }
        return decode(ciImage: ci)
    }

    static func decode(ciImage: CIImage) -> String? {
        let context = CIContext()
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: context,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) ?? []
        for case let qr as CIQRCodeFeature in features {
            if let msg = qr.messageString, !msg.isEmpty { return msg }
        }
        return nil
    }
}
