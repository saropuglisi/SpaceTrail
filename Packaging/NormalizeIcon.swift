import CoreGraphics
import Foundation
import ImageIO

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let size = 1_024
guard let inputImage = CGImageSourceCreateWithURL(input as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(inputImage, 0, nil),
      let cropped = source.cropping(to: CGRect(x: 93, y: 90, width: 1_062, height: 1_070)),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not read the source icon.")
}

// The supplied artwork has a luminous rounded badge inside an opaque square.
// These bounds and corner radii follow the edge of that badge in the source.
let frame = CGRect(x: 42, y: 42, width: 940, height: 940)
let outline = CGPath(roundedRect: frame, cornerWidth: 244, cornerHeight: 242, transform: nil)
canvas.setAllowsAntialiasing(true)
canvas.addPath(outline)
canvas.clip()
canvas.interpolationQuality = .high
canvas.draw(cropped, in: frame)

guard let icon = canvas.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not export the normalized icon.")
}
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the icon.") }
