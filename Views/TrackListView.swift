import SwiftUI
import TrackSplitterLib

/// 曲目预览列表组件。
struct TrackListView: View {
    /// 需要展示的曲目集合。
    let tracks: [CueTrack]

    var body: some View {
        List(tracks, id: \.index) { track in
            HStack(spacing: 12) {
                Text(String(format: "%02d", track.index))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)

                Text(track.title.isEmpty ? "(未命名曲目)" : track.title)
                    .lineLimit(1)

                Spacer()

                Text(formattedDuration(for: track))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
    }

    /// 将曲目时长格式化为 mm:ss。
    private func formattedDuration(for track: CueTrack) -> String {
        guard let endSeconds = track.endSeconds else {
            return "--:--"
        }

        let duration = max(endSeconds - track.startSeconds, 0)
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
