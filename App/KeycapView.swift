import SwiftUI

/// One physical-feeling keycap: a face with a lip underneath, an accent ring when selected, and a dot when
/// its assignment changed this session. Sized and positioned by the canvas.
struct KeycapView: View {
    let label: String
    let isInherited: Bool       // Transparent: shows the key from the layer below, dimmed
    let isSelected: Bool
    let isChanged: Bool
    let unit: Double

    private var radius: Double { max(4, unit * 0.12) }

    var body: some View {
        let face = RoundedRectangle(cornerRadius: radius, style: .continuous)
        face
            .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            .overlay(face.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .overlay(face.inset(by: 1).strokeBorder(
                LinearGradient(colors: [Color(nsColor: .highlightColor).opacity(0.7), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1))
            .overlay(face.strokeBorder(Color.accentColor, lineWidth: 2.5).opacity(isSelected ? 1 : 0))
            .shadow(color: Color.primary.opacity(0.22), radius: 0, x: 0, y: 1.5)
            .overlay {
                Text(label)
                    .font(.system(size: min(max(unit * 0.28, 10), 16), weight: .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isInherited ? .secondary : .primary)
                    .opacity(isInherited ? 0.7 : 1)
                    .padding(.horizontal, 3)
            }
            .overlay(alignment: .bottomTrailing) {
                if isInherited {
                    Text("▽").font(.system(size: 10)).foregroundStyle(.secondary).padding(.trailing, 4).padding(.bottom, 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isChanged {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(4)
                }
            }
    }
}
