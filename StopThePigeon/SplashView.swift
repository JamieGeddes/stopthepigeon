import SwiftUI

/// Launch screen: a cartoon net swoops at a pigeon, which hops clear, above the app name.
struct SplashView: View {
    var status: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The animation runs from when the splash appears, so it always starts with the
    /// net winding up rather than part-way through a swoop.
    @State private var start = Date.now

    var body: some View {
        ZStack {
            Color(red: 1.0, green: 0.96, blue: 0.88)

            VStack(spacing: 20) {
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
                    // With reduced motion, hold the frame where the pigeon is mid-hop.
                    let time = reduceMotion
                        ? PigeonChaseScene.period * 0.5
                        : timeline.date.timeIntervalSince(start)
                    Canvas { context, size in
                        PigeonChaseScene.draw(in: &context, size: size, time: time)
                    }
                }
                .frame(width: 560, height: 364)
                .background(PigeonChaseScene.sky)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(PigeonChaseScene.ink, lineWidth: 3))
                .background(
                    // Solid offset backing for a hard cartoon shadow on the panel only.
                    RoundedRectangle(cornerRadius: 28)
                        .fill(PigeonChaseScene.ink.opacity(0.25))
                        .offset(x: 6, y: 7)
                )
                .accessibilityLabel("A cartoon net swoops at a pigeon, which hops out of the way")

                VStack(spacing: 4) {
                    CartoonTitle(text: "Stop the Pigeon")
                    Text("stop-motion studio")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(PigeonChaseScene.ink.opacity(0.65))
                }

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(PigeonChaseScene.ink.opacity(0.7))
                }
            }
            .padding(24)
        }
        .ignoresSafeArea()
    }
}

/// Heavy rounded title with a hard cartoon outline and drop shadow.
private struct CartoonTitle: View {
    let text: String

    var body: some View {
        let ink = PigeonChaseScene.ink
        Text(text)
            .font(.system(size: 58, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: ink, radius: 0, x: 2, y: 0)
            .shadow(color: ink, radius: 0, x: -2, y: 0)
            .shadow(color: ink, radius: 0, x: 0, y: 2)
            .shadow(color: ink, radius: 0, x: 0, y: -2)
            .shadow(color: ink, radius: 0, x: 3, y: 5)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Scene

/// Draws one frame of the looping chase in a 400 × 260 design space.
enum PigeonChaseScene {
    static let period = 2.4
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.23)
    static let sky = LinearGradient(
        colors: [Color(red: 0.49, green: 0.76, blue: 0.96), Color(red: 0.86, green: 0.95, blue: 1.0)],
        startPoint: .top,
        endPoint: .bottom
    )

    private static let designSize = CGSize(width: 400, height: 260)
    private static let groundY: CGFloat = 222
    private static let pigeonX: CGFloat = 255
    private static let netPivot = CGPoint(x: 150, y: -140)
    private static let netRadius: CGFloat = 330
    private static let outlineWidth: CGFloat = 2.5

    static func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let scale = min(size.width / designSize.width, size.height / designSize.height)
        context.translateBy(
            x: (size.width - designSize.width * scale) / 2,
            y: (size.height - designSize.height * scale) / 2
        )
        context.scaleBy(x: scale, y: scale)

        let phase = time.truncatingRemainder(dividingBy: period) / period

        drawClouds(in: context, time: time)
        drawGround(in: context)

        let hop = hopHeight(phase)
        drawShadow(in: context, hop: hop)
        // The net passes behind the pigeon, so its handle never cuts across the bird.
        drawNet(in: context, pivot: netPivot, angle: netAngle(phase), reach: netReach(phase),
                speedLines: phase > 0.42 && phase < 0.60)
        drawFeathers(in: context, phase: phase)
        drawPigeon(in: context, at: CGPoint(x: pigeonX, y: groundY - 6 - hop), pose: pose(phase: phase, time: time, hop: hop))
    }

    // MARK: Timing

    /// Net angle in radians from straight down; positive swings towards the pigeon.
    private static func netAngle(_ p: Double) -> Double {
        let raised = -0.55, lowered = 0.75
        switch p {
        case ..<0.30:
            return raised + sin(p / 0.30 * .pi * 2) * 0.03 // waggle while winding up
        case ..<0.55:
            let f = (p - 0.30) / 0.25
            return raised + (lowered - raised) * f * f // accelerate into the swoop
        case ..<0.70:
            let f = (p - 0.55) / 0.15
            return lowered + sin(f * .pi) * 0.08 // overshoot
        default:
            let f = (p - 0.70) / 0.30
            return lowered + (raised - lowered) * (f * f * (3 - 2 * f))
        }
    }

    /// Distance from the pivot to the hoop. The net is pulled in on the way back so it
    /// lifts up and over the pigeon instead of sweeping through it.
    private static func netReach(_ p: Double) -> CGFloat {
        guard p >= 0.70 else { return netRadius }
        let f = (p - 0.70) / 0.30
        return netRadius - 120 * CGFloat(sin(f * .pi))
    }

    private static func hopHeight(_ p: Double) -> CGFloat {
        guard p >= 0.40, p <= 0.62 else { return 0 }
        let u = (p - 0.40) / 0.22
        return CGFloat(4 * 72 * u * (1 - u))
    }

    /// Vertical squash for anticipation before the hop and impact on landing.
    private static func squash(_ p: Double) -> CGFloat {
        switch p {
        case 0.34..<0.40: return 1 - 0.14 * sin((p - 0.34) / 0.06 * .pi)
        case 0.62..<0.68: return 1 - 0.12 * sin((p - 0.62) / 0.06 * .pi)
        default: return 1
        }
    }

    // MARK: Background

    private static func drawClouds(in context: GraphicsContext, time: Double) {
        for (offset, y, size, speed) in [(0.0, 42.0, 1.0, 9.0), (210.0, 78.0, 0.7, 6.0), (330.0, 30.0, 0.55, 12.0)] {
            let x = (time * speed + offset).truncatingRemainder(dividingBy: 520) - 60
            var path = Path()
            for (dx, dy, r) in [(0.0, 0.0, 16.0), (18.0, -8.0, 20.0), (40.0, 0.0, 15.0), (20.0, 6.0, 16.0)] {
                path.addEllipse(in: CGRect(x: x + dx * size - r * size, y: y + dy * size - r * size, width: 2 * r * size, height: 2 * r * size))
            }
            context.fill(path, with: .color(.white.opacity(0.9)))
        }
    }

    private static func drawGround(in context: GraphicsContext) {
        var hill = Path()
        hill.move(to: CGPoint(x: -10, y: groundY + 4))
        hill.addQuadCurve(to: CGPoint(x: 410, y: groundY - 2), control: CGPoint(x: 200, y: groundY - 18))
        hill.addLine(to: CGPoint(x: 410, y: 270))
        hill.addLine(to: CGPoint(x: -10, y: 270))
        hill.closeSubpath()
        context.fill(hill, with: .color(Color(red: 0.49, green: 0.77, blue: 0.42)))
        context.stroke(hill, with: .color(ink), lineWidth: outlineWidth)

        // A few tufts of grass.
        var tufts = Path()
        for x in stride(from: 30.0, through: 380.0, by: 58.0) {
            let y = groundY - 6 + abs(x - 200) / 40
            tufts.move(to: CGPoint(x: x - 5, y: y + 6))
            tufts.addLine(to: CGPoint(x: x - 2, y: y))
            tufts.move(to: CGPoint(x: x + 1, y: y + 6))
            tufts.addLine(to: CGPoint(x: x + 4, y: y - 1))
        }
        context.stroke(tufts, with: .color(Color(red: 0.30, green: 0.58, blue: 0.27)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private static func drawShadow(in context: GraphicsContext, hop: CGFloat) {
        let width = 74 * (1 - hop / 150)
        let rect = CGRect(x: pigeonX + 4 - width / 2, y: groundY - 6, width: width, height: 9)
        context.fill(Path(ellipseIn: rect), with: .color(ink.opacity(0.18)))
    }

    // MARK: Pigeon

    struct PigeonPose {
        var airborne = false
        var surprised = false
        var bob: CGFloat = 0
        var flap: Double = 0
        var squash: CGFloat = 1
        /// Size of the "!" from 0 to 1, or nil to hide it.
        var exclamation: Double?
    }

    private static func pose(phase p: Double, time: Double, hop: CGFloat) -> PigeonPose {
        let airborne = hop > 1
        return PigeonPose(
            airborne: airborne,
            surprised: p > 0.33 && p < 0.72,
            bob: airborne ? 0 : CGFloat(sin(p * .pi * 4)) * 3,
            flap: airborne ? sin(time * 45) * 0.7 - 0.35 : sin(time * 3) * 0.05,
            squash: squash(p),
            exclamation: p > 0.30 && p < 0.47 ? min((p - 0.30) / 0.04, 1) : nil
        )
    }

    /// Draws the pigeon facing left with its feet at `origin`. Also used for the app icon.
    static func drawPigeon(in context: GraphicsContext, at origin: CGPoint, pose: PigeonPose) {
        var ctx = context
        let airborne = pose.airborne
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: 1 / sqrt(pose.squash), y: pose.squash)
        if airborne { ctx.rotate(by: .radians(-0.12)) }

        let surprised = pose.surprised
        let bob = pose.bob
        let flap = pose.flap

        // Legs: standing, or tucked up in the air.
        var legs = Path()
        if airborne {
            legs.move(to: CGPoint(x: -6, y: -20)); legs.addLine(to: CGPoint(x: -12, y: -10))
            legs.move(to: CGPoint(x: 8, y: -20)); legs.addLine(to: CGPoint(x: 4, y: -10))
        } else {
            legs.move(to: CGPoint(x: -8, y: -20)); legs.addLine(to: CGPoint(x: -10, y: 0))
            legs.move(to: CGPoint(x: 8, y: -20)); legs.addLine(to: CGPoint(x: 10, y: 0))
            legs.move(to: CGPoint(x: -17, y: 0)); legs.addLine(to: CGPoint(x: -4, y: 0))
            legs.move(to: CGPoint(x: 3, y: 0)); legs.addLine(to: CGPoint(x: 16, y: 0))
        }
        ctx.stroke(legs, with: .color(Color(red: 0.91, green: 0.47, blue: 0.49)), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        // Tail.
        var tail = Path()
        tail.move(to: CGPoint(x: 28, y: -42))
        tail.addLine(to: CGPoint(x: 70, y: -56))
        tail.addLine(to: CGPoint(x: 74, y: -38))
        tail.addLine(to: CGPoint(x: 30, y: -28))
        tail.closeSubpath()
        fillAndOutline(ctx, tail, Color(red: 0.37, green: 0.42, blue: 0.48))

        // Body with a paler belly.
        let body = Path(ellipseIn: CGRect(x: -35, y: -69, width: 82, height: 54))
        ctx.fill(body, with: .color(Color(red: 0.58, green: 0.64, blue: 0.71)))
        ctx.fill(Path(ellipseIn: CGRect(x: -30, y: -48, width: 50, height: 30)), with: .color(Color(red: 0.71, green: 0.76, blue: 0.82)))
        ctx.stroke(body, with: .color(ink), lineWidth: outlineWidth)

        // Wing, hinged at the shoulder, with the two dark bars pigeons have.
        var wingContext = ctx
        wingContext.translateBy(x: 2, y: -58)
        wingContext.rotate(by: .radians(flap))
        var wing = Path()
        wing.move(to: .zero)
        wing.addQuadCurve(to: CGPoint(x: 54, y: 10), control: CGPoint(x: 30, y: -12))
        wing.addQuadCurve(to: CGPoint(x: 8, y: 24), control: CGPoint(x: 40, y: 30))
        wing.addQuadCurve(to: .zero, control: CGPoint(x: -6, y: 12))
        fillAndOutline(wingContext, wing, Color(red: 0.48, green: 0.53, blue: 0.61))
        var bars = Path()
        bars.move(to: CGPoint(x: 20, y: 7)); bars.addQuadCurve(to: CGPoint(x: 42, y: 13), control: CGPoint(x: 31, y: 6))
        bars.move(to: CGPoint(x: 17, y: 14)); bars.addQuadCurve(to: CGPoint(x: 38, y: 21), control: CGPoint(x: 28, y: 14))
        wingContext.stroke(bars, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // Iridescent neck.
        let neck = Path(ellipseIn: CGRect(x: -42 + bob * 0.5, y: -84, width: 32, height: 38))
        ctx.fill(neck, with: .linearGradient(
            Gradient(colors: [Color(red: 0.25, green: 0.66, blue: 0.48), Color(red: 0.55, green: 0.32, blue: 0.64)]),
            startPoint: CGPoint(x: -42, y: -84), endPoint: CGPoint(x: -10, y: -46)
        ))
        ctx.stroke(neck, with: .color(ink), lineWidth: outlineWidth)

        // Head, cere, beak and eye.
        let head = Path(ellipseIn: CGRect(x: -46 + bob, y: -103, width: 32, height: 32))
        fillAndOutline(ctx, head, Color(red: 0.52, green: 0.58, blue: 0.65))

        var beak = Path()
        beak.move(to: CGPoint(x: -44 + bob, y: -90))
        beak.addLine(to: CGPoint(x: -58 + bob, y: -85))
        beak.addLine(to: CGPoint(x: -44 + bob, y: -82))
        beak.closeSubpath()
        ctx.fill(beak, with: .color(Color(red: 0.24, green: 0.25, blue: 0.28)))
        ctx.stroke(beak, with: .color(ink), lineWidth: 1.5)
        ctx.fill(Path(ellipseIn: CGRect(x: -47 + bob, y: -93, width: 8, height: 5)), with: .color(.white))

        let eyeRadius: CGFloat = surprised ? 7 : 5
        let eyeCentre = CGPoint(x: -33 + bob, y: -91)
        let eye = Path(ellipseIn: CGRect(x: eyeCentre.x - eyeRadius, y: eyeCentre.y - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2))
        ctx.fill(eye, with: .color(Color(red: 0.95, green: 0.55, blue: 0.15)))
        ctx.stroke(eye, with: .color(ink), lineWidth: 1.5)
        let pupil: CGFloat = surprised ? 2.4 : 2.8
        ctx.fill(Path(ellipseIn: CGRect(x: eyeCentre.x - 1.5 - pupil, y: eyeCentre.y - pupil, width: pupil * 2, height: pupil * 2)), with: .color(ink))
        ctx.fill(Path(ellipseIn: CGRect(x: eyeCentre.x - 0.5, y: eyeCentre.y - 3, width: 2.4, height: 2.4)), with: .color(.white))

        // "!" as it spots the net.
        if let pop = pose.exclamation {
            ctx.draw(
                Text("!").font(.system(size: 26 * pop, weight: .black, design: .rounded)).foregroundStyle(Color(red: 0.86, green: 0.22, blue: 0.2)),
                at: CGPoint(x: -24, y: -124)
            )
        }
    }

    private static func drawFeathers(in context: GraphicsContext, phase p: Double) {
        guard p > 0.5 else { return }
        let k = (p - 0.5) / 0.5
        for (startX, drift, spin) in [(pigeonX - 4, -26.0, 1.0), (pigeonX + 16, 18.0, -1.3)] {
            var ctx = context
            ctx.opacity = 1 - k
            ctx.translateBy(x: startX + drift * k + sin(k * 7) * 8, y: groundY - 110 + 95 * k)
            ctx.rotate(by: .radians(sin(k * 5) * 0.8 * spin))
            var feather = Path()
            feather.move(to: CGPoint(x: 0, y: -9))
            feather.addQuadCurve(to: CGPoint(x: 0, y: 9), control: CGPoint(x: 7, y: 0))
            feather.addQuadCurve(to: CGPoint(x: 0, y: -9), control: CGPoint(x: -7, y: 0))
            ctx.fill(feather, with: .color(Color(red: 0.80, green: 0.84, blue: 0.89)))
            ctx.stroke(feather, with: .color(ink), lineWidth: 1.5)
        }
    }

    // MARK: Net

    /// Draws the net swinging from `pivot`; `angle` is in radians from straight down.
    /// Also used for the app icon.
    static func drawNet(in context: GraphicsContext, pivot netPivot: CGPoint, angle: Double, reach: CGFloat, speedLines: Bool) {
        // Speed lines trailing the hoop during the swoop.
        if speedLines {
            let direction = Double.pi / 2 - angle
            var streaks = Path()
            for offset: CGFloat in [-22, 0, 22] {
                streaks.addArc(center: netPivot, radius: reach + offset,
                               startAngle: .radians(direction + 0.07), endAngle: .radians(direction + 0.28), clockwise: false)
            }
            context.stroke(streaks, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        var ctx = context
        ctx.translateBy(x: netPivot.x, y: netPivot.y)
        ctx.rotate(by: .radians(-angle))

        let hoopCentre = CGPoint(x: 0, y: reach)
        let hoopRadius: CGFloat = 32

        // Handle.
        var handle = Path()
        handle.move(to: .zero)
        handle.addLine(to: CGPoint(x: 0, y: reach - hoopRadius))
        ctx.stroke(handle, with: .color(ink), style: StrokeStyle(lineWidth: 11, lineCap: .round))
        ctx.stroke(handle, with: .color(Color(red: 0.66, green: 0.42, blue: 0.20)), style: StrokeStyle(lineWidth: 6, lineCap: .round))

        // Mesh bag hanging from the hoop.
        var bag = Path()
        bag.move(to: CGPoint(x: -hoopRadius, y: hoopCentre.y))
        bag.addQuadCurve(to: CGPoint(x: 4, y: hoopCentre.y + 78), control: CGPoint(x: -34, y: hoopCentre.y + 64))
        bag.addQuadCurve(to: CGPoint(x: hoopRadius, y: hoopCentre.y), control: CGPoint(x: 34, y: hoopCentre.y + 58))
        bag.closeSubpath()
        ctx.fill(bag, with: .color(.white.opacity(0.35)))
        var mesh = ctx
        mesh.clip(to: bag)
        var grid = Path()
        for i in stride(from: -60.0, through: 60.0, by: 9.0) {
            grid.move(to: CGPoint(x: i - 40, y: hoopCentre.y - 10))
            grid.addLine(to: CGPoint(x: i + 40, y: hoopCentre.y + 90))
            grid.move(to: CGPoint(x: i + 40, y: hoopCentre.y - 10))
            grid.addLine(to: CGPoint(x: i - 40, y: hoopCentre.y + 90))
        }
        mesh.stroke(grid, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
        ctx.stroke(bag, with: .color(ink), lineWidth: 2)

        // Hoop.
        let hoop = Path(ellipseIn: CGRect(x: -hoopRadius, y: hoopCentre.y - 12, width: hoopRadius * 2, height: 24))
        ctx.stroke(hoop, with: .color(ink), lineWidth: 8)
        ctx.stroke(hoop, with: .color(Color(red: 0.86, green: 0.30, blue: 0.27)), lineWidth: 4)
    }

    private static func fillAndOutline(_ context: GraphicsContext, _ path: Path, _ colour: Color) {
        context.fill(path, with: .color(colour))
        context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: outlineWidth, lineJoin: .round))
    }
}

#Preview {
    SplashView(status: "Starting camera…")
        .frame(width: 960, height: 640)
}
