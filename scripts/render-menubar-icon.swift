// Renders the menu bar glyph ("hub": one library fanning out to three clients) to a template PDF.
// Usage: swift scripts/render-menubar-icon.swift <output.pdf>
// The PDF is black-on-transparent; the asset catalog marks it as a template image so macOS
// recolours it for light/dark menu bars.
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 18
var box = CGRect(x: 0, y: 0, width: size, height: size)
guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { fatalError("no pdf context") }
ctx.beginPDFPage(nil)

// Flip to SVG-style coordinates (origin top-left, y down) so the geometry matches the mockup.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.setLineWidth(1.8)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Library: rounded square
let r = CGRect(x: 2, y: 5.5, width: 7, height: 7)
ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
ctx.strokePath()

// Trunk + three branches
ctx.move(to: CGPoint(x: 9, y: 9)); ctx.addLine(to: CGPoint(x: 12, y: 9))
ctx.move(to: CGPoint(x: 12, y: 9)); ctx.addCurve(to: CGPoint(x: 15, y: 6), control1: CGPoint(x: 13.5, y: 9), control2: CGPoint(x: 13.5, y: 6))
ctx.move(to: CGPoint(x: 12, y: 9)); ctx.addLine(to: CGPoint(x: 15, y: 9))
ctx.move(to: CGPoint(x: 12, y: 9)); ctx.addCurve(to: CGPoint(x: 15, y: 12), control1: CGPoint(x: 13.5, y: 9), control2: CGPoint(x: 13.5, y: 12))
ctx.strokePath()

// Clients: three dots
for y in [6.0, 9.0, 12.0] {
    ctx.fillEllipse(in: CGRect(x: 15.6 - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
}

ctx.endPDFPage()
ctx.closePDF()
print("wrote \(out.path)")
