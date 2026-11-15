import Foundation

/// Resolves what a key really does on a layer: a Transparent key falls through to the layer below.
public enum KeymapResolver {
    /// `inherited` is true when `layer`'s own code is Transparent and a lower layer supplied `code`.
    public static func effective(keymap: [[UInt16]], layer: Int, position: Int) -> (code: UInt16, inherited: Bool) {
        guard keymap.indices.contains(layer), keymap[layer].indices.contains(position) else { return (Keycode.none, false) }
        var l = layer
        while keymap[l][position] == Keycode.transparent, l > 0, keymap[l - 1].indices.contains(position) { l -= 1 }
        let code = keymap[l][position]
        return (code, l != layer && code != Keycode.transparent)
    }
}
