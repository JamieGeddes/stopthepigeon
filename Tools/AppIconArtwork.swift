import SwiftUI

/// The app icon: the loading screen's pigeon, with the net closing in, on a sky tile
/// following the macOS icon grid (824-point rounded square on a 1024 canvas).
enum AppIconArtwork {
    static func draw(in context: inout GraphicsContext, pixelSize: CGFloat) {
        let detailed = pixelSize >= 64
        context.scaleBy(x: pixelSize / 1024, y: pixelSize / 1024)

        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = Path(roundedRect: tile, cornerRadius: 185, style: .continuous)

        var shadow = context
        shadow.addFilter(.shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 12))
        shadow.fill(shape, with: .color(.white))

        var art = context
        art.clip(to: shape)
        art.fill(shape, with: .linearGradient(
            Gradient(colors: [Color(red: 0.42, green: 0.71, blue: 0.95), Color(red: 0.82, green: 0.93, blue: 1.0)]),
            startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)
        ))

        // Work in a 240-unit square inside the tile.
        art.translateBy(x: tile.minX, y: tile.minY)
        art.scaleBy(x: tile.width / 240, y: tile.height / 240)

        if detailed {
            var cloud = Path()
            for (dx, dy, r) in [(0.0, 0.0, 13.0), (15.0, -7.0, 16.0), (32.0, 0.0, 12.0), (16.0, 5.0, 13.0)] {
                cloud.addEllipse(in: CGRect(x: 168 + dx - r, y: 40 + dy - r, width: r * 2, height: r * 2))
            }
            art.fill(cloud, with: .color(.white.opacity(0.9)))
        }

        var hill = Path()
        hill.move(to: CGPoint(x: -10, y: 204))
        hill.addQuadCurve(to: CGPoint(x: 250, y: 198), control: CGPoint(x: 120, y: 186))
        hill.addLine(to: CGPoint(x: 250, y: 250))
        hill.addLine(to: CGPoint(x: -10, y: 250))
        hill.closeSubpath()
        art.fill(hill, with: .color(Color(red: 0.49, green: 0.77, blue: 0.42)))
        art.stroke(hill, with: .color(PigeonChaseScene.ink), lineWidth: 2.5)

        if detailed {
            PigeonChaseScene.drawNet(in: art, pivot: CGPoint(x: -80, y: -120), angle: 0.651, reach: 211, speedLines: false)
        }

        let feet = CGPoint(x: 122, y: 200)
        art.fill(Path(ellipseIn: CGRect(x: feet.x - 50, y: feet.y - 6, width: 112, height: 12)),
                 with: .color(PigeonChaseScene.ink.opacity(0.18)))
        var bird = art
        bird.translateBy(x: feet.x, y: feet.y)
        bird.scaleBy(x: 1.35, y: 1.35)
        PigeonChaseScene.drawPigeon(in: bird, at: .zero, pose: .init(surprised: true, flap: -0.2))

        context.stroke(shape, with: .color(PigeonChaseScene.ink.opacity(0.35)), lineWidth: 4)
    }
}
