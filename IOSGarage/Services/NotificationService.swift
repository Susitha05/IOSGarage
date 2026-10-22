import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

final class NotificationService {
    static let shared = NotificationService()

    func requestPermission() async {
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if ok { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
    }

    /// Stores the FCM token on the user's profile so Cloud Functions can target this device.
    func saveToken(_ token: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try? await Firestore.firestore().collection("users").document(uid).setData(["fcmToken": token], merge: true)
    }

    func subscribe(role: UserRole) {
        if role == .towDriver { Messaging.messaging().subscribe(toTopic: "drivers") }
    }

    /// Local notification, e.g. predicted maintenance reminders. Respects Settings toggles.
    func schedule(id: String, title: String, body: String, at date: Date, pref: String = "notifyMaintenance") {
        guard UserDefaults.standard.object(forKey: pref) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: max(date, .now.addingTimeInterval(5)))
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func notifyNow(title: String, body: String) {
        schedule(id: UUID().uuidString, title: title, body: body, at: .now, pref: "notifyTow")
    }
}
