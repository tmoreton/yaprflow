import AppKit
import Combine
import EventKit
import Foundation
import UserNotifications

struct CalendarMeeting: Identifiable, Hashable {
    let id: String
    let recurrenceIdentifier: String?
    let title: String
    let startDate: Date
    let endDate: Date
    let attendees: [MeetingAttendee]
    let joinURL: URL?

    var isHappeningNow: Bool {
        let now = Date()
        return startDate.addingTimeInterval(-10 * 60) <= now
            && endDate.addingTimeInterval(15 * 60) >= now
    }
}

@MainActor
final class CalendarMeetingService: ObservableObject {
    static let shared = CalendarMeetingService()

    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let eventStore = EKEventStore()

    var canReadCalendar: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccessAndRefresh() {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let granted: Bool
                if #available(macOS 14.0, *) {
                    granted = try await eventStore.requestFullAccessToEvents()
                } else {
                    granted = try await eventStore.requestAccess(to: .event)
                }
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                guard granted else {
                    errorMessage = "Calendar access was not granted."
                    return
                }
                try loadUpcoming()
                await scheduleNotifications()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshIfAuthorized() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard canReadCalendar else { return }
        do {
            try loadUpcoming()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openJoinURL(for meeting: CalendarMeeting) {
        guard let joinURL = meeting.joinURL else { return }
        NSWorkspace.shared.open(joinURL)
    }

    private func loadUpcoming() throws {
        let start = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        meetings = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { event in
                CalendarMeeting(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    recurrenceIdentifier: event.calendarItemExternalIdentifier,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? "Untitled meeting",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    attendees: (event.attendees ?? []).compactMap { participant in
                        let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let email = participant.url.absoluteString.hasPrefix("mailto:")
                            ? String(participant.url.absoluteString.dropFirst("mailto:".count))
                            : nil
                        guard let name = name?.nilIfEmpty ?? email else { return nil }
                        return MeetingAttendee(name: name, email: email)
                    },
                    joinURL: Self.joinURL(for: event)
                )
            }
            .sorted { $0.startDate < $1.startDate }
        errorMessage = nil
    }

    private func scheduleNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let pending = await center.pendingNotificationRequests()
        let oldIDs = pending.map(\.identifier).filter { $0.hasPrefix("yaprflow-meeting-") }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)

        for meeting in meetings where meeting.startDate > Date().addingTimeInterval(60) {
            let content = UNMutableNotificationContent()
            content.title = "Meeting in one minute"
            content.body = meeting.title
            content.sound = .default
            content.userInfo = ["calendarEventID": meeting.id]
            let fireDate = meeting.startDate.addingTimeInterval(-60)
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: "yaprflow-meeting-\(meeting.id)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private static func joinURL(for event: EKEvent) -> URL? {
        if let url = event.url, isMeetingURL(url) { return url }
        let candidates = [event.location, event.notes].compactMap { $0 }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in candidates {
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector?.matches(in: text, range: range) ?? []
            if let url = matches.compactMap(\.url).first(where: isMeetingURL) { return url }
        }
        return nil
    }

    private static func isMeetingURL(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.contains("zoom.us")
            || value.contains("meet.google.com")
            || value.contains("teams.microsoft.com")
            || value.contains("facetime")
            || value.contains("webex")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
