import AppKit

// Entry point. Accessory activation policy => no Dock icon, menu bar only.
// This is the leanest possible AppKit lifecycle: one NSApplication, one delegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
