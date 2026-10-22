import WidgetKit
import SwiftUI

struct GarageEntry: TimelineEntry {
    let date: Date; let vehicle: String; let item: String; let km: Int; let days: Int; let tow: String
}

struct GarageProvider: TimelineProvider {
    func placeholder(in context: Context) -> GarageEntry { .init(date: .now, vehicle: "My Car", item: "Oil Change", km: 1200, days: 20, tow: "") }
    func getSnapshot(in context: Context, completion: @escaping (GarageEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GarageEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(1800))))
    }
    private func entry() -> GarageEntry {
        let d = SharedStore.read()
        return .init(date: .now, vehicle: d?.vehicle ?? "Add a vehicle", item: d?.item ?? "–", km: d?.km ?? 0, days: d?.days ?? 0, tow: d?.tow ?? "")
    }
}

struct GarageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let e: GarageEntry
    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading) { Text(e.item).bold(); Text(e.km <= 0 ? "Overdue" : "in \(e.km) km") }
        case .accessoryCircular:
            Gauge(value: Double(max(0, min(e.km, 5000))), in: 0...5000) { Image(systemName: "wrench.fill") }.gaugeStyle(.accessoryCircular)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label(e.vehicle, systemImage: "car.fill").font(.caption).lineLimit(1)
                Text(e.item).font(.headline)
                Text(e.km <= 0 ? "Overdue!" : "Due in \(e.km) km / ~\(e.days) d").font(.subheadline).foregroundStyle(e.km <= 0 ? .red : .primary)
                if !e.tow.isEmpty { Label(e.tow, systemImage: "truck.box.fill").font(.caption).foregroundStyle(.blue) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct GarageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GarageWidget", provider: GarageProvider()) { e in
            GarageWidgetView(e: e).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Vehicle Health")
        .description("Next predicted service and tow status.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}
