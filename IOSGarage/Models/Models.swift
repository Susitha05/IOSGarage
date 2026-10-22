import Foundation
import SwiftData
import CoreLocation
import FirebaseFirestore

// MARK: - Roles & users
enum UserRole: String, Codable, CaseIterable, Identifiable {
    case customer, garageOwner, towDriver
    var id: String { rawValue }
    var title: String {
        switch self { case .customer: "Vehicle Owner"; case .garageOwner: "Garage Owner"; case .towDriver: "Tow Driver" }
    }
}

struct AppUser: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    var name: String
    var email: String
    var role: UserRole
    var phone: String?
    var fcmToken: String?
}

// MARK: - Service catalogue
enum ServiceType: String, CaseIterable, Identifiable, Codable {
    case oilChange = "Oil Change", brakes = "Brake Service", tyres = "Tyres", battery = "Battery"
    case airFilter = "Air Filter", coolant = "Coolant Flush"
    case fullService = "Full Service", acService = "A/C Service", diagnostics = "Diagnostics"
    var id: String { rawValue }

    /// Manufacturer-style intervals used for rule-based fallback and ML training data.
    var intervalKm: Double? {
        switch self {
        case .oilChange: 10_000; case .brakes: 40_000; case .tyres: 50_000
        case .battery: 60_000; case .airFilter: 20_000; case .coolant: 40_000
        default: nil
        }
    }
    var intervalMonths: Double? {
        switch self {
        case .oilChange: 6; case .brakes: 24; case .tyres: 36
        case .battery: 48; case .airFilter: 12; case .coolant: 24
        default: nil
        }
    }
    var basePrice: Double {
        switch self {
        case .oilChange: 60; case .brakes: 180; case .tyres: 400; case .battery: 150
        case .airFilter: 30; case .coolant: 90; case .fullService: 250; case .acService: 120; case .diagnostics: 50
        }
    }
    var icon: String {
        switch self {
        case .oilChange: "drop.fill"; case .brakes: "exclamationmark.octagon.fill"; case .tyres: "circle.dotted"
        case .battery: "bolt.car.fill"; case .airFilter: "wind"; case .coolant: "thermometer.medium"
        case .fullService: "wrench.and.screwdriver.fill"; case .acService: "snowflake"; case .diagnostics: "stethoscope"
        }
    }
    static var tracked: [ServiceType] { allCases.filter { $0.intervalKm != nil } }
}

// MARK: - Local (SwiftData / Core Data-backed) models
@Model final class Vehicle {
    var id: UUID = UUID()
    var ownerId: String = ""
    var plate: String = ""
    var make: String = ""
    var model: String = ""
    var year: Int = 2020
    var mileage: Int = 0
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \ServiceRecord.vehicle) var services: [ServiceRecord] = []

    init(ownerId: String, plate: String, make: String, model: String, year: Int, mileage: Int) {
        self.ownerId = ownerId; self.plate = plate; self.make = make
        self.model = model; self.year = year; self.mileage = mileage
    }
    var title: String { "\(year) \(make) \(model)" }
}

@Model final class ServiceRecord {
    var id: UUID = UUID()
    var date: Date = Date()
    var type: String = ServiceType.oilChange.rawValue
    var mileage: Int = 0
    var cost: Double = 0
    var parts: String = ""
    var notes: String = ""
    var vehicle: Vehicle?

    init(date: Date, type: String, mileage: Int, cost: Double, parts: String = "", notes: String = "") {
        self.date = date; self.type = type; self.mileage = mileage
        self.cost = cost; self.parts = parts; self.notes = notes
    }
}

@Model final class Expense {
    var id: UUID = UUID()
    var ownerId: String = ""
    var date: Date = Date()
    var vendor: String = ""
    var amount: Double = 0
    var category: String = "Service"
    var note: String = ""
    var warrantyUntil: Date?
    @Attribute(.externalStorage) var receiptData: Data?

    init(ownerId: String, date: Date, vendor: String, amount: Double, category: String, note: String = "",
         warrantyUntil: Date? = nil, receiptData: Data? = nil) {
        self.ownerId = ownerId; self.date = date; self.vendor = vendor; self.amount = amount
        self.category = category; self.note = note; self.warrantyUntil = warrantyUntil; self.receiptData = receiptData
    }
}

// MARK: - Cloud (Firestore) models
enum AppointmentStatus: String, Codable, CaseIterable {
    case pending, confirmed, inProgress, completed, rejected, cancelled, noShow
    var title: String {
        switch self { case .inProgress: "In Progress"; case .noShow: "No-show"; default: rawValue.capitalized }
    }
    /// Valid state machine used by the garage dashboard (and unit-tested).
    func canTransition(to next: AppointmentStatus) -> Bool {
        switch (self, next) {
        case (.pending, .confirmed), (.pending, .rejected), (.pending, .cancelled): true
        case (.confirmed, .inProgress), (.confirmed, .noShow), (.confirmed, .cancelled): true
        case (.inProgress, .completed): true
        default: false
        }
    }
}

struct Appointment: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    var customerId: String
    var customerName: String
    var garageId: String
    var garageName: String
    var vehicleLabel: String
    var vehiclePlate: String
    var service: String
    var date: Date
    var createdAt: Date = Date()
    var status: AppointmentStatus = .pending
    var assignedStaffId: String?
    var assignedStaffName: String?
    var price: Double?
}

struct InventoryItem: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    var garageId: String
    var name: String
    var stock: Int
    var minThreshold: Int
    var unitCost: Double
    /// Units used per calendar month, oldest → newest (last element = current month).
    var monthlyUsage: [Double] = []
    var isLow: Bool { stock <= minThreshold }
}

struct Staff: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    var garageId: String
    var name: String
}

enum TowStatus: String, Codable, CaseIterable {
    case requested, accepted, enRoute, arrived, towing, completed, cancelled
    var title: String {
        switch self { case .enRoute: "Driver en route"; case .towing: "Towing"; default: rawValue.capitalized }
    }
    var next: TowStatus? {
        switch self {
        case .accepted: .enRoute; case .enRoute: .arrived; case .arrived: .towing; case .towing: .completed
        default: nil
        }
    }
    var isActive: Bool { self != .completed && self != .cancelled }
}

struct TowRequest: Codable, Identifiable, Hashable {
    @DocumentID var id: String?
    var customerId: String
    var customerName: String
    var customerPhone: String?
    var lat: Double
    var lon: Double
    var note: String?
    var status: TowStatus = .requested
    var driverId: String?
    var driverName: String?
    var driverLat: Double?
    var driverLon: Double?
    var createdAt: Date = Date()

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var driverCoordinate: CLLocationCoordinate2D? {
        guard let a = driverLat, let b = driverLon else { return nil }
        return .init(latitude: a, longitude: b)
    }
    static func == (l: TowRequest, r: TowRequest) -> Bool { l.id == r.id && l.status == r.status }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - ML result types
struct MaintenancePrediction: Identifiable {
    enum Urgency { case overdue, soon, ok }
    let id = UUID()
    let component: ServiceType
    let kmRemaining: Double
    let daysRemaining: Int
    let source: String            // "Core ML" or "Rule-based"
    var urgency: Urgency { kmRemaining <= 0 ? .overdue : (kmRemaining < 1_500 || daysRemaining < 30 ? .soon : .ok) }
    var dueDate: Date { Calendar.current.date(byAdding: .day, value: max(0, daysRemaining), to: .now) ?? .now }
}

struct RepairAnomaly: Identifiable {
    let id = UUID()
    let appointment: Appointment
    let reason: String
}
