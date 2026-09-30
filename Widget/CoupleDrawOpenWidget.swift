import SwiftUI
import WidgetKit

private struct OpenEntry: TimelineEntry {
    let date: Date
}

private struct OpenProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenEntry { OpenEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (OpenEntry) -> Void) {
        completion(OpenEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenEntry>) -> Void) {
        completion(Timeline(entries: [OpenEntry(date: .now)], policy: .never))
    }
}

private struct OpenWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "heart.circle.fill")
                    .font(.title2)
                    .accessibilityLabel("Open CoupleDraw")
            case .accessoryRectangular:
                HStack(spacing: 6) {
                    Image(systemName: "pencil.tip.crop.circle")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CoupleDraw").font(.caption.bold())
                        Text("Tap to draw").font(.caption2)
                    }
                }
            case .accessoryInline:
                Label("Open CoupleDraw", systemImage: "heart.fill")
            default:
                Image(systemName: "heart.fill")
            }
        }
        .widgetURL(URL(string: "coupledraw://open"))
        .containerBackground(.clear, for: .widget)
    }
}

@main struct CoupleDrawOpenWidget: Widget {
    let kind = "CoupleDrawOpenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OpenProvider()) { _ in
            OpenWidgetView()
        }
        .configurationDisplayName("Open CoupleDraw")
        .description("Open the drawing editor from your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
