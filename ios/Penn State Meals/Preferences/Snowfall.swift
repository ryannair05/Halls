//
//  Snowfall.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 12/2/24.
//

import SwiftUI
import WeatherKit

enum WeatherCondition: Equatable {
    case clear
    case rainy(windSpeed: CGFloat)
    case stormy(windSpeed: CGFloat)
    case snowy(windSpeed: CGFloat)
}

/// Stable raw values are persisted independently of the live weather reading.
enum ManualWeatherEffect: String, CaseIterable {
    case none, snowfall, rain, storm

    var title: LocalizedStringResource {
        switch self {
        case .none: "None"
        case .snowfall: "Snowfall"
        case .rain: "Rain"
        case .storm: "Heavy Rain"
        }
    }

    var requiresPro: Bool { self != .none && self != .snowfall }

    var condition: WeatherCondition {
        switch self {
        case .none: .clear
        case .snowfall: .snowy(windSpeed: 5)
        case .rain: .rainy(windSpeed: 50)
        case .storm: .stormy(windSpeed: 100)
        }
    }
}

extension UIImage {
    /// Creates a new version of the image, baking in a new size and tint color.
    /// This method is suitable for generating a CGImage for use in Core Animation layers like CAEmitterCell.
    /// - Parameters:
    ///   - size: The new size for the image. If nil, the original size is used.
    ///   - color: The color to bake into the image. If nil, the original colors are used.
    /// - Returns: A new, configured UIImage instance.
    func withConfiguration(size: CGSize? = nil, color: UIColor? = nil) -> UIImage {
        let finalSize = size ?? self.size
        
        // Create a new graphics context to draw into.
        let renderer = UIGraphicsImageRenderer(size: finalSize)
        
        let newImage = renderer.image { context in
            let rect = CGRect(origin: .zero, size: finalSize)
            
            // If a color is provided, we use the image as a mask to draw the color.
            if let tintColor = color {
                // 1. Fill the entire context with the desired tint color.
                tintColor.setFill()
                UIRectFill(rect)
                
                // 2. Draw the image's alpha channel using the .destinationIn blend mode.
                // This effectively "cuts out" the shape of the image from the colored background.
                self.draw(in: rect, blendMode: .destinationIn, alpha: 0.5)
            } else {
                // If no color, just draw the original image resized.
                self.draw(in: rect)
            }
        }
        
        return newImage
    }
}

@MainActor
final class WeatherEmitterView: UIView {
    
    // MARK: - Emitter Layers
    private var emitterLayers: [CAEmitterLayer] = []
    private var displayedCondition: WeatherCondition?

    // MARK: - Initializers
    init() {
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Method
    public func updateWeather(with condition: WeatherCondition) {
        guard displayedCondition != condition else { return }
        displayedCondition = condition
        reset()
        
        switch condition {
        case .clear, .rainy, .stormy:
            break // Rain is rendered by SwiftUI shaders.
        case .snowy(let windSpeed):
            setupSnow(windSpeed: windSpeed)
        }
    }

    // MARK: - Effect Setups
    
    private func setupSnow(windSpeed: CGFloat) {
        let emitter = CAEmitterLayer()
        
        let cell = CAEmitterCell()
        cell.contents = snowImage
        cell.birthRate = 15.0
        cell.lifetime = 20.0
        cell.velocity = -30
        cell.velocityRange = 100
        cell.yAcceleration = 30
        cell.xAcceleration = windSpeed // ✨ Wind effect!
        cell.scale = 0.2
        cell.scaleRange = 0.15
        cell.spin = 0.5
        cell.spinRange = 1.0
        cell.emissionRange = .pi
        cell.color = UIColor.white.withAlphaComponent(0.8).cgColor

        emitter.emitterShape = .line
        emitter.emitterCells = [cell]
        add(emitter: emitter)
    }

    private var snowImage: CGImage? {
        UIImage(named: "XMASSnowflake", in: .main, compatibleWith: traitCollection)?.cgImage
    }

    // MARK: - Layout & Management
    private func add(emitter: CAEmitterLayer, at index: Int? = nil) {
        if let i = index {
            layer.insertSublayer(emitter, at: UInt32(i))
        } else {
            layer.addSublayer(emitter)
        }
        emitterLayers.append(emitter)
        layoutEmitters()
    }
    
    private func reset() {
        emitterLayers.forEach { $0.removeFromSuperlayer() }
        emitterLayers.removeAll()
    }
    
    private func layoutEmitters() {
        emitterLayers.forEach { emitter in
            emitter.frame = bounds
            if emitter.emitterShape == .line {
                emitter.emitterPosition = CGPoint(x: bounds.midX, y: -50)
                emitter.emitterSize = CGSize(width: bounds.width, height: 0)
            }
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutEmitters()
    }
}

@MainActor
struct SnowEmitterView: UIViewRepresentable {
    
    var condition: WeatherCondition
    
    func makeUIView(context: Context) -> WeatherEmitterView {
        return WeatherEmitterView()
    }
    
    func updateUIView(_ uiView: WeatherEmitterView, context: Context) {
        uiView.updateWeather(with: condition)
    }
}

func mapWeatherKitToCondition(currentWeather: CurrentWeather) -> WeatherCondition {
    let windSpeed = currentWeather.wind.speed.converted(to: .kilometersPerHour).value
    
    let windEffect = CGFloat(windSpeed) * 5.0 // Adjust multiplier for visual effect

    switch currentWeather.condition {
    case .rain, .drizzle, .heavyRain:
        return .rainy(windSpeed: windEffect)
    case .strongStorms, .thunderstorms, .hail:
        return .stormy(windSpeed: windEffect)
    case .snow, .flurries, .heavySnow, .blizzard:
        return .snowy(windSpeed: windEffect)
    default:
        return .clear
    }
}
