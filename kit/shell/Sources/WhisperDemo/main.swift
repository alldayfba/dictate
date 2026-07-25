import AppKit

// Entry point. LSUIElement in Info.plist keeps us out of the Dock; accessory policy
// is set again in the delegate as belt-and-suspenders.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
