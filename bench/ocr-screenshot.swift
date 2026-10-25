import Foundation
import Vision
import AppKit

// Local OCR baseline for screenshots (macOS Vision). No network, no VLM API.
// Usage: swift bench/ocr-screenshot.swift /path/to.png

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: ocr-screenshot.swift <png>\n", stderr)
    exit(2)
}
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let cgImage = bitmap.cgImage else {
    fputs("could not load image\n", stderr)
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])
let observations = request.results ?? []
var lines: [String] = []
for obs in observations {
    if let candidate = obs.topCandidates(1).first {
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(text)
        }
    }
}
let payload: [String: Any] = [
    "engine": "macos-vision-ocr",
    "path": path,
    "lines": lines,
    "lineCount": lines.count,
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
