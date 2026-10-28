// 轻盈 图标：一片向上飘起的羽叶（羽毛 = 轻盈，叶子 = 健康）+ 下方浮起的气泡，原创。重新生成：swift appicon.swift BooheeLite/Assets.xcassets/AppIcon.appiconset
import AppKit
let out = CommandLine.arguments[1], S: CGFloat = 1024
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a) }
// 羽叶局部坐标：y 向上沿羽轴，羽根在下、尖在上；右缘光滑，左缘两道羽毛分叉
let L: CGFloat = 690, W: CGFloat = 285
let T = CGAffineTransform(translationX: 548, y: 548).rotated(by: -0.62)
func vane() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: -0.32 * L))
    p.addCurve(to: CGPoint(x: 0, y: 0.5 * L), control1: CGPoint(x: W * 0.64, y: -0.16 * L), control2: CGPoint(x: W * 0.40, y: 0.38 * L))
    p.addCurve(to: CGPoint(x: -W * 0.40, y: 0.13 * L), control1: CGPoint(x: -W * 0.20, y: 0.44 * L), control2: CGPoint(x: -W * 0.40, y: 0.28 * L))
    p.addLine(to: CGPoint(x: -W * 0.20, y: 0.07 * L))
    p.addCurve(to: CGPoint(x: -W * 0.47, y: -0.09 * L), control1: CGPoint(x: -W * 0.36, y: 0.04 * L), control2: CGPoint(x: -W * 0.47, y: 0.0))
    p.addLine(to: CGPoint(x: -W * 0.25, y: -0.15 * L))
    p.addCurve(to: CGPoint(x: 0, y: -0.32 * L), control1: CGPoint(x: -W * 0.38, y: -0.22 * L), control2: CGPoint(x: -W * 0.16, y: -0.30 * L))
    p.closeSubpath()
    var t = T
    return p.copy(using: &t)!
}
func draw(_ name: String, bg: (UInt32, UInt32)?, fg: CGColor, barb: CGColor, halo: CGColor, dots: CGColor) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext, sp = CGColorSpace(name: CGColorSpace.sRGB)!
    if let bg {
        let grad = CGGradient(colorsSpace: sp, colors: [rgb(bg.0), rgb(bg.1)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    } else { c.setFillColor(rgb(0x000000)); c.fill(CGRect(x: 0, y: 0, width: S, height: S)) }
    // 柔光：羽叶背后一圈淡淡的亮
    let hg = CGGradient(colorsSpace: sp, colors: [halo, halo.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(hg, startCenter: CGPoint(x: 580, y: 600), startRadius: 0, endCenter: CGPoint(x: 580, y: 600), endRadius: 420, options: [])
    // 浮起的气泡（左下，越往下越小）
    for (x, y, r, a) in [(CGFloat(318), CGFloat(292), CGFloat(30), CGFloat(0.95)), (262, 214, 20, 0.7), (224, 152, 12, 0.5)] {
        c.setFillColor(dots.copy(alpha: dots.alpha * a)!); c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    // 羽根（叶面以外的一小段）+ 叶面 + 羽轴 / 羽枝（裁在叶面里）
    var t = T
    let quill = CGMutablePath(); quill.move(to: CGPoint(x: 0, y: -0.30 * L)); quill.addQuadCurve(to: CGPoint(x: -6, y: -0.47 * L), control: CGPoint(x: 4, y: -0.40 * L))
    c.addPath(quill.copy(using: &t)!); c.setStrokeColor(fg); c.setLineWidth(24); c.setLineCap(.round); c.strokePath()
    let v = vane()
    c.addPath(v); c.setFillColor(fg); c.fillPath()
    c.saveGState(); c.addPath(v); c.clip()
    let lines = CGMutablePath()
    lines.move(to: CGPoint(x: 0, y: -0.30 * L)); lines.addQuadCurve(to: CGPoint(x: 0, y: 0.46 * L), control: CGPoint(x: 14, y: 0.05 * L))
    for i in 0..<5 {
        let y = -0.20 * L + CGFloat(i) * 0.13 * L
        lines.move(to: CGPoint(x: 6, y: y)); lines.addLine(to: CGPoint(x: W * 0.55, y: y + 0.12 * L))
        lines.move(to: CGPoint(x: 4, y: y + 0.02 * L)); lines.addLine(to: CGPoint(x: -W * 0.55, y: y + 0.13 * L))
    }
    c.addPath(lines.copy(using: &t)!); c.setStrokeColor(barb); c.setLineWidth(7); c.setLineCap(.round); c.strokePath()
    c.restoreGState()
    // 去掉 alpha 通道再写 PNG（App Store 不收带 alpha 的图标）
    let opaque = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: sp, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    opaque.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: S, height: S))
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(out)/\(name).png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, opaque.makeImage()!, nil); CGImageDestinationFinalize(dst)
}
draw("icon-light", bg: (0x8CEFD0, 0x13A894), fg: rgb(0xFFFFFF), barb: rgb(0x34C3A6, 0.32), halo: rgb(0xFFFFFF, 0.34), dots: rgb(0xFFFFFF))
draw("icon-dark", bg: (0x12403A, 0x061915), fg: rgb(0x6BEBC8), barb: rgb(0x0B2E28, 0.35), halo: rgb(0x6BEBC8, 0.16), dots: rgb(0x6BEBC8))
draw("icon-tinted", bg: nil, fg: rgb(0xFFFFFF), barb: rgb(0x000000, 0.35), halo: rgb(0xFFFFFF, 0.10), dots: rgb(0xFFFFFF))
print("ok")
