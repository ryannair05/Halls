import UIKit

enum OpaqueImageRenderer {
    static func image(
        size: CGSize,
        scale: CGFloat = 1,
        actions: (CGContext) -> Void
    ) -> UIImage {
        precondition(scale > 0)
        let pixelWidth = max(1, Int(ceil(size.width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            assertionFailure("Unable to create an opaque image context")
            return UIImage()
        }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        actions(context)
        UIGraphicsPopContext()

        guard let image = context.makeImage() else {
            assertionFailure("Unable to create an opaque image")
            return UIImage()
        }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
