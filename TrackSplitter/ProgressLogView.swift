import SwiftUI

struct ProgressLogView: View {
    let logLines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
            .onChange(of: logLines.count) { _ in
                guard let last = logLines.indices.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
