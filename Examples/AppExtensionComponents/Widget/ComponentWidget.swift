@preconcurrency import Foundation
import LatchwayAppExtensions
import SwiftUI
@preconcurrency import WidgetKit

struct ComponentEntry: TimelineEntry {
    let date: Date
    let status: String
}

struct ComponentProvider: TimelineProvider {
    func placeholder(in _: Context) -> ComponentEntry {
        ComponentEntry(date: Date(), status: "Waiting for containing app")
    }

    func getSnapshot(in _: Context, completion: @escaping (ComponentEntry) -> Void) {
        completion(ComponentEntry(date: Date(), status: "Latchway component"))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ComponentEntry>) -> Void) {
        let completion = LegacyTimelineCompletion(completion)
        Task {
            let entry = await loadEntry()
            completion.call(Timeline(
                entries: [entry],
                policy: .after(Date().addingTimeInterval(15 * 60))
            ))
        }
    }

    private func loadEntry() async -> ComponentEntry {
        do {
            let configuration = try ComponentExampleConfiguration.latchway()
            let component = try ComponentExampleConfiguration.widget()
            let feature = try ComponentExampleConfiguration.feature(for: component)
            let client = try LatchwayExtensionClient(
                configuration: configuration,
                component: component
            )
            let transport = client.transport(feature: feature)
            var request = URLRequest(url: try transport.endpoint(path: "v1/responses"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"input":"Return a short weekly summary.","stream":false}"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let response = try await transport.send(request)
            let status = (200 ... 299).contains(response.statusCode)
                ? "Component request authorized"
                : "Gateway HTTP \(response.statusCode)"
            return ComponentEntry(date: Date(), status: status)
        } catch let error as LatchwayComponentError {
            return ComponentEntry(date: Date(), status: error.recovery.action)
        } catch {
            return ComponentEntry(date: Date(), status: "Latchway request unavailable")
        }
    }
}

/// WidgetKit's iOS 15 callback predates Sendable annotations. This immutable,
/// single-use bridge does not introduce shared mutable state; it only carries
/// WidgetKit's completion into the asynchronous timeline operation.
private final class LegacyTimelineCompletion: @unchecked Sendable {
    private let callback: (Timeline<ComponentEntry>) -> Void

    init(_ callback: @escaping (Timeline<ComponentEntry>) -> Void) {
        self.callback = callback
    }

    func call(_ timeline: Timeline<ComponentEntry>) {
        callback(timeline)
    }
}

struct ComponentWidgetView: View {
    let entry: ComponentEntry

    var body: some View {
        VStack(alignment: .leading) {
            Text("Weekly summary").font(.headline)
            Text(entry.status).font(.caption)
        }
        .padding()
    }
}

@main
struct ComponentWidget: Widget {
    let kind = "LatchwayComponentWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComponentProvider()) { entry in
            ComponentWidgetView(entry: entry)
        }
        .configurationDisplayName("Latchway component")
        .description("Exercises an independently keyed Latchway widget session.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
