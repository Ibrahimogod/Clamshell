import AppIntents
import SwiftUI
import WidgetKit

/// The Home Screen / Lock Screen widget and the Control Center control (1.1). Both just open the app at
/// `clamshell://connect`; the app picks the way to the Mac.
@main
struct ClamshellWidgets: WidgetBundle {
    var body: some Widget {
        ConnectWidget()
        ConnectControl()
    }
}

struct ConnectEntry: TimelineEntry { let date: Date }

struct ConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConnectEntry { ConnectEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ConnectEntry) -> Void) { completion(ConnectEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ConnectEntry>) -> Void) {
        completion(Timeline(entries: [ConnectEntry(date: .now)], policy: .never))
    }
}

struct ConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "connect", provider: ConnectProvider()) { _ in ConnectWidgetView() }
            .configurationDisplayName("Connect to Mac")
            .description("Opens Clamshell and connects to your Mac.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct ConnectWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "laptopcomputer.and.iphone").font(.title3)
            case .accessoryRectangular:
                Label("Connect to Mac", systemImage: "laptopcomputer.and.iphone")
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.title)
                    Spacer()
                    Text("Connect").font(.headline)
                    Text("to my Mac").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.11, green: 0.10, blue: 0.10) }
        .widgetURL(URL(string: "clamshell://connect"))
    }
}

struct ConnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "connect-control") {
            ControlWidgetButton(action: ConnectToMacIntent()) {
                Label("Connect to Mac", systemImage: "laptopcomputer.and.iphone")
            }
        }
        .displayName("Connect to Mac")
        .description("Opens Clamshell and connects to your Mac.")
    }
}
