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
            context: ActiveScreenContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: "", selectedText: "", precedingText: "", hasFocusedTextInput: true),
            config: .default
        )
        expect(
            formatted == "使用 DeepSeek 提升 35% 速度",
            "Applies CJK-Latin Pangu spacing, percentage ITN, and strips trailing period in IM"
        )
        let normQ = PolishEngine.applyPostFormattingRules(
            "今天发财报会不会一样? 太好了!",
            context: ActiveScreenContext(appName: "微信", bundleID: "com.tencent.xinwechat", windowTitle: "", selectedText: "", precedingText: "", hasFocusedTextInput: true),
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
            context: ActiveScreenContext(appName: "微信", bundleID: "com.tencent.xinwechat", windowTitle: "", selectedText: "", precedingText: "", hasFocusedTextInput: true),
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
        let wechatCtx = ActiveScreenContext(appName: "微信", bundleID: "com.tencent.xinwechat", windowTitle: "", selectedText: "", precedingText: "", hasFocusedTextInput: true)
        let notesCtx = ActiveScreenContext(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "", selectedText: "", precedingText: "", hasFocusedTextInput: true)
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
