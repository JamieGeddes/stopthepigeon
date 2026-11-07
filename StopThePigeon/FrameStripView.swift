import SwiftUI

struct FrameStripView: View {
    let model: AppModel

    private static let liveID = "live-tile"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    if let project = model.project {
                        ForEach(Array(project.frames.enumerated()), id: \.element) { index, frame in
                            FrameThumbnail(
                                url: project.url(for: frame),
                                number: index + 1,
                                isSelected: model.selectedFrame == frame || model.playbackFrame == frame,
                                cache: model.images,
                                effect: model.activeEffect
                            )
                            .onTapGesture { model.stopPlayback(); model.selectedFrame = frame }
                            .contextMenu {
                                Button("Move Earlier") { model.selectedFrame = frame; model.moveSelectedFrame(by: -1) }
                                Button("Move Later") { model.selectedFrame = frame; model.moveSelectedFrame(by: 1) }
                                Divider()
                                Button("Delete Frame", role: .destructive) { model.selectedFrame = frame; model.deleteSelectedFrame() }
                            }
                            .id(frame)
                        }
                    }
                    LiveTile(isSelected: model.selectedFrame == nil && !model.isPlaying)
                        .onTapGesture { model.stopPlayback(); model.selectedFrame = nil }
                        .id(Self.liveID)
                }
                .padding(12)
            }
            .onChange(of: model.frames.count) { proxy.scrollTo(Self.liveID, anchor: .trailing) }
            .onChange(of: model.selectedFrame) { _, frame in
                withAnimation { proxy.scrollTo(frame ?? Self.liveID) }
            }
            .onChange(of: model.playbackFrame) { _, frame in
                if let frame { proxy.scrollTo(frame) }
            }
        }
    }
}

private struct FrameThumbnail: View {
    let url: URL
    let number: Int
    let isSelected: Bool
    let cache: FrameImageCache
    let effect: FrameEffect?

    var body: some View {
        FrameImageView(url: url, maxPixelSize: 240, cache: cache, effect: effect, contentMode: .fill)
            .frame(width: 104, height: 78)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .contentShape(Rectangle())
    }
}

private struct LiveTile: View {
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "video.fill")
            Text("Live").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(width: 104, height: 78)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(Rectangle())
    }
}
