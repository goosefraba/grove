import AppKit

extension NSImage {
    func resized(to size: NSSize) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect, from: NSRect(origin: .zero, size: self.size),
                      operation: .copy, fraction: 1.0)
            return true
        }
        result.isTemplate = self.isTemplate
        return result
    }
}
