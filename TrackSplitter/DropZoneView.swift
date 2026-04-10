import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    var isProcessing: Bool
    var onDropFile: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 3, dash: [10])
                )
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
                )

            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 40, weight: .medium))
                Text("Drop FLAC file here")
                    .font(.title2.weight(.semibold))
                Text(isProcessing ? "Track splitting in progress…" : "Requires a matching .cue file with the same name in the same folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted, perform: onDropFile)
    }
}
