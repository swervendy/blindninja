import AppKit

/// CSS-equivalent state dot — colored circle with optional glow/pulse animation.
final class StateDotView: NSView {
    private let state: SessionState
    private let theme: AppTheme

    init(state: SessionState, theme: AppTheme) {
        self.state = state
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        wantsLayer = true
        setupDot()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    private func setupDot() {
        guard let layer = layer else { return }

        layer.cornerRadius = 3
        layer.masksToBounds = false

        let color: NSColor
        switch state {
        case .waiting:
            color = theme.idleColor
        case .blocked:
            color = theme.blockedColor
            addGlow(color: color)
        case .working:
            color = theme.workingColor
            addPulse(color: color)
        case .idle:
            color = theme.idleColor
            layer.opacity = 0.5
        case .new:
            color = theme.idleColor
            layer.opacity = 0.3
        }

        layer.backgroundColor = color.cgColor
    }

    /// Soft glow effect (matches CSS box-shadow on waiting/blocked dots)
    private func addGlow(color: NSColor) {
        guard let layer = layer else { return }
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 4
        layer.shadowOpacity = 0.6
    }

    /// Pulsing animation (matches CSS @keyframes pulse on working dots)
    private func addPulse(color: NSColor) {
        guard let layer = layer else { return }

        // Glow base
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 3
        layer.shadowOpacity = 0.4

        // Opacity pulse: 0.5 -> 1.0 -> 0.5
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
