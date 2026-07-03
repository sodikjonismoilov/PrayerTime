//
//  PrayerTimeApp.swift
//  PrayerTime
//
//  Created by Sodikjon Ismoilov on 7/2/26.
//

import SwiftUI
import Adhan
import UserNotifications

struct Prayer: Identifiable {
    let id = UUID()
    let name: String
    let time: Date
}

func todaysPrayers() -> [Prayer] {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month, .day], from: Date())

    let coords = Coordinates(latitude: 35.78056, longitude: -78.6389) // ← CHANGE to your coordinates
    var params = CalculationMethod.northAmerica.params                 // ← your calc method
    params.madhab = .hanafi                                            // ← .hanafi shifts Asr later

    guard let t = PrayerTimes(coordinates: coords, date: comps, calculationParameters: params) else {
        return []
    }
    return [
        Prayer(name: "Fajr",    time: t.fajr),
        Prayer(name: "Sunrise", time: t.sunrise),
        Prayer(name: "Dhuhr",   time: t.dhuhr),
        Prayer(name: "Asr",     time: t.asr),
        Prayer(name: "Maghrib", time: t.maghrib),
        Prayer(name: "Isha",    time: t.isha),
    ]
}

func nextPrayerLabel() -> String {
    guard let next = todaysPrayers().first(where: { $0.time > Date() }) else {
        return "Isha done"
    }
    let f = DateFormatter(); f.dateFormat = "h:mm"
    return "\(next.name) \(f.string(from: next.time))"
}

// Owns everything to do with local notifications: asking for permission, scheduling
// today's prayer alerts, and re-scheduling once the day rolls over. `NSObject` + the
// `UNUserNotificationCenterDelegate` conformance are needed only so we can be told
// "a notification is about to fire" and choose to show it even while the app is frontmost.
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    // Timer.invalidate() has no effect once the timer has already fired, but keeping a
    // reference lets us cancel and replace it if scheduleMidnightRollover() is ever called twice.
    private var midnightTimer: Timer?

    func requestAuthorizationAndSchedule() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
            // requestAuthorization's completion handler runs on a background queue;
            // scheduling notifications is safe from any thread, but we hop to main
            // out of habit since everything else in this app touches Date()/Timer on main.
            DispatchQueue.main.async {
                self.scheduleTodaysPrayerNotifications()
                self.scheduleMidnightRollover()
            }
        }
    }

    // Builds one identifier per prayer per day (e.g. "prayer-Fajr-2026-7-2") so that
    // re-running this on the same day replaces yesterday's leftovers cleanly instead
    // of stacking up duplicate pending notifications.
    private func identifier(for prayer: Prayer) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: prayer.time)
        return "prayer-\(prayer.name)-\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    func scheduleTodaysPrayerNotifications() {
        let center = UNUserNotificationCenter.current()
        let prayers = todaysPrayers().filter { $0.name != "Sunrise" }

        // Clear out any notifications we scheduled for these same slots before
        // (relevant when this is called again after granting permission, or at rollover).
        center.removePendingNotificationRequests(withIdentifiers: prayers.map(identifier(for:)))

        let now = Date()
        for prayer in prayers where prayer.time > now {
            let content = UNMutableNotificationContent()
            content.title = prayer.name
            content.body = "It's time for \(prayer.name)."
            content.sound = .default

            // UNCalendarNotificationTrigger fires the next time the given date components
            // match. Including year/month/day (not just hour/minute) pins it to this one
            // specific moment instead of repeating daily — we re-schedule fresh every day anyway.
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: prayer.time
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: identifier(for: prayer), content: content, trigger: trigger
            )
            center.add(request) { error in
                if let error = error {
                    print("Failed to schedule \(prayer.name): \(error)")
                }
            }
        }
    }

    // Fires shortly after midnight to compute tomorrow's (now "today's") prayer times
    // and schedule fresh notifications, then re-arms itself for the following midnight.
    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()),
              let midnight = cal.date(bySettingHour: 0, minute: 0, second: 5, of: tomorrow) else {
            return
        }
        let timer = Timer(fireAt: midnight, interval: 0, target: self,
                           selector: #selector(rolloverFired), userInfo: nil, repeats: false)
        // .common lets the timer keep firing even while the menu bar dropdown/menu is
        // open, which otherwise pauses timers scheduled on the default run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    @objc private func rolloverFired() {
        scheduleTodaysPrayerNotifications()
        scheduleMidnightRollover()
    }

    func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test notification"
        content.body = "If you see this, the notification pipeline works."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: "test-notification", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // Without this delegate method, macOS silently drops alerts while PrayerTime is the
    // frontmost app. Returning .banner/.sound here tells it to show them anyway.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// SwiftUI's App protocol has no "app just launched, do some setup" hook by itself —
// that's an AppKit-level event. NSApplicationDelegateAdaptor bridges an old-school
// NSApplicationDelegate into a SwiftUI App so we can catch applicationDidFinishLaunching.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationScheduler.shared.requestAuthorizationAndSchedule()
    }
}

struct PrayerListView: View {
    let prayers = todaysPrayers()
    let now = Date()
    var nextIndex: Int? { prayers.firstIndex { $0.time > now } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today").font(.headline)
            ForEach(Array(prayers.enumerated()), id: \.element.id) { i, p in
                HStack {
                    Text(p.name).fontWeight(i == nextIndex ? .bold : .regular)
                    Spacer()
                    Text(p.time, style: .time)
                        .foregroundStyle(i == nextIndex ? .primary : .secondary)
                }
            }
            Divider()
            // Temporary: lets us confirm notifications actually show up without waiting
            // for a real prayer time. Remove once Milestone 2 is verified.
            Button("Test notification (5s)") {
                NotificationScheduler.shared.scheduleTestNotification()
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 220)
    }
}

@main
struct PrayerTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(nextPrayerLabel(), systemImage: "moon.stars") {
            PrayerListView()
        }
        .menuBarExtraStyle(.window)
    }
}
