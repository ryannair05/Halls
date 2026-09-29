//
//  AppIcon.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 2/16/25.
//

import SwiftUI

@MainActor
/// Shared SVG-derived brand animation. Each appearance draws once; Reduce Motion
/// shows the finished mark immediately. Callers provide the square display size.
struct AnimatedAppLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var bubbleProgress: CGFloat = 0
    @State private var forkProgress: CGFloat = 0
    @State private var finish: Double = 0

    var body: some View {
        ZStack {
            AppLogoShape(part: .bubble)
                .fill(LinearGradient(colors: [.cyan, Color(red: 0.02, green: 0.39, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(0.08 + finish * 0.92)
                .shadow(color: .blue.opacity(0.18 * finish), radius: 14, y: 8)
            AppLogoShape(part: .bubble)
                .trim(from: 0, to: bubbleProgress)
                .stroke(.cyan, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .opacity(1 - finish * 0.8)
            ZStack {
                AppLogoShape(part: .fork)
                    .fill(
                        LinearGradient(colors: [.white, Color(red: 0.72, green: 0.90, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: FillStyle(eoFill: true)
                    )
                    .opacity(finish)
                    .shadow(color: .blue.opacity(0.22), radius: 2, y: 2)
                AppLogoShape(part: .fork)
                    .stroke(colorScheme == .dark ? .white : Color(red: 0.12, green: 0.48, blue: 0.78), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .opacity(1 - finish)
            }
            .mask(alignment: .bottom) {
                GeometryReader { geometry in
                    Rectangle()
                        .frame(height: geometry.size.height * forkProgress)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        // The supplied icon clips the long fork handle at its 1024-point artboard.
        // Fade that edge for a standalone mark instead of showing a hard crop.
        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .scaleEffect(0.96 + finish * 0.04)
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            bubbleProgress = reduceMotion ? 1 : 0
            forkProgress = reduceMotion ? 1 : 0
            finish = reduceMotion ? 1 : 0
            guard !reduceMotion else { return }
            do {
                withAnimation(.easeInOut(duration: 0.75)) { bubbleProgress = 1 }
                try await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeInOut(duration: 0.75)) { forkProgress = 1 }
                try await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeInOut(duration: 0.5)) { finish = 1 }
            } catch {
                // SwiftUI cancels this sequence when the artwork disappears.
            }
        }
    }
}

/// Geometry transcribed from the supplied final iOS 26 icon SVGs.
/// Paths are cached and transformed together to preserve their shared artboard.
private struct AppLogoShape: Shape {
    enum Part { case bubble, fork }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 1024
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: rect.midX - 512 * scale, ty: rect.midY - 512 * scale)
        return (part == .bubble ? Self.bubble : Self.fork).applying(transform)
    }

    private static let bubble: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 648.780, y: 773.250))
        path.addCurve(to: CGPoint(x: 904.780, y: 517.250), control1: CGPoint(x: 847.530, y: 773.250), control2: CGPoint(x: 904.780, y: 716.000))
        path.addLine(to: CGPoint(x: 904.780, y: 404.280))
        path.addCurve(to: CGPoint(x: 648.780, y: 148.280), control1: CGPoint(x: 904.780, y: 205.530), control2: CGPoint(x: 847.530, y: 148.280))
        path.addLine(to: CGPoint(x: 375.220, y: 148.280))
        path.addCurve(to: CGPoint(x: 119.220, y: 404.280), control1: CGPoint(x: 176.470, y: 148.280), control2: CGPoint(x: 119.220, y: 205.530))
        path.addLine(to: CGPoint(x: 119.220, y: 646.450))
        path.addCurve(to: CGPoint(x: 226.160, y: 772.690), control1: CGPoint(x: 119.220, y: 709.850), control2: CGPoint(x: 165.420, y: 762.560))
        path.addCurve(to: CGPoint(x: 246.220, y: 796.110), control1: CGPoint(x: 237.680, y: 774.610), control2: CGPoint(x: 246.220, y: 784.430))
        path.addLine(to: CGPoint(x: 246.220, y: 871.680))
        path.addCurve(to: CGPoint(x: 284.720, y: 890.810), control1: CGPoint(x: 246.220, y: 891.510), control2: CGPoint(x: 268.910, y: 902.790))
        path.addLine(to: CGPoint(x: 405.520, y: 799.230))
        path.addCurve(to: CGPoint(x: 482.850, y: 773.230), control1: CGPoint(x: 427.770, y: 782.360), control2: CGPoint(x: 454.930, y: 773.230))
        path.addLine(to: CGPoint(x: 648.780, y: 773.230))
        path.closeSubpath()
        return path
    }()

    private static let fork: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 689.590, y: 393.940))
        path.addCurve(to: CGPoint(x: 683.510, y: 254.990), control1: CGPoint(x: 685.560, y: 339.570), control2: CGPoint(x: 683.510, y: 309.490))
        path.addLine(to: CGPoint(x: 683.510, y: 252.690))
        path.addCurve(to: CGPoint(x: 652.390, y: 223.710), control1: CGPoint(x: 683.510, y: 236.690), control2: CGPoint(x: 669.580, y: 223.710))
        path.addLine(to: CGPoint(x: 652.390, y: 223.710))
        path.addCurve(to: CGPoint(x: 621.270, y: 252.690), control1: CGPoint(x: 635.200, y: 223.710), control2: CGPoint(x: 621.270, y: 236.680))
        path.addLine(to: CGPoint(x: 621.270, y: 426.860))
        path.addCurve(to: CGPoint(x: 582.370, y: 463.080), control1: CGPoint(x: 621.270, y: 446.860), control2: CGPoint(x: 603.850, y: 463.080))
        path.addLine(to: CGPoint(x: 582.370, y: 463.080))
        path.addCurve(to: CGPoint(x: 543.470, y: 426.860), control1: CGPoint(x: 560.880, y: 463.080), control2: CGPoint(x: 543.470, y: 446.860))
        path.addLine(to: CGPoint(x: 543.470, y: 252.690))
        path.addCurve(to: CGPoint(x: 512.350, y: 223.710), control1: CGPoint(x: 543.470, y: 236.690), control2: CGPoint(x: 529.540, y: 223.710))
        path.addCurve(to: CGPoint(x: 481.230, y: 252.690), control1: CGPoint(x: 495.160, y: 223.710), control2: CGPoint(x: 481.230, y: 236.680))
        path.addLine(to: CGPoint(x: 481.230, y: 426.860))
        path.addCurve(to: CGPoint(x: 442.330, y: 463.080), control1: CGPoint(x: 481.230, y: 446.860), control2: CGPoint(x: 463.810, y: 463.080))
        path.addLine(to: CGPoint(x: 442.330, y: 463.080))
        path.addCurve(to: CGPoint(x: 403.430, y: 426.860), control1: CGPoint(x: 420.840, y: 463.080), control2: CGPoint(x: 403.430, y: 446.860))
        path.addLine(to: CGPoint(x: 403.430, y: 252.690))
        path.addCurve(to: CGPoint(x: 372.310, y: 223.710), control1: CGPoint(x: 403.430, y: 236.690), control2: CGPoint(x: 389.500, y: 223.710))
        path.addLine(to: CGPoint(x: 372.310, y: 223.710))
        path.addCurve(to: CGPoint(x: 341.190, y: 252.690), control1: CGPoint(x: 355.120, y: 223.710), control2: CGPoint(x: 341.190, y: 236.680))
        path.addLine(to: CGPoint(x: 341.190, y: 254.990))
        path.addCurve(to: CGPoint(x: 335.100, y: 393.940), control1: CGPoint(x: 341.190, y: 309.490), control2: CGPoint(x: 339.130, y: 339.570))
        path.addCurve(to: CGPoint(x: 325.870, y: 520.530), control1: CGPoint(x: 332.060, y: 434.990), control2: CGPoint(x: 325.870, y: 486.930))
        path.addCurve(to: CGPoint(x: 369.560, y: 658.320), control1: CGPoint(x: 327.830, y: 570.860), control2: CGPoint(x: 341.090, y: 619.270))
        path.addCurve(to: CGPoint(x: 443.780, y: 739.630), control1: CGPoint(x: 392.140, y: 689.290), control2: CGPoint(x: 423.280, y: 705.510))
        path.addCurve(to: CGPoint(x: 463.600, y: 868.600), control1: CGPoint(x: 471.250, y: 785.340), control2: CGPoint(x: 467.350, y: 817.930))
        path.addCurve(to: CGPoint(x: 432.020, y: 1267.570), control1: CGPoint(x: 453.770, y: 1001.550), control2: CGPoint(x: 441.370, y: 1134.500))
        path.addCurve(to: CGPoint(x: 443.940, y: 1358.230), control1: CGPoint(x: 429.570, y: 1302.410), control2: CGPoint(x: 421.930, y: 1327.040))
        path.addCurve(to: CGPoint(x: 512.020, y: 1393.220), control1: CGPoint(x: 460.640, y: 1381.910), control2: CGPoint(x: 486.400, y: 1393.360))
        path.addCurve(to: CGPoint(x: 580.100, y: 1358.230), control1: CGPoint(x: 537.640, y: 1393.350), control2: CGPoint(x: 563.390, y: 1381.910))
        path.addCurve(to: CGPoint(x: 592.020, y: 1267.570), control1: CGPoint(x: 602.100, y: 1327.030), control2: CGPoint(x: 594.470, y: 1302.410))
        path.addCurve(to: CGPoint(x: 560.440, y: 868.600), control1: CGPoint(x: 582.670, y: 1134.500), control2: CGPoint(x: 570.270, y: 1001.560))
        path.addCurve(to: CGPoint(x: 580.260, y: 739.630), control1: CGPoint(x: 556.690, y: 817.930), control2: CGPoint(x: 552.790, y: 785.340))
        path.addCurve(to: CGPoint(x: 654.480, y: 658.320), control1: CGPoint(x: 600.760, y: 705.510), control2: CGPoint(x: 631.900, y: 689.290))
        path.addCurve(to: CGPoint(x: 698.170, y: 520.530), control1: CGPoint(x: 682.950, y: 619.270), control2: CGPoint(x: 696.210, y: 570.860))
        path.addCurve(to: CGPoint(x: 689.610, y: 393.940), control1: CGPoint(x: 698.170, y: 486.930), control2: CGPoint(x: 692.650, y: 434.990))
        path.closeSubpath()
        path.move(to: CGPoint(x: 435.210, y: 595.380))
        path.addCurve(to: CGPoint(x: 387.370, y: 595.380), control1: CGPoint(x: 422.000, y: 608.590), control2: CGPoint(x: 400.580, y: 608.590))
        path.addCurve(to: CGPoint(x: 387.370, y: 547.540), control1: CGPoint(x: 374.160, y: 582.170), control2: CGPoint(x: 374.160, y: 560.750))
        path.addCurve(to: CGPoint(x: 435.210, y: 547.540), control1: CGPoint(x: 400.580, y: 534.330), control2: CGPoint(x: 422.000, y: 534.330))
        path.addCurve(to: CGPoint(x: 435.210, y: 595.380), control1: CGPoint(x: 448.420, y: 560.750), control2: CGPoint(x: 448.420, y: 582.170))
        path.closeSubpath()
        path.move(to: CGPoint(x: 533.530, y: 595.380))
        path.addCurve(to: CGPoint(x: 485.690, y: 595.380), control1: CGPoint(x: 520.320, y: 608.590), control2: CGPoint(x: 498.900, y: 608.590))
        path.addCurve(to: CGPoint(x: 485.690, y: 547.540), control1: CGPoint(x: 472.480, y: 582.170), control2: CGPoint(x: 472.480, y: 560.750))
        path.addCurve(to: CGPoint(x: 533.530, y: 547.540), control1: CGPoint(x: 498.900, y: 534.330), control2: CGPoint(x: 520.320, y: 534.330))
        path.addCurve(to: CGPoint(x: 533.530, y: 595.380), control1: CGPoint(x: 546.740, y: 560.750), control2: CGPoint(x: 546.740, y: 582.170))
        path.closeSubpath()
        path.move(to: CGPoint(x: 631.850, y: 595.380))
        path.addCurve(to: CGPoint(x: 584.010, y: 595.380), control1: CGPoint(x: 618.640, y: 608.590), control2: CGPoint(x: 597.220, y: 608.590))
        path.addCurve(to: CGPoint(x: 584.010, y: 547.540), control1: CGPoint(x: 570.800, y: 582.170), control2: CGPoint(x: 570.800, y: 560.750))
        path.addCurve(to: CGPoint(x: 631.850, y: 547.540), control1: CGPoint(x: 597.220, y: 534.330), control2: CGPoint(x: 618.640, y: 534.330))
        path.addCurve(to: CGPoint(x: 631.850, y: 595.380), control1: CGPoint(x: 645.060, y: 560.750), control2: CGPoint(x: 645.060, y: 582.170))
        path.closeSubpath()
        return path
    }()
}
