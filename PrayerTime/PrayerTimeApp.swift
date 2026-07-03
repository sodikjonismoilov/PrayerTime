//
//  PrayerTimeApp.swift
//  PrayerTime
//
//  Created by Sodikjon Ismoilov on 7/2/26.
//

import SwiftUI
import Adhan
import UserNotifications
import Combine

struct Prayer: Identifiable {
    let id = UUID()
    let name: String
    let time: Date
}

func todaysPrayers() -> [Prayer] {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month, .day], from: Date())

    let coords = Coordinates(latitude: 40.2601, longitude: -74.2746) // Freehold, NJ
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

// `ObservableObject` + `@Published` is SwiftUI's way of saying "some outside class holds
// state a view cares about, and the view should redraw itself whenever that state changes."
// Without it, `todaysPrayers()`/`Date()` would only ever be read once, at whatever moment
// the view happened to be constructed — which is exactly the staleness bug we're fixing.
final class PrayerClock: ObservableObject {
    @Published private(set) var labelText = "…"

    private var timer: Timer?

    // Recomputing PrayerTimes (solar position math) every second would be wasted work,
    // since the times themselves don't change until the calendar day does. We cache
    // today's list and only rebuild it when the day component changes.
    private var cachedDay: Int?
    private var cachedPrayers: [Prayer] = []

    init() {
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common keeps the timer firing while the dropdown menu is open, which otherwise
        // pauses timers registered on the default run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let day = Calendar.current.component(.day, from: now)
        if day != cachedDay {
            cachedPrayers = todaysPrayers()
            cachedDay = day
        }

        guard let next = cachedPrayers.first(where: { $0.time > now }) else {
            labelText = "Isha done"
            return
        }
        labelText = "\(next.name) in \(Self.countdown(to: next.time, from: now))"
    }

    private static func countdown(to target: Date, from now: Date) -> String {
        let seconds = max(0, Int(target.timeIntervalSince(now)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%d:%02d", m, s)
    }
}

// Tracks which prayers have been marked "prayed" for the current day. Persists via
// UserDefaults, keyed per-day (e.g. "prayed-2026-7-3"), rather than Core Data/SwiftData —
// this is a handful of strings, not a database's worth of data, so a plist-backed
// key/value store is the right amount of machinery.
final class PrayerTracker: ObservableObject {
    @Published private(set) var prayedNames: Set<String> = []

    private var cachedDayKey: String?

    init() {
        loadForToday()
    }

    func isPrayed(_ prayer: Prayer) -> Bool {
        refreshIfDayChanged()
        return prayedNames.contains(prayer.name)
    }

    func toggle(_ prayer: Prayer) {
        refreshIfDayChanged()
        if prayedNames.contains(prayer.name) {
            prayedNames.remove(prayer.name)
        } else {
            prayedNames.insert(prayer.name)
        }
        UserDefaults.standard.set(Array(prayedNames), forKey: cachedDayKey!)
    }

    // Because the UserDefaults key is scoped to today's date, a new day simply reads
    // an empty (never-written) key — that's the entire "reset marks each new day"
    // behavior, no explicit clearing required.
    private func refreshIfDayChanged() {
        let key = Self.dayKey(for: Date())
        if key != cachedDayKey {
            loadForToday()
        }
    }

    private func loadForToday() {
        let key = Self.dayKey(for: Date())
        cachedDayKey = key
        prayedNames = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func dayKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "prayed-\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }
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
    // Passed in (not owned here) as @ObservedObject: the App struct's @StateObject is
    // the single source of truth for the clock's lifetime, this view just observes it —
    // that's what lets the countdown below stay in sync with the menu bar label for free.
    @ObservedObject var clock: PrayerClock

    let prayers = todaysPrayers()
    let now = Date()
    var nextIndex: Int? { prayers.firstIndex { $0.time > now } }

    // @StateObject here (not passed in from the App) because this view is the only
    // place the tracker is used — no need to thread it through from above.
    @StateObject private var tracker = PrayerTracker()

    // Sunrise isn't something you "pray," so it's excluded from the prayed-count fraction —
    // same reasoning as skipping it for notifications.
    private var trackablePrayers: [Prayer] { prayers.filter { $0.name != "Sunrise" } }
    private var prayedCount: Int { trackablePrayers.filter(tracker.isPrayed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // .rounded is a system font *design*, not a new font — it just picks a
            // softer, friendlier glyph variant of the same San Francisco typeface.
            // Small touch, but it's what separates "styled" from "default UIKit-y."
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.system(.headline, design: .rounded))
                Text(clock.labelText)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                ForEach(Array(prayers.enumerated()), id: \.element.id) { i, p in
                    prayerRow(p, isNext: i == nextIndex)
                }
            }

            Divider()

            Text("\(prayedCount) / \(trackablePrayers.count) prayed today")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 240)
    }

    // Breaking the row out into its own @ViewBuilder keeps `body` readable and makes the
    // "next prayer" background highlight (a RoundedRectangle behind the row's content)
    // easy to reason about in one place instead of tangled into the ForEach.
    @ViewBuilder
    private func prayerRow(_ p: Prayer, isNext: Bool) -> some View {
        HStack(spacing: 8) {
            if p.name == "Sunrise" {
                // Not a prayer — nothing to mark as prayed, so just plain text.
                Text(p.name)
                    .font(.system(.body, design: .rounded))
            } else {
                Button {
                    tracker.toggle(p)
                } label: {
                    HStack(spacing: 8) {
                        checkmark(prayed: tracker.isPrayed(p))
                        Text(p.name)
                            .font(.system(.body, design: .rounded))
                            .fontWeight(isNext ? .semibold : .regular)
                    }
                    // SwiftUI only hit-tests visibly-drawn pixels by default — the
                    // checkmark circle's Color.clear fill (when unprayed) and thin
                    // strokeBorder ring aren't tappable on their own, so taps in the
                    // empty circle's interior would silently do nothing without this.
                    .contentShape(Rectangle())
                }
                // .plain strips the default button chrome (blue capsule background,
                // press highlight) so it reads as a row you can tap, not a system button.
                .buttonStyle(.plain)
            }
            Spacer()
            Text(p.time, style: .time)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(isNext ? .primary : .secondary)
                .fontWeight(isNext ? .semibold : .regular)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            // The "next prayer" highlight: a tinted rounded rect behind just that row,
            // rather than only relying on bold text — much more noticeable at a glance.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isNext ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    // A small custom checkbox instead of SF Symbols' checkmark.circle/circle pair:
    // a filled accent-colored circle with a white checkmark reads as "done" more
    // clearly than a green icon swap, and matches the row highlight's accent color.
    @ViewBuilder
    private func checkmark(prayed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(prayed ? Color.accentColor : Color.clear)
            Circle()
                .strokeBorder(prayed ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
            if prayed {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }
}

@main
struct PrayerTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // @StateObject (not @ObservedObject) because this App instance owns the clock's
    // lifetime — it should be created once and live as long as the app does, not get
    // torn down and recreated whenever SwiftUI happens to re-evaluate `body`.
    @StateObject private var clock = PrayerClock()

    var body: some Scene {
        MenuBarExtra(clock.labelText, systemImage: "moon.stars") {
            PrayerListView(clock: clock)
        }
        .menuBarExtraStyle(.window)
    }
}
