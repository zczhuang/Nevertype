import Foundation

/// Deterministic sample content for `--render-ui` (never written to the user's real data).
enum TZSampleData {
    struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: History

    private static let dictations: [String] = [
        "Sounds good, I'll take a look this afternoon.",
        "Can we move our sync to Thursday at 10? I have a conflict on Wednesday.",
        "Thanks for the quick turnaround. I'll merge it once CI is green.",
        "Quick update: the staging deploy finished and the smoke tests passed.",
        "Let's do three things today. First, review the pull request. Second, update the docs. Third, ship the release.",
        "Hi Priya, thanks for sending the deck over. I read through it twice and I think the pricing slide needs one more pass before we share it with the wider group. Could you add the monthly view next to the annual numbers?",
        "Reminder to self: renew the domain, book flights for the offsite, and send the invoice to Northwind before Friday.",
        "I think the root cause is the retry loop. When the upstream returns a 429 we back off, but we never reset the counter, so after a few minutes every request waits the maximum delay.",
        "Meeting notes. We agreed to freeze the scope for the Q4 roadmap, move the migration to January, and revisit hiring after the board meeting.",
        "Hey, are you free for a quick call? I want to walk you through the new onboarding flow.",
        "Draft reply: Thanks so much for reaching out. We would love to set up a pilot with your team. Does next Tuesday afternoon work for a thirty minute intro?",
        "Add a unit test for the empty history case and make sure the heatmap handles days before the first dictation.",
        "The quarterly numbers look strong. Revenue is up eleven percent, churn is flat, and the new onboarding flow lifted activation by four points.",
        "Looks great to me. One small nit: can we rename the helper so it matches the rest of the module?",
        "Idea for the blog post: how we cut our dictation latency in half by running everything on device.",
        "1. Pull the latest changes. 2. Run the migration. 3. Restart the worker. 4. Check the dashboard for errors.",
        "Good morning team, a quick heads up that the build will be unavailable from noon to one while we rotate the credentials.",
        "I'm running about ten minutes late, please start without me.",
        "TODO: write the release notes, tag the build, and post the changelog in the community channel.",
        "Could you share the latest numbers for Acme Robotics? I want to compare them with last quarter before the call.",
        "Dear Dr. Okafor, thank you for your time yesterday. As discussed, I am attaching the protocol and the consent form for your review.",
        "The new design feels much calmer. I like the grey panels and the single blue accent, but the sidebar could use a little more breathing room at the bottom.",
        "Remember to ask Jonas about the Terraform state file and whether we can move it to the shared bucket.",
        "Summary of today: shipped the dictionary page, fixed the focus bug in search, and started on the settings layout.",
        "Okay.",
        "Yes, that works for me.",
        "Let me think about it and get back to you tomorrow morning.",
        "Please find the updated contract attached. The main change is in section four, where we clarified the termination clause and the notice period.",
        "What if we ran the cleanup model locally and only fell back to the cloud when it is unavailable? That would keep everything private by default.",
        "Lunch at one? The new ramen place on the corner looks good."
    ]

    private static let rewrites: [(polished: String, raw: String)] = [
        ("Thanks for the quick turnaround. I'll review it first thing tomorrow.", "make it more polite and say I'll review it tomorrow"),
        ("We should ship the beta on Friday.", "shorten this"),
        ("Hi team, a quick reminder that the offsite agenda is due on Monday.", "turn this into a friendly reminder"),
        ("I'm sorry for the delay. The fix is now live.", "make this sound apologetic"),
        ("Let's regroup after lunch and decide on the rollout plan.", "make it sound more casual")
    ]

    private static let apps: [(name: String, weight: Int)] = [
        ("Slack", 28), ("Cursor", 20), ("Mail", 14), ("Notion", 10), ("Safari", 8), ("Messages", 6), ("Terminal", 5), ("Notes", 5), ("ChatGPT", 4)
    ]

    private static func pickApp(_ rng: inout SeededRNG) -> String {
        let total = apps.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<total, using: &rng)
        for app in apps {
            if roll < app.weight { return app.name }
            roll -= app.weight
        }
        return "Slack"
    }

    private static func rawTranscript(from polished: String, _ rng: inout SeededRNG) -> String {
        let stripped = polished
            .lowercased()
            .replacingOccurrences(of: "[\\.,!?:;]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        var words = stripped.split(separator: " ").map(String.init)
        if words.count > 4 {
            let fillers = ["um", "uh", "like", "you know"]
            words.insert(fillers[Int.random(in: 0..<fillers.count, using: &rng)], at: Int.random(in: 1..<min(words.count, 6), using: &rng))
        }
        if Bool.random(using: &rng) { words.insert("uh", at: 0) }
        return words.joined(separator: " ")
    }

    /// One dictation is one or several of the sentences above; most sessions are a few sentences long.
    private static func composedDictation(_ rng: inout SeededRNG) -> String {
        let roll = Double.random(in: 0..<1, using: &rng)
        let sentences: Int
        switch roll {
        case ..<0.28: sentences = 1
        case ..<0.55: sentences = 2
        case ..<0.78: sentences = 3
        case ..<0.92: sentences = 5
        default: sentences = 8
        }
        var parts: [String] = []
        for _ in 0..<sentences {
            parts.append(dictations[Int.random(in: 0..<dictations.count, using: &rng)])
        }
        return parts.joined(separator: " ")
    }

    static func history(now: Date, days: Int = 120) -> [DictationRecord] {
        var rng = SeededRNG(seed: 20_261_124)
        let cal = TZStats.calendar
        let today = cal.startOfDay(for: now)
        var records: [DictationRecord] = []

        func isActive(offset: Int, weekend: Bool, _ rng: inout SeededRNG) -> Bool {
            switch offset {
            case 0...8: return true                       // current streak of 9 days
            case 9: return false
            case 10...21: return !(weekend && Double.random(in: 0..<1, using: &rng) < 0.6)
            case 22...27: return false                    // a week off
            case 28...51: return true                     // the longest streak, 24 days
            case 52...53: return false
            default: return Double.random(in: 0..<1, using: &rng) < (weekend ? 0.35 : 0.82)
            }
        }

        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            guard isActive(offset: offset, weekend: weekend, &rng) else { continue }

            let spread = pow(Double.random(in: 0..<1, using: &rng), 1.7)
            var count = 3 + Int(spread * 18)
            if offset == 0 { count = 6 }

            for k in 0..<count {
                var stamp: Date
                if offset == 0 {
                    let candidate = now.addingTimeInterval(-Double(k + 1) * 1_380 - Double.random(in: 0..<420, using: &rng))
                    stamp = max(candidate, today.addingTimeInterval(60 + Double(count - k) * 30))
                } else {
                    let hour = Int.random(in: 8..<22, using: &rng)
                    let minute = Int.random(in: 0..<60, using: &rng)
                    let second = Int.random(in: 0..<60, using: &rng)
                    stamp = day.addingTimeInterval(Double(hour * 3600 + minute * 60 + second))
                }

                let isRewrite = Double.random(in: 0..<1, using: &rng) < 0.07
                let polished: String
                let raw: String
                let app = pickApp(&rng)
                if isRewrite {
                    let r = rewrites[Int.random(in: 0..<rewrites.count, using: &rng)]
                    polished = r.polished
                    raw = r.raw
                } else {
                    polished = composedDictation(&rng)
                    raw = rawTranscript(from: polished, &rng)
                }

                let words = TZStats.wordCount(polished)
                let wordsPerSecond = Double.random(in: 2.0..<2.8, using: &rng)
                let seconds = Double(words) / wordsPerSecond + Double.random(in: 0.5..<1.4, using: &rng)
                let latency = polished.count <= 28 ? 0 : Int.random(in: 190..<820, using: &rng)

                records.append(DictationRecord(
                    timestamp: stamp,
                    rawTranscript: raw,
                    polishedText: polished,
                    durationSeconds: seconds,
                    polishLatencyMs: latency,
                    targetAppName: app,
                    mode: isRewrite ? .rewriteSelection : .dictate,
                    matchedTerms: []
                ))
            }
        }
        return Array(records.sorted { $0.timestamp > $1.timestamp }.prefix(1_000))
    }

    // MARK: Lexicon

    private struct Seed {
        let term: String
        let aliases: [String]
        let category: LexiconCategory
        var weight: Int = 8
    }

    private static let seeds: [Seed] = [
        Seed(term: "Priya Raman", aliases: ["pria ramen", "priya ramon"], category: .person, weight: 10),
        Seed(term: "Jonas Albrecht", aliases: ["jonas albright"], category: .person),
        Seed(term: "Mei-Ling Tan", aliases: ["may ling tan"], category: .person),
        Seed(term: "Dr. Okafor", aliases: ["doctor oh kaffer"], category: .person),
        Seed(term: "Sofia Marchetti", aliases: ["sofia marketti"], category: .person),
        Seed(term: "Tomás Herrera", aliases: ["tomas errera"], category: .person),
        Seed(term: AppBrand.name, aliases: ["never type"], category: .project, weight: 10),
        Seed(term: "Parakeet", aliases: ["para keet"], category: .project),
        Seed(term: "Ollama", aliases: ["oh llama", "olama"], category: .project),
        Seed(term: "SwiftUI", aliases: ["swift ui"], category: .project),
        Seed(term: "Kubernetes", aliases: ["cuber nettys", "kubernetties"], category: .project),
        Seed(term: "PostgreSQL", aliases: ["post gress", "postgres q l"], category: .project),
        Seed(term: "Terraform", aliases: ["terra form"], category: .project),
        Seed(term: "GraphQL", aliases: ["graph q l"], category: .project),
        Seed(term: "Figma", aliases: ["fig ma"], category: .project),
        Seed(term: "Linear", aliases: [], category: .project),
        Seed(term: "Supabase", aliases: ["super base"], category: .project),
        Seed(term: "Playwright", aliases: ["play right"], category: .project),
        Seed(term: "pnpm", aliases: ["p n p m"], category: .project),
        Seed(term: "NVDA", aliases: ["nvidia ticker"], category: .finance),
        Seed(term: "Northwind Traders", aliases: ["north wind"], category: .finance),
        Seed(term: "Acme Robotics", aliases: ["acme robotic"], category: .finance),
        Seed(term: "Q4 roadmap", aliases: ["q four road map"], category: .memo),
        Seed(term: "OKRs", aliases: ["o k rs"], category: .memo),
        Seed(term: "Project Lighthouse", aliases: ["project light house"], category: .memo),
        Seed(term: "Cloudflare", aliases: ["cloud flare"], category: .browser),
        Seed(term: "Anthropic", aliases: ["and thropic"], category: .autoLearned, weight: 9),
        Seed(term: "Claude", aliases: ["cloud"], category: .autoLearned, weight: 9),
        Seed(term: "gRPC", aliases: ["g r p c", "gee rpc"], category: .autoLearned, weight: 9),
        Seed(term: "OAuth", aliases: ["oh auth"], category: .autoLearned, weight: 9),
        Seed(term: "Vercel", aliases: ["versel"], category: .autoLearned, weight: 9),
        Seed(term: "Tailwind", aliases: ["tail wind"], category: .autoLearned, weight: 9),
        Seed(term: "Zod", aliases: ["zahd"], category: .autoLearned, weight: 9),
        Seed(term: "Next.js", aliases: ["next j s"], category: .autoLearned, weight: 9),
        Seed(term: "Drizzle", aliases: ["drizzel"], category: .autoLearned, weight: 9),
        Seed(term: "tRPC", aliases: ["t r p c"], category: .autoLearned, weight: 9),
        Seed(term: "Xcode", aliases: ["x code"], category: .autoLearned, weight: 9),
        Seed(term: "Redis", aliases: ["red is"], category: .autoLearned, weight: 9),
        Seed(term: "Datadog", aliases: ["data dog"], category: .autoLearned, weight: 9),
        Seed(term: "Mixpanel", aliases: ["mix panel"], category: .autoLearned, weight: 9)
    ]

    /// Replaces the store's entries with 40 sample terms (about a third auto-learned).
    static func seedLexicon(_ store: PersonalLexiconStore) {
        store.removeBatch(ids: Set(store.entries.map(\.id)))
        // `upsert` inserts at the top, so insert in a fixed shuffled order to interleave auto and manual words.
        var rng = SeededRNG(seed: 4_242)
        var order = Array(seeds.indices)
        order.shuffle(using: &rng)
        for index in order {
            let s = seeds[index]
            store.upsert(term: s.term, aliases: s.aliases, category: s.category, weight: s.weight)
        }
    }

    static func clearLexicon(_ store: PersonalLexiconStore) {
        store.removeBatch(ids: Set(store.entries.map(\.id)))
    }
}
