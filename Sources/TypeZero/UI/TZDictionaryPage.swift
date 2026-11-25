import SwiftUI
import AppKit

enum TZDictionaryFilter: Hashable {
    case all, auto, manual
}

/// What the edit sheet is working on.
enum TZLexiconSheetTarget: Identifiable {
    case new
    case edit(LexiconEntry)
    case importText

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let entry): return entry.id.uuidString
        case .importText: return "import"
        }
    }
}

enum TZAliasParser {
    /// Splits "a, b / c; d" into ["a", "b", "c", "d"] (also accepts full-width separators).
    static func parse(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",/;\u{FF0C}\u{3001}\u{FF1B}\n")
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Page

struct TZDictionaryPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject var lexiconStore: PersonalLexiconStore
    let snapshot: TZSnapshotOptions?

    @State private var filter: TZDictionaryFilter
    @State private var searchOpen: Bool
    @State private var searchText: String
    @State private var sheetTarget: TZLexiconSheetTarget? = nil
    @State private var batchMode: Bool
    @State private var selected: Set<UUID> = []
    @FocusState private var searchFocused: Bool

    init(appState: AppState, lexiconStore: PersonalLexiconStore, snapshot: TZSnapshotOptions?) {
        self.appState = appState
        self.lexiconStore = lexiconStore
        self.snapshot = snapshot
        _filter = State(initialValue: snapshot?.dictionaryFilter ?? .all)
        _searchOpen = State(initialValue: snapshot?.dictionarySearch != nil)
        _searchText = State(initialValue: snapshot?.dictionarySearch ?? "")
        _batchMode = State(initialValue: snapshot?.dictionaryBatchMode ?? false)
    }

    private var visibleEntries: [LexiconEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return lexiconStore.entries.filter { entry in
            switch filter {
            case .all: break
            case .auto: if !entry.category.tzIsAuto { return false }
            case .manual: if entry.category.tzIsAuto { return false }
            }
            guard !needle.isEmpty else { return true }
            return entry.term.localizedCaseInsensitiveContains(needle)
                || entry.phoneticKey.localizedCaseInsensitiveContains(needle)
                || entry.aliases.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                TZPageTitle(text: "Dictionary")
                Spacer()
                Button {
                    sheetTarget = .new
                } label: {
                    Text("New word")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(TZTheme.ink))
                }
                .buttonStyle(.plain)
                moreMenu
            }

            filterRow
                .padding(.top, 22)

            if batchMode {
                batchBar
                    .padding(.top, 14)
            }

            content
                .padding(.top, 18)
        }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .new:
                TZLexiconEditSheet(appState: appState, entry: nil)
            case .edit(let entry):
                TZLexiconEditSheet(appState: appState, entry: entry)
            case .importText:
                TZLexiconImportSheet(appState: appState)
            }
        }
    }

    // MARK: Top bar

    private var moreMenu: some View {
        Menu {
            Button {
                importFromFolder()
            } label: {
                Label("Import from a notes folder…", systemImage: "folder")
            }
            Button {
                sheetTarget = .importText
            } label: {
                Label("Paste text to import…", systemImage: "doc.on.clipboard")
            }
            Button {
                let added = lexiconStore.importFromLocalBrowserHistory(maxEntries: 60)
                appState.statusBanner = "✅ Added \(added) frequent terms from your browser history (read-only)."
            } label: {
                Label("Learn terms from browser history", systemImage: "safari")
            }
            Divider()
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    batchMode.toggle()
                    if !batchMode { selected.removeAll() }
                }
            } label: {
                Label(batchMode ? "Stop selecting" : "Select words…", systemImage: "checkmark.circle")
            }
            Divider()
            Toggle("Learn from my corrections", isOn: $appState.llmConfig.enableAutoLearn)
        } label: {
            TZCircleButtonLabel(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Dictionary options")
    }

    private func importFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan folder"
        panel.message = "Choose a folder of notes (.md, .txt, .csv). \(AppBrand.name) picks out names and terms that repeat."
        if panel.runModal() == .OK, let dir = panel.url {
            let added = lexiconStore.importFromMarkdownFolder(dir, maxEntries: 120)
            appState.statusBanner = "✅ Scanned the folder and added \(added) frequent terms."
        }
    }

    // MARK: Filter row

    private var filterRow: some View {
        HStack(spacing: 10) {
            TZSegmentedControl(
                items: [
                    .init(value: TZDictionaryFilter.all, title: "All"),
                    .init(value: TZDictionaryFilter.auto, title: "Auto-added", icon: "sparkle", iconColor: TZTheme.teal),
                    .init(value: TZDictionaryFilter.manual, title: "Manually-added", icon: "pencil.line", iconColor: TZTheme.inkMuted)
                ],
                selection: $filter
            )

            Spacer(minLength: 8)

            if searchOpen {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TZTheme.inkMuted)
                    TextField("Search words or misheard forms", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(TZTheme.ink)
                        .focused($searchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(TZTheme.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: 250, height: 34)
                .background(Capsule().fill(TZTheme.segmentTrack))
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    searchOpen.toggle()
                    if !searchOpen { searchText = "" }
                }
                if searchOpen {
                    DispatchQueue.main.async { searchFocused = true }
                }
            } label: {
                TZCircleButtonLabel(systemName: "magnifyingglass", size: 34, active: searchOpen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search the dictionary")
        }
    }

    private var batchBar: some View {
        HStack(spacing: 10) {
            Text(selected.isEmpty ? "Select words to delete" : "\(selected.count) selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TZTheme.inkSecondary)
            Spacer()
            Button("Delete\(selected.isEmpty ? "" : " (\(selected.count))")") {
                let count = selected.count
                lexiconStore.removeBatch(ids: selected)
                selected.removeAll()
                appState.statusBanner = "✅ Removed \(count) \(count == 1 ? "word" : "words") from your dictionary."
            }
            .buttonStyle(.tzDestructiveCompact)
            .disabled(selected.isEmpty)
            Button("Done") {
                withAnimation(.easeOut(duration: 0.14)) {
                    batchMode = false
                    selected.removeAll()
                }
            }
            .buttonStyle(.tzSecondaryCompact)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .tzPanel(radius: 12)
    }

    // MARK: Grid

    @ViewBuilder
    private var content: some View {
        let entries = visibleEntries
        if lexiconStore.entries.isEmpty {
            emptyState
        } else if entries.isEmpty {
            Text(searchText.isEmpty ? "No words in this view yet." : "No words match “\(searchText)”.")
                .font(.system(size: 15))
                .foregroundStyle(TZTheme.inkSecondary)
                .padding(.top, 8)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(entries) { entry in
                    TZLexiconChip(
                        entry: entry,
                        batchMode: batchMode,
                        isSelected: selected.contains(entry.id)
                    ) {
                        if batchMode {
                            if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                        } else {
                            sheetTarget = .edit(entry)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(TZTheme.inkSecondary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(TZTheme.panel))
            Text("Your dictionary is empty")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TZTheme.ink)
            Text("Add names, products and jargon you say often so \(AppBrand.name) spells them right. Words you correct by hand are added automatically.")
                .font(.system(size: 14))
                .foregroundStyle(TZTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("New word") { sheetTarget = .new }
                .buttonStyle(.tzPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TZTheme.border, lineWidth: 1))
    }
}

// MARK: - Chip

struct TZLexiconChip: View {
    let entry: LexiconEntry
    let batchMode: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if batchMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? TZTheme.blue : TZTheme.inkMuted)
                }
                Image(systemName: entry.category.tzIsAuto ? "sparkle" : "pencil.line")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(entry.category.tzIsAuto ? TZTheme.teal : TZTheme.inkMuted)
                    .frame(width: 14)
                Text(entry.term)
                    .font(.system(size: 15))
                    .foregroundStyle(TZTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !entry.category.tzIsAuto && entry.weight >= 9 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(hex: 0xE5A21F))
                        .help("Always prioritized")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? TZTheme.wash : Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? TZTheme.blue : TZTheme.border, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var tooltip: String {
        var lines: [String] = []
        if !entry.aliases.isEmpty {
            lines.append("Often misheard as: " + entry.aliases.prefix(6).joined(separator: ", "))
        }
        lines.append(entry.category.displayName + (entry.hitCount > 0 ? " · used \(entry.hitCount)×" : ""))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Edit sheet

struct TZLexiconEditSheet: View {
    @ObservedObject var appState: AppState
    let entry: LexiconEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var term: String
    @State private var aliasText: String
    @State private var category: LexiconCategory
    @State private var pinned: Bool

    init(appState: AppState, entry: LexiconEntry?) {
        self.appState = appState
        self.entry = entry
        _term = State(initialValue: entry?.term ?? "")
        _aliasText = State(initialValue: entry?.aliases.joined(separator: ", ") ?? "")
        _category = State(initialValue: entry?.category ?? .project)
        _pinned = State(initialValue: (entry?.weight ?? 0) >= 9)
    }

    private var isEditing: Bool { entry != nil }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool { trimmedTerm.count >= (isEditing ? 1 : 2) }

    /// Auto-learned words keep their category visible; hand-written words can pick any manual category.
    private var categoryChoices: [LexiconCategory] {
        var choices = LexiconCategory.tzManualCases
        if let entry, entry.category.tzIsAuto { choices.append(.autoLearned) }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditing ? "Edit word" : "New word")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(TZTheme.ink)
                Text("\(AppBrand.name) listens for this spelling and fixes the forms it tends to mishear.")
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.inkSecondary)
            }

            field(label: "Term") {
                TextField("e.g. Kubernetes", text: $term)
                    .tzField(height: 36)
                    .onSubmit { save() }
            }

            field(label: "Often misheard as", hint: "Separate with commas. Each one is replaced by the term above.") {
                TextField("e.g. cuber nettys, koo ber net ease", text: $aliasText)
                    .tzField(height: 36)
                    .onSubmit { save() }
            }

            field(label: "Category") {
                TZMenuField(options: categoryChoices.map { (value: $0, title: $0.displayName) }, selection: $category, height: 36)
            }

            Toggle(isOn: $pinned) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always prioritize")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TZTheme.ink)
                    Text("Keep this word in every recognition hint list, even in unrelated contexts.")
                        .font(.system(size: 13))
                        .foregroundStyle(TZTheme.inkSecondary)
                }
            }
            .toggleStyle(TZSwitchStyle(expands: true))
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isEditing && !trimmedTerm.isEmpty && trimmedTerm.count < 2 {
                Text("Words need at least 2 characters.")
                    .font(.system(size: 13))
                    .foregroundStyle(TZTheme.amber)
            }

            HStack(spacing: 10) {
                if let entry {
                    Button {
                        appState.lexiconStore.remove(id: entry.id)
                        appState.statusBanner = "✅ Removed “\(entry.term)” from your dictionary."
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.tzDestructive)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.tzSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.tzPrimary)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private func field<Content: View>(label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TZTheme.inkSecondary)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TZTheme.inkMuted)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let aliases = TZAliasParser.parse(aliasText)
        if let entry {
            appState.lexiconStore.updateEntry(
                id: entry.id,
                newTerm: trimmedTerm,
                newAliases: aliases,
                newCategory: category,
                newWeight: pinned ? 10 : 7
            )
            appState.statusBanner = "✅ Updated “\(trimmedTerm)”."
        } else {
            appState.lexiconStore.upsert(term: trimmedTerm, aliases: aliases, category: category, weight: pinned ? 10 : 8)
            appState.statusBanner = "✅ Added “\(trimmedTerm)” to your dictionary."
        }
        dismiss()
    }
}

// MARK: - Paste import sheet

struct TZLexiconImportSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var category: LexiconCategory = .person
    @State private var isDistilling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import words")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(TZTheme.ink)
                Text("Paste meeting notes, a spec, or a list of names. Import one word per line, or let your cleanup model pull out the names and jargon.")
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste text here…")
                        .font(.system(size: 14))
                        .foregroundStyle(TZTheme.inkMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .foregroundStyle(TZTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(height: 150)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TZTheme.panel))

            HStack(spacing: 8) {
                Text("Category for line-by-line import")
                    .font(.system(size: 13))
                    .foregroundStyle(TZTheme.inkSecondary)
                Menu {
                    ForEach(LexiconCategory.tzManualCases) { choice in
                        Button(choice.displayName) { category = choice }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(category.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TZTheme.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(TZTheme.inkMuted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(TZTheme.segmentTrack))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.tzGhost)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import line by line") {
                    let items = text
                        .components(separatedBy: CharacterSet(charactersIn: "\n,;\u{FF0C}\u{3001}\u{FF1B}"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.count >= 2 }
                        .map { (term: $0, aliases: [String](), category: category) }
                    let added = appState.lexiconStore.bulkUpsert(items)
                    appState.statusBanner = "✅ Imported \(added) \(added == 1 ? "word" : "words")."
                    dismiss()
                }
                .buttonStyle(.tzSecondary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(isDistilling ? "Extracting…" : "Extract with AI") {
                    guard !isDistilling else { return }
                    isDistilling = true
                    let pasted = text
                    Task {
                        await appState.distillPastedCorpus(pasted)
                        isDistilling = false
                        dismiss()
                    }
                }
                .buttonStyle(.tzPrimary)
                .disabled(isDistilling || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color.white)
        .preferredColorScheme(.light)
    }
}
