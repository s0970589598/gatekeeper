import Foundation
import AVFoundation
import CoreImage
import Vision
import AppKit

let args = CommandLine.arguments
let videoPath = args.count > 1 ? args[1] : "/Users/ylwu/code/gatekeeper/rabbit.mov"
let outputPath = args.count > 2 ? args[2] : "/Users/ylwu/code/gatekeeper/rabbit-frame-alpha.png"
let timeSec = args.count > 3 ? (Double(args[3]) ?? 1.0) : 1.0

let videoURL = URL(fileURLWithPath: videoPath)
let outputURL = URL(fileURLWithPath: outputPath)

let asset = AVURLAsset(url: videoURL)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

let time = CMTime(seconds: timeSec, preferredTimescale: 600)
let cgImage = try gen.copyCGImage(at: time, actualTime: nil)
print("Frame @ \(timeSec)s: \(cgImage.width)x\(cgImage.height)")

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])

guard let observation = request.results?.first else {
    print("❌ No foreground instances detected")
    exit(1)
}
print("✅ Detected \(observation.allInstances.count) instance(s): \(Array(observation.allInstances))")

let maskedPixelBuffer = try observation.generateMaskedImage(
    ofInstances: observation.allInstances,
    from: handler,
    croppedToInstancesExtent: false
)

let ci = CIImage(cvPixelBuffer: maskedPixelBuffer)
let ctx = CIContext()
guard let outputCG = ctx.createCGImage(ci, from: ci.extent) else {
    print("❌ Failed to create CGImage from CIImage")
    exit(1)
}

let bitmap = NSBitmapImageRep(cgImage: outputCG)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("❌ Failed to encode PNG")
    exit(1)
}
try pngData.write(to: outputURL)
print("✅ Saved: \(outputURL.path) (\(pngData.count) bytes, alpha=\(outputCG.alphaInfo.rawValue))")
