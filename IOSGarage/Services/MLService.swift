import Foundation
import CoreML

/// On-device intelligence. Uses Create ML models bundled as `.mlmodelc` when present,
/// and falls back to transparent rule/statistical methods so the app works before models are trained.
final class MLService {
    static let shared = MLService()
    private lazy var maintenanceModel = load("MaintenancePredictor")
    private lazy var noShowModel = load("NoShowClassifier")

    private func load(_ name: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { return nil }
        return try? MLModel(contentsOf: url)
    }

    // MARK: 1. Predictive maintenance (BoostedTreeRegressor → kmUntilDue)
    func predictMaintenance(for v: Vehicle, now: Date = .now) -> [MaintenancePrediction] {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: v.year)) ?? now
        let ageMonths = max(1, Double(cal.dateComponents([.month], from: start, to: now).month ?? 1))
        let avgKmPerMonth = max(100, Double(v.mileage) / ageMonths)

        return ServiceType.tracked.compactMap { c -> MaintenancePrediction? in
            let last = v.services.filter { $0.type == c.rawValue }.max { $0.date < $1.date }
            let kmSince = max(0, Double(v.mileage - (last?.mileage ?? 0)))
            let daysSince = last.map { Double(cal.dateComponents([.day], from: $0.date, to: now).day ?? 0) } ?? ageMonths * 30.4

            let rule = Self.ruleRemaining(c, kmSince: kmSince, daysSince: daysSince, avgKmPerMonth: avgKmPerMonth)
            var km = rule, source = "Rule-based"
            if let model = maintenanceModel,
               let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "component": c.rawValue, "mileage": Double(v.mileage), "ageYears": ageMonths / 12,
                    "kmSinceLast": kmSince, "daysSinceLast": daysSince, "avgKmPerMonth": avgKmPerMonth])),
               let v = out.featureValue(for: "kmUntilDue")?.doubleValue {
                km = v; source = "Core ML"
            }
            let days = Int(km / (avgKmPerMonth / 30.4))
            return MaintenancePrediction(component: c, kmRemaining: km, daysRemaining: days, source: source)
        }.sorted { $0.kmRemaining < $1.kmRemaining }
    }

    static func ruleRemaining(_ c: ServiceType, kmSince: Double, daysSince: Double, avgKmPerMonth: Double) -> Double {
        guard let ik = c.intervalKm, let im = c.intervalMonths else { return .infinity }
        return min(ik - kmSince, (im * 30.4 - daysSince) / 30.4 * avgKmPerMonth)
    }

    // MARK: 2. No-show prediction (BoostedTreeClassifier → noShow)
    func noShowRisk(leadDays: Double, weekday: Int, hour: Int, pastBookings: Int, pastNoShows: Int) -> Double {
        if let model = noShowModel,
           let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "leadDays": leadDays, "weekday": Double(weekday), "hour": Double(hour),
                "pastBookings": Double(pastBookings), "pastNoShows": Double(pastNoShows)])),
           let p = out.featureValue(for: "noShowProbability")?.dictionaryValue[Int64(1)]?.doubleValue {
            return p
        }
        // Logistic fallback with sensible priors
        let rate = Double(pastNoShows + 1) / Double(pastBookings + 8)
        let z = -2.4 + 0.045 * leadDays + 4.0 * rate + (weekday == 1 || weekday == 7 ? 0.3 : 0) + (hour < 9 ? 0.25 : 0)
        return 1 / (1 + exp(-z))
    }

    func noShowRisk(for a: Appointment, history: [Appointment]) -> Double {
        let mine = history.filter { $0.customerId == a.customerId && $0.id != a.id && $0.date < a.date }
        let cal = Calendar.current
        return noShowRisk(leadDays: max(0, a.date.timeIntervalSince(a.createdAt) / 86_400),
                          weekday: cal.component(.weekday, from: a.date), hour: cal.component(.hour, from: a.date),
                          pastBookings: mine.count, pastNoShows: mine.filter { $0.status == .noShow }.count)
    }
}

// MARK: - Statistical analytics (no model file needed)
enum Analytics {
    /// Linear trend + additive seasonality. Create ML has no time-series trainer, so this runs natively.
    static func forecast(_ y: [Double], season: Int, horizon: Int) -> [Double] {
        let n = y.count
        guard n >= 2 else { return Array(repeating: y.last ?? 0, count: horizon) }
        let xs = (0..<n).map(Double.init)
        let xm = xs.reduce(0, +) / Double(n), ym = y.reduce(0, +) / Double(n)
        let sxx = xs.reduce(0) { $0 + ($1 - xm) * ($1 - xm) }
        let sxy = zip(xs, y).reduce(0) { $0 + ($1.0 - xm) * ($1.1 - ym) }
        let slope = sxx == 0 ? 0 : sxy / sxx
        let icpt = ym - slope * xm
        var seasonal = [Double](repeating: 0, count: season), counts = [Int](repeating: 0, count: season)
        if n >= season * 2 {
            for i in 0..<n { seasonal[i % season] += y[i] - (icpt + slope * Double(i)); counts[i % season] += 1 }
            for s in 0..<season where counts[s] > 0 { seasonal[s] /= Double(counts[s]) }
        }
        return (0..<horizon).map { h in let i = n + h; return max(0, icpt + slope * Double(i) + seasonal[i % season]) }
    }

    /// Contiguous monthly series (gaps filled with 0) for completed appointments.
    static func monthly(_ appts: [Appointment], value: (Appointment) -> Double) -> [(month: Date, value: Double)] {
        let cal = Calendar.current
        let done = appts.filter { $0.status == .completed }
        guard let first = done.map(\.date).min(), let last = done.map(\.date).max() else { return [] }
        func key(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d))! }
        var buckets: [Date: Double] = [:]
        done.forEach { buckets[key($0.date), default: 0] += value($0) }
        var out: [(Date, Double)] = []
        var m = key(first)
        while m <= key(last) { out.append((m, buckets[m] ?? 0)); m = cal.date(byAdding: .month, value: 1, to: m)! }
        return out
    }

    static func revenueForecast(_ appts: [Appointment], months: Int = 3) -> (history: [(month: Date, value: Double)], forecast: [(month: Date, value: Double)]) {
        let hist = monthly(appts) { $0.price ?? 0 }
        guard let last = hist.last else { return ([], []) }
        let f = forecast(hist.map(\.value), season: 12, horizon: months)
        let fut = f.enumerated().map { (Calendar.current.date(byAdding: .month, value: $0.offset + 1, to: last.month)!, $0.element) }
        return (hist, fut)
    }

    static func bookingsForecast(_ appts: [Appointment], months: Int = 3) -> [(month: Date, value: Double)] {
        let hist = monthly(appts) { _ in 1 }
        guard let last = hist.last else { return [] }
        return forecast(hist.map(\.value), season: 12, horizon: months).enumerated()
            .map { (Calendar.current.date(byAdding: .month, value: $0.offset + 1, to: last.month)!, $0.element) }
    }

    /// Next-month demand and suggested reorder quantity for a part.
    static func inventoryForecast(_ item: InventoryItem) -> (demand: Double, reorder: Int) {
        let d = forecast(item.monthlyUsage, season: 12, horizon: 1).first ?? 0
        return (d, max(0, Int((d + Double(item.minThreshold) - Double(item.stock)).rounded(.up))))
    }

    /// Modified z-score (median/MAD) on price per service type + repeat-repair detection per vehicle.
    static func anomalies(_ appts: [Appointment]) -> [RepairAnomaly] {
        var out: [RepairAnomaly] = []
        let done = appts.filter { $0.status == .completed && $0.price != nil }
        for (svc, group) in Dictionary(grouping: done, by: \.service) where group.count >= 8 {
            let prices = group.compactMap(\.price).sorted()
            let med = prices[prices.count / 2]
            let mad = prices.map { abs($0 - med) }.sorted()[prices.count / 2]
            guard mad > 0 else { continue }
            for a in group {
                let z = 0.6745 * ((a.price ?? 0) - med) / mad
                if abs(z) > 3.5 {
                    out.append(RepairAnomaly(appointment: a, reason: "\(svc) cost \(String(format: "%.0f", a.price ?? 0)) vs typical \(String(format: "%.0f", med)) (z=\(String(format: "%.1f", z)))"))
                }
            }
        }
        for (plate, group) in Dictionary(grouping: done, by: \.vehiclePlate) {
            for (svc, same) in Dictionary(grouping: group, by: \.service) where same.count >= 2 {
                let sorted = same.sorted { $0.date < $1.date }
                for (a, b) in zip(sorted, sorted.dropFirst()) where b.date.timeIntervalSince(a.date) < 60 * 86_400 {
                    out.append(RepairAnomaly(appointment: b, reason: "\(plate): repeat \(svc) within 60 days"))
                }
            }
        }
        return out.sorted { $0.appointment.date > $1.appointment.date }
    }

    /// Greedy least-loaded assignment.
    static func leastLoaded(_ staff: [Staff], _ appts: [Appointment]) -> Staff? {
        let active = appts.filter { $0.status == .confirmed || $0.status == .inProgress }
        return staff.min { l, r in active.filter { $0.assignedStaffId == l.id }.count < active.filter { $0.assignedStaffId == r.id }.count }
    }
}
