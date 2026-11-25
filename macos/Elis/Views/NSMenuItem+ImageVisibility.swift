import AppKit

extension NSMenuItem {
    /// keepsImageVisible stops macOS 27 hiding the item's image, which its default `preferredImageVisibility` does.
    func keepsImageVisible() {
        // macOS 27 SDK API the CI toolchain cannot name, so it is set by key; 1 is .visible
        if responds(to: NSSelectorFromString("setPreferredImageVisibility:")) { setValue(1, forKey: "preferredImageVisibility") }
    }
}
