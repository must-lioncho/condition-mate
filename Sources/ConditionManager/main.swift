import AppKit

// Entry point. Regular activation policy => Dock icon + app switcher, alongside the
// menu bar status item. This is the leanest possible AppKit lifecycle: one
// NSApplication, one delegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
