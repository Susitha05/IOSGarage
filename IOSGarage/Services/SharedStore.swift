import Foundation
import WidgetKit

/// Bridge between the app and the WidgetKit extension through an App Group. Add this file to BOTH targets.
enum SharedStore {
    static let suite = "group.com.nibm.garage"      // ← change to your App Group id
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suite) }

    static func write(vehicle: String, item: String, kmRemaining: Int, daysRemaining: Int, tow: String) {
        defaults?.set(["vehicle": vehicle, "item": item, "km": kmRemaining, "days": daysRemaining, "tow": tow], forKey: "widget")
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func read() -> (vehicle: String, item: String, km: Int, days: Int, tow: String)? {
        guard let d = defaults?.dictionary(forKey: "widget") else { return nil }
        return (d["vehicle"] as? String ?? "", d["item"] as? String ?? "", d["km"] as? Int ?? 0, d["days"] as? Int ?? 0, d["tow"] as? String ?? "")
    }
}
