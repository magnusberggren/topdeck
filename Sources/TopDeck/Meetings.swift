import AppKit
import EventKit

/// A video call from the calendar, joined in one click as the right account.
struct Meeting: Identifiable, Equatable {
    enum Service { case meet, zoom, teams, other }

    /// The join link, so the same call on several calendars shows up once.
    let id: String
    var title: String
    var start: Date
    var end: Date
    var link: URL
    var service: Service
    /// The Google account to join as, like "you@work.example".
    var account: String?
    /// The accounts whose calendars have this meeting, then your other accounts.
    var accounts: [String]
    var color: DeckColor
    /// For "Show in Calendar".
    var eventIdentifier: String?

    func isLive(at now: Date) -> Bool { start <= now && now < end }

    /// Starting within ten minutes, or already going.
    func isSoon(at now: Date) -> Bool { start.timeIntervalSince(now) < 600 && now < end }

    /// Google Meet picks the signed-in account from `authuser`, so the call
    /// opens as the account that was invited instead of the browser's default.
    func joinURL(as account: String?) -> URL {
        guard service == .meet, let account,
              var components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return link }
        var items = (components.queryItems ?? []).filter { $0.name != "authuser" }
        items.append(URLQueryItem(name: "authuser", value: account))
        components.queryItems = items
        return components.url ?? link
    }

    /// "work.example": the part that tells several "you@" accounts apart.
    static func shortAccount(_ email: String) -> String {
        email.split(separator: "@").last.map(String.init) ?? email
    }
}

#if DEBUG
extension Meeting {
    static var samples: [Meeting] {
        let now = Date()
        func sample(_ title: String, _ minutes: Double, _ account: String, _ color: DeckColor, _ code: String) -> Meeting {
            Meeting(
                id: code, title: title,
                start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval(minutes * 60 + 1800),
                link: URL(string: "https://meet.google.com/\(code)")!, service: .meet,
                account: account, accounts: [account], color: color, eventIdentifier: nil
            )
        }
        return [
            sample("Daily Standup", -10, "you@work.example", .blue, "abc-defg-hij"),
            sample("Design Review", 6, "you@work.example", .blue, "bcd-efgh-ijk"),
            sample("Product Demo", 150, "you@side.example", .green, "cde-fghi-jkl"),
            sample("Client Check-in", 60 * 20, "you@studio.example", .purple, "def-ghij-klm"),
            sample("Site Visit", 60 * 50, "you@work.example", .orange, "efg-hijk-lmn"),
        ]
    }
}
#endif

/// A Google account TopDeck found or was given, and whether it's on the
/// Meetings page.
struct AccountChoice: Equatable {
    enum Source { case calendarAccount, sharedCalendar, added }

    let account: GoogleAccount
    let source: Source
    let isShown: Bool
}

/// One of your Google accounts, with a color to tell it apart.
struct GoogleAccount: Identifiable, Equatable {
    let email: String
    var color: DeckColor

    var id: String { email }
    /// "shuuto.no", which tells several "magnus@" accounts apart.
    var label: String { Meeting.shortAccount(email) }
    /// "S" for shuuto.no, like the letter in a Google profile picture.
    var initial: String { label.first.map { String($0).uppercased() } ?? "?" }

    /// Colors to fall back on when two accounts' calendars look alike.
    static let palette: [DeckColor] = [.blue, .orange, .purple, .teal, .pink, .green, .yellow, .red, .indigo]

    var links: [AccountLink] { AccountLink.Kind.allCases.map { AccountLink(kind: $0, account: email) } }
}

/// Google Calendar or Drive, opened as one particular account.
struct AccountLink: Identifiable, Equatable {
    enum Kind: CaseIterable { case calendar, drive }

    let kind: Kind
    let account: String

    var id: String { "\(kind)|\(account)" }

    var title: String {
        switch kind {
        case .calendar: "Calendar"
        case .drive: "Drive"
        }
    }

    var symbol: String {
        switch kind {
        case .calendar: "calendar"
        case .drive: "externaldrive.fill"
        }
    }

    var product: GoogleProduct {
        switch kind {
        case .calendar: .calendar
        case .drive: .drive
        }
    }

    var color: DeckColor {
        switch kind {
        case .calendar: .blue
        case .drive: .green
        }
    }

    /// Like Meet, both pick the signed-in account from `authuser`, so they
    /// open as this account without switching in the browser.
    var url: URL {
        let base = switch kind {
        case .calendar: "https://calendar.google.com/calendar/r"
        case .drive: "https://drive.google.com/drive/my-drive"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "authuser", value: account)]
        return components.url!
    }

}

enum CalendarAccess: Equatable {
    case notDetermined
    case granted
    case denied
}

/// A calendar the user can show or hide on the Meetings page.
struct CalendarChoice {
    let id: String
    let title: String
    let account: String
    let isIncluded: Bool
    let color: NSColor
}

/// Reads upcoming video calls from the calendars in macOS Calendar, which
/// already syncs every Google account added in Internet Accounts. No Google
/// sign-in of its own. State is only touched on the main thread.
final class CalendarStore {
    var onChange: (([Meeting]) -> Void)?
    /// Your Google accounts, for the Calendar and Drive shortcuts.
    var onAccounts: (([AccountChoice]) -> Void)?
    var onAccessChange: ((CalendarAccess) -> Void)?

    private(set) var access: CalendarAccess
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "TopDeck.CalendarStore", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var refreshTimer: Timer?

    private static let lookahead: TimeInterval = 7 * 86_400
    private static let maxMeetings = 30

    init() {
        access = Self.currentAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // Meetings that ended drop off even if nothing else changes.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        refreshTimer?.invalidate()
    }

    private static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.reset()
                self.setAccess(Self.currentAccess())
                self.refresh()
            }
        }
    }

    private func setAccess(_ access: CalendarAccess) {
        guard access != self.access else { return }
        self.access = access
        onAccessChange?(access)
    }

    func refresh() {
        setAccess(Self.currentAccess())
        guard access == .granted else { return }
        let overrides = Preferences.calendarOverrides
        let shown = Preferences.accountChoices
        let added = Preferences.addedAccounts
        queue.async { [weak self] in
            guard let self else { return }
            let meetings = self.fetch(overrides: overrides)
            let accounts = self.accountChoices(shown: shown, added: added)
            DispatchQueue.main.async {
                self.onChange?(meetings)
                self.onAccounts?(accounts)
            }
        }
    }

    /// Calendars grouped by account, for the Calendars menu.
    func choices() -> [(account: String, calendars: [CalendarChoice])] {
        guard access == .granted else { return [] }
        let overrides = Preferences.calendarOverrides
        let calendars = store.calendars(for: .event)
        var groups: [String: [CalendarChoice]] = [:]
        for calendar in calendars {
            let account = calendar.source?.title ?? "Other"
            groups[account, default: []].append(CalendarChoice(
                id: Self.portableID(of: calendar),
                title: calendar.title,
                account: account,
                isIncluded: Self.isIncluded(calendar, overrides: overrides),
                color: calendar.color ?? .gray
            ))
        }
        return groups.keys.sorted().map { key in
            (key, groups[key]!.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
    }

    // MARK: - Reading

    private static let appleDomains = ["icloud.com", "me.com", "mac.com"]

    /// The accounts your own calendars belong to, minus iCloud: in practice
    /// the Google accounts added in Internet Accounts. Each gets the color of
    /// its main calendar, so it matches Calendar, and no two share a color.
    /// Every Google account TopDeck could show, and whether it does:
    /// - accounts added to the Mac (Internet Accounts), shown unless hidden;
    /// - addresses of calendars shared into those accounts from another
    ///   domain (say a personal Gmail shared into a work account), hidden
    ///   unless picked. Same-domain addresses are colleagues, so they're left out;
    /// - addresses added by hand, shown unless hidden.
    private func accountChoices(shown: [String: Bool], added: [String]) -> [AccountChoice] {
        let all = store.calendars(for: .event)
        let own = all.filter { Self.isIncluded($0, overrides: [:]) }
        let ownEmails = Self.unique(own.compactMap { Self.account(of: $0) })
            .filter { !Self.appleDomains.contains(Meeting.shortAccount($0)) }
            .sorted()
        let ownDomains = Set(ownEmails.map(Meeting.shortAccount))

        var candidates: [(email: String, source: AccountChoice.Source, calendar: EKCalendar?)] = []
        for email in ownEmails {
            let calendars = own.filter { Self.account(of: $0) == email }
            // Google names your main calendar after your address.
            candidates.append((email, .calendarAccount, calendars.first { $0.title.lowercased() == email } ?? calendars.first))
        }
        for calendar in all {
            let email = calendar.title.lowercased().trimmingCharacters(in: .whitespaces)
            guard Self.looksLikeEmail(email), !candidates.contains(where: { $0.email == email }),
                  !ownDomains.contains(Meeting.shortAccount(email)),
                  !Self.appleDomains.contains(Meeting.shortAccount(email)) else { continue }
            candidates.append((email, .sharedCalendar, calendar))
        }
        for email in added.map({ $0.lowercased() }) where !candidates.contains(where: { $0.email == email }) {
            candidates.append((email, .added, nil))
        }

        var used = Set<DeckColor>()
        return candidates.map { candidate in
            var color = candidate.calendar.map { DeckColor.nearest(to: $0.color) }
                ?? GoogleAccount.palette.first { !used.contains($0) } ?? .blue
            if used.contains(color) {
                color = GoogleAccount.palette.first { !used.contains($0) } ?? color
            }
            used.insert(color)
            return AccountChoice(
                account: GoogleAccount(email: candidate.email, color: color),
                source: candidate.source,
                isShown: shown[candidate.email] ?? (candidate.source != .sharedCalendar)
            )
        }
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
    }

    private func fetch(overrides: [String: Bool]) -> [Meeting] {
        let calendars = store.calendars(for: .event).filter { Self.isIncluded($0, overrides: overrides) }
        guard !calendars.isEmpty else { return [] }
        // Every account you could join as, for "Join As".
        let known = Self.unique(calendars.compactMap { Self.account(of: $0) })
            .filter { !Self.appleDomains.contains(Meeting.shortAccount($0)) }

        let now = Date()
        // Starting a little back catches calls already under way.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(Self.lookahead),
            calendars: calendars
        )

        // The same call often sits on several calendars, one per account it
        // was sent to. Group the copies by link.
        var copies: [String: [EKEvent]] = [:]
        var links: [String: (URL, Meeting.Service)] = [:]
        for event in store.events(matching: predicate) {
            guard !event.isAllDay, event.endDate > now, event.status != .canceled,
                  !Self.isDeclined(event),
                  let (link, service) = Self.joinLink(in: event) else { continue }
            let key = Self.key(for: link, service: service) + "|" + String(Int(event.startDate.timeIntervalSince1970))
            copies[key, default: []].append(event)
            links[key] = (link, service)
        }

        var meetings: [Meeting] = []
        for (key, events) in copies {
            guard let first = events.first, let (link, service) = links[key] else { continue }
            let accounts = Self.unique(events.compactMap { Self.account(of: $0.calendar) })
            let invited = Set(events.flatMap(Self.invitedEmails))
            // Join as the account that was actually invited, if one of ours was.
            let account = accounts.first { invited.contains($0.lowercased()) } ?? accounts.first
            let owner = events.first { Self.account(of: $0.calendar) == account } ?? first
            meetings.append(Meeting(
                id: key,
                title: first.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Meeting",
                start: first.startDate,
                end: first.endDate,
                link: link,
                service: service,
                account: account,
                accounts: Self.unique(accounts + known),
                color: DeckColor.nearest(to: owner.calendar?.color),
                eventIdentifier: owner.eventIdentifier
            ))
        }
        meetings.sort { ($0.start, $0.title) < ($1.start, $1.title) }
        return Array(meetings.prefix(Self.maxMeetings))
    }

    /// By default only your own calendars count. Calendars shared with you by
    /// colleagues have no owner identity, and holding their meetings would
    /// fill the page with calls you aren't in.
    private static func isIncluded(_ calendar: EKCalendar, overrides: [String: Bool]) -> Bool {
        if let choice = overrides[portableID(of: calendar)] ?? overrides[calendar.calendarIdentifier] { return choice }
        switch calendar.type {
        case .birthday, .subscription: return false
        default: break
        }
        let key = "ownerIdentityEmail"
        guard calendar.responds(to: NSSelectorFromString(key)) else { return true }
        return (calendar.value(forKey: key) as? String)?.isEmpty == false
    }

    /// Names a calendar the same way on every Mac, unlike its identifier,
    /// so hiding it here hides it on your other Macs too.
    static func portableID(of calendar: EKCalendar) -> String {
        (account(of: calendar) ?? calendar.source?.title ?? "") + "|" + calendar.title
    }

    /// The account the calendar belongs to, like "you@work.example".
    static func account(of calendar: EKCalendar?) -> String? {
        guard let calendar else { return nil }
        if let email = string(calendar, "selfIdentityEmail")?.nilIfEmpty { return email.lowercased() }
        if let email = string(calendar, "ownerIdentityEmail")?.nilIfEmpty { return email.lowercased() }
        // Google names your main calendar after your address.
        if calendar.title.contains("@") { return calendar.title.lowercased() }
        return nil
    }

    /// EventKit knows each calendar's account address but doesn't publish it,
    /// so ask carefully and fall back when it isn't there.
    private static func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private static func invitedEmails(_ event: EKEvent) -> [String] {
        var people = event.attendees ?? []
        if let organizer = event.organizer { people.append(organizer) }
        return people.compactMap(email(of:))
    }

    private static func email(of participant: EKParticipant) -> String? {
        if let email = string(participant, "emailAddress")?.nilIfEmpty { return email.lowercased() }
        let url = participant.url.absoluteString
        guard url.lowercased().hasPrefix("mailto:") else { return nil }
        return String(url.dropFirst("mailto:".count)).lowercased()
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Links

    private static let patterns: [(Meeting.Service, NSRegularExpression)] = {
        let raw: [(Meeting.Service, String)] = [
            (.meet, #"https?://meet\.google\.com/[a-z]{3,}-[a-z]{3,}-[a-z]{3,}"#),
            (.zoom, #"https?://(?:[\w-]+\.)?zoom\.us/(?:j|my|w)/[^\s<>"']+"#),
            (.teams, #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#),
            (.other, #"https?://(?:[\w-]+\.)?(?:whereby\.com|webex\.com/meet|around\.co|meet\.jit\.si|app\.gather\.town)/[^\s<>"']+"#),
        ]
        return raw.compactMap { service, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (service, $0) }
        }
    }()

    /// Google puts the Meet link in the description; others use the URL or
    /// location field.
    static func joinLink(in event: EKEvent) -> (URL, Meeting.Service)? {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for (service, regex) in patterns {
            for text in fields {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let swiftRange = Range(match.range, in: text),
                   let url = URL(string: String(text[swiftRange])) {
                    return (url, service)
                }
            }
        }
        return nil
    }

    private static func key(for link: URL, service: Meeting.Service) -> String {
        if service == .meet { return "meet:" + link.lastPathComponent.lowercased() }
        return link.absoluteString
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension DeckColor {
    /// The deck color closest to a calendar's color, so tiles match Calendar.
    static func nearest(to color: NSColor?) -> DeckColor {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return .blue }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.18 { return .graphite }
        let degrees = hue * 360
        switch degrees {
        case ..<15, 345...: return .red
        case ..<40: return .orange
        case ..<65: return .yellow
        case ..<160: return .green
        case ..<195: return .teal
        case ..<235: return .blue
        case ..<260: return .indigo
        case ..<300: return .purple
        default: return .pink
        }
    }
}

/// Google's own product icons. They're Google's trademarks, so they aren't
/// shipped with the app: they're fetched from Google the first time the
/// Meetings page needs them and kept in Caches. Until then, and offline,
/// tiles fall back to plain symbols.
enum GoogleProduct: String, CaseIterable {
    case meet, calendar, drive

    fileprivate var url: URL {
        URL(string: "https://ssl.gstatic.com/images/branding/product/1x/\(rawValue)_2020q4_512dp.png")!
    }
}

final class GoogleIcons {
    var onLoad: ((GoogleProduct, NSImage) -> Void)?

    private var requested = Set<GoogleProduct>()

    private static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("TopDeck/GoogleIcons", isDirectory: true)
    }

    /// Reports each icon from the cache, downloading the ones it doesn't have yet.
    func load() {
        for product in GoogleProduct.allCases where !requested.contains(product) {
            requested.insert(product)
            let file = Self.folder.appendingPathComponent(product.rawValue + ".png")
            if let image = NSImage(contentsOf: file) {
                onLoad?(product, image)
                continue
            }
            URLSession.shared.dataTask(with: product.url) { [weak self] data, response, _ in
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data), image.isValid else {
                    // Try again next time the page opens.
                    DispatchQueue.main.async { self?.requested.remove(product) }
                    return
                }
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                DispatchQueue.main.async { self?.onLoad?(product, image) }
            }.resume()
        }
    }
}
