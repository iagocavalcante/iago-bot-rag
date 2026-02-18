#!/usr/bin/swift

import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppResources/AppIcon-1024.png"
let outputURL = URL(fileURLWithPath: outputPath)

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Failed to create graphics context\n", stderr)
    exit(1)
}

let rect = CGRect(origin: .zero, size: size)

// Background
let bgColor = NSColor(calibratedRed: 0.07, green: 0.74, blue: 0.41, alpha: 1.0)
bgColor.setFill()
NSBezierPath(roundedRect: rect, xRadius: 230, yRadius: 230).fill()

// Chat bubble
let bubbleRect = CGRect(x: 110, y: 180, width: 804, height: 670)
let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 180, yRadius: 180)
NSColor.white.setFill()
bubblePath.fill()

// Bubble tail
let tail = NSBezierPath()
tail.move(to: CGPoint(x: 300, y: 220))
tail.line(to: CGPoint(x: 190, y: 100))
tail.line(to: CGPoint(x: 365, y: 170))
tail.close()
NSColor.white.setFill()
tail.fill()

// Bot head
let headRect = CGRect(x: 332, y: 350, width: 360, height: 300)
let headPath = NSBezierPath(roundedRect: headRect, xRadius: 95, yRadius: 95)
let darkGreen = NSColor(calibratedRed: 0.02, green: 0.34, blue: 0.19, alpha: 1.0)
darkGreen.setFill()
headPath.fill()

// Antenna
let antenna = NSBezierPath()
antenna.lineWidth = 36
antenna.move(to: CGPoint(x: 512, y: 680))
antenna.line(to: CGPoint(x: 512, y: 760))
darkGreen.setStroke()
antenna.stroke()

let antennaDot = NSBezierPath(ovalIn: CGRect(x: 476, y: 752, width: 72, height: 72))
darkGreen.setFill()
antennaDot.fill()

// Eyes
let eyeColor = NSColor.white
eyeColor.setFill()
NSBezierPath(ovalIn: CGRect(x: 405, y: 475, width: 66, height: 66)).fill()
NSBezierPath(ovalIn: CGRect(x: 553, y: 475, width: 66, height: 66)).fill()

// Mouth
let mouth = NSBezierPath()
mouth.lineWidth = 30
mouth.lineCapStyle = .round
mouth.move(to: CGPoint(x: 425, y: 425))
mouth.line(to: CGPoint(x: 599, y: 425))
eyeColor.setStroke()
mouth.stroke()

// Status dot
let statusDot = NSBezierPath(ovalIn: CGRect(x: 760, y: 740, width: 120, height: 120))
let statusColor = NSColor(calibratedRed: 0.02, green: 0.57, blue: 0.24, alpha: 1.0)
statusColor.setFill()
statusDot.fill()

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try pngData.write(to: outputURL)
    print("Generated logo: \(outputURL.path)")
} catch {
    fputs("Failed to write PNG: \(error)\n", stderr)
    exit(1)
}
