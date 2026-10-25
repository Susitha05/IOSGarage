import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        Task { await NotificationService.shared.saveToken(token) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

@main
struct IOSGarage: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var auth = AuthService()
    @State private var store = DataStore()
    @State private var location = LocationService()

    init() { FirebaseApp.configure() }   // must run before any Firebase object is touched

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(store)
                .environment(location)
                .task { auth.start() }
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
        .modelContainer(for: [Vehicle.self, ServiceRecord.self, Expense.self])
    }
}
