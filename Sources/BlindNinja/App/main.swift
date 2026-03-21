import AppKit

let app = NSApplication.shared
// Required when running as a bare executable (not a .app bundle) —
// without this, macOS treats the process as a background app and
// keyboard events never reach the window.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
