import Foundation
import AppKit
import AVFoundation
import Carbon.HIToolbox
import CSherpaOnnx
import CryptoKit
import Speech

/// Built-in deterministic regression test suite (`Nevertype --self-test`).
/// Runs in <50ms on pure CommandLineTools without requiring full Xcode / XCTest installation.
public enum SelfTestSuite {
    @discardableResult
    public static func runAll() -> Int32 {
        var passed = 0
        var failed = 0

        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() {
                passed += 1
                print("  ✓ PASS: \(label)")
            } else {
                failed += 1
                print("  ✗ FAIL: \(label)")
            }
        }

        print("==> Running \(AppBrand.name) Core Regression Suite...")

        // 1. Fuzzy Accent Phonetic Skeleton (`zh/z`, `ing/in`, `n/l`)
        expect(
            PhoneticIndexer.fuzzySkeleton("清晨") == PhoneticIndexer.fuzzySkeleton("亲臣"),
            "Fuzzy skeleton matches '清晨' (qingchen) <-> '亲臣' (qincen)"
        )
        expect(
            PhoneticIndexer.fuzzySkeleton("实验") == PhoneticIndexer.fuzzySkeleton("思言"),
            "Fuzzy skeleton matches '实验' (shiyan) <-> '思言' (siyan)"
        )
        expect(
            PhoneticIndexer.fuzzySkeleton("张伟") == PhoneticIndexer.fuzzySkeleton("赞尾"),
            "Fuzzy skeleton matches '张伟' (zhangwei) <-> '赞尾' (zanwei)"
        )
        expect(
            PhoneticIndexer.fuzzySkeleton("林峰") == PhoneticIndexer.fuzzySkeleton("宁风"),
            "Fuzzy skeleton collapses n/l & eng/en ('林峰' <-> '宁风')"
        )

        // 2. Lexicon Store Smart Rename Merge & Recall (in isolated temp file)
        let tempLexiconURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tz_selftest_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.trashItem(at: tempLexiconURL, resultingItemURL: nil)
        }
        let store = PersonalLexiconStore(customStorageURL: tempLexiconURL)
        store.upsert(term: "张伟", aliases: ["张威"], category: .person, weight: 8)
        store.upsert(term: "章玮", aliases: ["章维"], category: .memo, weight: 7)

        if let wrongItem = store.entries.first(where: { $0.term == "章玮" }) {
            store.updateEntry(
                id: wrongItem.id,
                newTerm: "张伟",
                newAliases: wrongItem.aliases,
                newCategory: .person,
                newWeight: 9
            )
        }
        let mergedMatches = store.entries.filter { $0.term == "张伟" }
        expect(mergedMatches.count == 1, "Renaming '章玮' -> '张伟' smart-merges into single entry without duplicates")
        expect(
            mergedMatches.first?.aliases.contains("章玮") == true && mergedMatches.first?.aliases.contains("章维") == true,
            "Smart merge preserves old wrong term '章玮' and its aliases inside '张伟'"
        )

        let recalled = store.recallRelevantTerms(for: "这件事交给章维跟进一下", limit: 10)
        expect(recalled.contains(where: { $0.term == "张伟" }), "Sub-ms recall hits '张伟' from misheard '章维'")

        // 3. Markdown Auto-Continued Duplicate List Marker Prevention (`2. 2. ` -> `2. `)
        let cleanExpected = "现在我们做几件事：\n1. 检查代码质量；\n2. 准备 GitHub 分支；\n3. 写现状日志。"
        let buggyEditorBox = "现在我们做几件事：\n1. 检查代码质量；\n2. 2. 准备 GitHub 分支；\n3. 3. 写现状日志。"
        expect(
            ContextInjector.extractLeadingListMarker("2. 准备分支") == "2. ",
            "Extracts leading numbered list marker '2. '"
        )
        expect(
            ContextInjector.extractLeadingListMarker("- 无序要点") == "- ",
            "Extracts leading bullet list marker '- '"
        )
        expect(
            ContextInjector.containsDuplicatedListMarker(in: buggyEditorBox, expected: cleanExpected),
            "Detects Markdown editor duplicated list markers ('2. 2. ' / '3. 3. ')"
        )
        expect(
            ContextInjector.collapseDuplicatedListMarkers(buggyEditorBox) == cleanExpected,
            "Cleanly collapses '2. 2. ' and '3. 3. ' back to single markers"
        )

        // 4. Deterministic Pangu Spacing, Full-Width Chinese Punctuation & Percentage ITN
        let formatted = PolishEngine.applyPostFormattingRules(
            "使用DeepSeek提升百分之35速度。",
            context: ActiveScreenContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: "", selectedText: "", precedingText: ""),
            config: .default
        )
        expect(
            formatted == "使用 DeepSeek 提升 35% 速度",
            "Applies CJK-Latin Pangu spacing, percentage ITN, and strips trailing period in IM"
        )
        let normQ = PolishEngine.applyPostFormattingRules(
            "今天发财报会不会一样? 太好了!",
            context: ActiveScreenContext(appName: "微信", bundleID: "com.tencent.xinwechat", windowTitle: "", selectedText: "", precedingText: ""),
            config: .default
        )
        expect(
            normQ == "今天发财报会不会一样？ 太好了！",
            "Normalizes stray half-width ?/! directly after CJK characters to crisp full-width punctuation"
        )
        let noBlankLines = PolishEngine.applyPostFormattingRules(
            "第一段说明。\n\n第二段继续。",
            context: .empty,
            config: .default
        )
        expect(
            noBlankLines == "第一段说明。\n第二段继续。",
            "Collapses unwanted blank empty lines (\\n\\n) to clean single newline"
        )
        let strippedMd = PolishEngine.applyPostFormattingRules(
            "### 核心结论\n这是**重点内容**，请确认。",
            context: ActiveScreenContext(appName: "微信", bundleID: "com.tencent.xinwechat", windowTitle: "", selectedText: "", precedingText: ""),
            config: .default
        )
        expect(
            strippedMd == "核心结论\n这是重点内容，请确认。",
            "Strips stray Markdown headings/bold markers in non-code chat/doc apps"
        )
        expect(
            PersonalLexiconStore.isCommonOrDisposableAutoLearnTerm("v0.4.2")
                && PersonalLexiconStore.isCommonOrDisposableAutoLearnTerm("今天")
                && !PersonalLexiconStore.isCommonOrDisposableAutoLearnTerm("星河")
                && !PersonalLexiconStore.isCommonOrDisposableAutoLearnTerm("DeepSeek"),
            "Auto-learn pollution filter skips common words & version numbers while keeping proper nouns"
        )

        // 5. Keychain Provider Slot Isolation & Safety Guardrail
        expect(KeychainHelper.providerSlot(for: "https://api.deepseek.com/v1") == "deepseek_api_key", "Routes DeepSeek slot")
        expect(KeychainHelper.providerSlot(for: "https://ark.cn-beijing.volces.com/api/v3") == "ark_api_key", "Routes Volcengine Ark slot")
        expect(ContextInjector.isAllowedTarget(bundleID: "com.tencent.xinwechat", appName: "微信"), "Allows universal dictation input in all user-focused IM apps")

        // 6. Dual-Engine Acoustic Stack (Seed-ASR 2.0 Polyphase 16kHz Resampler + Local FP32 Model Detection)
        let legacyJSON = #"{"baseURL":"https://api.deepseek.com/v1","modelName":"deepseek-flash"}"#.data(using: .utf8) ?? Data()
        let decodedLegacy = try? JSONDecoder().decode(LLMConfig.self, from: legacyJSON)
        expect(decodedLegacy?.enableVolcSeedASR == true, "Legacy config.json auto-enables Volcengine Seed-ASR 2.0 dual engine")

        let wave48k: [Float] = (0..<4800).map { i in Float(sin(2.0 * Double.pi * 1000.0 * Double(i) / 48_000.0) * 0.45) }
        let resampled16k = StreamingASREngine.resampleFloatTo16kHzInt16(wave48k, sourceRate: 48_000.0)
        let maxAmp = resampled16k.map { abs(Int($0)) }.max() ?? 0
        expect(
            resampled16k.count >= 1580 && resampled16k.count <= 1620 && maxAmp > 10_000,
            "Polyphase AVAudioConverter resamples 48kHz Float32 -> 16kHz Int16 mono accurately (\(resampled16k.count) samples, peak \(maxAmp))"
        )

        if let modelInfo = StreamingASREngine.senseVoiceModelPaths() {
            expect(modelInfo.isFullFP32, "Local lossless 886MB SenseVoice FP32 model detected and prioritized")
        }

        // 7. Word-Boundary Acronym Glide Correction ("Su" / "s Su" -> "SEO" without touching "Summary" / "Supabase")
        let seoEntry = LexiconEntry(term: "SEO", aliases: ["Su", "s Su", "艾斯伊欧"], phoneticKey: "seo", category: .project, weight: 10)
        let glideFixed = PolishEngine.applyInstantLocalDictionary(
            "招这个 Su 的人做日本的 s Su，让 Summary 看一下 Supabase",
            entries: [seoEntry],
            context: .empty,
            config: .default,
            stripPeriod: false
        )
        expect(
            glideFixed == "招这个 SEO 的人做日本的 SEO，让 Summary 看一下 Supabase",
            "Word-boundary dictionary fixes 'Su' / 's Su' -> 'SEO' while keeping 'Summary' & 'Supabase' intact"
        )

        // 8. Multi-Paragraph Auto-Learn, Selection Voice Teach-in & Context-Ranked Hotwords
        let multiOrig = "第一段背景说明。\n\n第二段我们让星合跟进一下海外投放。\n\n第三段收尾。"
        let multiEdited = "第一段背景说明。\n\n第二段我们让星河跟进一下海外投放。\n\n第三段收尾。"
        let learnedMulti = store.learnFromManualEditIfApplicable(injectedText: multiOrig, editedBoxValue: multiEdited)
        expect(
            learnedMulti?.wrong == "星合" && learnedMulti?.corrected == "星河",
            "Multi-paragraph auto-learn extracts '星合' -> '星河' across newline-separated text"
        )

        let taughtVoice = store.learnFromSelectionRewrite(selectedText: "Su", rewrittenText: "SEO")
        expect(
            taughtVoice?.wrong == "Su" && taughtVoice?.corrected == "SEO",
            "Selection voice rewrite permanently learns 'Su' -> 'SEO' into personal lexicon"
        )

        let dynamicHot = store.topAcousticContextualStrings(contextHint: "正在对比 Semrush 与 GitHub 增长数据", limit: 15)
        expect(
            dynamicHot.contains("Semrush") && dynamicHot.contains("GitHub"),
            "Context-ranked hotwords dynamically inject live CamelCase/uppercase terms from active context"
        )

        // 9. Default Live Inline Typing Mode (`enableLiveInlineTyping == true`) + Smart <=28-Char Clean Cloud Bypass
        expect(
            LLMConfig.default.enableLiveInlineTyping == true,
            "Default config turns ON frontend inline typing by default"
        )
        let decodedEmptyConfig = try? JSONDecoder().decode(LLMConfig.self, from: Data("{}".utf8))
        expect(
            decodedEmptyConfig?.enableLiveInlineTyping == true,
            "Decoding config JSON without enableLiveInlineTyping defaults to true"
        )
        expect(
            PolishEngine.canBypassCloudPolish(
                locallyFixed: "好的，那你动手把这3点改上吧。",
                recalledTerms: [],
                formattingStyle: .structured,
                isHighAccuracyLocalASR: true,
                isPunctuatedCloudASR: true
            ),
            "Clean <=28-char Seed-ASR sentence bypasses Pass-2 LLM in 0ms"
        )
        expect(
            !PolishEngine.canBypassCloudPolish(
                locallyFixed: "嗯，那个帮我看一下第一点不对改成第二点。",
                recalledTerms: [],
                formattingStyle: .structured,
                isHighAccuracyLocalASR: true,
                isPunctuatedCloudASR: true
            ),
            "Sentence with fillers or self-corrections still routes to Pass-2 LLM"
        )
        AudioLevelBus.shared.reset()
        AudioLevelBus.shared.pushRecognizedCount(14)
        let symSnap = AudioLevelBus.shared.sampleRecognizedSymbolProgress()
        expect(
            symSnap.exactTarget == 14 && symSnap.smoothProgress > 0,
            "Capsule Micro-Symbol counter smoothly advances toward recognized character count"
        )
        AudioLevelBus.shared.reset()

        // 10. Full Left & Right Modifier Hotkeys + Combo Isolation + Unified Check-to-Activate LLM Config
        expect(
            TriggerKeyOption.presetMatrixOrder.count == 10,
            "Symmetric 2x5 hotkey preset grid exposes all Left/Right modifiers + Fn + Option+Space"
        )
        let leftOptFlags = NSEvent.ModifierFlags.option.rawValue | HotkeyMonitor.nxDeviceLeftAltMask
        let rightOptFlags = NSEvent.ModifierFlags.option.rawValue | HotkeyMonitor.nxDeviceRightAltMask
        expect(
            HotkeyMonitor.matchesSingleModifierPress(option: .leftOption, keyCode: 58, rawFlags: leftOptFlags)
                && !HotkeyMonitor.matchesSingleModifierPress(option: .rightOption, keyCode: 58, rawFlags: leftOptFlags),
            "Left Option (keyCode 58) triggers ONLY .leftOption and never leaks into .rightOption"
        )
        expect(
            HotkeyMonitor.matchesSingleModifierPress(option: .rightOption, keyCode: 61, rawFlags: rightOptFlags)
                && !HotkeyMonitor.matchesSingleModifierPress(option: .leftOption, keyCode: 61, rawFlags: rightOptFlags),
            "Right Option (keyCode 61) triggers ONLY .rightOption and never leaks into .leftOption"
        )
        let leftCtrlFlags = NSEvent.ModifierFlags.control.rawValue | HotkeyMonitor.nxDeviceLeftCtrlMask
        let rightShiftFlags = NSEvent.ModifierFlags.shift.rawValue | HotkeyMonitor.nxDeviceRightShiftMask
        expect(
            HotkeyMonitor.matchesSingleModifierPress(option: .leftControl, keyCode: 59, rawFlags: leftCtrlFlags)
                && HotkeyMonitor.matchesSingleModifierPress(option: .rightShift, keyCode: 60, rawFlags: rightShiftFlags),
            "Left Control (59) & Right Shift (60) match cleanly via hardware keyCode + device mask"
        )
        expect(
            HotkeyMonitor.formatComboLabel(keyCode: 49, carbonModifiers: UInt32(controlKey | optionKey)) == "⌃ + ⌥ + Space",
            "Custom combo formatter outputs crisp macOS keycap symbols ('⌃ + ⌥ + Space')"
        )

        var cfg = LLMConfig.default
        cfg.selectProvider(.volcengine)
        cfg.modelName = "ep-20260915-fast"
        cfg.selectProvider(.custom)
        cfg.baseURL = "http://localhost:11434/v1"
        cfg.modelName = "qwen2.5:7b"
        cfg.selectProvider(.deepseek)
        cfg.selectProvider(.volcengine)
        let restoredVolcModel = cfg.modelName
        cfg.selectProvider(.custom)
        expect(
            restoredVolcModel == "ep-20260915-fast"
                && cfg.baseURL == "http://localhost:11434/v1"
                && PolishEngine.isKeylessLocalEndpoint(cfg.baseURL),
            "Provider switching preserves per-provider model IDs/URLs and supports keyless local Ollama endpoints"
        )
        expect(
            KeychainHelper.providerSlot(for: .dashscope) == "dashscope_api_key"
                && KeychainHelper.providerSlot(for: .openai) == "openai_api_key"
                && KeychainHelper.providerSlot(for: .gemini) == "gemini_api_key"
                && KeychainHelper.providerSlot(for: .anthropic) == "anthropic_api_key"
                && KeychainHelper.providerSlot(for: .custom) == "custom_api_key",
            "Unified provider selector routes DashScope, OpenAI, Gemini, Anthropic, and Custom keys to isolated Keychain slots"
        )
        expect(
            LLMProviderOption.infer(from: "https://api.openai.com/v1") == .openai
                && LLMProviderOption.infer(from: "https://generativelanguage.googleapis.com/v1beta/openai") == .gemini
                && LLMProviderOption.infer(from: "https://api.anthropic.com/v1") == .anthropic
                && PolishEngine.isAnthropicEndpoint("https://api.anthropic.com/v1")
                && PolishEngine.normalizeAnthropicMessagesEndpoint("https://api.anthropic.com/v1") == "https://api.anthropic.com/v1/messages",
            "Accurately detects OpenAI, Google Gemini, and native Anthropic Claude Messages API endpoints"
        )
        let oaiGpt5 = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-5-mini",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let gemini25 = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            model: "gemini-2.5-flash",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let gemini38 = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            model: "gemini-3.8-flash",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        expect(
            (oaiGpt5["max_completion_tokens"] as? Int) == 200
                && oaiGpt5["max_tokens"] == nil
                && (oaiGpt5["reasoning_effort"] as? String) == "minimal"
                && (gemini25["reasoning_effort"] as? String) == "none"
                && (gemini38["reasoning_effort"] as? String) == "minimal",
            "Builds provider-accurate OpenAI GPT-5 (max_completion_tokens) and Gemini 2.5/3.8 (reasoning_effort) payloads"
        )

        expect(
            LLMConfig.default.showInDock == false,
            "Default app mode runs cleanly in top Menu Bar without cluttering the macOS Dock"
        )

        // v0.4.5: OpenAI / Groq Cloud ASR endpoint normalization, 16kHz WAV encoding, hotword prompt hint & ASRProvider migration
        let legacyLocalJSON = #"{"enableVolcSeedASR":false,"baseURL":"https://api.openai.com/v1","modelName":"gpt-4.1-mini"}"#
        let decodedLegacyLocal = try? JSONDecoder().decode(LLMConfig.self, from: Data(legacyLocalJSON.utf8))
        let explicitOpenAIASRJSON = #"{"asrProvider":"openAIWhisper","openAIASRBaseURL":"https://api.groq.com/openai/v1","openAIASRModel":"whisper-large-v3-turbo"}"#
        let decodedOpenAIASR = try? JSONDecoder().decode(LLMConfig.self, from: Data(explicitOpenAIASRJSON.utf8))
        expect(
            decodedLegacyLocal?.asrProvider == .localSenseVoice
                && decodedOpenAIASR?.asrProvider == .openAIWhisper
                && decodedOpenAIASR?.openAIASRModel == "whisper-large-v3-turbo"
                && decodedOpenAIASR?.enableVolcSeedASR == false,
            "ASRProviderOption migrates legacy enableVolcSeedASR configs and preserves OpenAI/Groq ASR settings"
        )
        expect(
            OpenAITranscriptionClient.normalizeTranscriptionEndpoint("https://api.openai.com/v1") == "https://api.openai.com/v1/audio/transcriptions"
                && OpenAITranscriptionClient.normalizeTranscriptionEndpoint("https://api.groq.com/openai/v1/") == "https://api.groq.com/openai/v1/audio/transcriptions"
                && OpenAITranscriptionClient.normalizeTranscriptionEndpoint("https://relay.example.com") == "https://relay.example.com/v1/audio/transcriptions"
                && OpenAITranscriptionClient.normalizeTranscriptionEndpoint("https://api.openai.com/v1/audio/transcriptions") == "https://api.openai.com/v1/audio/transcriptions"
                && OpenAITranscriptionClient.isGroqEndpoint("https://api.groq.com/openai/v1"),
            "Normalizes OpenAI, Groq, and custom transcription endpoints cleanly without duplicating path segments"
        )
        let samplePCM: [Int16] = [0, 1000, -1000, 32000, -32000, 500]
        let wavBytes = OpenAITranscriptionClient.encodePCM16ToWAV(samplePCM, sampleRate: 16_000)
        let riffHeader = String(data: wavBytes.prefix(4), encoding: .ascii)
        let waveHeader = String(data: wavBytes.subdata(in: 8..<12), encoding: .ascii)
        let dataChunkTag = String(data: wavBytes.subdata(in: 36..<40), encoding: .ascii)
        let encodedSampleRate = wavBytes.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let encodedDataSize = wavBytes.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        expect(
            wavBytes.count == 44 + samplePCM.count * 2
                && riffHeader == "RIFF"
                && waveHeader == "WAVE"
                && dataChunkTag == "data"
                && encodedSampleRate == 16_000
                && encodedDataSize == UInt32(samplePCM.count * 2),
            "Encodes 16kHz mono Int16 PCM into a valid 44-byte RIFF/WAVE payload in memory"
        )
        let promptHint = OpenAITranscriptionClient.buildPromptHint(
            hotwords: ["TypeZero", "typezero", "DeepSeek", "SwiftUI", "A", "Groq"],
            maxChars: 24
        )
        let enPromptHint = OpenAITranscriptionClient.buildPromptHint(
            hotwords: ["五彩石", "TypeZero", "火山引擎", "DeepSeek"],
            maxChars: 80,
            languageLocale: "en-US"
        )
        expect(
            promptHint == "TypeZero, DeepSeek"
                && enPromptHint == "TypeZero, DeepSeek"
                && OpenAITranscriptionClient.isoLanguageCode(from: "auto") == nil
                && OpenAITranscriptionClient.isoLanguageCode(from: "zh-CN") == "zh"
                && OpenAITranscriptionClient.isoLanguageCode(from: "en-US") == "en",
            "Deduplicates and bounds OpenAI/Groq vocabulary prompt hints, filters CJK terms in EN mode, and omits language for auto"
        )

        // 12b. Anti-Translation Language Guardrails & Legacy speechLocale Auto-Migration
        let legacyLocaleJSON = #"{"speechLocale":"zh-CN","modelName":"deepseek-flash"}"#.data(using: .utf8)!
        let explicitLocaleJSON = #"{"speechLocale":"zh-CN","speechLocaleExplicitlySet":true,"modelName":"deepseek-flash"}"#.data(using: .utf8)!
        let migratedLocaleCfg = try? JSONDecoder().decode(LLMConfig.self, from: legacyLocaleJSON)
        let explicitLocaleCfg = try? JSONDecoder().decode(LLMConfig.self, from: explicitLocaleJSON)
        expect(
            LLMConfig.default.speechLocale == "auto"
                && migratedLocaleCfg?.speechLocale == "auto"
                && explicitLocaleCfg?.speechLocale == "zh-CN"
                && LLMConfig.senseVoiceLanguageCode(for: "auto") == "auto"
                && LLMConfig.senseVoiceLanguageCode(for: "zh-CN") == "zh"
                && LLMConfig.senseVoiceLanguageCode(for: "en-US") == "en",
            "Defaults speechLocale to auto, migrates legacy unconfigured zh-CN to auto, preserves explicit user choice, and maps SenseVoice language"
        )

        let enRaw = "Hey team, let's push the release tomorrow afternoon after we verify the audio pipeline."
        let badEnToZh = "嘿团队，我们在验证完音频管线后，明天下午再发布这个版本吧。"
        let goodEnPolished = "Hey team, let's push the release tomorrow afternoon after we verify the audio pipeline."
        let zhRaw = "我们今天下午三点开会同步一下最新的产品进展和发布计划"
        let badZhToEn = "We will have a meeting at 3 pm this afternoon to sync on the latest product progress and release plan."
        let mixedRaw = "我们用 DeepSeek 和 TypeZero 来做语音输入法"
        let mixedOut = "我们用 DeepSeek 和 TypeZero 来做语音输入法。"
        expect(
            PolishEngine.guardAgainstUnexpectedTranslation(rawInput: enRaw, llmOutput: badEnToZh) == enRaw
                && PolishEngine.guardAgainstUnexpectedTranslation(rawInput: enRaw, llmOutput: goodEnPolished) == goodEnPolished
                && PolishEngine.guardAgainstUnexpectedTranslation(rawInput: zhRaw, llmOutput: badZhToEn) == zhRaw
                && PolishEngine.guardAgainstUnexpectedTranslation(rawInput: mixedRaw, llmOutput: mixedOut) == mixedOut,
            "Anti-translation circuit breaker rejects accidental En->Zh and Zh->En LLM translations while preserving normal EN, ZH, and mixed polishing"
        )
        expect(
            AppUpdater.isNewerVersion("0.5.6", than: "0.5.5")
                && AppUpdater.isNewerVersion("v0.10.0", than: "0.5.9")
                && !AppUpdater.isNewerVersion("0.5.5", than: "0.5.5")
                && !AppUpdater.isNewerVersion("0.5.4", than: "0.5.5"),
            "Semantic version comparator accurately detects newer releases for in-app auto-updater"
        )

        // 13. Zero-Rewind Atomic Polish Routing (WeChat/QQ & Long Drafts >= 25 Chars) + Prefix-Preserving Replacement Diff
        let wechatCtx = ActiveScreenContext(appName: "微信", bundleID: "com.tencent.xinwechat", windowTitle: "", selectedText: "", precedingText: "")
        let notesCtx = ActiveScreenContext(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "", selectedText: "", precedingText: "")
        let longDraft = "似乎我在微信里面发不是特别容易回行比如现在我说很长的字我在看一个巴黎视频第一他有真人出镜感第二讲解很轻快"
        expect(
            wechatCtx.prefersAtomicPolishReplacement
                && !notesCtx.prefersAtomicPolishReplacement
                && !LiveInputSession.shouldUseLiveSSEStream(draft: "你好世界", context: wechatCtx)
                && LiveInputSession.shouldUseLiveSSEStream(draft: "帮我查一下今天的日程", context: notesCtx)
                && !LiveInputSession.shouldUseLiveSSEStream(draft: longDraft, context: notesCtx),
            "Routes WeChat/QQ and long (>24 char) drafts to steady atomic post-polish replacement instead of SSE backspace rewind"
        )
        let atomicDiff = LiveInputSession.computeAtomicReplacementDiff(
            emitted: "似乎我在微信里面发不是特别容易回行，第2天视频很好看",
            finalText: "似乎我在微信里面发不是特别容易回行，第 2 天视频很好看。\n1. 画面稳"
        )
        expect(
            atomicDiff.commonPrefixCount == 19
                && atomicDiff.replaceCount == 7
                && atomicDiff.replacementSuffix == " 2 天视频很好看。\n1. 画面稳",
            "Preserves unchanged leading prefix in atomic replacement diff so only the divergent tail is selected and pasted"
        )
        let mergedExact = LiveInputSession.buildMergedBoxReplacement(
            boxText: "明天我要开三个会第一个上午开会第二个中午吃饭",
            alreadyEmitted: "明天我要开三个会第一个上午开会第二个中午吃饭",
            finalText: "明天我要开 3 个会：\n1. 上午开会；\n2. 中午吃饭。"
        )
        let mergedWithPrefix = LiveInputSession.buildMergedBoxReplacement(
            boxText: "张总你好，明天我要开三个会第一个上午开会",
            alreadyEmitted: "明天我要开三个会第一个上午开会",
            finalText: "明天我要开 3 个会：\n1. 上午开会。"
        )
        expect(
            mergedExact == "明天我要开 3 个会：\n1. 上午开会；\n2. 中午吃饭。"
                && mergedWithPrefix == "张总你好，明天我要开 3 个会：\n1. 上午开会。"
                && LiveInputSession.buildMergedBoxReplacement(boxText: "完全不相关的内容", alreadyEmitted: "明天开会", finalText: "明天开会。") == nil
                && !ContextInjector.pasteboardContainsNonTextRichObject(typeNames: ["public.utf8-plain-text", "NSStringPboardType"])
                && ContextInjector.pasteboardContainsNonTextRichObject(typeNames: ["public.utf8-plain-text", "public.tiff"]),
            "Cmd+A/Cmd+C zero-rewind merge preserves user-typed prefixes and guards against flattening rich media/images"
        )

        // 14. Steady Window-Bottom Pill Anchor (Never chases mouse cursor, never flips to window top)
        let vf = CGRect(x: 0, y: 60, width: 1920, height: 990)
        let pillSz = CGSize(width: 140, height: 34)
        let midWin = CGRect(x: 200, y: 120, width: 1000, height: 680) // cocoaBottomY = 1080 - 800 = 280
        let midAnchor = ContextInjector.anchorWindowBottomCocoaOrigin(
            forWindowQuartzRect: midWin,
            pillSize: pillSz,
            primaryScreenHeight: 1080,
            visibleFrame: vf,
            horizontalRatio: 0.64
        )
        let flushBottomWin = CGRect(x: 200, y: 80, width: 1000, height: 940) // cocoaBottomY = 1080 - 1020 = 60 (flush with Dock)
        let flushAnchor = ContextInjector.anchorWindowBottomCocoaOrigin(
            forWindowQuartzRect: flushBottomWin,
            pillSize: pillSz,
            primaryScreenHeight: 1080,
            visibleFrame: vf,
            horizontalRatio: 0.64
        )
        expect(
            abs(midAnchor.x - (200 + 640 - 70)) < 1.0
                && abs(midAnchor.y - (280 - 34 - 10)) < 1.0
                && flushAnchor.y >= vf.minY + 12 && flushAnchor.y < 120,
            "Tier-3 window anchor locks pill beneath WeChat compose pane and stays tucked at bottom when window is flush with Dock"
        )

        // 49. Live inline typing zero-deadlock under deep (>6 char) early punctuation/word revisions across many turns
        var simEmitted = "我发现有一个问题就是我在打字用语音的过程中"
        var simTarget = simEmitted
        var simCloudRaw = simEmitted
        // Seed-ASR inserts a comma 12 chars earlier AND adds new words at the end
        let rev1 = LiveInputSession.reconcileLiveTargetAdvance(
            emitted: simEmitted,
            targetConfirmed: simTarget,
            lastCloudRaw: simCloudRaw,
            newStable: "我发现有一个问题，就是我在打字用语音的过程中，出着出着字就不继续往前出了",
            isCloudStream: true
        )
        simTarget = rev1.nextTarget
        simCloudRaw = rev1.nextCloudRaw
        simEmitted = simTarget
        let rev2 = LiveInputSession.reconcileLiveTargetAdvance(
            emitted: simEmitted,
            targetConfirmed: simTarget,
            lastCloudRaw: simCloudRaw,
            newStable: "我发现有一个问题，就是我在打字用语音的过程中，出着出着字就不继续往前出了，现在测试连续跟出",
            isCloudStream: true
        )
        expect(
            rev1.didAdvanceOrRevise
                && rev1.nextTarget.hasPrefix("我发现有一个问题就是我在打字用语音的过程中")
                && rev1.nextTarget.contains("出着出着字就不继续往前出了")
                && rev2.didAdvanceOrRevise
                && rev2.nextTarget.hasSuffix("现在测试连续跟出"),
            "Live inline typing never deadlocks on deep (>6 char) cloud revisions and continues streaming every utterance"
        )

        // 50. Live inline typing zero-stall when Doubao DDC deletes filler words mid-sentence
        let ddcEmitted = "我觉得那个嗯就是这个方案"
        let ddcShrink = LiveInputSession.reconcileLiveTargetAdvance(
            emitted: ddcEmitted,
            targetConfirmed: ddcEmitted,
            lastCloudRaw: ddcEmitted,
            newStable: "我觉得这个方案",
            isCloudStream: true
        )
        let ddcNext = LiveInputSession.reconcileLiveTargetAdvance(
            emitted: ddcEmitted,
            targetConfirmed: ddcShrink.nextTarget,
            lastCloudRaw: ddcShrink.nextCloudRaw,
            newStable: "我觉得这个方案非常丝滑",
            isCloudStream: true
        )
        expect(
            ddcShrink.nextCloudRaw == "我觉得这个方案"
                && ddcNext.didAdvanceOrRevise
                && ddcNext.nextTarget == "我觉得那个嗯就是这个方案非常丝滑",
            "Live inline typing absorbs Doubao DDC filler deletion with 0 payback stall on the very next syllable"
        )

        // 51. Empty-box guard detects sent/cleared input box on AX apps (prevents ghost re-paste after Enter/Send)
        expect(
            LiveInputSession.isBoxClearedAfterLiveEmit(currentBoxText: "", alreadyEmitted: "这是一段已经发出去的语音内容", isRichSlowEditor: false) == true
                && LiveInputSession.isBoxClearedAfterLiveEmit(currentBoxText: nil, alreadyEmitted: "这是一段在微信里的语音内容", isRichSlowEditor: true) == false
                && LiveInputSession.isBoxClearedAfterLiveEmit(currentBoxText: "", alreadyEmitted: "", isRichSlowEditor: false) == false,
            "Empty-box guard aborts re-paste when AX input box is cleared after live emit without breaking WeChat nil AX"
        )

        // 52. Atomic probe copyTimeout guard aborts blind Shift+Left re-paste into emptied box
        expect(
            LiveInputSession.shouldAbortOnAtomicProbeFailure(probeReason: "copyTimeout", alreadyEmitted: "已经发出去了的六十个字草稿") == true
                && LiveInputSession.shouldAbortOnAtomicProbeFailure(probeReason: "richMediaGuard", alreadyEmitted: "带图片的草稿") == false
                && LiveInputSession.shouldAbortOnAtomicProbeFailure(probeReason: "copyTimeout", alreadyEmitted: "") == false,
            "Atomic probe copyTimeout aborts blind Shift+Left re-paste when box was already emptied"
        )

        // 53. Physical Return/Enter detection triggers on bare Return / Cmd+Return and ignores Shift+Return soft newlines
        expect(
            HotkeyMonitor.isUserSubmitEnterKey(keyCode: 36, modifiers: []) == true
                && HotkeyMonitor.isUserSubmitEnterKey(keyCode: 36, modifiers: [.command]) == true
                && HotkeyMonitor.isUserSubmitEnterKey(keyCode: 76, modifiers: []) == true
                && HotkeyMonitor.isUserSubmitEnterKey(keyCode: 36, modifiers: [.shift]) == false
                && HotkeyMonitor.isUserSubmitEnterKey(keyCode: 36, modifiers: [.option]) == false,
            "Submit-Enter detector recognizes bare/Cmd Return while preserving Shift+Enter and Option+Enter soft newlines"
        )

        // 54. Fork: local Ollama thinking switch (`reasoning_effort: "none"`) for keyless local endpoints ONLY
        let ollamaPayload = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "http://127.0.0.1:11434/v1/chat/completions",
            model: "gemma4:12b-mlx",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let localhostPayload = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "http://localhost:11434/v1/chat/completions",
            model: "qwen3:8b",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let deepseekPayload = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://api.deepseek.com/v1/chat/completions",
            model: "deepseek-flash",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let openAIMiniPayload = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-4.1-mini",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let gemini20Payload = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            model: "gemini-2.0-flash",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        let siliconPayload = PolishEngine.buildOpenAICompatiblePayload(
            endpoint: "https://api.siliconflow.cn/v1/chat/completions",
            model: "Qwen/Qwen2.5-72B-Instruct",
            systemPrompt: "sys",
            userContent: "hi",
            maxTokens: 200,
            stream: true
        )
        // Expected cloud payloads exactly as they were before this fork touched PolishEngine
        func expectedPayload(model: String, extra: [String: Any]) -> NSDictionary {
            var d: [String: Any] = [
                "model": model,
                "stream": true,
                "max_tokens": 200,
                "messages": [["role": "system", "content": "sys"], ["role": "user", "content": "hi"]]
            ]
            for (k, v) in extra { d[k] = v }
            return d as NSDictionary
        }
        expect(
            (ollamaPayload["reasoning_effort"] as? String) == "none"
                && (ollamaPayload["temperature"] as? Double) == 0.1
                && (ollamaPayload["max_tokens"] as? Int) == 200
                && (localhostPayload["reasoning_effort"] as? String) == "none",
            "Local Ollama (127.0.0.1 / localhost) payloads carry reasoning_effort \"none\" so gemma-class models do not think for ~11s before the first token"
        )
        expect(
            (deepseekPayload as NSDictionary).isEqual(expectedPayload(model: "deepseek-flash", extra: ["thinking": ["type": "disabled"]]))
                && (openAIMiniPayload as NSDictionary).isEqual(expectedPayload(model: "gpt-4.1-mini", extra: ["temperature": 0.1]))
                && (gemini20Payload as NSDictionary).isEqual(expectedPayload(model: "gemini-2.0-flash", extra: ["temperature": 0.1]))
                && (siliconPayload as NSDictionary).isEqual(expectedPayload(model: "Qwen/Qwen2.5-72B-Instruct", extra: ["temperature": 0.1]))
                && deepseekPayload["reasoning_effort"] == nil
                && openAIMiniPayload["reasoning_effort"] == nil
                && gemini20Payload["reasoning_effort"] == nil
                && siliconPayload["reasoning_effort"] == nil
                && (gemini25["reasoning_effort"] as? String) == "none"
                && (oaiGpt5["reasoning_effort"] as? String) == "minimal",
            "DeepSeek / OpenAI / Gemini / SiliconFlow payloads are unchanged byte-for-byte (no reasoning_effort injected; Gemini 2.5 and GPT-5 keep their own)"
        )

        // 55. SSE parser only takes delta.content (never delta.reasoning thinking tokens)
        expect(
            PolishEngine.parseOpenAIStreamLine(#"data: {"choices":[{"delta":{"reasoning":"Let me think about this","content":""}}]}"#) == .ignore
                && PolishEngine.parseOpenAIStreamLine(#"data: {"choices":[{"delta":{"reasoning":"hmm"}}]}"#) == .ignore
                && PolishEngine.parseOpenAIStreamLine(#"data: {"choices":[{"delta":{"reasoning_content":"step 1"}}]}"#) == .ignore
                && PolishEngine.parseOpenAIStreamLine(#"data: {"choices":[{"delta":{"role":"assistant","content":"Hi there","reasoning":"x"}}]}"#) == .token("Hi there")
                && PolishEngine.parseOpenAIStreamLine("data: [DONE]") == .done
                && PolishEngine.parseOpenAIStreamLine(": keep-alive") == .ignore
                && PolishEngine.parseOpenAIStreamLine("") == .ignore,
            "OpenAI-compatible SSE parser streams only delta.content and ignores delta.reasoning / reasoning_content"
        )

        // 56. Ollama keep-alive warm-up request (`POST /api/generate {"model","keep_alive":-1}`): keep_alive is the JSON NUMBER -1
        // ("resident until Ollama quits"); Ollama rejects the string "-1" with HTTP 400 (missing unit in duration)
        let warmReq = PolishEngine.ollamaKeepAliveRequest(baseURL: "http://127.0.0.1:11434/v1", model: "gemma4:12b-mlx")
        let warmBody = (warmReq?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let warmJSON = (warmReq?.httpBody).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let warmReqLM = PolishEngine.ollamaKeepAliveRequest(baseURL: "http://localhost:1234/v1/", model: " m ")
        expect(
            warmReq?.url?.absoluteString == "http://127.0.0.1:11434/api/generate"
                && warmReq?.httpMethod == "POST"
                && warmBody?["model"] as? String == "gemma4:12b-mlx"
                && (warmBody?["keep_alive"] as? NSNumber)?.intValue == -1
                && !(warmBody?["keep_alive"] is String)
                && warmJSON.contains("\"keep_alive\":-1")
                && warmReqLM?.url?.absoluteString == "http://localhost:1234/api/generate"
                && PolishEngine.ollamaKeepAliveRequest(baseURL: "http://127.0.0.1:11434/v1", model: "  ") == nil,
            "Local endpoints get a model-load warm-up POST to <scheme>://<host>:<port>/api/generate with keep_alive -1 sent as a JSON number (resident until Ollama quits)"
        )

        // 57. English cleanup prompts keep the tag contract, stay English and static
        func containsCJK(_ text: String) -> Bool {
            text.unicodeScalars.contains { ($0.value >= 0x3400 && $0.value <= 0x4DBF) || ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || ($0.value >= 0x3000 && $0.value <= 0x30FF) }
        }
        let structuredPrompt = PolishEngine.structuredStaticSystemPrompt
        let lightPrompt = PolishEngine.lightStaticSystemPrompt
        let rewritePrompt = PolishEngine.rewriteSelectionSystemPrompt
        expect(
            ["<scene>", "<recent_context>", "<preceding_text>", "<lexicon>", "<raw_speech>"].allSatisfy { structuredPrompt.contains($0) }
                && ["<recent_context>", "<preceding_text>", "<lexicon>", "<raw_speech>"].allSatisfy { lightPrompt.contains($0) }
                && ["<selected_text>", "<voice_instruction>", "<lexicon>"].allSatisfy { rewritePrompt.contains($0) }
                && !containsCJK(structuredPrompt) && !containsCJK(lightPrompt) && !containsCJK(rewritePrompt)
                && structuredPrompt.contains("<example_5>")
                && !structuredPrompt.contains("\\(")
                && structuredPrompt.count < 6_000,
            "English cleanup prompts (structured, light, rewrite) keep the full tag contract, contain no Chinese, have no interpolation and stay compact"
        )
        let sceneLabels = [AppToneProfile.instantMessaging, .emailAndFormalDoc, .aiPromptAndNotes, .shellTerminal].map(\.rawValue)
        expect(
            sceneLabels.allSatisfy { $0.unicodeScalars.allSatisfy { $0.isASCII } }
                && ActiveScreenContext.empty.toneProfile.rawValue == "AI prompt or notes"
                && Set(sceneLabels).count == 4,
            "Scene labels interpolated into <scene> are distinct English strings"
        )
        expect(
            !PolishEngine.canBypassCloudPolish(locallyFixed: "Uh, yes please.", recalledTerms: [], formattingStyle: .lightPolish, isHighAccuracyLocalASR: true, isPunctuatedCloudASR: false)
                && !PolishEngine.canBypassCloudPolish(locallyFixed: "Um, okay.", recalledTerms: [], formattingStyle: .lightPolish, isHighAccuracyLocalASR: true, isPunctuatedCloudASR: false)
                && PolishEngine.canBypassCloudPolish(locallyFixed: "Yes, please.", recalledTerms: [], formattingStyle: .lightPolish, isHighAccuracyLocalASR: true, isPunctuatedCloudASR: false)
                && PolishEngine.containsEnglishDisfluencyOrSelfCorrection("Thursday, no wait, Friday.")
                && !PolishEngine.containsEnglishDisfluencyOrSelfCorrection("The umbrella is in the hallway."),
            "Short English phrases with fillers or self-corrections still route to the LLM; clean ones (and words like \"umbrella\") are not caught"
        )

        // 58. Fork defaults + persisted settings still win
        let forkDefault = LLMConfig.default
        expect(
            forkDefault.asrProvider == .localSenseVoice
                && forkDefault.localASRModel == .parakeetTDTv2
                && forkDefault.enableVolcSeedASR == false
                && forkDefault.selectedProvider == .custom
                && forkDefault.baseURL == "http://127.0.0.1:11434/v1"
                && forkDefault.modelName == "gemma4:12b-mlx"
                && forkDefault.customBaseURL == "http://127.0.0.1:11434/v1"
                && forkDefault.providerModels["custom"] == "gemma4:12b-mlx"
                && PolishEngine.isKeylessLocalEndpoint(forkDefault.baseURL),
            "Fresh config defaults to local Parakeet ASR + Custom OpenAI-compatible LLM at http://127.0.0.1:11434/v1 (gemma4:12b-mlx)"
        )
        let persistedJSON = #"{"selectedProvider":"deepseek","baseURL":"https://api.deepseek.com/v1","modelName":"deepseek-flash","asrProvider":"volcSeedASR","localASRModel":"senseVoice"}"#
        let persistedCfg = try? JSONDecoder().decode(LLMConfig.self, from: Data(persistedJSON.utf8))
        let legacyNoModelCfg = try? JSONDecoder().decode(LLMConfig.self, from: Data(#"{"asrProvider":"localSenseVoice"}"#.utf8))
        var roundTrip = LLMConfig.default
        roundTrip.localASRModel = .senseVoice
        let roundTripData = (try? JSONEncoder().encode(roundTrip)) ?? Data()
        let roundTripCfg = try? JSONDecoder().decode(LLMConfig.self, from: roundTripData)
        expect(
            persistedCfg?.selectedProvider == .deepseek
                && persistedCfg?.baseURL == "https://api.deepseek.com/v1"
                && persistedCfg?.asrProvider == .volcSeedASR
                && persistedCfg?.localASRModel == .senseVoice
                && legacyNoModelCfg?.localASRModel == .parakeetTDTv2
                && roundTripCfg?.localASRModel == .senseVoice
                && roundTripCfg?.baseURL == "http://127.0.0.1:11434/v1"
                && LocalASRModel.parakeetTDTv2.rawValue == "parakeetTDTv2"
                && LocalASRModel.senseVoice.rawValue == "senseVoice",
            "Persisted provider/ASR/local-model settings override the fork defaults; configs without localASRModel decode to Parakeet; raw values are stable"
        )

        // 59. Local model detection (Parakeet TDT v2 + SenseVoice) in an isolated temp models folder
        let tempModelsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tz_selftest_models_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempModelsRoot) }
        func touch(_ relativePath: String) {
            let url = tempModelsRoot.appendingPathComponent(relativePath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        }
        let pkFolder = LocalASRModel.parakeetTDTv2.extractedFolderName
        let noModels = LocalASRModel.resolve(preferred: .parakeetTDTv2, modelsRoot: tempModelsRoot) == nil
            && !LocalASRModel.anyInstalled(modelsRoot: tempModelsRoot)
        touch("\(pkFolder)/encoder.int8.onnx")
        touch("\(pkFolder)/decoder.int8.onnx")
        touch("\(pkFolder)/joiner.int8.onnx")
        let missingTokens = LocalASRModel.parakeetTDTv2.installedFiles(modelsRoot: tempModelsRoot) == nil
        touch("\(pkFolder)/tokens.txt")
        let pkFiles = LocalASRModel.parakeetTDTv2.installedFiles(modelsRoot: tempModelsRoot)
        let fallbackToParakeet = LocalASRModel.resolve(preferred: .senseVoice, modelsRoot: tempModelsRoot)?.model == .parakeetTDTv2
        touch("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/model.int8.onnx")
        touch("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/tokens.txt")
        let svInt8 = LocalASRModel.senseVoice.installedFiles(modelsRoot: tempModelsRoot)
        touch("\(LocalASRModel.senseVoice.extractedFolderName)/model.onnx")
        touch("\(LocalASRModel.senseVoice.extractedFolderName)/tokens.txt")
        let svFP32 = LocalASRModel.senseVoice.installedFiles(modelsRoot: tempModelsRoot)
        expect(
            noModels
                && missingTokens
                && pkFiles?.model == .parakeetTDTv2
                && pkFiles?.modelPath.hasSuffix("/\(pkFolder)/encoder.int8.onnx") == true
                && pkFiles?.decoderPath?.hasSuffix("/decoder.int8.onnx") == true
                && pkFiles?.joinerPath?.hasSuffix("/joiner.int8.onnx") == true
                && pkFiles?.tokensPath.hasSuffix("/tokens.txt") == true
                && pkFiles?.isFullPrecision == false
                && fallbackToParakeet
                && svInt8?.isFullPrecision == false
                && svFP32?.isFullPrecision == true
                && LocalASRModel.resolve(preferred: .senseVoice, modelsRoot: tempModelsRoot)?.model == .senseVoice
                && LocalASRModel.resolve(preferred: .parakeetTDTv2, modelsRoot: tempModelsRoot)?.model == .parakeetTDTv2
                && LocalASRModel.anyInstalled(modelsRoot: tempModelsRoot),
            "Parakeet TDT v2 detection needs encoder+decoder+joiner+tokens; selection falls back to the other installed model; SenseVoice FP32 beats int8"
        )
        expect(
            LocalASRModel.parakeetTDTv2.downloadURLStrings == [
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
            ]
                && LocalASRModel.senseVoice.downloadURLStrings == [
                    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2"
                ]
                && LocalASRModel.allCases.allSatisfy { model in
                    model.downloadURLStrings.count == 1
                        && model.downloadURLStrings.allSatisfy { $0.hasPrefix("https://github.com/k2-fsa/sherpa-onnx/releases/download/") }
                }
                && LocalASRModel.parakeetTDTv2.requiredFileNames.contains("encoder.int8.onnx")
                && LocalASRModel.senseVoice.extractedFolderName == "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09",
            "Downloader specs: each model downloads only from its official GitHub release URL (no mirror or proxy); folders and required files"
        )
        let hexDigits = Set("0123456789abcdef")
        expect(
            LocalASRModel.parakeetTDTv2.archiveSHA256 == "6fc4426b54aa549a0019b8a75b8dea59164e71790a37ac56a045ad57f915f714"
                && LocalASRModel.senseVoice.archiveSHA256 == "bce28acdb0fb3a5b1e0b93f8b202e904ea1d2eca4f3a4c0cd5006626f10d540e"
                && LocalASRModel.allCases.allSatisfy { $0.archiveSHA256.count == 64 && $0.archiveSHA256.allSatisfy { hexDigits.contains($0) } }
                && LocalASRModel.parakeetTDTv2.archiveSHA256 != LocalASRModel.senseVoice.archiveSHA256,
            "Each model archive is pinned to its SHA-256 from GitHub's release API (64 lowercase hex digits, one per model)"
        )

        // 59a. Archive checksum verifier on small temp files (no network): match, mismatch, missing, unreadable, chunked reads
        do {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("tz_selftest_sha_\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let abc = work.appendingPathComponent("abc.bin")
            try? Data("abc".utf8).write(to: abc)
            // A multi-chunk file: 3 MiB + 17 bytes of a repeating pattern, read 1 MiB at a time.
            let big = work.appendingPathComponent("big.bin")
            var pattern = Data((0..<256).map { UInt8($0) })
            while pattern.count < 3 * 1_048_576 + 17 { pattern.append(pattern) }
            let bigData = pattern.prefix(3 * 1_048_576 + 17)
            try? Data(bigData).write(to: big)
            let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            let bigDigest = SHA256.hash(data: bigData).map { String(format: "%02x", $0) }.joined()
            let folder = work.appendingPathComponent("folder", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

            expect(
                ArchiveChecksum.verify(fileAt: abc, expectedSHA256: abcDigest) == .match
                    && ArchiveChecksum.verify(fileAt: abc, expectedSHA256: "  \(abcDigest.uppercased())\n") == .match
                    && (try? ArchiveChecksum.sha256Hex(of: abc, chunkSize: 1)) == abcDigest,
                "Checksum verifier: a file whose SHA-256 equals the expected digest matches (digest case and surrounding whitespace ignored, even one byte per chunk)"
            )
            expect(
                ArchiveChecksum.verify(fileAt: abc, expectedSHA256: bigDigest) == .mismatch(actual: abcDigest)
                    && ArchiveChecksum.verify(fileAt: abc, expectedSHA256: "") == .mismatch(actual: abcDigest)
                    && ArchiveChecksum.verify(fileAt: abc, expectedSHA256: String(abcDigest.dropLast())) == .mismatch(actual: abcDigest)
                    && ArchiveChecksum.verify(fileAt: abc, expectedSHA256: String(repeating: "0", count: 64)) == .mismatch(actual: abcDigest),
                "Checksum verifier: another digest, an empty one and a truncated one are all a mismatch that reports the file's actual SHA-256"
            )
            var folderIsUnreadable = false
            if case .unreadable = ArchiveChecksum.verify(fileAt: folder, expectedSHA256: abcDigest) { folderIsUnreadable = true }
            expect(
                ArchiveChecksum.verify(fileAt: work.appendingPathComponent("nope.tar.bz2"), expectedSHA256: abcDigest) == .missing
                    && folderIsUnreadable,
                "Checksum verifier: a missing file is reported as missing and a folder as unreadable, never as a match"
            )
            expect(
                ArchiveChecksum.verify(fileAt: big, expectedSHA256: bigDigest, chunkSize: 1_048_576) == .match
                    && ArchiveChecksum.verify(fileAt: big, expectedSHA256: bigDigest, chunkSize: 4_000_000) == .match
                    && ArchiveChecksum.verify(fileAt: big, expectedSHA256: bigDigest) == .match
                    && ArchiveChecksum.chunkSize == 4 * 1024 * 1024,
                "Checksum verifier: a file bigger than one chunk gives the same digest whatever the chunk size (the 887 MB SenseVoice archive is hashed 4 MiB at a time)"
            )
        }

        // 59b. Generalized downloader end-to-end on tiny local fixtures (no network, temp folder only):
        //      first URL is bogus -> mirror fallback; archive is extracted; required files verified; both models work.
        func runDownloaderFixture(model: LocalASRModel, expectedDigest: String? = nil, corruptArchive: Bool = false) -> (success: Bool, installed: Bool, message: String, leftovers: [String]) {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("tz_selftest_dl_\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: work) }
            let staging = work.appendingPathComponent("staging", isDirectory: true)
            let modelDir = staging.appendingPathComponent(model.extractedFolderName, isDirectory: true)
            let installRoot = work.appendingPathComponent("Models", isDirectory: true)
            try? fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
            for name in model.requiredFileNames {
                fm.createFile(atPath: modelDir.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            let archive = work.appendingPathComponent("fixture.tar.bz2")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-cjf", archive.path, "-C", staging.path, model.extractedFolderName]
            guard (try? tar.run()) != nil else { return (false, false, "tar failed to start", []) }
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { return (false, false, "tar failed", []) }
            let intactDigest = (try? ArchiveChecksum.sha256Hex(of: archive)) ?? ""
            if corruptArchive, var bytes = try? Data(contentsOf: archive) {
                bytes[bytes.count / 2] ^= 0xFF   // flip one byte in the middle: the same size, no longer the expected archive
                try? bytes.write(to: archive)
            }

            final class Outcome: @unchecked Sendable { var finished = false; var success = false; var message = "" }
            let outcome = Outcome()
            let downloader = OfflineModelDownloader()
            downloader.modelsRootOverride = installRoot
            downloader.downloadURLStringsOverride = [work.appendingPathComponent("missing.tar.bz2").absoluteString, archive.absoluteString]
            // The fixture is not the real release, so it is checked against its own (intact) digest, or against a wrong one.
            downloader.expectedSHA256Override = expectedDigest ?? intactDigest
            downloader.onCompletion = { ok, message in
                outcome.success = ok
                outcome.message = message
                outcome.finished = true
            }
            downloader.startDownload(model: model)
            let deadline = Date().addingTimeInterval(30)
            while !outcome.finished && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            let leftovers = ((try? fm.contentsOfDirectory(atPath: installRoot.path)) ?? []).sorted()
            return (outcome.success, model.isInstalled(modelsRoot: installRoot), outcome.message, leftovers)
        }
        let parakeetDownload = runDownloaderFixture(model: .parakeetTDTv2)
        let senseVoiceDownload = runDownloaderFixture(model: .senseVoice)
        expect(
            parakeetDownload.success && parakeetDownload.installed && senseVoiceDownload.success && senseVoiceDownload.installed
                && parakeetDownload.leftovers == [LocalASRModel.parakeetTDTv2.extractedFolderName]
                && senseVoiceDownload.leftovers == [LocalASRModel.senseVoice.extractedFolderName],
            "OfflineModelDownloader downloads (falling through a dead first URL), verifies the SHA-256, extracts and checks both the Parakeet and SenseVoice packs, leaving no archive behind"
        )
        // A wrong digest and a damaged archive are refused: a clear error, the archive is discarded, nothing is extracted.
        let wrongDigest = runDownloaderFixture(model: .parakeetTDTv2, expectedDigest: String(repeating: "0", count: 64))
        let damagedArchive = runDownloaderFixture(model: .senseVoice, corruptArchive: true)
        expect(
            !wrongDigest.success && !wrongDigest.installed && wrongDigest.leftovers.isEmpty
                && wrongDigest.message.contains("failed its SHA-256 check")
                && wrongDigest.message.contains("nothing was installed"),
            "OfflineModelDownloader refuses an archive that does not match the expected SHA-256: a clear error, the archive is discarded, nothing is extracted"
        )
        expect(
            !damagedArchive.success && !damagedArchive.installed && damagedArchive.leftovers.isEmpty
                && damagedArchive.message.contains("failed its SHA-256 check"),
            "OfflineModelDownloader refuses a download that was damaged after the fact (one flipped byte) before running tar on it"
        )

        // 60. English-safe segment joining (CJK still concatenates directly)
        expect(
            StreamingASREngine.joinTranscriptFragments("Hello world.", "How are you?") == "Hello world. How are you?"
                && StreamingASREngine.joinTranscriptFragments("Hello,", "world") == "Hello, world"
                && StreamingASREngine.joinTranscriptFragments("Hello ", "world") == "Hello world"
                && StreamingASREngine.joinTranscriptFragments("你好。", "再见") == "你好。再见"
                && StreamingASREngine.joinTranscriptFragments("你好", "OK") == "你好OK"
                && StreamingASREngine.joinTranscriptFragments("OK", "你好") == "OK你好"
                && StreamingASREngine.joinTranscriptFragments("Done", ".") == "Done."
                && StreamingASREngine.joinTranscriptFragments("", "Hi") == "Hi"
                && StreamingASREngine.joinTranscriptFragments("Hi", "") == "Hi",
            "VAD segment joiner inserts one space between English fragments and keeps CJK text contiguous"
        )

        // 61. There is no updater: nothing can fetch or install a release, and a manual check only says where new versions are
        expect(
            AppUpdater.isUpdaterEnabled == false
                && AppUpdater.currentAppVersion == AppBrand.version
                && AppUpdater.manualCheckMessage.contains("Automatic updates are off")
                && AppUpdater.manualCheckMessage.contains("GitHub page")
                && AppUpdater.manualCheckMessage.contains(AppBrand.releasesDisplayString)
                && AppUpdater.manualCheckMessage.contains(AppBrand.name)
                && !AppUpdater.manualCheckMessage.contains(AppBrand.upstreamName)
                && AppBrand.releasesURL.absoluteString.hasPrefix(AppBrand.repositoryURL.absoluteString)
                && AppBrand.releasesURL.host == "github.com",
            "No updater: automatic updates are off, and a manual check says so and points at the project's GitHub releases page (not the upstream project's)"
        )

        // 61b. Polish diagnostics: route reporting (no network except a refused loopback connection)
        final class PolishProbe: @unchecked Sendable {
            var verbatim: PolishEngine.PolishOutcome?
            var bypass: PolishEngine.PolishOutcome?
            var failed: PolishEngine.PolishOutcome?
            var fillerDictation: PolishEngine.PolishOutcome?
            var fillerVerbatim: PolishEngine.PolishOutcome?
            var fillerRewrite: PolishEngine.PolishOutcome?
        }
        let polishProbe = PolishProbe()
        let polishDone = DispatchSemaphore(value: 0)
        Task {
            let engine = PolishEngine()
            var verbatimCfg = LLMConfig.default
            verbatimCfg.formattingStyle = .verbatimLocal
            polishProbe.verbatim = await engine.polishWithDiagnostics(
                rawTranscript: "um keep this exactly", mode: .dictate, screenContext: .empty, recalledTerms: [],
                recentOutputs: [], config: verbatimCfg, apiKey: ""
            )
            polishProbe.bypass = await engine.polishWithDiagnostics(
                rawTranscript: "Yes.", mode: .dictate, screenContext: .empty, recalledTerms: [],
                recentOutputs: [], config: .default, apiKey: ""
            )
            var deadCfg = LLMConfig.default
            deadCfg.baseURL = "http://127.0.0.1:9/v1"   // discard port: connection refused immediately
            polishProbe.failed = await engine.polishWithDiagnostics(
                rawTranscript: "Um, so this sentence should come back untouched because the model is down.",
                mode: .dictate, screenContext: .empty, recalledTerms: [], recentOutputs: [], config: deadCfg, apiKey: ""
            )
            // Filler-only speech never reaches any other route: with the dead endpoint above an LLM attempt would end in
            // `.llmFailedFallback` and "Uh" would be typed; "Ah." would take the fast bypass.
            polishProbe.fillerDictation = await engine.polishWithDiagnostics(
                rawTranscript: "Uh, um...", mode: .dictate, screenContext: .empty, recalledTerms: [], recentOutputs: [], config: deadCfg, apiKey: ""
            )
            polishProbe.fillerVerbatim = await engine.polishWithDiagnostics(
                rawTranscript: "Ah.", mode: .dictate, screenContext: .empty, recalledTerms: [], recentOutputs: [], config: verbatimCfg, apiKey: ""
            )
            polishProbe.fillerRewrite = await engine.polishWithDiagnostics(
                rawTranscript: "um", mode: .rewriteSelection, screenContext: .empty, recalledTerms: [], recentOutputs: [], config: deadCfg, apiKey: ""
            )
            polishDone.signal()
        }
        polishDone.wait()
        expect(
            polishProbe.verbatim?.route == .verbatimLocal
                && polishProbe.bypass?.route == .fastBypass
                && polishProbe.bypass?.usedFastPath == true
                && polishProbe.failed?.route == .llmFailedFallback
                && polishProbe.failed?.usedFastPath == true
                && polishProbe.failed?.llmError != nil
                && polishProbe.failed?.text.hasPrefix("Um, so this sentence") == true,
            "polishWithDiagnostics reports verbatim / fast-bypass / LLM-failed routes, and an unreachable local LLM falls back to the raw transcript with the error"
        )
        expect(
            [polishProbe.fillerDictation, polishProbe.fillerVerbatim, polishProbe.fillerRewrite].allSatisfy {
                $0?.route == .noSpeech && $0?.text == "" && $0?.llmError == nil && $0?.usedFastPath == true
            },
            "A filler-only transcript ('Uh, um...', 'Ah.', a rewrite instruction of 'um') returns the noSpeech route with no text and never reaches the LLM, the fast bypass or verbatim output"
        )

        // 62. Headless CLI argument parsing (`--dictate-file`)
        let cliOK = DictateFileCLI.parse(arguments: ["--dictate-file", "/tmp/a.wav", "--style", "light", "--scene", "terminal"])
        let cliDefaults = DictateFileCLI.parse(arguments: ["--dictate-file", "/tmp/a.wav"])
        var cliParsedOK = false
        if case .options(let o) = cliOK { cliParsedOK = o.wavPath == "/tmp/a.wav" && o.style == .lightPolish && o.scene == .terminal }
        var cliDefaultsOK = false
        if case .options(let o) = cliDefaults { cliDefaultsOK = o.style == nil && o.scene == .notes }
        var cliRejectsBad = true
        for bad in [["--dictate-file"], ["--dictate-file", "a.wav", "--style", "loud"], ["--dictate-file", "a.wav", "--scene", "slackk"], ["--style", "light"]] {
            if case .options = DictateFileCLI.parse(arguments: bad) { cliRejectsBad = false }
        }
        expect(
            cliParsedOK && cliDefaultsOK && cliRejectsBad,
            "--dictate-file parses <wav> plus optional --style structured|light and --scene chat|email|notes|terminal, and rejects bad input"
        )

        // 63. Live: Parakeet TDT v2 (only when the model is installed on this Mac) transcribes the bundled English test wav
        if let parakeetFiles = LocalASRModel.parakeetTDTv2.installedFiles() {
            let testWav = URL(fileURLWithPath: parakeetFiles.modelPath)
                .deletingLastPathComponent()
                .appendingPathComponent("test_wavs/0.wav")
            if let audio = try? DictateFileCLI.readWAV(path: testWav.path),
               let handle = StreamingASREngine.createLocalRecognizerHandle(files: parakeetFiles, speechLocale: "auto") {
                let text = StreamingASREngine.runSenseVoice(
                    handle: handle,
                    samples: audio.samples,
                    sampleRate: Int32(audio.sampleRate),
                    applyWhisperAGC: false
                )
                tz_sensevoice_destroy(handle)
                let letters = text.unicodeScalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }.count
                expect(
                    !text.isEmpty && letters >= 10 && !containsCJK(text),
                    "Parakeet TDT v2 loads through tz_parakeet_create and transcribes test_wavs/0.wav to English text (\(text.prefix(60)))"
                )
            } else {
                print("  - SKIP: Parakeet is installed but test_wavs/0.wav could not be loaded")
            }
        } else {
            print("  - SKIP: Parakeet TDT v2 model not installed; live Parakeet transcription test skipped")
        }

        // 64. Live-preview decode throttle: Parakeet re-decodes the active segment at most every ~0.35 s of new audio, SenseVoice keeps ~55 ms
        let pkStep48k = StreamingASREngine.livePreviewMinStepSamples(sampleRate: 48_000, model: .parakeetTDTv2)
        let pkStep44k = StreamingASREngine.livePreviewMinStepSamples(sampleRate: 44_100, model: .parakeetTDTv2)
        let pkStep16k = StreamingASREngine.livePreviewMinStepSamples(sampleRate: 16_000, model: .parakeetTDTv2)
        let svStep48k = StreamingASREngine.livePreviewMinStepSamples(sampleRate: 48_000, model: .senseVoice)
        let svStep16k = StreamingASREngine.livePreviewMinStepSamples(sampleRate: 16_000, model: .senseVoice)
        let noModelStep48k = StreamingASREngine.livePreviewMinStepSamples(sampleRate: 48_000, model: nil)
        expect(
            pkStep48k == 16_800 && pkStep44k == 15_435 && pkStep16k == 5_600
                && svStep48k == 48_000 / 18 && svStep16k == 16_000 / 18
                && noModelStep48k == 48_000 / 18
                && pkStep48k >= svStep48k * 6,
            "Live preview waits ~0.35 s of new audio between Parakeet decodes (SenseVoice keeps its ~55 ms step), so a key release does not queue behind back-to-back preview decodes"
        )

        // 65. Lexicon extraction ("distillation") prompt is English and keeps the line contract its parser expects
        let distillPrompt = PolishEngine.distillSystemPrompt
        let distilled = PolishEngine.parseDistilledTerms("""
        Supabase|super base,soup a base|project
        Priya Raman||person
        NVDA|in video|finance
        Q3 offsite notes
        x|y|person
        """)
        expect(
            !containsCJK(distillPrompt)
                && distillPrompt.contains("|")
                && ["person", "project", "finance", "memo"].allSatisfy { distillPrompt.contains($0) }
                && distillPrompt.contains("40")
                && distilled.count == 4
                && distilled[0].term == "Supabase" && distilled[0].aliases == ["super base", "soup a base"] && distilled[0].category == .project
                && distilled[1].term == "Priya Raman" && distilled[1].aliases.isEmpty && distilled[1].category == .person
                && distilled[2].term == "NVDA" && distilled[2].aliases == ["in video"] && distilled[2].category == .finance
                && distilled[3].term == "Q3 offsite notes" && distilled[3].category == .memo,
            "Lexicon extraction prompt is English and asks for term|misheard variants|category lines (max 40); its parser reads that format (empty variants, missing category -> memo, 1-char terms skipped)"
        )

        // 66. User-visible enum labels are English, while persisted raw values (history.json / lexicon / config) stay untouched
        var displayStrings: [String] = []
        displayStrings += TriggerKeyOption.allCases.flatMap { [$0.displayName, $0.shortLabel, $0.compactSidebarLabel] }
        displayStrings += TriggerBehavior.allCases.map(\.displayName)
        displayStrings += FormattingStyle.allCases.map(\.displayName)
        displayStrings += ASRProviderOption.allCases.flatMap { [$0.title, $0.shortName] }
        displayStrings += LLMProviderOption.allCases.flatMap { [$0.title, $0.shortName, $0.subtitle] }
        displayStrings += LocalASRModel.allCases.flatMap { [$0.displayName, $0.shortName, $0.detail] }
        displayStrings += SidebarTab.allCases.map(\.rawValue)
        displayStrings += [DictationMode.dictate, DictationMode.rewriteSelection].map(\.displayName)
        displayStrings += LexiconCategory.allCases.map(\.displayName)
        let legacyEntryJSON = #"{"term":"Supabase","aliases":[],"category":"人名/称呼","weight":3}"#
        let legacyEntry = try? JSONDecoder().decode(LexiconEntry.self, from: Data(legacyEntryJSON.utf8))
        let legacyRecordJSON = #"{"id":"7B3C2D1E-0000-4000-8000-000000000001","timestamp":0,"rawTranscript":"a","polishedText":"b","durationSeconds":1,"polishLatencyMs":5,"targetAppName":"Notes","mode":"选中改写","matchedTerms":[]}"#
        let legacyRecord = try? JSONDecoder().decode(DictationRecord.self, from: Data(legacyRecordJSON.utf8))
        expect(
            displayStrings.count > 60
                && displayStrings.allSatisfy { !$0.isEmpty && !containsCJK($0) }
                && TriggerKeyOption.rightOption.displayName == "Right Option (⌥)"
                && TriggerKeyOption.fnKey.displayName == "Fn (Globe)"
                && DictationMode.dictate.rawValue == "口述成稿" && DictationMode.rewriteSelection.rawValue == "选中改写"
                && LexiconCategory.allCases.map(\.rawValue) == ["人名/称呼", "项目/技术", "标的/商业", "纪要/备忘", "浏览高频", "纠错自学习"]
                && legacyEntry?.category == .person
                && legacyRecord?.mode == .rewriteSelection,
            "Enum display names, titles and sidebar labels contain no Chinese; DictationMode / LexiconCategory raw values stay stable so existing history and lexicon files still decode"
        )

        // 67. Dictation failures: the floating pill has room for about 60 characters (two short lines). Every fixed message and every
        // shortened engine error must fit, while the main-window banner keeps the full wording behind a leading warning emoji.
        do {
            let limit = DictationFailure.pillCharacterLimit
            let fixed = DictationFailure.permissionFailures
            expect(
                limit == 60
                    && fixed.count == 3
                    && fixed.allSatisfy { !$0.pillText.isEmpty && $0.pillText.count <= limit && $0.detail.count > $0.pillText.count }
                    && Set(fixed.map(\.pillText)).count == 3
                    && DictationFailure.accessibilityOff.pillText.contains("Accessibility")
                    && DictationFailure.microphoneOff.pillText.contains("microphone")
                    && DictationFailure.speechRecognitionOff.pillText.contains("Speech Recognition")
                    && fixed.allSatisfy { $0.pillText.contains("System Settings") && $0.detail.contains("System Settings") },
                "Accessibility, microphone and Speech Recognition failure texts fit the pill's 60-character limit, name the right permission, and have a longer explanation for the main window"
            )
            expect(
                fixed.allSatisfy { $0.bannerText == "⚠️ " + $0.detail }
                    && DictationFailure.engineError("The request timed out.").bannerText == "⚠️ The request timed out.",
                "The main-window banner is the full explanation behind a leading ⚠️, the convention the UI keys its warning style off"
            )

            let cloudRaw = "Cloud speech recognition failed: HTTP 401: Incorrect API key provided: gsk_abc123. You can find your API key at https://console.groq.com/keys."
            let cloud = DictationFailure.engineError(cloudRaw)
            let system = DictationFailure.engineError("The operation couldn’t be completed.\n   (com.apple.coreaudio.avfaudio error 2003329396.)")
            let mic = DictationFailure.engineError("Microphone input is unavailable. Check microphone permissions.")
            let cjk = DictationFailure.engineError(String(repeating: "语音识别服务暂时不可用，", count: 12))
            let oneWord = DictationFailure.engineError(String(repeating: "x", count: 200))
            let short = DictationFailure.engineError("The request timed out.")
            let exact = DictationFailure.engineError(String(repeating: "a", count: 60))
            let over = DictationFailure.engineError(String(repeating: "a", count: 61))
            let blank = DictationFailure.engineError("  \n ")
            let engineErrors = [cloud, system, mic, cjk, oneWord, short, exact, over, blank]
            expect(
                engineErrors.allSatisfy { !$0.pillText.isEmpty && $0.pillText.count <= limit && !$0.pillText.contains("\n") },
                "Engine errors of any length (cloud HTTP error, multi-line system error, Chinese text, one 200-character word, empty) reach the pill in at most 60 characters on one line"
            )
            expect(
                cloud.pillText == "Cloud speech failed: HTTP 401: Incorrect API key provided…"
                    && cloud.detail == cloudRaw
                    && system.pillText == "The operation couldn’t be completed…"
                    && system.detail == "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error 2003329396.)"
                    && mic.pillText == "Microphone input is unavailable. Check microphone…",
                "A long cloud error keeps its reason in the pill (prefix shortened, cut at a word boundary, ellipsis) while the banner detail keeps the full text on one line"
            )
            expect(
                short.pillText == "The request timed out." && short.detail == short.pillText
                    && exact.pillText == exact.detail && exact.pillText.count == 60
                    && over.pillText.count == 60 && over.pillText.hasSuffix("…") && over.detail.count == 61
                    && blank.pillText == "Dictation failed. Please try again." && !blank.detail.isEmpty,
                "Short engine errors pass through unchanged, 60 characters is the cut-off, and a blank error gets a generic reason instead of an empty pill"
            )
            expect(
                DictationFailure.displaySeconds >= 4.5 && DictationFailure.displaySeconds <= 6,
                "The error pill stays up for about 5 seconds so two lines can be read"
            )
            expect(
                DictationFailure.noSpeechPillText == "No speech detected"
                    && DictationFailure.noSpeechPillText.count <= limit
                    && DictationFailure.noSpeechDisplaySeconds > 1 && DictationFailure.noSpeechDisplaySeconds < DictationFailure.displaySeconds,
                "The 'No speech detected' pill fits the pill and is shown more briefly than a real error"
            )
        }

        // 68. Filler-only transcripts ("Uh", "um...", "嗯") are noise: nothing is inserted and no model is asked. Any real word keeps the text.
        do {
            let fillerOnly = [
                "Uh", "uh.", "Um,", "UM", "umm", "uhh...", "Er", "erm", "Hmm", "hmmm.", "hm", "Mm", "mm-hmm", "mhm", "Ah.", "ahh", "Oh!", "ooh",
                "like", "Like...", "you know", "You know,", "uh, um, you know, like", "Uh... um... hmm.", "  ...  ", "—", "。", "",
                "嗯", "嗯嗯。", "啊…", "呃，那个", "就是，那个，嗯", "然后呢？", "怎么说", "额。", "Uh 嗯", "嗯, um"
            ]
            let realContent = [
                "Uh, okay", "Um, hello", "like this", "Like, totally", "you know what I mean", "Oh no", "Ah, I see", "I like it", "Hello",
                "Yes.", "OK", "uh-huh", "mmm-hmm okay", "123", "umbrella", "hammer", "ohio", "error", "ahead", "Erin", "alike", "likely",
                "嗯，好的", "那个人", "就是这样", "啊，对", "怎么说呢好", "Hmm, interesting", "uh 3 pm"
            ]
            expect(
                fillerOnly.allSatisfy { PolishEngine.isFillerOnlyTranscript($0) },
                "Filler-only transcripts are detected: uh/um/er/hmm/mm/ah/oh/like/you know in any case, with stretched spellings and punctuation, the Chinese fillers 嗯 啊 呃 额 那个 就是 然后呢 怎么说, and punctuation-only text"
            )
            let missed = fillerOnly.filter { !PolishEngine.isFillerOnlyTranscript($0) }
            let falsePositives = realContent.filter { PolishEngine.isFillerOnlyTranscript($0) }
            expect(
                falsePositives.isEmpty,
                "Real speech is never treated as filler: a single real word ('Uh, okay', 'like this', 'I like it', 'uh-huh', '那个人', 'umbrella', 'hammer', 'error') keeps the transcript (false positives: \(falsePositives), missed: \(missed))"
            )
        }

        // 69. Cleanup output budget: proportional to the input so a model with nothing to say cannot run to a huge `max_tokens`
        do {
            let sentence = "Can we move the review to Thursday at three pm please?"   // 54 characters
            func budget(_ text: String, local: Bool = true) -> Int {
                PolishEngine.cleanupMaxTokens(mode: .dictate, spokenText: text, selectedText: "", isLocalEndpoint: local)
            }
            expect(
                PolishEngine.approximateTokenCount("") == 0
                    && PolishEngine.approximateTokenCount("Uh") == 1
                    && PolishEngine.approximateTokenCount(sentence) == 16
                    && PolishEngine.approximateTokenCount("你好世界") == 4
                    && PolishEngine.approximateTokenCount("Hello 你好") == 4
                    && PolishEngine.approximateTokenCount("こんにちは") == 5
                    && PolishEngine.approximateTokenCount("안녕하세요") == 5,
                "Token estimate: about 3.5 Latin characters per token (rounded up) and one token per CJK character"
            )
            expect(
                budget("Uh") == 48 && budget("") == 48 && budget("你好世界") == 48
                    && budget(sentence) == 64
                    && budget(String(repeating: "你", count: 30)) == 92
                    && budget(String(repeating: "x", count: 2_000)) == 1_176,
                "Dictation max_tokens = twice the estimated input tokens + 32, at least 48 (48 for 'Uh', 64 for a 10-word sentence, 92 for 30 Chinese characters)"
            )
            expect(
                budget(String(repeating: "x", count: 2_100)) == 1_200
                    && budget(String(repeating: "x", count: 6_000)) == 1_971
                    && budget(String(repeating: "你", count: 1_000)) == 1_256
                    && budget(String(repeating: "x", count: 6_000)) > PolishEngine.approximateTokenCount(String(repeating: "x", count: 6_000)),
                "Very long dictations keep a budget above their own length (input + 256 once past ~1200 tokens), so the end of a long dictation is never cut off"
            )
            let selected = "Hello there my friend how are you doing today"   // 45 characters
            let rewrite = PolishEngine.cleanupMaxTokens(mode: .rewriteSelection, spokenText: "make it formal", selectedText: selected, isLocalEndpoint: true)
            let rewriteLong = PolishEngine.cleanupMaxTokens(mode: .rewriteSelection, spokenText: "make it formal", selectedText: String(repeating: "x", count: 4_000), isLocalEndpoint: true)
            expect(
                rewrite == 66
                    && rewrite > PolishEngine.cleanupMaxTokens(mode: .dictate, spokenText: "make it formal", selectedText: selected, isLocalEndpoint: true)
                    && rewriteLong >= PolishEngine.approximateTokenCount(String(repeating: "x", count: 4_000)) + 256,
                "Rewrite selection sizes its budget from the selected text plus the spoken instruction, because the result can grow"
            )
            expect(
                budget("Uh", local: false) == 180 && budget(sentence, local: false) == 180
                    && budget(String(repeating: "x", count: 2_000), local: false) == 1_176,
                "Cloud models keep a 180-token floor (hidden reasoning tokens count against the cap); the proportional budget applies above it"
            )
        }

        // 70. "Sound effects" setting: on by default, on for configs saved before it existed, and an explicit off survives a save/load
        do {
            let legacy = #"{"baseURL":"http://127.0.0.1:11434/v1","modelName":"gemma4:12b-mlx","enableAutoMuteDuringDictation":false}"#
            let decodedLegacy = try? JSONDecoder().decode(LLMConfig.self, from: Data(legacy.utf8))
            var muted = LLMConfig.default
            muted.enableSoundEffects = false
            let mutedData = try? JSONEncoder().encode(muted)
            let decodedMuted = mutedData.flatMap { try? JSONDecoder().decode(LLMConfig.self, from: $0) }
            let mutedJSON = mutedData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            expect(
                LLMConfig.default.enableSoundEffects == true
                    && LLMConfig().enableSoundEffects == true
                    && decodedLegacy?.enableSoundEffects == true
                    && decodedLegacy?.enableAutoMuteDuringDictation == false
                    && decodedMuted?.enableSoundEffects == false
                    && mutedJSON.contains("\"enableSoundEffects\":false"),
                "Sound effects default to on (also for configs saved without the setting) and an explicit off round-trips through the saved config"
            )
        }

        // 71. Session cues: the built-in macOS sounds "Tink" (start) and "Pop" (stop), at audible volumes, with auto-mute timed after the start cue
        do {
            func audibleSeconds(ofSystemSound name: String, floorDBFS: Double = -50) -> Double? {
                let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
                guard let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil,
                      let channels = buffer.floatChannelData else { return nil }
                let floor = Float(pow(10.0, floorDBFS / 20.0))
                var lastLoudFrame = -1
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<Int(buffer.format.channelCount) where abs(channels[channel][frame]) > floor {
                        lastLoudFrame = frame
                    }
                }
                return Double(lastLoudFrame + 1) / buffer.format.sampleRate
            }
            expect(
                SessionCues.start == SessionCues.Cue(soundName: "Tink", volume: 0.5)
                    && SessionCues.stop == SessionCues.Cue(soundName: "Pop", volume: 0.5)
                    && SessionCues.cancel == SessionCues.Cue(soundName: "Funk", volume: 0.22)
                    && SessionCues.allSoundNames == ["Tink", "Pop", "Funk"]
                    && [SessionCues.start, SessionCues.stop].allSatisfy { $0.volume >= 0.3 && $0.volume <= 1 }
                    && SessionCues.allSoundNames.allSatisfy { FileManager.default.fileExists(atPath: "/System/Library/Sounds/\($0).aiff") },
                "Sound effects play the built-in macOS sounds: Tink when recording starts and Pop when it stops, both at volume 0.5 (relative to the system volume)"
            )
            expect(
                SessionCues.startMuteDelay == 0.2
                    && SessionCues.muteDelayAfterStartCue(soundEffectsEnabled: true) == 0.2
                    && SessionCues.muteDelayAfterStartCue(soundEffectsEnabled: false) == 0,
                "Auto-mute waits 0.2 s after the start cue begins, and does not wait at all when sound effects are off"
            )
            if let tinkAudible = audibleSeconds(ofSystemSound: SessionCues.start.soundName) {
                expect(
                    tinkAudible > 0 && tinkAudible < SessionCues.startMuteDelay,
                    "The start cue (Tink) is audible for \(Int(tinkAudible * 1000)) ms, which is shorter than the 200 ms auto-mute delay, so muting never cuts it off"
                )
            } else {
                print("  - SKIP: /System/Library/Sounds/Tink.aiff could not be read; start-cue length check skipped")
            }
        }

        // 72. Brand: one source of truth for the name, bundle id, version and data folder
        do {
            let support = AppBrand.applicationSupportDirectory().path
            expect(
                AppBrand.name == "Nevertype"
                    && AppBrand.bundleID == "io.github.zczhuang.nevertype"
                    && AppBrand.version == "0.1.0"
                    && support.hasSuffix("/Library/Application Support/Nevertype")
                    && LocalASRModel.defaultModelsRoot().path == support + "/Models"
                    && TypelessPaths.importedIDsURL.path == support + "/typeless-imported-ids.json"
                    && AppBrand.upstreamRepositoryURL.absoluteString == "https://github.com/nasadunadu/TypeZero"
                    && AppBrand.upstreamAttribution == "Based on \(AppBrand.upstreamName) (MIT)",
                "AppBrand names the app Nevertype (io.github.zczhuang.nevertype, v0.1.0), keeps all data under Application Support/Nevertype, and attributes the upstream project"
            )
            let visibleTexts: [String] = DictationFailure.permissionFailures.flatMap { [$0.pillText, $0.detail, $0.bannerText] }
                + [AppUpdater.manualCheckMessage]
            expect(
                visibleTexts.allSatisfy { !$0.contains(AppBrand.upstreamName) }
                    && DictationFailure.permissionFailures.allSatisfy { $0.pillText.contains(AppBrand.name) || $0.pillText.contains("System Settings") }
                    && DictationFailure.accessibilityOff.detail.contains(AppBrand.name),
                "User-visible permission and update texts say Nevertype and never the upstream name"
            )
            expect(
                TZStats.displayAppName("\(AppBrand.name) Sandbox") == "\(AppBrand.name) practice pad"
                    && TZStats.displayAppName("") == "Unknown app"
                    && TZStats.displayAppName("Mail") == "Mail",
                "The in-app practice pad is saved as 'Nevertype Sandbox' and listed as 'Nevertype practice pad'"
            )
        }

        // 73. Saved configs: keys written by earlier builds are ignored, and an engine this build no longer has falls back to the default
        do {
            let withRemovedKeys = #"{"baseURL":"http://127.0.0.1:11434/v1","modelName":"gemma4:12b-mlx","enableSoundEffects":false,"removedSetting":"x","anotherRemovedSetting":{"nested":[1,2]}}"#
            let decodedRemoved = try? JSONDecoder().decode(LLMConfig.self, from: Data(withRemovedKeys.utf8))
            let unknownASR = try? JSONDecoder().decode(LLMConfig.self, from: Data(#"{"asrProvider":"someRemovedEngine","enableVolcSeedASR":true}"#.utf8))
            let unknownLLM = try? JSONDecoder().decode(
                LLMConfig.self,
                from: Data(#"{"selectedProvider":"someRemovedProvider","baseURL":"http://127.0.0.1:11434/v1","modelName":"gemma4:12b-mlx"}"#.utf8)
            )
            let unknownLocalModel = try? JSONDecoder().decode(LLMConfig.self, from: Data(#"{"localASRModel":"someRemovedModel"}"#.utf8))
            let reencoded = decodedRemoved.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            expect(
                decodedRemoved?.enableSoundEffects == false
                    && decodedRemoved?.baseURL == "http://127.0.0.1:11434/v1"
                    && !reencoded.contains("removedSetting"),
                "A saved config with keys this build does not know (settings from earlier builds) still decodes, keeps its other settings, and does not write those keys back"
            )
            expect(
                unknownASR?.asrProvider == LLMConfig.default.asrProvider
                    && unknownASR?.asrProvider == .localSenseVoice
                    && unknownLLM?.selectedProvider == .custom
                    && unknownLLM?.baseURL == "http://127.0.0.1:11434/v1"
                    && unknownLocalModel?.localASRModel == LocalASRModel.default,
                "An unknown stored speech engine, cleanup provider or local model decodes to the default instead of failing the whole config"
            )
        }

        // 74. Apple Speech fallback (used when no speech model is installed): macOS on-device recognition only, never the server
        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            StreamingASREngine.configureAppleFallbackRequest(request, contextualStrings: ["Nevertype", "Ollama"])
            let failure = DictationFailure.onDeviceSpeechUnavailable
            expect(
                request.requiresOnDeviceRecognition && request.shouldReportPartialResults && request.contextualStrings == ["Nevertype", "Ollama"],
                "Apple Speech fallback: its recognition request is set to on-device only (requiresOnDeviceRecognition), never server recognition"
            )
            expect(
                StreamingASREngine.appleFallbackFailure(isAvailable: true, supportsOnDeviceRecognition: false) == failure
                    && StreamingASREngine.appleFallbackFailure(isAvailable: false, supportsOnDeviceRecognition: true) == failure
                    && StreamingASREngine.appleFallbackFailure(isAvailable: false, supportsOnDeviceRecognition: false) == failure
                    && StreamingASREngine.appleFallbackFailure(isAvailable: true, supportsOnDeviceRecognition: true) == nil,
                "Apple Speech fallback: refused when macOS cannot recognize on this Mac (or is not ready); allowed only when it can"
            )
            expect(
                failure.pillText.count <= DictationFailure.pillCharacterLimit
                    && failure.pillText.contains("speech model") && failure.pillText.contains("Settings")
                    && failure.detail.contains("Download a speech model in Settings") && failure.detail.contains("never sends your audio to Apple")
                    && failure.bannerText == "⚠️ " + failure.detail
                    && DictationFailure.engineError(failure.detail) == failure
                    && DictationFailure.engineError("Microphone input is unavailable.") != failure,
                "Apple Speech fallback failure: a short pill (download a speech model in Settings) plus a full explanation, carried through the engine error path"
            )
        }

        // 72. Focus check: the three-way classification of the focused element. The Accessibility read is separate from these rules,
        // so everything here runs on plain values, without any app in focus.
        func focus(
            _ role: String?, subrole: String? = nil, app: String = "com.example.editor",
            range: Bool = false, value: Bool = false, noFocus: Bool = false, host: String? = nil,
            web: Bool = false, electron: Bool = false
        ) -> FocusedTextInputStatus {
            FocusedTextInputClassifier.classify(FocusedElementFacts(
                bundleID: app, noFocusedElement: noFocus, role: role, subrole: subrole,
                selectedTextRangeSettable: range, valueSettable: value, webAreaHost: host,
                isWebContent: web, isElectronApp: electron
            ))
        }
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        expect(
            Set(textRoles) == FocusedTextInputClassifier.textInputRoles
                && textRoles.allSatisfy { focus($0) == .editable }
                && focus("AXTextField", subrole: "AXSearchField") == .editable
                && focus("AXTextField", subrole: "AXSecureTextField") == .editable
                && focus("AXGroup", subrole: "AXSearchField") == .editable,
            "Focus check: text field, text area, combo box and search field (also by subrole) are editable"
        )
        let nonTextRoles = [
            "AXDesktop", "AXButton", "AXImage", "AXToolbar", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXBrowser",
            "AXStaticText", "AXLink", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXTabGroup", "AXMenuItem"
        ]
        expect(
            nonTextRoles.count == 19
                && Set(nonTextRoles) == FocusedTextInputClassifier.nonTextRoles
                && nonTextRoles.allSatisfy { focus($0) == .notEditable },
            "Focus check: the desktop and every clear non-text control (button, list, table, link, slider, menu item ...) are not editable"
        )
        expect(
            ["AXWindow", "AXApplication", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXSomethingNew", ""].allSatisfy { focus($0) == .unknown }
                && focus(nil) == .unknown
                && focus(nil, noFocus: true) == .unknown
                && focus(nil, app: "com.tinyspeck.slackmacgap") == .unknown
                && focus("AXGroup", app: "com.hnc.Discord") == .unknown
                && focus("AXWindow", app: "com.microsoft.VSCode") == .unknown,
            "Focus check: a window, application, group, scroll area, an unfamiliar role, no focused element or a failed read stay unknown (Electron and Qt apps keep typing)"
        )
        expect(
            focus("AXGroup", range: true) == .editable
                && focus("AXScrollArea", range: true) == .editable
                && focus("AXGroup", value: true) == .editable
                && focus("AXWindow", range: true, value: true) == .editable
                && focus("AXGroup") == .unknown,
            "Focus check: any other element whose selected-text range or value is settable counts as editable"
        )
        expect(
            focus("AXSlider", value: true) == .notEditable
                && focus("AXCheckBox", value: true) == .notEditable
                && focus("AXPopUpButton", value: true) == .notEditable
                && focus("AXLink", range: true) == .notEditable
                && focus("AXStaticText", range: true, value: true) == .notEditable,
            "Focus check: a clear non-text control stays not editable even when its value is settable (sliders, check boxes and pop-up buttons have one)"
        )
        // Spreadsheets: a selected cell reports AXCell (or its row / table) and typing starts a cell edit, so dictation keeps typing there
        let numbers = "com.apple.iWork.Numbers", excel = "com.microsoft.Excel", libreOffice = "org.libreoffice.script"
        expect(
            focus("AXCell", app: numbers) == .unknown
                && focus("AXCell", app: excel) == .unknown
                && focus("AXTable", app: libreOffice) == .unknown
                && focus("AXRow", app: numbers) == .unknown
                && focus("AXTable", app: excel) == .unknown
                && focus("AXRow", app: libreOffice) == .unknown
                && focus("AXCell", app: "com.APPLE.iwork.numbers") == .unknown
                && [numbers, excel, libreOffice].allSatisfy { FocusedTextInputClassifier.isSpreadsheet(bundleID: $0) },
            "Focus check: a selected cell (or its row or table) in Numbers, Excel and LibreOffice stays unknown, so dictation types into it as before"
        )
        expect(
            focus("AXCell", app: "com.apple.mail") == .notEditable
                && focus("AXTable", app: "com.apple.Music") == .notEditable
                && focus("AXRow", app: "com.apple.mail") == .notEditable
                && focus("AXCell", app: "com.example.editor") == .notEditable
                && focus("AXCell", app: "com.apple.finder") == .notEditable
                && !["com.apple.mail", "com.apple.Music", "com.apple.finder", "com.apple.iWork.Pages", "com.apple.iWork.Keynote"]
                    .contains { FocusedTextInputClassifier.isSpreadsheet(bundleID: $0) },
            "Focus check: a cell in Mail's message list, a table in Music's library and cells anywhere else that is not a spreadsheet stay not editable"
        )
        expect(
            focus("AXButton", app: numbers) == .notEditable
                && focus("AXList", app: excel) == .notEditable
                && focus("AXOutline", app: numbers) == .notEditable
                && focus("AXStaticText", app: libreOffice) == .notEditable
                && focus("AXToolbar", app: excel) == .notEditable
                && focus("AXTextField", app: excel) == .editable
                && focus("AXTextArea", app: numbers) == .editable
                && FocusedTextInputClassifier.spreadsheetCellRoles == ["AXCell", "AXRow", "AXTable"],
            "Focus check: in a spreadsheet only the cell, row and table roles are exempt; buttons, lists and the like stay not editable, and its text fields stay editable"
        )
        let finder = "com.apple.finder"
        expect(
            focus("AXTextField", app: finder) == .editable
                && focus("AXTextField", subrole: "AXSearchField", app: finder) == .editable
                && focus("AXList", app: finder) == .notEditable
                && focus("AXOutline", app: finder) == .notEditable
                && focus("AXDesktop", app: finder) == .notEditable
                && focus("AXScrollArea", app: finder) == .notEditable
                && focus("AXWindow", app: finder) == .notEditable
                && focus(nil, app: finder, noFocus: true) == .notEditable
                && focus("AXScrollArea", app: finder, range: true) == .editable,
            "Focus check: Finder's rename and search fields are editable; its file list, the desktop and everything else in Finder are not"
        )
        expect(
            focus(nil, app: finder) == .unknown && focus("AXList", app: "com.apple.dt.Xcode") == .notEditable,
            "Focus check: a failed Accessibility read in Finder stays unknown (a timeout must not hide a rename field)"
        )
        expect(
            ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac"]
                .allSatisfy { focus("AXWebArea", app: $0, host: "example.com") == .notEditable && FocusedTextInputClassifier.isWebBrowser(bundleID: $0) },
            "Focus check: a web page with nothing focused (the web area itself in focus) is not editable in Safari and Chromium browsers"
        )
        expect(
            ["com.apple.mail", "org.mozilla.firefox", "com.example.webview"]
                .allSatisfy { focus("AXWebArea", app: $0, host: "example.com") == .unknown && !FocusedTextInputClassifier.isWebBrowser(bundleID: $0) },
            "Focus check: a web area in Mail and other web views that are neither a browser nor Electron stays unknown, because an editable page (Mail compose) also reports its web area as focused"
        )
        expect(
            focus("AXWebArea", app: "com.google.Chrome") == .unknown
                && focus("AXWebArea", app: "com.apple.Safari", host: nil) == .unknown
                && focus("AXWebArea", app: "com.google.Chrome", host: "docs.google.com") == .unknown
                && focus("AXWebArea", app: "com.google.Chrome", host: "DOCS.google.com") == .unknown
                && focus("AXWebArea", app: "com.apple.Safari", host: "docs.google.com") == .unknown
                && focus("AXWebArea", app: "com.google.Chrome", host: "mail.google.com") == .notEditable
                && focus("AXWebArea", app: "com.google.Chrome", host: "notdocs.google.com.evil.example") == .notEditable
                && FocusedTextInputClassifier.isHiddenInputWebHost("docs.google.com")
                && FocusedTextInputClassifier.isHiddenInputWebHost("a.docs.google.com")
                && !FocusedTextInputClassifier.isHiddenInputWebHost("google.com")
                && !FocusedTextInputClassifier.isHiddenInputWebHost(nil),
            "Focus check: a browser's web area is only called not editable once the page's address was read, and Google Docs, Sheets and Slides stay unknown (their hidden typing frame is unverified)"
        )
        expect(
            focus("AXTextArea", app: "com.google.Chrome") == .editable
                && focus("AXTextArea", app: "com.google.Chrome", host: "docs.google.com") == .editable
                && focus("AXGroup", app: "com.google.Chrome") == .unknown
                && focus("AXWebArea", app: "com.google.Chrome", range: true) == .editable
                && focus("AXWebArea", app: "com.apple.Safari", value: true) == .editable
                && focus("AXLink", app: "com.google.Chrome") == .notEditable,
            "Focus check: a contenteditable editor (Gmail compose) reports AXTextArea, never the web area, and an editable web area is editable"
        )
        // Web content in an Electron app or a browser. Real-world case: dictating in the Claude desktop app with the focus on the
        // conversation, not the message box, traced as a plain AXGroup (and was typed into nothing).
        let claude = "com.anthropic.claudefordesktop"
        let slack = "com.tinyspeck.slackmacgap", discord = "com.hnc.Discord", vsCode = "com.microsoft.VSCode"
        expect(
            focus("AXGroup", app: claude, web: true, electron: true) == .notEditable
                && focus("AXGroup", app: claude, host: "claude.ai", web: true, electron: true) == .notEditable
                && [slack, discord, vsCode, "notion.id", "md.obsidian"].allSatisfy { focus("AXGroup", app: $0, web: true, electron: true) == .notEditable }
                && focus("AXWebArea", app: claude, electron: true) == .notEditable
                && focus("AXScrollArea", app: claude, web: true, electron: true) == .notEditable
                && focus("AXHeading", app: claude, web: true, electron: true) == .notEditable,
            "Focus check: an Electron app with the focus on page content that is not a text input (the conversation in the Claude desktop app, an empty page) is not editable"
        )
        expect(
            focus("AXTextArea", app: claude, web: true, electron: true) == .editable
                && focus("AXTextField", app: slack, web: true, electron: true) == .editable
                && focus("AXGroup", app: claude, range: true, web: true, electron: true) == .editable
                && focus("AXGroup", app: discord, value: true, web: true, electron: true) == .editable
                && focus("AXTextArea", app: claude, host: "docs.google.com", web: true, electron: true) == .editable,
            "Focus check: Electron's contenteditable editors (the Claude message box, Slack, Discord, Notion) stay editable: they report a text role or a settable selected range"
        )
        expect(
            focus("AXWindow", app: claude, electron: true) == .unknown
                && focus("AXWindow", app: claude, web: true, electron: true) == .unknown
                && focus("AXApplication", app: claude, web: true, electron: true) == .unknown
                && focus(nil, app: claude, electron: true) == .unknown
                && focus(nil, app: claude, noFocus: true, electron: true) == .unknown
                && focus("AXGroup", app: claude, electron: true) == .unknown
                && focus("AXGroup", app: claude, host: "docs.google.com", web: true, electron: true) == .unknown
                && focus("AXGroup", app: claude, host: "a.docs.google.com", web: true, electron: true) == .unknown,
            "Focus check: in an Electron app a window, the application, no focused element, a failed read, a group outside web content and Google Docs stay unknown"
        )
        expect(
            focus("AXGroup", app: "com.google.Chrome", host: "example.com", web: true) == .notEditable
                && focus("AXGroup", app: "com.apple.Safari", host: "example.com", web: true) == .notEditable
                && focus("AXGroup", app: "com.google.Chrome", host: "docs.google.com", web: true) == .unknown
                && focus("AXGroup", app: "com.google.Chrome", web: true) == .unknown
                && focus("AXGroup", app: "com.google.Chrome", range: true, host: "example.com", web: true) == .editable
                && focus("AXTextArea", app: "com.google.Chrome", host: "example.com", web: true) == .editable
                && focus("AXWindow", app: "com.google.Chrome", host: "example.com", web: true) == .unknown
                && focus("AXGroup", app: "com.google.Chrome", host: "example.com") == .unknown,
            "Focus check: in a browser, page content that is not a text input is not editable once the page's address was read; Google Docs, an unreadable address and a group outside the page stay unknown"
        )
        expect(
            ["com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.googlecode.iterm2", "com.apple.Terminal"]
                .allSatisfy { focus("AXGroup", app: $0) == .unknown && focus("AXGroup", app: $0, host: "example.com") == .unknown }
                && focus("AXGroup", app: "com.apple.mail", web: true) == .unknown
                && focus("AXGroup", app: "com.apple.mail", host: "example.com", web: true) == .unknown
                && focus("AXWebArea", app: "com.apple.mail", host: "example.com") == .unknown
                && focus("AXGroup", app: "com.example.tauri", web: true) == .unknown,
            "Focus check: native apps with a plain group in focus (terminals) and web content in apps that are neither a browser nor Electron (Mail, other web views) stay unknown"
        )
        expect(
            FocusedTextInputClassifier.isDecisive(role: "AXTextArea", subrole: nil)
                && FocusedTextInputClassifier.isDecisive(role: "AXSlider", subrole: nil)
                && FocusedTextInputClassifier.isDecisive(role: "AXGroup", subrole: "AXSearchField")
                && !FocusedTextInputClassifier.isDecisive(role: "AXGroup", subrole: nil)
                && !FocusedTextInputClassifier.isDecisive(role: "AXWebArea", subrole: nil)
                && !FocusedTextInputClassifier.isDecisive(role: nil, subrole: nil),
            "Focus check: the settable reads are only needed when the role does not settle the answer"
        )
        let traceLine = FocusedElementFacts(bundleID: "com.apple.Safari", role: "AXWebArea", subrole: nil, webAreaHost: "example.com").traceDescription(status: .notEditable)
        expect(
            traceLine == "app=com.apple.Safari role=AXWebArea subrole=none noFocus=0 rangeSettable=0 valueSettable=0 web=1 electron=0 page=plain status=notEditable"
                && !traceLine.contains("\n") && !traceLine.contains("example")
                && FocusedElementFacts(bundleID: "x", role: "AXTextField", subrole: "AXSearchField").traceDescription(status: .editable)
                    == "app=x role=AXTextField subrole=AXSearchField noFocus=0 rangeSettable=0 valueSettable=0 web=0 electron=0 status=editable"
                && FocusedElementFacts(bundleID: claude, role: "AXGroup", isWebContent: true, isElectronApp: true).traceDescription(status: .notEditable)
                    == "app=com.anthropic.claudefordesktop role=AXGroup subrole=none noFocus=0 rangeSettable=0 valueSettable=0 web=1 electron=1 page=unreadable status=notEditable"
                && FocusedElementFacts(bundleID: "x", role: "AXWebArea", webAreaHost: "docs.google.com").traceDescription(status: .unknown).contains("page=webEditor")
                && !FocusedElementFacts(bundleID: "x", role: "AXWebArea", webAreaHost: "docs.google.com").traceDescription(status: .unknown).contains("google")
                && FocusedElementFacts(bundleID: "x", role: "AXWebArea").traceDescription(status: .unknown).contains("page=unreadable"),
            "Focus check: the injection trace line carries the app, role, subrole, web / Electron flags and result, on one line, with no field text and no page address"
        )
        expect(
            ActiveScreenContext.empty.focusStatus == .unknown
                && ActiveScreenContext(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "", selectedText: "", precedingText: "").focusStatus == .unknown
                && ActiveScreenContext(appName: "Finder", bundleID: finder, windowTitle: "", selectedText: "", precedingText: "", focusStatus: .notEditable).focusStatus == .notEditable,
            "Focus check: a context nobody checked is unknown, and carries the result when one was taken"
        )

        // Web content lookup: the walk up the accessibility parents (pure; the real read plugs AXUIElement into it) ...
        func climb(_ start: Int, parents: [Int: Int], roles: [Int: String], maxLevels: Int = WebContentWalk.maxLevels, stopAfterSteps: Int? = nil) -> WebContentWalk.Outcome<Int> {
            var steps = 0
            return WebContentWalk.enclosingWebArea(
                of: start, maxLevels: maxLevels,
                parent: { parents[$0] }, role: { roles[$0] },
                shouldStop: { steps += 1; return stopAfterSteps.map { steps > $0 } ?? false }
            )
        }
        let chain = Dictionary(uniqueKeysWithValues: (1...30).map { ($0, $0 + 1) })              // 1 -> 2 -> 3 ... -> 31
        func chainRoles(webAreaAt: Int? = nil, windowAt: Int? = nil) -> [Int: String] {
            var roles = Dictionary(uniqueKeysWithValues: (2...31).map { ($0, "AXGroup") })
            if let webAreaAt { roles[webAreaAt] = "AXWebArea" }
            if let windowAt { roles[windowAt] = "AXWindow" }
            return roles
        }
        expect(
            climb(1, parents: chain, roles: chainRoles(webAreaAt: 4)) == .webArea(4)
                && climb(1, parents: chain, roles: chainRoles(webAreaAt: 2)) == .webArea(2)
                && climb(1, parents: chain, roles: chainRoles(webAreaAt: 16)) == .webArea(16)
                && WebContentWalk.maxLevels == 15,
            "Web content walk: finds the web area up to 15 parents above the focused element"
        )
        expect(
            climb(1, parents: chain, roles: chainRoles(webAreaAt: 17)) == .undetermined
                && climb(1, parents: chain, roles: chainRoles(webAreaAt: 6), maxLevels: 3) == .undetermined
                && climb(1, parents: chain, roles: chainRoles(webAreaAt: 4), stopAfterSteps: 2) == .undetermined
                && climb(1, parents: chain, roles: chainRoles(webAreaAt: 4), stopAfterSteps: 3) == .webArea(4),
            "Web content walk: gives up after 15 levels or when the time budget runs out, and says so (not 'outside the web')"
        )
        expect(
            climb(1, parents: chain, roles: chainRoles(webAreaAt: 6, windowAt: 4)) == .outsideWeb
                && climb(1, parents: chain, roles: chainRoles(windowAt: 2)) == .outsideWeb
                && climb(1, parents: chain, roles: { var r = chainRoles(webAreaAt: 6); r[3] = "AXApplication"; return r }()) == .outsideWeb
                && climb(1, parents: chain, roles: { var r = chainRoles(webAreaAt: 4); r[1] = "AXWindow"; return r }()) == .webArea(4),
            "Web content walk: stops at the window (or application) without finding a web area, and never looks at the focused element's own role"
        )
        expect(
            climb(1, parents: [1: 2, 2: 3], roles: [2: "AXGroup", 3: "AXGroup"]) == .undetermined
                && climb(1, parents: [1: 2], roles: [:]) == .undetermined
                && climb(1, parents: [:], roles: [:]) == .undetermined
                && climb(1, parents: [1: 2, 2: 3], roles: [2: "AXGroup"]) == .undetermined,
            "Web content walk: an element without a parent, or a read that fails on the way, is undetermined, not 'outside the web'"
        )

        // ... and Electron detection (the bundle carries Electron Framework.framework), remembered per bundle path
        let electronRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tz-electron-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: electronRoot) }
        func makeApp(_ name: String, frameworks: [String]) -> URL {
            let app = electronRoot.appendingPathComponent("\(name).app", isDirectory: true)
            try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
            for framework in frameworks {
                try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/\(framework)", isDirectory: true), withIntermediateDirectories: true)
            }
            return app
        }
        let electronApp = makeApp("Claude", frameworks: ["Electron Framework.framework", "Squirrel.framework"])
        let chromeLikeApp = makeApp("Chrome", frameworks: ["Google Chrome Framework.framework"])
        let nativeApp = makeApp("Notes", frameworks: [])
        expect(
            ContextInjector.isElectronApp(bundleURL: electronApp)
                && !ContextInjector.isElectronApp(bundleURL: chromeLikeApp)
                && !ContextInjector.isElectronApp(bundleURL: nativeApp)
                && !ContextInjector.isElectronApp(bundleURL: electronRoot.appendingPathComponent("Missing.app", isDirectory: true))
                && !ContextInjector.isElectronApp(bundleURL: nil),
            "Electron detection: a bundle with Electron Framework.framework is an Electron app; Chrome, a native app, a missing bundle and no bundle are not"
        )
        try? FileManager.default.removeItem(at: electronApp)
        try? FileManager.default.removeItem(at: nativeApp)
        _ = try? FileManager.default.createDirectory(at: nativeApp.appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true), withIntermediateDirectories: true)
        expect(
            ContextInjector.isElectronApp(bundleURL: electronApp) && !ContextInjector.isElectronApp(bundleURL: nativeApp),
            "Electron detection: the answer is remembered per bundle path, so the bundle is not looked at again"
        )

        // 73. Delivery: what happens to the finished text, and whether the user's words are typed live while speaking
        let allStatuses: [FocusedTextInputStatus] = [.editable, .notEditable, .unknown]
        expect(
            DictationDelivery.plan(status: .editable, accessibilityTrusted: true, targetAllowed: true) == .insert
                && DictationDelivery.plan(status: .unknown, accessibilityTrusted: true, targetAllowed: true) == .insert
                && DictationDelivery.plan(status: .notEditable, accessibilityTrusted: true, targetAllowed: true) == .offerCopy(.notEditable),
            "Delivery: editable and unknown focus get the text as before; no text input in focus offers it on the Copy pill instead"
        )
        expect(
            allStatuses.allSatisfy { DictationDelivery.plan(status: $0, accessibilityTrusted: false, targetAllowed: true) == .offerCopy(.accessibilityNotTrusted) }
                && allStatuses.allSatisfy { DictationDelivery.plan(status: $0, accessibilityTrusted: true, targetAllowed: false) == .offerCopy(.targetNotAllowed) },
            "Delivery: Accessibility not trusted and a blocked target also offer the Copy pill, whatever the focus check said"
        )
        expect(
            DictationDelivery.CopyOfferReason.notEditable.traceBranch == "noFocus"
                && DictationDelivery.CopyOfferReason.accessibilityNotTrusted.traceBranch == "untrusted"
                && DictationDelivery.CopyOfferReason.targetNotAllowed.traceBranch == "blockedTarget",
            "Delivery: the trace keeps the older branch names (noFocus, untrusted) for the Copy pill cases"
        )
        expect(
            DictationDelivery.allowsLiveTyping(status: .editable)
                && DictationDelivery.allowsLiveTyping(status: .unknown)
                && !DictationDelivery.allowsLiveTyping(status: .notEditable),
            "Live typing: allowed with a text input or an unknown focus, off for the whole dictation when no text input is in focus at the start"
        )
        expect(
            !LiveInputSession.allowsLiveTyping(focusChecked: false, status: .editable)
                && !LiveInputSession.allowsLiveTyping(focusChecked: false, status: .unknown)
                && LiveInputSession.allowsLiveTyping(focusChecked: true, status: .editable)
                && LiveInputSession.allowsLiveTyping(focusChecked: true, status: .unknown)
                && !LiveInputSession.allowsLiveTyping(focusChecked: true, status: .notEditable),
            "Live typing: nothing is typed until the first focus check has run, then it follows the result"
        )

        // 74. Copy pill: one-line preview, and the 8 s countdown with its pause while the pointer is over the pill
        let longSentence = Array(repeating: "A long dictation that keeps going", count: 8).joined(separator: " ")
        let longPreview = CopyPill.preview(of: longSentence)
        expect(
            CopyPill.preview(of: "Can you move the standup to 3 pm?") == "Can you move the standup to 3 pm?"
                && CopyPill.preview(of: "  First line\n\nSecond\tline  \r\n") == "First line Second line"
                && CopyPill.preview(of: "") == "" && CopyPill.preview(of: " \n ") == ""
                && longPreview.count <= CopyPill.previewCharacterLimit && longPreview.hasSuffix("…") && !longPreview.contains("\n")
                && longSentence.hasPrefix(String(longPreview.dropLast()))
                && CopyPill.preview(of: String(repeating: "你", count: 200)).count == CopyPill.previewCharacterLimit
                && CopyPill.preview(of: String(repeating: "a", count: CopyPill.previewCharacterLimit)).count == CopyPill.previewCharacterLimit
                && !CopyPill.preview(of: String(repeating: "a", count: CopyPill.previewCharacterLimit)).hasSuffix("…"),
            "Copy pill preview: whitespace and line breaks collapse to one line, and only a text over the limit is cut with an ellipsis"
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var countdown = CopyPillCountdown()
        expect(
            CopyPillCountdown.visibleSeconds == 8 && CopyPillCountdown.copiedSeconds == 1
                && countdown.remaining == 8 && !countdown.isRunning,
            "Copy pill: it waits 8 s for a click and shows \"Copied\" for 1 s"
        )
        countdown.start(now: t0)
        countdown.pause(now: t0.addingTimeInterval(3))
        let afterFirstPause = countdown.remaining
        countdown.pause(now: t0.addingTimeInterval(50))                       // already paused: nothing changes
        countdown.resume(now: t0.addingTimeInterval(10))
        countdown.resume(now: t0.addingTimeInterval(11))                      // already running: the clock is not restarted
        countdown.pause(now: t0.addingTimeInterval(12))
        let afterSecondPause = countdown.remaining
        countdown.resume(now: t0.addingTimeInterval(20))
        countdown.pause(now: t0.addingTimeInterval(200))
        expect(
            afterFirstPause == 5 && afterSecondPause == 3 && countdown.remaining == 0 && !countdown.isRunning,
            "Copy pill: hovering pauses the countdown and moving away continues it from what was left (8 s - 3 s - 2 s, never below 0)"
        )
        countdown.start(now: t0.addingTimeInterval(300))
        expect(countdown.remaining == 8 && countdown.isRunning, "Copy pill: a new offer starts a fresh 8 s countdown")

        // 75. Speech hints and the cloud: one decision picks the speech backend, and the same decision says whether the hints (the terms
        // handed to the recognizer, which can include a clipboard word) would be sent off this Mac. Only a cloud backend whose server is
        // not on this Mac sends them.
        do {
            func leaves(_ provider: ASRProviderOption, volcKey: String = "", openAIKey: String = "", baseURL: String = "https://api.openai.com/v1") -> Bool {
                StreamingASREngine.speechHintsLeaveThisMac(provider: provider, volcSpeechAPIKey: volcKey, openAIASRAPIKey: openAIKey, openAIASRBaseURL: baseURL)
            }
            func choice(_ provider: ASRProviderOption, volcKey: String = "", openAIKey: String = "", baseURL: String = "https://api.openai.com/v1") -> StreamingASREngine.CloudBackendChoice {
                StreamingASREngine.cloudBackendChoice(provider: provider, volcSpeechAPIKey: volcKey, openAIASRAPIKey: openAIKey, openAIASRBaseURL: baseURL)
            }
            expect(
                leaves(.volcSeedASR, volcKey: "test-key")
                    && leaves(.openAIWhisper, openAIKey: "test-key", baseURL: "https://api.openai.com/v1")
                    && leaves(.openAIWhisper, openAIKey: "test-key", baseURL: "https://api.groq.com/openai/v1")
                    && leaves(.openAIWhisper, openAIKey: "test-key", baseURL: "https://localhost.example.com/v1")
                    && leaves(.openAIWhisper, openAIKey: "test-key", baseURL: "http://mac-studio.local:8000/v1"),
                "Speech hints leave this Mac for Volcengine and for an OpenAI-compatible server that is not on it (OpenAI, Groq, localhost.example.com, a .local name)"
            )
            expect(
                leaves(.openAIWhisper, baseURL: "https://localhost.example.com/v1"),
                "Speech hints leave this Mac for a keyless server named localhost.example.com too: the loose keyless check accepts it, the host check does not"
            )
            expect(
                !leaves(.volcSeedASR) && !leaves(.volcSeedASR, volcKey: "  \n")
                    && !leaves(.openAIWhisper, baseURL: "http://127.0.0.1:8000/v1")
                    && !leaves(.openAIWhisper, openAIKey: "test-key", baseURL: "http://localhost:9000/v1")
                    && !leaves(.openAIWhisper, openAIKey: "test-key", baseURL: "http://[::1]:8000/v1")
                    && !leaves(.openAIWhisper, baseURL: "https://api.openai.com/v1")
                    && !leaves(.localSenseVoice, volcKey: "test-key", openAIKey: "test-key"),
                "Speech hints stay on this Mac for Volcengine without a key, for an OpenAI-compatible server on this Mac, for OpenAI without a key, and for the local engine"
            )
            expect(
                choice(.openAIWhisper, baseURL: "http://127.0.0.1:8000/v1") == .init(seedASR: false, openAI: true)
                    && choice(.openAIWhisper, openAIKey: "test-key", baseURL: "http://localhost:9000/v1") == .init(seedASR: false, openAI: true)
                    && choice(.openAIWhisper, openAIKey: "test-key", baseURL: "http://[::1]:8000/v1") == .init(seedASR: false, openAI: true)
                    && choice(.openAIWhisper, baseURL: "https://api.openai.com/v1") == .init(seedASR: false, openAI: false)
                    && choice(.volcSeedASR) == .init(seedASR: false, openAI: false)
                    && choice(.localSenseVoice, volcKey: "test-key", openAIKey: "test-key") == .init(seedASR: false, openAI: false),
                "Backend choice: a server on this Mac really is the chosen engine there (only its host keeps the hints here), while a missing key or the local engine chooses no cloud backend"
            )
            var choiceMatchesEarlierFormulas = true
            for provider in ASRProviderOption.allCases {
                for volcKey in ["", "   ", "test-key", " test-key\n"] {
                    for openAIKey in ["", "   ", "test-key"] {
                        for baseURL in ["https://api.openai.com/v1", "https://api.groq.com/openai/v1", "http://127.0.0.1:8000/v1", "http://localhost:9000/v1",
                                        "http://[::1]:8000/v1", "https://localhost.example.com/v1", "http://mac-studio.local:8000/v1", ""] {
                            // The two formulas `startStreamingInternal` used before the decision was shared:
                            let cleanSpeechKey = volcKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            let cleanOpenAIKey = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            let wantCloudSeedASR = (provider == .volcSeedASR) && !cleanSpeechKey.isEmpty
                            let wantOpenAIASR = (provider == .openAIWhisper) && (!cleanOpenAIKey.isEmpty || PolishEngine.isKeylessLocalEndpoint(baseURL))
                            let shared = choice(provider, volcKey: volcKey, openAIKey: openAIKey, baseURL: baseURL)
                            if shared.seedASR != wantCloudSeedASR || shared.openAI != wantOpenAIASR {
                                choiceMatchesEarlierFormulas = false
                            }
                        }
                    }
                }
            }
            expect(
                choiceMatchesEarlierFormulas,
                "Backend choice: the shared decision gives the same answer as the two formulas used before, for every engine, key (empty, blank, set) and base URL tried"
            )
            let onThisMac = ["http://127.0.0.1:8000/v1", "http://127.12.0.9/v1", "http://localhost:9000/v1", "HTTP://LocalHost/v1",
                             "http://[::1]:8000/v1", "http://0.0.0.0:8080/v1", "  http://localhost:11434/v1\n"]
            let notOnThisMac = ["", "   ", "not a url", "localhost:8000/v1", "https://api.openai.com/v1", "https://localhost.example.com/v1",
                                "http://127.0.0.1.example.com/v1", "http://localhost@evil.example.com/v1", "http://mac-studio.local:8000/v1",
                                "http://192.168.1.20:8000/v1", "http://10.0.0.5/v1", "http://128.0.0.1/v1", "http://127.0.0.256/v1", "http://127.0.0/v1"]
            expect(
                onThisMac.allSatisfy(StreamingASREngine.isLoopbackEndpoint) && !notOnThisMac.contains(where: StreamingASREngine.isLoopbackEndpoint),
                "Loopback check: the parsed host must be localhost, ::1, 0.0.0.0 or 127.x.x.x; no host, a non-URL, .local, a LAN address or a name that only contains these does not count"
            )
            let engine = StreamingASREngine()
            engine.asrProvider = .openAIWhisper
            engine.openAIASRAPIKey = "test-key"
            engine.openAIASRBaseURL = "https://api.groq.com/openai/v1"
            let groqLeaves = engine.speechHintsLeaveThisMac
            engine.openAIASRBaseURL = "http://127.0.0.1:8000/v1"
            let ownServerStays = !engine.speechHintsLeaveThisMac
            engine.asrProvider = .volcSeedASR
            engine.volcSpeechAPIKey = "test-key"
            let volcengineLeaves = engine.speechHintsLeaveThisMac
            engine.volcSpeechAPIKey = ""
            let volcengineWithoutKeyStays = !engine.speechHintsLeaveThisMac
            expect(
                groqLeaves && ownServerStays && volcengineLeaves && volcengineWithoutKeyStays,
                "The engine's own speechHintsLeaveThisMac follows the provider, keys and base URL it holds right now"
            )
        }

        // 76. Clipboard hint: used only when the speech engine runs on this Mac, never from contents marked private, and only a short single line
        do {
            // A private named pasteboard holding `text`. `marker` is added with empty data to the same item, or to a second item, the way a
            // password manager marks a copy. NSPasteboardItem refuses a type that is not a valid UTI string ("Pasteboard generator type"
            // has spaces), so that legacy marker is declared on the pasteboard itself, as an older app would. The real clipboard is never
            // read or written.
            func hint(for text: String, marker: String? = nil, markerOnSecondItem: Bool = false, speechHintsLeaveThisMac: Bool = false) -> String {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.typezero.selftest.\(UUID().uuidString)"))
                defer { pasteboard.releaseGlobally() }
                pasteboard.clearContents()
                let first = NSPasteboardItem()
                first.setString(text, forType: .string)
                var items = [first]
                var legacyMarker: NSPasteboard.PasteboardType? = nil
                if let marker {
                    let type = NSPasteboard.PasteboardType(marker)
                    if marker.contains(" ") {
                        legacyMarker = type
                    } else if markerOnSecondItem {
                        let second = NSPasteboardItem()
                        second.setData(Data(), forType: type)
                        items.append(second)
                    } else {
                        first.setData(Data(), forType: type)
                    }
                }
                pasteboard.writeObjects(items)
                if let legacyMarker { pasteboard.setData(Data(), forType: legacyMarker) }
                return SpeechHintPrivacy.clipboardHintText(from: pasteboard, speechHintsLeaveThisMac: speechHintsLeaveThisMac)
            }
            let markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                           "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
                           "Pasteboard generator type", "net.antelle.keeweb"]
            expect(
                hint(for: "Kubernetes") == "Kubernetes" && hint(for: "Kubernetes", speechHintsLeaveThisMac: true) == "",
                "Clipboard hint: a short word is used when the speech engine runs on this Mac, and nothing is used when the hints would leave it"
            )
            expect(
                SpeechHintPrivacy.privateClipboardTypes.isSuperset(of: markers),
                "Clipboard hint: the private markers include the nspasteboard.org types and the legacy markers of password managers and clipboard tools"
            )
            expect(
                hint(for: "hunter2") == "hunter2" && markers.allSatisfy { hint(for: "hunter2", marker: $0) == "" },
                "Clipboard hint: text copied with any private marker is not used, while the same text without a marker is"
            )
            expect(
                hint(for: "hunter2", marker: "org.nspasteboard.ConcealedType", markerOnSecondItem: true) == ""
                    && hint(for: "hunter2", marker: "com.agilebits.onepassword", markerOnSecondItem: true) == "",
                "Clipboard hint: a private marker on a second pasteboard item counts too"
            )
            let fortyTwo = String(repeating: "x", count: 42)
            expect(
                hint(for: "first line\nsecond line") == "" && hint(for: "a") == "" && hint(for: fortyTwo + "x") == ""
                    && hint(for: "ab") == "ab" && hint(for: fortyTwo) == fortyTwo && hint(for: "  Kubernetes \n") == "Kubernetes",
                "Clipboard hint: only one line of 2 to 42 characters is used, after trimming; several lines, 1 character and 43 characters give nothing"
            )
        }

        // 77. Speaking time (`SpeakingTimeMeter`): the calibrated pause rule on synthetic audio. A 440 Hz tone is speech and faint, fixed
        // noise is the quiet room. Everything is in memory or in a throw-away temp folder.
        do {
            typealias Audio = SpeakingTestAudio
            func measured(_ samples: [Float], rate: Double = Audio.sampleRate) -> SpeakingTimeMeter.Measurement {
                var meter = SpeakingTimeMeter(sampleRate: rate)
                meter.append(samples)
                return meter.result
            }
            func levels(_ db: Float, _ count: Int) -> [Float] { [Float](repeating: db, count: count) }
            func rule(_ frameLevels: [Float], total: Double) -> Double {
                SpeakingTimeMeter.speakingSeconds(levels: frameLevels, frameSeconds: 0.01, totalSeconds: total)
            }
            let oneFrame = 1 / SpeakingTimeMeter.framesPerSecond

            expect(
                SpeakingTimeMeter.framesPerSecond == 100 && SpeakingTimeMeter.noiseFloorPercentile == 0.10
                    && SpeakingTimeMeter.loudLevelPercentile == 0.95 && SpeakingTimeMeter.speechMarginDB == 13
                    && SpeakingTimeMeter.loudMarginDB == 10 && SpeakingTimeMeter.minimumPauseSeconds == 0.3
                    && SpeakingTimeMeter.minimumMeasurableSeconds == 1.0 && SpeakingTimeMeter.minimumRMS == 1e-5
                    && SpeakingTimeMeter.digitalSilenceLevel == -100
                    && SpeakingTimeMeter.isDigitalSilence(-100) && !SpeakingTimeMeter.isDigitalSilence(-99.9),
                "Speaking time: the calibrated rule is 10 ms frames, a 10th-percentile noise floor + 13 dB, a 95th-percentile loud level - 10 dB, 0.3 s minimum pauses, a 1 s minimum length, and digital silence at -100 dBFS"
            )
            let frameLengths = [48_000.0, 44_100.0, 16_000.0, 22_050.0, 0, .nan].map { SpeakingTimeMeter(sampleRate: $0).frameLength }
            expect(frameLengths == [480, 441, 160, 221, 1, 1], "Speaking time: a frame is 10 ms of samples (rounded, never fewer than one), and a bad sample rate cannot trap")

            // 2 s of speech, 1 s of quiet, 2 s of speech: the pause comes out.
            let spoken = Audio.tone(2) + Audio.hiss(1) + Audio.tone(2)
            let base = measured(spoken)
            expect(
                abs(base.recordingSeconds - 5.0) < 1e-9 && abs(base.speakingSeconds - 4.0) <= 2 * oneFrame,
                "Speaking time: 2 s of tone, 1 s of faint noise and 2 s of tone measure about 4 s of speaking in 5 s of recording"
            )

            // A quiet run shorter than 0.3 s is part of speaking; one of exactly 0.3 s is a pause.
            let shortGaps = measured(Audio.tone(0.6) + Audio.hiss(0.2) + Audio.tone(0.6) + Audio.hiss(0.2, seed: 2) + Audio.tone(0.6))
            let exactPause = measured(Audio.tone(0.6) + Audio.hiss(0.3) + Audio.tone(0.6))
            expect(
                abs(shortGaps.recordingSeconds - 2.2) < 1e-9 && abs(shortGaps.speakingSeconds - shortGaps.recordingSeconds) < 1e-9,
                "Speaking time: two 0.2 s gaps are not pauses, so nothing is taken out of the recording"
            )
            expect(abs(exactPause.speakingSeconds - 1.2) <= oneFrame, "Speaking time: a quiet run of exactly 0.3 s is a pause (1.5 s of recording -> 1.2 s of speaking)")

            // A recording shorter than 1 s counts in full; at 1 s the rule applies.
            let belowOneSecond = measured(Audio.tone(0.3) + Audio.hiss(0.5))
            let silentBelowOneSecond = measured(Audio.hiss(0.9))
            let exactlyOneSecond = measured(Audio.tone(0.2) + Audio.hiss(0.8))
            let justOverOneSecond = measured(Audio.tone(0.3) + Audio.hiss(0.8))
            expect(
                abs(belowOneSecond.speakingSeconds - 0.8) < 1e-9 && abs(silentBelowOneSecond.speakingSeconds - 0.9) < 1e-9
                    && abs(exactlyOneSecond.speakingSeconds - 0.2) <= oneFrame && abs(justOverOneSecond.speakingSeconds - 0.3) <= oneFrame,
                "Speaking time: a recording under 1 s counts in full, however quiet; from 1 s on its 0.8 s pause is taken out"
            )

            // The rule only looks at levels relative to the recording's own levels.
            let quieter = measured(spoken.map { $0 * 0.1 })
            let louder = measured(spoken.map { $0 * 4 })
            expect(
                abs(quieter.speakingSeconds - base.speakingSeconds) < 1e-9 && abs(louder.speakingSeconds - base.speakingSeconds) < 1e-9,
                "Speaking time: scaling the whole signal by 0.1, or by 4, gives the same speaking time"
            )

            // However the samples are split into appends, the answer is the same.
            var oneShot = SpeakingTimeMeter(sampleRate: Audio.sampleRate)
            oneShot.append(spoken)
            var chunked = SpeakingTimeMeter(sampleRate: Audio.sampleRate)
            var chunkRandom: UInt64 = 12_345
            var chunkStart = 0
            var viaBuffer = false
            while chunkStart < spoken.count {
                chunkRandom = chunkRandom &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let size = min(1 + Int((chunkRandom >> 33) % 5_000), spoken.count - chunkStart)
                let slice = Array(spoken[chunkStart..<(chunkStart + size)])
                if viaBuffer { slice.withUnsafeBufferPointer { chunked.append($0) } } else { chunked.append(slice) }
                viaBuffer.toggle()
                chunkStart += size
            }
            var oneByOne = SpeakingTimeMeter(sampleRate: Audio.sampleRate)
            for sample in spoken.prefix(5_000) { oneByOne.append([sample]) }
            var firstChunk = SpeakingTimeMeter(sampleRate: Audio.sampleRate)
            firstChunk.append(Array(spoken.prefix(5_000)))
            var untouched = SpeakingTimeMeter(sampleRate: Audio.sampleRate)
            untouched.append([Float]())
            expect(
                chunked.frameLevels == oneShot.frameLevels && chunked.sampleCount == spoken.count && chunked.result == oneShot.result
                    && oneByOne.frameLevels == firstChunk.frameLevels && oneByOne.result == firstChunk.result
                    && untouched.sampleCount == 0 && untouched.result == (0, 0),
                "Speaking time: random chunk sizes (as arrays and as buffers), one sample at a time and empty appends all give exactly the one-append result"
            )

            // The unfinished frame at the end counts as a frame (a full frame of quiet time when it is quiet).
            let withTail = Audio.tone(1) + Audio.hiss(1) + Audio.hiss(samples: 50, seed: 3)
            var tailMeter = SpeakingTimeMeter(sampleRate: Audio.sampleRate)
            tailMeter.append(withTail)
            let tailSpeaking = Double(withTail.count) / Audio.sampleRate - 101 * oneFrame
            expect(
                tailMeter.frameLevels.count == 200 && tailMeter.sampleCount == 96_050 && abs(tailMeter.result.speakingSeconds - tailSpeaking) < 1e-9,
                "Speaking time: a final partial frame counts as a frame (100 quiet frames and a partial one make a 1.01 s pause)"
            )

            // Speech with almost no pauses: the level only swings up and down, 2 to 4 times a second like syllables, and nothing is silent.
            // The 10th-percentile level of such a recording is part of the speech itself, so a threshold a fixed 12 dB above it lies above
            // most of the frames. That older rule kept 0%, 31% and 100% of these three as speaking; the last, widest and fastest swing
            // never leaves a quiet stretch of 0.3 s, so it passes under either rule and only guards against a threshold set too high.
            let narrowSwing = measured(Audio.swing(seconds: 5, hertz: 3, swingDB: 5))
            let mediumSwing = measured(Audio.swing(seconds: 5, hertz: 2, swingDB: 8))
            let wideSwing = measured(Audio.swing(seconds: 5, hertz: 4, swingDB: 10))
            expect(
                narrowSwing.speakingSeconds >= 0.9 * narrowSwing.recordingSeconds,
                "Speaking time: 5 s of tone with no silence whose level swings 10 dB from trough to peak, 3 times a second, keeps at least 90% as speaking"
            )
            expect(
                mediumSwing.speakingSeconds >= 0.9 * mediumSwing.recordingSeconds,
                "Speaking time: ... and so does one that swings 16 dB from trough to peak, 2 times a second"
            )
            expect(
                wideSwing.speakingSeconds >= 0.9 * wideSwing.recordingSeconds,
                "Speaking time: ... and one that swings 20 dB from trough to peak, 4 times a second"
            )

            // Digital zeros (the start of an Opus file, a microphone that is not warm yet) are not the room: they take no part in the
            // noise floor or the loud level, but they are quiet when pauses are looked for.
            let speechPauseSpeech = Audio.tone(1.2) + Audio.hiss(1) + Audio.tone(1.2)
            let withoutZeros = measured(speechPauseSpeech)
            let withZeros = measured(Audio.zeros(0.6) + speechPauseSpeech)
            let scaledWithZeros = measured((Audio.zeros(0.6) + speechPauseSpeech).map { $0 * 0.1 })
            let shortZeros = measured(Audio.zeros(0.2) + speechPauseSpeech)
            expect(
                abs(withoutZeros.speakingSeconds - 2.4) <= oneFrame && abs(withZeros.recordingSeconds - 4.0) < 1e-9
                    && abs(withZeros.speakingSeconds - withoutZeros.speakingSeconds) <= oneFrame
                    && abs(scaledWithZeros.speakingSeconds - withZeros.speakingSeconds) < 1e-9,
                "Speaking time: 15% leading digital zeros change nothing but the zeros themselves: the pause is found as before (2.4 s of speaking with or without them), at any gain"
            )
            expect(
                abs(shortZeros.speakingSeconds - (withoutZeros.speakingSeconds + 0.2)) <= oneFrame,
                "Speaking time: digital zeros are quiet like any other quiet frames, so 0.2 s of them before the speech is no pause"
            )
            expect(
                measured(Audio.zeros(1.0)).speakingSeconds == 0 && measured(Audio.zeros(2.0)).speakingSeconds == 0
                    && abs(measured(Audio.zeros(0.9)).speakingSeconds - 0.9) < 1e-9,
                "Speaking time: a recording of digital silence has no speaking time from 1 s on, and counts in full under 1 s"
            )

            // The rule on frame levels: nearest-rank percentiles of the frames that are not digital silence, the threshold the lower of
            // floor + 13 dB and loud level - 10 dB (a frame has to be strictly above it), pauses of 30 frames or more.
            expect(
                abs(rule(levels(-70, 40) + levels(-20, 60), total: 1.0) - 0.6) < 1e-9
                    && abs(rule(levels(-20, 35) + levels(-70, 29) + levels(-20, 36), total: 1.0) - 1.0) < 1e-9
                    && abs(rule(levels(-20, 35) + levels(-70, 30) + levels(-20, 35), total: 1.0) - 0.7) < 1e-9
                    && abs(rule(levels(-20, 70) + levels(-70, 30), total: 1.0) - 0.7) < 1e-9,
                "Speaking time: a quiet run of 29 frames stays, 30 frames are a pause, at the start, in the middle or at the end"
            )
            expect(
                abs(rule(levels(-70, 40) + levels(-57, 20) + levels(-20, 40), total: 1.0) - 0.4) < 1e-9
                    && abs(rule(levels(-70, 40) + levels(-56, 20) + levels(-20, 40), total: 1.0) - 0.6) < 1e-9,
                "Speaking time: a frame exactly 13 dB above the noise floor is still quiet, one just above that is speech"
            )
            expect(
                abs(rule(levels(-32, 35) + levels(-22, 65), total: 1.0) - 0.65) < 1e-9
                    && abs(rule(levels(-31, 35) + levels(-22, 65), total: 1.0) - 1.0) < 1e-9,
                "Speaking time: the threshold is capped 10 dB below the loud level: a frame 10 dB below it is quiet, one 9 dB below it is speech, however close the noise floor is"
            )
            expect(
                abs(rule(levels(-70, 10) + levels(-50, 30) + levels(-20, 60), total: 1.0) - 0.6) < 1e-9
                    && abs(rule(levels(-40, 30) + levels(-35, 67) + levels(0, 3), total: 1.0) - 1.0) < 1e-9,
                "Speaking time: the noise floor is the level at nearest rank round(0.1 * (n - 1)) and the loud level the one at round(0.95 * (n - 1)), so a few peaks do not set the loud level"
            )
            expect(
                abs(rule(levels(-100, 40) + levels(-20, 60), total: 1.0) - 0.6) < 1e-9
                    && abs(rule(levels(-100, 20) + levels(-20, 80), total: 1.0) - 1.0) < 1e-9
                    && abs(rule(levels(-100, 15) + levels(-70, 20) + levels(-20, 65), total: 1.0) - 0.65) < 1e-9
                    && abs(rule(levels(-100, 40) + levels(-99.5, 60), total: 1.0) - 0.6) < 1e-9,
                "Speaking time: digital silence (-100 dBFS) is left out of the percentiles, yet is quiet in the pause search whatever the threshold is"
            )
            expect(
                rule([], total: 5) == 5 && rule(levels(-70, 50), total: 0.5) == 0.5
                    && rule(levels(-100, 100), total: 1.0) == 0 && rule(levels(-100, 250), total: 2.5) == 0,
                "Speaking time: no frames, or under 1 s, count in full; a recording of digital silence has no speaking time from 1 s on"
            )
            expect(
                rule(levels(-70, 100), total: 1.0) == 1.0 && abs(measured(Audio.hiss(2)).speakingSeconds - 2.0) < 1e-9,
                "Speaking time: a recording at one steady level has nothing 10 dB below its loud level, so all of it counts as speaking"
            )

            // Files: the same answer as the samples in memory, read-only, unreadable files are nil, and the developer report.
            let audioFolder = FileManager.default.temporaryDirectory.appendingPathComponent("typezero-speaking-selftest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: audioFolder) }
            let wavURL = audioFolder.appendingPathComponent("clip.wav")
            let garbageURL = audioFolder.appendingPathComponent("garbage.ogg")
            let emptyURL = audioFolder.appendingPathComponent("empty.ogg")
            try? Data(String(repeating: "not audio ", count: 500).utf8).write(to: garbageURL)
            try? Data().write(to: emptyURL)
            let wroteWAV = Audio.writeWAV(spoken, to: wavURL)
            let attributesBefore = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
            let fromFile = SpeakingTimeMeter.measure(fileAt: wavURL)
            let attributesAfter = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
            expect(
                wroteWAV && abs((fromFile?.recordingSeconds ?? -1) - base.recordingSeconds) < 1e-9
                    && abs((fromFile?.speakingSeconds ?? -1) - base.speakingSeconds) < 1e-9,
                "Speaking time: measuring a WAV file gives the same answer as the same samples in memory"
            )
            expect(
                (attributesBefore?[.size] as? NSNumber) == (attributesAfter?[.size] as? NSNumber)
                    && (attributesBefore?[.modificationDate] as? Date) == (attributesAfter?[.modificationDate] as? Date),
                "Speaking time: measuring a file leaves it as it was"
            )
            expect(
                SpeakingTimeMeter.measure(fileAt: garbageURL) == nil && SpeakingTimeMeter.measure(fileAt: emptyURL) == nil
                    && SpeakingTimeMeter.measure(fileAt: audioFolder.appendingPathComponent("missing.ogg")) == nil,
                "Speaking time: a file that is missing, empty or not audio is unknown (nil), not zero"
            )
            // A compressed file's length is only an estimate: one that is cut short opens, claims its full length, and then fails to
            // read. What could be read is measured (it used to be thrown away).
            let aacURL = audioFolder.appendingPathComponent("clip.caf")
            let cutURL = audioFolder.appendingPathComponent("clip-cut.caf")
            let wroteAAC = Audio.writeAAC(spoken, to: aacURL)
            let aacData = (try? Data(contentsOf: aacURL)) ?? Data()
            try? aacData.prefix(aacData.count * 9 / 10).write(to: cutURL)
            let wholeAAC = SpeakingTimeMeter.measure(fileAt: aacURL)
            let cutAAC = SpeakingTimeMeter.measure(fileAt: cutURL)
            expect(
                wroteAAC && !aacData.isEmpty && abs((wholeAAC?.recordingSeconds ?? -1) - 5.0) < 0.2
                    && abs((wholeAAC?.speakingSeconds ?? -1) - 4.0) < 0.2,
                "Speaking time: a compressed (AAC) file measures about the same as the audio it was made from"
            )
            expect(
                cutAAC != nil && (cutAAC?.recordingSeconds ?? 0) > 0.5 && (cutAAC?.recordingSeconds ?? 9) <= (wholeAAC?.recordingSeconds ?? 0) + 1e-9
                    && (cutAAC?.speakingSeconds ?? 9) <= (cutAAC?.recordingSeconds ?? 0) + 1e-9
                    && SpeakingTimeMeter.measure(fileAt: audioFolder.appendingPathComponent("not-there.caf")) == nil,
                "Speaking time: a compressed file that is cut short gives the measurement of what could be read, not nil; only a file with nothing readable is nil"
            )
            expect(
                SpeakingTimeMeter.report(forFiles: [wavURL.path, garbageURL.path])
                    == ["recording=5.00\tspeaking=4.00\tclip.wav", "error\tgarbage.ogg", "total recording=5.00 speaking=4.00 files=1"]
                    && SpeakingTimeMeter.report(forFiles: []) == ["total recording=0.00 speaking=0.00 files=0"],
                "Speaking time: --speaking-time prints one line per file (tab separated, file name only, error for an unreadable file) and a total line"
            )

            // History: a history.json from before the field existed still decodes, and an unmeasured record's JSON is unchanged.
            let beforeJSON = #"[{"id":"7B3C2D1E-0000-4000-8000-000000000002","timestamp":0,"rawTranscript":"a","polishedText":"b","durationSeconds":4,"polishLatencyMs":5,"targetAppName":"Notes","mode":"口述成稿","matchedTerms":[]}]"#
            let decodedBefore = try? JSONDecoder().decode([DictationRecord].self, from: Data(beforeJSON.utf8))
            let unmeasuredRecord = DictationRecord(rawTranscript: "a", polishedText: "b", durationSeconds: 4, polishLatencyMs: 5, targetAppName: "Notes")
            let measuredRecord = DictationRecord(rawTranscript: "a", polishedText: "b", durationSeconds: 4, polishLatencyMs: 5, targetAppName: "Notes", speakingSeconds: 3.25)
            let unmeasuredText = (try? JSONEncoder().encode([unmeasuredRecord])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let measuredData = try? JSONEncoder().encode([unmeasuredRecord, measuredRecord])
            let roundTrip = measuredData.flatMap { try? JSONDecoder().decode([DictationRecord].self, from: $0) }
            expect(
                decodedBefore?.count == 1 && decodedBefore?.first?.speakingSeconds == nil && decodedBefore?.first?.durationSeconds == 4
                    && !unmeasuredText.isEmpty && !unmeasuredText.contains("speakingSeconds"),
                "Speaking time: a history.json without the key decodes to nil, and a record that was never measured is written without the key"
            )
            expect(
                roundTrip?.count == 2 && roundTrip?[0].speakingSeconds == nil && roundTrip?[1].speakingSeconds == 3.25
                    && roundTrip?[1].id == measuredRecord.id,
                "Speaking time: a measured value survives the history.json encode/decode round trip"
            )
            let nonFinite = DictationRecord(rawTranscript: "a", polishedText: "b", durationSeconds: 4, polishLatencyMs: 5, targetAppName: "Notes", speakingSeconds: .infinity)
            let notANumber = DictationRecord(rawTranscript: "a", polishedText: "b", durationSeconds: 4, polishLatencyMs: 5, targetAppName: "Notes", speakingSeconds: .nan)
            let negative = DictationRecord(rawTranscript: "a", polishedText: "b", durationSeconds: 4, polishLatencyMs: 5, targetAppName: "Notes", speakingSeconds: -2)
            expect(
                nonFinite.speakingSeconds == nil && notANumber.speakingSeconds == nil && negative.speakingSeconds == 0
                    && (try? JSONEncoder().encode([nonFinite, notANumber, negative])) != nil,
                "Speaking time: a value that cannot be written to JSON is dropped (it would stop history.json from saving), and a negative one becomes 0"
            )
        }

        print("==> Summary: \(passed) passed, \(failed) failed.")
        return failed == 0 ? 0 : 1
    }

    /// Live dual-engine smoke benchmark (`Nevertype --bench-asr`): tests the selected Local model (Parakeet TDT v2 or SenseVoice) and Cloud Volcengine Seed-ASR 2.0 on real audio without printing any credentials.
    public static func runDualASRSmokeBenchmark() -> Int32 {
        print("==> Running Dual-ASR Live Smoke Benchmark (Seed-ASR 2.0 + Local model)...")
        guard let localFiles = LocalASRModel.resolve(preferred: LLMConfig.default.localASRModel) else {
            print("  ✗ No local speech model found (Parakeet TDT v2 or SenseVoice).")
            return 1
        }
        let modelDir = URL(fileURLWithPath: localFiles.modelPath).deletingLastPathComponent()
        let wavURL = modelDir.appendingPathComponent(localFiles.model == .parakeetTDTv2 ? "test_wavs/0.wav" : "test_wavs/zh.wav")
        guard let audioFile = try? AVAudioFile(forReading: wavURL) else {
            print("  ✗ Sample test_wavs/zh.wav not found at \(wavURL.path)")
            return 1
        }
        let fmt = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount),
              (try? audioFile.read(into: buf)) != nil,
              let ch0 = buf.floatChannelData?[0] else {
            return 1
        }
        let floatSamples = Array(UnsafeBufferPointer(start: ch0, count: Int(buf.frameLength)))
        let sr = Int32(fmt.sampleRate)

        // 1. Local model (same handle construction as the app engine)
        let tLoad0 = DispatchTime.now().uptimeNanoseconds
        guard let handle = StreamingASREngine.createLocalRecognizerHandle(files: localFiles, speechLocale: "auto") else {
            print("  ✗ Failed to load \(localFiles.model.displayName)")
            return 1
        }
        defer { tz_sensevoice_destroy(handle) }
        let loadMs = (DispatchTime.now().uptimeNanoseconds - tLoad0) / 1_000_000

        // Warm pass + timed pass
        floatSamples.withUnsafeBufferPointer { ptr in
            if let warmStr = tz_sensevoice_transcribe(handle, ptr.baseAddress, Int32(ptr.count), sr) {
                tz_sensevoice_free_string(warmStr)
            }
        }
        let tInf0 = DispatchTime.now().uptimeNanoseconds
        var localOut = ""
        floatSamples.withUnsafeBufferPointer { ptr in
            if let cStr = tz_sensevoice_transcribe(handle, ptr.baseAddress, Int32(ptr.count), sr) {
                localOut = String(cString: cStr)
                tz_sensevoice_free_string(cStr)
            }
        }
        let infMs = (DispatchTime.now().uptimeNanoseconds - tInf0) / 1_000_000
        print("  ✓ [Local Standby] \(localFiles.model.displayName)\(localFiles.isFullPrecision ? " FP32" : ""): load=\(loadMs)ms, infer=\(infMs)ms -> 「\(localOut)」")

        // 2. Cloud Volcengine Doubao Seed-ASR 2.0 (`volc.seedasr.sauc.duration`)
        let speechKey = KeychainHelper.loadVolcSpeechAPIKey()
        guard !speechKey.isEmpty else {
            print("  ! Volcengine Speech API Key not set in Keychain; skipping cloud benchmark.")
            return 0
        }

        var finishedFlag = false
        var exitStatus: Int32 = 0
        Task {
            do {
                let probeRtt = try await VolcSeedASRClient.probeHandshakeLatency(apiKey: speechKey)
                let pcm16 = StreamingASREngine.resampleFloatTo16kHzInt16(floatSamples, sourceRate: fmt.sampleRate)
                print("  [diag] floatSamples=\(floatSamples.count) sr=\(fmt.sampleRate) -> pcm16=\(pcm16.count)")
                let client = VolcSeedASRClient()
                var partialsCount = 0
                client.onStreamingTranscript = { txt, def in
                    partialsCount += 1
                    print("  [stream #\(partialsCount) def=\(def)] \(txt)")
                }
                client.onConnectionFallbackNeeded = { reason in
                    print("  [failover] \(reason)")
                }
                client.startSession(
                    apiKey: speechKey,
                    hotwords: ["DeepSeek", "SwiftUI", AppBrand.name, "SEO"],
                    dialogContext: ["我们刚刚确认了门店开放时间与海外 SEO 计划"]
                )
                // Wait 120ms for TLS+WS upgrade just like user starting to speak after pressing Fn, then stream at real-time 100ms cadence
                try? await Task.sleep(nanoseconds: 120_000_000)

                // Stream in realistic 100ms (1600-sample) slices at 95ms real-time mic cadence
                let step = 1600
                var idx = 0
                while idx < pcm16.count {
                    let end = min(pcm16.count, idx + step)
                    client.appendPCM16Samples(Array(pcm16[idx..<end]))
                    idx = end
                    try? await Task.sleep(nanoseconds: 95_000_000)
                }
                let tFin0 = DispatchTime.now().uptimeNanoseconds
                let cloudText = await client.finishAndAwaitFinalTranscript(timeoutMs: 1200) ?? ""
                let finTailMs = (DispatchTime.now().uptimeNanoseconds - tFin0) / 1_000_000
                if cloudText.isEmpty {
                    print("  ✗ [Cloud Primary] Seed-ASR 2.0 returned empty transcript")
                    exitStatus = 1
                } else {
                    print("  ✓ [Cloud Primary] Volcengine Seed-ASR 2.0 (volc.seedasr.sauc.duration): handshake_rtt=\(probeRtt)ms, tail_finalize=\(finTailMs)ms, streaming_frames=\(partialsCount) -> 「\(cloudText)」")
                }
            } catch {
                print("  ✗ [Cloud Primary] Seed-ASR 2.0 error: \(error.localizedDescription)")
                exitStatus = 1
            }
            finishedFlag = true
        }
        while !finishedFlag {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return exitStatus
    }

    /// Scientific A/B verification on natural spoken Mandarin+English WAV (`Nevertype --ab-verify <wav>`).
    public static func runEmpiricalABVerification(wavPath: String) -> Int32 {
        let wavURL = URL(fileURLWithPath: wavPath)
        guard let audioFile = try? AVAudioFile(forReading: wavURL) else {
            print("  ✗ Could not read \(wavPath)")
            return 1
        }
        let fmt = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount),
              (try? audioFile.read(into: buf)) != nil,
              let ch0 = buf.floatChannelData?[0] else {
            return 1
        }
        let floatSamples = Array(UnsafeBufferPointer(start: ch0, count: Int(buf.frameLength)))
        var pcm16 = StreamingASREngine.resampleFloatTo16kHzInt16(floatSamples, sourceRate: fmt.sampleRate)
        // Trim leading TTS silence so `first_char` measures true speech-onset -> first-character latency!
        if let firstVoiceIdx = pcm16.firstIndex(where: { abs(Int($0)) > 650 }), firstVoiceIdx > 800 {
            pcm16.removeFirst(firstVoiceIdx - 480) // keep 30ms natural pre-roll
        }

        let speechKey = KeychainHelper.loadVolcSpeechAPIKey()
        guard !speechKey.isEmpty else {
            print("  ✗ Speech key empty")
            return 1
        }

        // Load user's actual local hotwords from Application Support (never printed to logs, only test output checked)
        let store = PersonalLexiconStore()
        let rankedHotwords = store.topAcousticContextualStrings(contextHint: "海外 SEO 投放增长", limit: 65)

        var done = false
        Task {
            // Shared client so TLS session ticket reuse is tested realistically across utterances!
            let sharedClient = VolcSeedASRClient()
            sharedClient.prewarmStandbySocket(apiKey: speechKey)
            try? await Task.sleep(nanoseconds: 250_000_000)

            func runCase(
                title: String,
                useColdClient: Bool,
                hotwords: [String],
                dialogCtx: [String],
                enableDDC: Bool,
                enableNonstream: Bool
            ) async -> String {
                let client = useColdClient ? VolcSeedASRClient() : sharedClient
                var firstCharMs: UInt64 = 0
                var firstPreview = ""
                var streamUpdates = 0
                let sessionStartNs = DispatchTime.now().uptimeNanoseconds

                client.onStreamingTranscript = { txt, _ in
                    streamUpdates += 1
                    if firstCharMs == 0 && !txt.isEmpty {
                        firstCharMs = (DispatchTime.now().uptimeNanoseconds - sessionStartNs) / 1_000_000
                        firstPreview = txt
                    }
                }
                client.startSession(
                    apiKey: speechKey,
                    hotwords: hotwords,
                    dialogContext: dialogCtx,
                    enableDDC: enableDDC,
                    enableNonstream: enableNonstream
                )

                // Feed 60ms slices at realistic 60ms microphone cadence immediately at t=0ms
                let step = 960
                var idx = 0
                while idx < pcm16.count {
                    let end = min(pcm16.count, idx + step)
                    client.appendPCM16Samples(Array(pcm16[idx..<end]))
                    idx = end
                    try? await Task.sleep(nanoseconds: 58_000_000)
                }

                let finStartNs = DispatchTime.now().uptimeNanoseconds
                let finalOut = await client.finishAndAwaitFinalTranscript(timeoutMs: 950) ?? "(nil)"
                let tailMs = (DispatchTime.now().uptimeNanoseconds - finStartNs) / 1_000_000
                print("  [\(title)] first_char=\(firstCharMs)ms (「\(firstPreview)」) | updates=\(streamUpdates) | tail_fin=\(tailMs)ms | final=「\(finalOut)」")
                return finalOut
            }

            let dynSampleCtx = ["正在讨论美国与日本的 SEO 增长以及 \(rankedHotwords.prefix(4).joined(separator: "、")) 项目进度"]
            print("==> Running Empirical A/B Verification (Loaded Lexicon=\(store.entries.count) terms, TopHotwords=\(rankedHotwords.count))...")
            _ = await runCase(title: "1: Bare (No Hotwords)", useColdClient: true, hotwords: [], dialogCtx: [], enableDDC: false, enableNonstream: false)
            let outHotOnly = await runCase(title: "2: WarmTLS + Hotwords ONLY", useColdClient: false, hotwords: rankedHotwords, dialogCtx: [], enableDDC: false, enableNonstream: false)
            let outBoth = await runCase(title: "3: WarmTLS + Hotwords + DialogCtx", useColdClient: false, hotwords: rankedHotwords, dialogCtx: dynSampleCtx, enableDDC: false, enableNonstream: false)

            // End-to-End Pass 1 Instant Dict + Pass 2 DeepSeek 4 Flash Polish
            let chosenRaw = outHotOnly.isEmpty ? outBoth : outHotOnly
            let pass1Instant = PolishEngine.applyInstantLocalDictionary(chosenRaw, entries: store.entries, context: .empty, config: .default, stripPeriod: false)
            let dsKey = KeychainHelper.loadAPIKey(for: "https://api.deepseek.com/v1")
            if !dsKey.isEmpty {
                let polishEngine = PolishEngine()
                polishEngine.prewarmConnection(baseURL: "https://api.deepseek.com/v1", apiKey: dsKey)
                try? await Task.sleep(nanoseconds: 150_000_000)
                let recalled = store.recallRelevantTerms(for: chosenRaw, activeWindowTitle: "", limit: 26)
                let (polished, ttftMs, _) = await polishEngine.polish(
                    rawTranscript: chosenRaw,
                    mode: .dictate,
                    screenContext: .empty,
                    recalledTerms: recalled,
                    recentOutputs: [],
                    config: .default,
                    apiKey: dsKey,
                    isHighAccuracyLocalASR: true
                )
                print("  [E2E Pass1 Instant] 「\(pass1Instant)」")
                print("  [E2E Pass2 DeepSeek TTFT=\(ttftMs)ms] 「\(polished)」")
            }
            done = true
        }

        while !done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.015))
        }
        return 0
    }
}

/// Synthetic audio for the speaking-time self-tests (`SelfTestSuite` and `TypelessImportSelfTests`): a 440 Hz tone stands for
/// speech and faint noise, the same on every run, for the quiet room. The levels are far enough apart (about 50 dB) that frames
/// never land near the +13 dB threshold, so the expected speaking times are exact to a frame.
enum SpeakingTestAudio {
    static let sampleRate = 48_000.0

    /// `seconds` of a 440 Hz sine with the given peak `amplitude` (about -13.5 dBFS rms at 0.3).
    static func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int((seconds * sampleRate).rounded())
        return (0..<count).map { Float(Double(amplitude) * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    }

    /// `samples` samples of faint noise, uniform in +-`amplitude` (about -64 dBFS rms at 0.001). The same `seed` gives the same noise.
    static func hiss(samples count: Int, amplitude: Float = 0.001, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * (Float((state >> 40) & 0xFFFF) / 32_767.5 - 1)
        }
    }

    static func hiss(_ seconds: Double, amplitude: Float = 0.001, seed: UInt64 = 1) -> [Float] {
        hiss(samples: Int((seconds * sampleRate).rounded()), amplitude: amplitude, seed: seed)
    }

    /// `seconds` of digital silence: every sample exactly zero.
    static func zeros(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int((seconds * sampleRate).rounded()))
    }

    /// `seconds` of a 440 Hz tone, with no silence in it, whose level swings sinusoidally by +-`swingDB` around its mean (-20 dBFS
    /// peak) `hertz` times a second: a stand-in for speech without pauses. The swing is in dB, so it is `2 * swingDB` from trough to peak.
    static func swing(seconds: Double, hertz: Double, swingDB: Double) -> [Float] {
        let count = Int((seconds * sampleRate).rounded())
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let amplitude = 0.1 * pow(10, swingDB * sin(2 * Double.pi * hertz * time) / 20)
            return Float(amplitude * sin(2 * Double.pi * 440 * time))
        }
    }

    /// Writes `samples` as a mono 32-bit float WAV file. Every sample is stored exactly, so measuring the file gives the same
    /// answer as measuring the samples. False when the file could not be written.
    static func writeWAV(_ samples: [Float], to url: URL) -> Bool {
        write(samples, to: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
    }

    /// Writes `samples` as mono AAC in a CAF file (a compressed format, so its length is an estimate). False when it could not be written.
    static func writeAAC(_ samples: [Float], to url: URL) -> Bool {
        write(samples, to: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
    }

    private static func write(_ samples: [Float], to url: URL, settings: [String: Any]) -> Bool {
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        return (try? file.write(from: buffer)) != nil
    }
}
