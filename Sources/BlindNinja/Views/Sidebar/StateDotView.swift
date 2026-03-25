import AppKit

/// State indicator view — renders as dot, ring, or bar depending on settings.
final class StateDotView: NSView {
    private let state: SessionState
    private let theme: AppTheme
    private let style: IndicatorStyle
    private let density: SidebarDensity

    init(state: SessionState, theme: AppTheme,
         style: IndicatorStyle = SidebarSettings.indicatorStyle,
         density: SidebarDensity = SidebarSettings.density) {
        self.state = state
        self.theme = theme
        self.style = style
        self.density = density
        super.init(frame: .zero)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Intrinsic size based on style & density.
    var indicatorSize: NSSize {
        switch style {
        case .dot, .ring, .glow:
            let s = density.dotSize
            return NSSize(width: s, height: s)
        case .bar:
            return NSSize(width: density.barWidth, height: 0) // height stretches to row
        case .none:
            return NSSize(width: 0, height: 0)
        }
    }

    override var intrinsicContentSize: NSSize { indicatorSize }

    override func layout() {
        super.layout()
        switch style {
        case .dot, .ring, .glow:
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        case .bar:
            layer?.cornerRadius = density.barWidth / 2
        case .none:
            break
        }
    }

    private func setup() {
        guard let layer = layer else { return }
        layer.masksToBounds = false

        let color = stateColor()
        let opacity = stateOpacity()
        layer.opacity = opacity

        switch style {
        case .dot:
            setupDot(color: color, layer: layer)
        case .ring:
            setupRing(color: color, layer: layer)
        case .bar:
            setupBar(color: color, layer: layer)
        case .glow:
            setupGlow(color: color, layer: layer)
        case .none:
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - State helpers

    private func stateColor() -> NSColor {
        switch state {
        case .waiting:  return theme.idleColor
        case .blocked:  return theme.blockedColor
        case .working:  return theme.workingColor
        case .idle:     return theme.idleColor
        case .new:      return theme.idleColor
        }
    }

    private func stateOpacity() -> Float {
        switch state {
        case .idle: return 0.6
        case .new:  return 0.35
        default:    return 1.0
        }
    }

    // MARK: - Dot style (filled circle with optional glow)

    private func setupDot(color: NSColor, layer: CALayer) {
        layer.backgroundColor = color.cgColor
        layer.cornerRadius = density.dotSize / 2

        switch state {
        case .blocked:
            addGlow(color: color, layer: layer)
            addBorder(color: color, opacity: 0.4, layer: layer)
        case .working:
            addPulse(color: color, layer: layer)
            addBorder(color: color, opacity: 0.35, layer: layer)
        case .waiting:
            addBorder(color: color, opacity: 0.3, layer: layer)
        case .idle:
            addBorder(color: color, opacity: 0.2, layer: layer)
        case .new:
            break
        }
    }

    // MARK: - Ring style (hollow circle, fill on active states)

    private func setupRing(color: NSColor, layer: CALayer) {
        layer.cornerRadius = density.dotSize / 2

        switch state {
        case .working:
            // Filled ring with glow
            layer.backgroundColor = color.cgColor
            layer.borderWidth = 2
            layer.borderColor = color.withAlphaComponent(0.5).cgColor
            addPulse(color: color, layer: layer)
        case .blocked:
            layer.backgroundColor = color.cgColor
            layer.borderWidth = 2
            layer.borderColor = color.withAlphaComponent(0.5).cgColor
            addGlow(color: color, layer: layer)
        case .waiting:
            // Half-filled: ring with dim fill
            layer.backgroundColor = color.withAlphaComponent(0.25).cgColor
            layer.borderWidth = 1.5
            layer.borderColor = color.cgColor
        case .idle:
            // Hollow ring
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 1.5
            layer.borderColor = color.cgColor
        case .new:
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 1
            layer.borderColor = color.withAlphaComponent(0.5).cgColor
        }
    }

    // MARK: - Bar style (vertical left-edge bar)

    private func setupBar(color: NSColor, layer: CALayer) {
        layer.backgroundColor = color.cgColor
        layer.cornerRadius = density.barWidth / 2

        switch state {
        case .blocked:
            addGlow(color: color, layer: layer)
        case .working:
            addPulse(color: color, layer: layer)
        default:
            break
        }
    }

    // MARK: - Glow style (soft radial glow, no hard edge)

    private func setupGlow(color: NSColor, layer: CALayer) {
        layer.backgroundColor = color.cgColor
        layer.cornerRadius = density.dotSize / 2

        switch state {
        case .blocked:
            layer.shadowColor = color.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 8
            layer.shadowOpacity = 0.9
        case .working:
            layer.shadowColor = color.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 6
            layer.shadowOpacity = 0.7
            addPulse(color: color, layer: layer)
        case .waiting:
            layer.shadowColor = color.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.5
        case .idle:
            layer.shadowColor = color.cgColor
            layer.shadowOffset = .zero
            layer.shadowRadius = 3
            layer.shadowOpacity = 0.3
        case .new:
            break
        }
    }

    // MARK: - Effects

    private func addBorder(color: NSColor, opacity: CGFloat, layer: CALayer) {
        layer.borderWidth = 1.5
        layer.borderColor = color.withAlphaComponent(opacity).cgColor
    }

    private func addGlow(color: NSColor, layer: CALayer) {
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 5
        layer.shadowOpacity = 0.7
    }

    private func addPulse(color: NSColor, layer: CALayer) {
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 4
        layer.shadowOpacity = 0.5

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.5
        pulse.toValue = 1.0
        pulse.duration = 1.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
