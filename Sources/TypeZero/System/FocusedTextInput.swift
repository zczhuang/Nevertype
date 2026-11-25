import Foundation

// The "is a text field focused?" decision and what follows from it. Everything in this file is pure: the Accessibility reading lives in
// `ContextInjector.focusedTextInputStatus`, which fills a `FocusedElementFacts` and hands it to `FocusedTextInputClassifier`.

/// Whether typing now would land in a text input.
public enum FocusedTextInputStatus: String, Equatable, Sendable {
    /// A text field, text area, combo box or search field, or something whose text or selection can be written.
    case editable
    /// Clearly not a place to type: the desktop, Finder without a text field, a button, a list, a link, a web page with nothing focused.
    case notEditable
    /// Cannot tell. Qt apps, terminals and the bare windows of Electron apps often report a window or group even with a live caret, so
    /// this is treated like `.editable` and dictation behaves as it always did.
    case unknown
}

/// What Accessibility reported about the focused element, copied into plain values so the rules can be tested without any app running.
public struct FocusedElementFacts: Equatable, Sendable {
    public var bundleID: String
    /// Accessibility answered, but the app has no focused element (Finder with no window, for example).
    public var noFocusedElement: Bool
    /// `nil` when there is no focused element, or when Accessibility could not be read at all (permission, timeout).
    public var role: String?
    public var subrole: String?
    public var selectedTextRangeSettable: Bool
    public var valueSettable: Bool
    /// Host of the page URL (lower case) of the web area that holds the focused element; `nil` when not read or not readable.
    public var webAreaHost: String?
    /// The focused element is part of a web page: it has an AXWebArea among its ancestors (`WebContentWalk`). Only looked up when the rules
    /// need it (an Electron app or a web browser, a role that does not decide on its own, nothing settable), so `false` can also mean
    /// "not looked at". A focused AXWebArea counts as web content without the lookup (see `inWebContent`).
    public var isWebContent: Bool
    /// The front app is an Electron app: its bundle carries `Electron Framework.framework`.
    public var isElectronApp: Bool

    /// Web content, including the case where the focused element is the web area itself.
    public var inWebContent: Bool { isWebContent || role == FocusedTextInputClassifier.webAreaRole }

    public init(
        bundleID: String,
        noFocusedElement: Bool = false,
        role: String? = nil,
        subrole: String? = nil,
        selectedTextRangeSettable: Bool = false,
        valueSettable: Bool = false,
        webAreaHost: String? = nil,
        isWebContent: Bool = false,
        isElectronApp: Bool = false
    ) {
        self.bundleID = bundleID
        self.noFocusedElement = noFocusedElement
        self.role = role
        self.subrole = subrole
        self.selectedTextRangeSettable = selectedTextRangeSettable
        self.valueSettable = valueSettable
        self.webAreaHost = webAreaHost
        self.isWebContent = isWebContent
        self.isElectronApp = isElectronApp
    }

    /// One line for the injection trace: roles, flags and the result only. Never any text from the field and never the page's address
    /// (web content only says whether its page was readable and whether it is one of the web editors the rules keep out of).
    public func traceDescription(status: FocusedTextInputStatus) -> String {
        var line = "app=\(bundleID) role=\(role ?? "none") subrole=\(subrole ?? "none") noFocus=\(noFocusedElement ? 1 : 0) "
            + "rangeSettable=\(selectedTextRangeSettable ? 1 : 0) valueSettable=\(valueSettable ? 1 : 0) "
            + "web=\(inWebContent ? 1 : 0) electron=\(isElectronApp ? 1 : 0)"
        if inWebContent {
            let page = webAreaHost == nil ? "unreadable" : (FocusedTextInputClassifier.isHiddenInputWebHost(webAreaHost) ? "webEditor" : "plain")
            line += " page=\(page)"
        }
        return line + " status=\(status.rawValue)"
    }
}

public enum FocusedTextInputClassifier {
    /// Roles of elements that take typed text.
    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles of controls that never take typed text. With one of these focused, typing would go nowhere or press things.
    static let nonTextRoles: Set<String> = [
        "AXDesktop", "AXButton", "AXImage", "AXToolbar", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXBrowser",
        "AXStaticText", "AXLink", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXTabGroup", "AXMenuItem"
    ]

    static let searchFieldSubrole = "AXSearchField"
    static let webAreaRole = "AXWebArea"
    static let windowRole = "AXWindow"
    static let applicationRole = "AXApplication"
    static let finderBundleID = "com.apple.finder"

    /// Browsers built on WebKit or Chromium, whose sources were checked for how they expose the focus. Lower case.
    /// Firefox is left out on purpose: how it exposes an editable region was not verified.
    static let browserBundleIDs: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview",
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary", "org.chromium.chromium",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.microsoft.edgemac.canary",
        "com.brave.browser", "com.brave.browser.beta", "com.brave.browser.nightly",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.operasoftware.operagx",
        "company.thebrowser.browser", "company.thebrowser.dia"
    ]

    public static func isWebBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID.lowercased())
    }

    /// Web apps that take typing in a frame Accessibility may not expose (Google Docs, Sheets and Slides are known to read keystrokes from
    /// a separate iframe). How Chrome reports the focus there could not be verified, so a bare web area on one of these stays `.unknown`.
    static let hiddenInputWebHosts: Set<String> = ["docs.google.com"]

    public static func isHiddenInputWebHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return hiddenInputWebHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Spreadsheets: Numbers, Excel and LibreOffice. Lower case.
    static let spreadsheetBundleIDs: Set<String> = ["com.apple.iwork.numbers", "com.microsoft.excel", "org.libreoffice.script"]

    /// What a selected spreadsheet cell reports as the focused element: the cell itself, or its row or table.
    static let spreadsheetCellRoles: Set<String> = ["AXCell", "AXRow", "AXTable"]

    public static func isSpreadsheet(bundleID: String) -> Bool {
        spreadsheetBundleIDs.contains(bundleID.lowercased())
    }

    /// True when the role (or the search-field subrole) settles the answer, so the two "is it settable" reads can be skipped.
    public static func isDecisive(role: String?, subrole: String?) -> Bool {
        if subrole == searchFieldSubrole { return true }
        guard let role else { return false }
        return textInputRoles.contains(role) || nonTextRoles.contains(role)
    }

    /// The rules, in order. The first that applies wins.
    ///
    /// 1. A text role (or the search-field subrole) is `.editable`. That includes Finder's rename and search fields.
    /// 2. A clear non-text role is `.notEditable`, even when its AXValue is settable: sliders, check boxes and pop-up buttons all have a
    ///    settable value, and none of them takes typed text. The one exception is a spreadsheet (Numbers, Excel, LibreOffice): a selected
    ///    cell reports AXCell (or its AXRow or AXTable), and typing into it starts a cell edit, so those three roles are `.unknown` there
    ///    and dictation types as before. Everywhere else they stay `.notEditable` (Mail's message list, Music's library).
    /// 3. Any other element whose AXSelectedTextRange or AXValue is settable is `.editable`.
    /// 4. Finder with an element in focus that is not a text field (or nothing in focus) is `.notEditable`. A failed Accessibility read stays
    ///    `.unknown`, so a timeout cannot hide a rename field.
    /// 5. Web content (the focused element is a web area, or sits inside one) in an Electron app or a web browser, with a role that is
    ///    none of the above, is `.notEditable`: the page's own text or a page with nothing focused (AXGroup, AXWebArea, AXScrollArea ...).
    ///    Not for an AXWindow, an AXApplication or a missing role (the tree may not be ready), and not on one of `hiddenInputWebHosts`
    ///    (Google Docs and friends). A browser also needs the page's address to have been read, so an unreadable one stays `.unknown`;
    ///    an Electron app is one app's own pages, so there the address only matters for that exclusion.
    /// 6. Everything else is `.unknown`: AXWindow, AXApplication, an AXGroup outside web content (terminals such as Ghostty, kitty,
    ///    WezTerm), no focused element, a failed read, and web content in any app that is neither a browser nor Electron (Mail).
    ///
    /// Rule 5 and web content. A text input in a page reports itself, so it never gets here: a contenteditable region (Gmail compose,
    /// Claude's ProseMirror box, Slack, Discord, Notion) is AXTextArea in both engines (WebKit since 2014; Chromium after the Oct 2024
    /// revert of its AXTextArea -> AXGroup change), or at least has a settable selected range. What is left in web content is not a place
    /// to type: a page with nothing focused reports the page itself (AXWebArea) as the focused element, and clicking on a message or any
    /// other page text reports a plain AXGroup (seen in the Claude desktop app, an Electron app). The catch is a page that is editable
    /// as a whole (what Mail's compose body is built on, and `designMode`): WebKit's own layout test for editable pages
    /// (accessibility/editable-webpage-focused-ui-element) expects the web area as the focused element, and nothing in Accessibility
    /// tells that apart from "nothing focused". That is why rule 5 is limited to web browsers and Electron apps, where whole-page editing
    /// is rare, and Mail and other web views stay `.unknown` (typing as before). One more editor is kept out because its focus could not
    /// be checked: Google Docs types into a hidden iframe, and whether Chrome then reports that frame or the bare page as focused is
    /// unverified (see `hiddenInputWebHosts`).
    public static func classify(_ facts: FocusedElementFacts) -> FocusedTextInputStatus {
        let role = facts.role ?? ""

        if textInputRoles.contains(role) || facts.subrole == searchFieldSubrole {
            return .editable
        }
        if nonTextRoles.contains(role) {
            if spreadsheetCellRoles.contains(role), isSpreadsheet(bundleID: facts.bundleID) {
                return .unknown
            }
            return .notEditable
        }
        if facts.selectedTextRangeSettable || facts.valueSettable {
            return .editable
        }
        if facts.bundleID == finderBundleID, facts.noFocusedElement || facts.role != nil {
            return .notEditable
        }
        if facts.isElectronApp || isWebBrowser(bundleID: facts.bundleID),
           facts.inWebContent,
           !role.isEmpty, role != windowRole, role != applicationRole,
           !isHiddenInputWebHost(facts.webAreaHost),
           facts.isElectronApp || facts.webAreaHost != nil {
            return .notEditable
        }
        return .unknown
    }
}

/// Finds the web page that holds a focused element by following its accessibility parents. Generic over the node type, so the walk can be
/// tested on a made-up tree; `ContextInjector` plugs in AXUIElement.
public enum WebContentWalk {
    /// How many parents are followed before giving up. A page's accessibility tree has far fewer levels than its DOM (generic containers
    /// are pruned), so 15 reaches the web area from anywhere in an ordinary page.
    public static let maxLevels = 15

    public enum Outcome<Node> {
        /// The web area that holds the element.
        case webArea(Node)
        /// A window or the application came first: the element is not part of a web page. A solid answer.
        case outsideWeb
        /// No answer: a read failed, an element had no parent, `maxLevels` was used up, or the time budget ran out. Nothing to remember.
        case undetermined
    }

    /// Follows `parent` up from `start` (not looking at `start` itself) until a web area, a window or the application turns up.
    /// `parent` and `role` return `nil` when the element has none or the read failed. `shouldStop` is asked before every step.
    public static func enclosingWebArea<Node>(
        of start: Node,
        maxLevels: Int = WebContentWalk.maxLevels,
        parent: (Node) -> Node?,
        role: (Node) -> String?,
        shouldStop: () -> Bool = { false }
    ) -> Outcome<Node> {
        var current = start
        for _ in 0..<maxLevels {
            if shouldStop() { return .undetermined }
            guard let above = parent(current), let aboveRole = role(above) else { return .undetermined }
            if aboveRole == FocusedTextInputClassifier.webAreaRole { return .webArea(above) }
            if aboveRole == FocusedTextInputClassifier.windowRole || aboveRole == FocusedTextInputClassifier.applicationRole { return .outsideWeb }
            current = above
        }
        return .undetermined
    }
}

extension WebContentWalk.Outcome: Equatable where Node: Equatable {}

/// Where finished dictation text goes, and whether to type while the user is still speaking. Pure, so it can be tested.
public enum DictationDelivery {
    /// Why the text is offered on the Copy pill instead of being typed.
    public enum CopyOfferReason: String, Equatable, Sendable {
        case notEditable
        case accessibilityNotTrusted
        case targetNotAllowed

        /// Branch name in the injection trace (kept in line with the older `untrusted` / `noFocus` names).
        public var traceBranch: String {
            switch self {
            case .notEditable: return "noFocus"
            case .accessibilityNotTrusted: return "untrusted"
            case .targetNotAllowed: return "blockedTarget"
            }
        }
    }

    public enum Plan: Equatable, Sendable {
        /// Type or paste the text, as dictation always did.
        case insert
        /// Do not touch the app in front and do not write to the clipboard: offer the text on the Copy pill.
        case offerCopy(CopyOfferReason)
    }

    /// `status` should come from a fresh focus check taken when the cleaned text is ready, because the user may have clicked into
    /// (or out of) a field while speaking. Only `.notEditable` stops delivery: `.unknown` types, as before.
    public static func plan(status: FocusedTextInputStatus, accessibilityTrusted: Bool, targetAllowed: Bool) -> Plan {
        if !accessibilityTrusted { return .offerCopy(.accessibilityNotTrusted) }
        if !targetAllowed { return .offerCopy(.targetNotAllowed) }
        if status == .notEditable { return .offerCopy(.notEditable) }
        return .insert
    }

    /// Live typing while the user speaks. `status` is the focus check taken when the dictation started: with no text input in focus
    /// there is no live typing for that whole dictation (single-key shortcuts in Gmail, Finder's type-to-select, a focused button).
    public static func allowsLiveTyping(status: FocusedTextInputStatus) -> Bool {
        status != .notEditable
    }
}
