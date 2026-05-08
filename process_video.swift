import Foundation
import AVFoundation
import CoreImage
import Vision
import CoreMedia
import CoreVideo
import AppKit

// Args: input.mov output.mov [maxFrames]
let args = CommandLine.arguments
let inputPath  = args.count > 1 ? args[1] : "/Users/ylwu/code/gatekeeper/rabbit.mov"
let outputPath = args.count > 2 ? args[2] : "/Users/ylwu/code/gatekeeper/rabbit-alpha.mov"
let maxFrames  = args.count > 3 ? Int(args[3]) : nil

let inputURL  = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: outputURL)

let asset = AVURLAsset(url: inputURL)
guard let videoTrack = asset.tracks(withMediaType: .video).first else {
    print("❌ No video track"); exit(1)
}
let naturalSize = videoTrack.naturalSize
let preferredTransform = videoTrack.preferredTransform
let nominalFps = videoTrack.nominalFrameRate
let totalFrames = Int(asset.duration.seconds * Double(nominalFps))

let maskDir = ProcessInfo.processInfo.environment["MASK_DIR"]  // if set: read pre-computed PNG masks instead of running Vision
let mergeAll = ProcessInfo.processInfo.environment["MERGE_ALL"] == "1"  // include every detected instance instead of just the largest
let enhance = ProcessInfo.processInfo.environment["ENHANCE"] != "0"
let smoothAlphaEnv = ProcessInfo.processInfo.environment["SMOOTH"] ?? "1.0"
let smoothAlpha = max(0, min(1, Double(smoothAlphaEnv) ?? 1.0))  // 1.0 = no temporal smoothing (default)
let refine = ProcessInfo.processInfo.environment["REFINE"] != "0"  // spatial mask cleanup, default ON
let closeRadius = Double(ProcessInfo.processInfo.environment["CLOSE"] ?? "2.0") ?? 2.0  // morphological close radius
let edgeBlur   = Double(ProcessInfo.processInfo.environment["EDGEBLUR"] ?? "1.0") ?? 1.0  // gaussian blur on mask edges
let thresholdSteepness = Double(ProcessInfo.processInfo.environment["THRESH"] ?? "6.0") ?? 6.0  // soft threshold steepness
let ciContext = CIContext()

print("Input:  \(inputPath)")
print("Output: \(outputPath)")
print("Track:  \(Int(naturalSize.width))x\(Int(naturalSize.height)) @ \(nominalFps)fps, ~\(totalFrames) frames")
print("Mask:    \(maskDir ?? "Apple Vision (per-frame)")")
print("MergeAll: \(mergeAll ? "ON (include every instance)" : "OFF (largest only)")")
print("Enhance: \(enhance ? "ON (sharpen + contrast + denoise)" : "OFF")")
print("Refine:  \(refine ? "ON (close r=\(closeRadius), blur r=\(edgeBlur), thresh=\(thresholdSteepness))" : "OFF")")
print("TempSmooth: alpha=\(smoothAlpha) (\(Int(smoothAlpha*100))% cur + \(Int((1-smoothAlpha)*100))% prev) — 1.0=off")
if let m = maxFrames { print("Limit:  first \(m) frames (test mode)") }

// --- Reader ---
let reader = try AVAssetReader(asset: asset)
let readerOutput = AVAssetReaderTrackOutput(
    track: videoTrack,
    outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
)
reader.add(readerOutput)

// --- Writer ---
let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.proRes4444,
    AVVideoWidthKey: Int(naturalSize.width),
    AVVideoHeightKey: Int(naturalSize.height),
])
writerInput.transform = preferredTransform
writerInput.expectsMediaDataInRealTime = false

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: writerInput,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(naturalSize.width),
        kCVPixelBufferHeightKey as String: Int(naturalSize.height),
    ]
)
writer.add(writerInput)

reader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: .zero)

// Helper: make a fully-transparent BGRA buffer (used as fallback if Vision misses a frame)
func makeTransparentBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    let base = CVPixelBufferGetBaseAddress(buf)!
    let bpr = CVPixelBufferGetBytesPerRow(buf)
    memset(base, 0, bpr * height)
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

let startTime = Date()
var frameCount = 0
var missedFrames = 0
var multiInstanceFrames = 0
var lastGoodBuffer: CVPixelBuffer? = nil
var lastSmoothedMask: CVPixelBuffer? = nil
let request = VNGenerateForegroundInstanceMaskRequest()

let pbAttrs: CFDictionary = [
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
] as CFDictionary
let imgW = Int(naturalSize.width)
let imgH = Int(naturalSize.height)

func newPB(_ format: OSType) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, imgW, imgH, format, pbAttrs, &pb)
    return pb
}

func loadMaskCI(_ path: String) -> CIImage? {
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let img = NSImage(data: data),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }
    return CIImage(cgImage: cg)
}

while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
    if let m = maxFrames, frameCount >= m { break }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        frameCount += 1; continue
    }

    var handlerImage: CVPixelBuffer = pixelBuffer
    if enhance {
        let inputCI = CIImage(cvPixelBuffer: pixelBuffer)
        let enhanced = inputCI
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.4])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.6])
            .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.08, "inputSaturation": 1.08])
        var enhancedPB: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(naturalSize.width), Int(naturalSize.height), kCVPixelFormatType_32BGRA, [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &enhancedPB)
        if let pb = enhancedPB {
            ciContext.render(enhanced, to: pb)
            handlerImage = pb
        }
    }
    var outBuffer: CVPixelBuffer?
    var rawMaskCI: CIImage? = nil
    var rawMaskExtent: CGRect = CGRect(x: 0, y: 0, width: imgW, height: imgH)

    if let dir = maskDir {
        let path = "\(dir)/\(String(format: "%05d", frameCount)).png"
        if let m = loadMaskCI(path) {
            rawMaskCI = m
            rawMaskExtent = m.extent
        }
    } else {
        let handler = VNImageRequestHandler(cvPixelBuffer: handlerImage, options: [:])
        do {
            try handler.perform([request])
            if let observation = request.results?.first {
                if observation.allInstances.count > 1 { multiInstanceFrames += 1 }

                let chosenInstances: IndexSet
                if mergeAll {
                    // Include every detected instance (multi-subject scenes like 5 rabbits dancing)
                    chosenInstances = observation.allInstances
                } else {
                    // Pick the largest instance by mask area (avoids spurious secondary detections like cage bars)
                    var bestInstance = observation.allInstances.first ?? 1
                    if observation.allInstances.count > 1 {
                        var bestArea = -1
                        for idx in observation.allInstances {
                            if let mask = try? observation.generateMask(forInstances: IndexSet(integer: idx)) {
                                CVPixelBufferLockBaseAddress(mask, .readOnly)
                                let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
                                let bpr = CVPixelBufferGetBytesPerRow(mask)
                                let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
                                var area = 0
                                for y in stride(from: 0, to: h, by: 4) {
                                    let row = base + y * bpr
                                    for x in stride(from: 0, to: w, by: 4) where row[x] > 32 { area += 1 }
                                }
                                CVPixelBufferUnlockBaseAddress(mask, .readOnly)
                                if area > bestArea { bestArea = area; bestInstance = idx }
                            }
                        }
                    }
                    chosenInstances = IndexSet(integer: bestInstance)
                }

                let rm = try observation.generateScaledMaskForImage(
                    forInstances: chosenInstances,
                    from: handler
                )
                let ci = CIImage(cvPixelBuffer: rm)
                rawMaskCI = ci
                rawMaskExtent = ci.extent
            }
        } catch {
            print("⚠️ frame \(frameCount) Vision error: \(error.localizedDescription)")
        }
    }

    if var curMaskCI = rawMaskCI {

            // --- Spatial mask refinement (per-frame, no temporal mixing) ---
            if refine {
                // 1) Soft threshold: pull weak edge pixels toward 0 or 1 to stabilize wavering edges.
                //    Map x → clamp((x - 0.5) * steepness + 0.5, 0, 1)  (linear ramp around 0.5)
                let s = CGFloat(thresholdSteepness)
                let bias = (1.0 - s) * 0.5
                curMaskCI = curMaskCI.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
                ]).applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ])

                // 2) Morphological close (dilate then erode) to fill small holes inside the rabbit
                if closeRadius > 0 {
                    curMaskCI = curMaskCI
                        .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: closeRadius])
                        .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: closeRadius])
                }

                // 3) Gentle gaussian blur to soften edges and remove sub-pixel jitter
                if edgeBlur > 0 {
                    curMaskCI = curMaskCI.applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: edgeBlur
                    ])
                    // Re-crop to original extent (gaussian blur expands the image extent)
                    curMaskCI = curMaskCI.cropped(to: rawMaskExtent)
                }
            }

            // Temporal smoothing: weighted average with previous frame's smoothed mask
            // Default off (smoothAlpha=1.0) — produces ghost trails on moving subjects.
            var smoothedMaskCI = curMaskCI
            if smoothAlpha < 1.0, let prev = lastSmoothedMask {
                let aCur = CGFloat(smoothAlpha)
                let aPrev = CGFloat(1.0 - smoothAlpha)
                let scaledCur = curMaskCI.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: aCur, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: aCur, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: aCur, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                let scaledPrev = CIImage(cvPixelBuffer: prev).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: aPrev, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: aPrev, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: aPrev, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                smoothedMaskCI = scaledCur.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: scaledPrev
                ])
            }

            // Render smoothed mask for next iteration's reference
            if let maskPB = newPB(kCVPixelFormatType_OneComponent8) {
                ciContext.render(smoothedMaskCI, to: maskPB)
                lastSmoothedMask = maskPB
            }

            // Composite original frame + smoothed mask → BGRA with alpha
            let srcCI = CIImage(cvPixelBuffer: handlerImage)
            let composed = srcCI.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputMaskImageKey: smoothedMaskCI,
                kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: srcCI.extent)
            ])

            if let pb = newPB(kCVPixelFormatType_32BGRA) {
                ciContext.render(composed, to: pb)
                outBuffer = pb
            }
    }

    if outBuffer == nil {
        missedFrames += 1
        // Fallback: reuse last successful frame to avoid flicker; if no prior frame yet, use transparent
        outBuffer = lastGoodBuffer ?? makeTransparentBuffer(width: Int(naturalSize.width), height: Int(naturalSize.height))
    } else {
        lastGoodBuffer = outBuffer
    }

    while !writerInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    if let buf = outBuffer {
        adaptor.append(buf, withPresentationTime: pts)
    }

    frameCount += 1
    if frameCount % 15 == 0 {
        let elapsed = Date().timeIntervalSince(startTime)
        let fps = Double(frameCount) / elapsed
        let target = maxFrames ?? totalFrames
        let pct = Int(Double(frameCount) / Double(target) * 100)
        let etaSec = Double(target - frameCount) / fps
        print(String(format: "  frame %d/%d (%d%%) | %.1f fps | eta %.0fs", frameCount, target, pct, fps, etaSec))
    }
}

writerInput.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()

let elapsed = Date().timeIntervalSince(startTime)
print("")
print("✅ Done in \(String(format: "%.1f", elapsed))s")
print("   frames: \(frameCount), missed: \(missedFrames), multi-instance: \(multiInstanceFrames)")
if writer.status == .failed {
    print("❌ writer failed: \(writer.error?.localizedDescription ?? "unknown")")
    exit(1)
}
let outSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
print("   output: \(outputPath) (\(outSize / 1024 / 1024) MB)")
