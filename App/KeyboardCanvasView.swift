import KeycraftCore
import SwiftUI

/// The keyboard itself: caps at their true positions (rotated clusters included), scaled to fit the window.
/// Arrow keys move the selection, Return or Space jumps to the inspector, Escape deselects.
struct KeyboardCanvasView: View {
    @Bindable var session: KeyboardSession
    let definition: VIADefinition
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private static let padding = 28.0

    var body: some View {
        let geometry = KeyboardGeometry(keys: definition.keys)
        GeometryReader { proxy in
            let available = CGSize(width: proxy.size.width - 2 * Self.padding, height: proxy.size.height - 2 * Self.padding)
            let unit = geometry.unit(fitting: available)
            ScrollView([.horizontal, .vertical]) {
                caps(geometry: geometry, unit: unit)
                    .frame(width: geometry.bounds.width * unit, height: geometry.bounds.height * unit)
                    .padding(Self.padding)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: session.layer)
    }

    private func caps(geometry: KeyboardGeometry, unit: Double) -> some View {
        let gap = max(2, unit * 0.07)
        let layerName = Keycode.layerName(session.layer)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(definition.keys.enumerated()), id: \.offset) { index, key in
                let position = key.row * definition.cols + key.col
                let (code, inherited) = KeymapResolver.effective(keymap: session.keymap, layer: session.layer, position: position)
                let info = Keycode.info(code, protocolVersion: session.protocolVersion, custom: definition.customKeycodes)
                let own = Keycode.info(session.keymap[session.layer][position], protocolVersion: session.protocolVersion,
                                       custom: definition.customKeycodes)
                KeycapView(label: info.label, isInherited: inherited || own.code == Keycode.transparent,
                           isSelected: session.selectedKey == index,
                           isChanged: session.changed.contains(.init(layer: session.layer, position: position)),
                           unit: unit)
                    .frame(width: key.w * unit - gap, height: key.h * unit - gap)
                    // Hit area and accessibility frame belong to the cap itself; after .position they'd span the whole canvas.
                    .contentShape(Rectangle())
                    .onTapGesture { session.selectedKey = index; focused = true }
                    .help(own.code == Keycode.transparent ? "Uses the key from the layer below" : own.description)
                    .accessibilityElement()
                    .accessibilityLabel("\(own.name), row \(key.row), column \(key.col), \(layerName)")
                    .accessibilityHint("Double-tap to change")
                    .accessibilityAddTraits(session.selectedKey == index ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { session.selectedKey = index; store.showInspector = true }
                    .rotationEffect(.degrees(key.angle))
                    .position(x: geometry.centers[index].x * unit, y: geometry.centers[index].y * unit)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .escape]) { press in
            handle(press.key, geometry: geometry)
        }
    }

    private func handle(_ key: KeyEquivalent, geometry: KeyboardGeometry) -> KeyPress.Result {
        let direction: KeyboardGeometry.Direction? = switch key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        default: nil
        }
        if let direction {
            guard let current = session.selectedKey else { session.selectedKey = 0; return .handled }
            if let next = geometry.neighbour(of: current, direction) { session.selectedKey = next }
            return .handled
        }
        switch key {
        case .escape:
            session.selectedKey = nil
        default:   // Return or Space
            guard session.selectedKey != nil else { return .ignored }
            store.showInspector = true
            session.pickerFocusRequest += 1
        }
        return .handled
    }
}
