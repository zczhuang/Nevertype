# Nevertype

Voice typing for macOS that runs on your Mac. Hold or tap a key, speak, and cleaned-up text is typed where your cursor is, in any app.

Nevertype is a fork of [TypeZero](https://github.com/nasadunadu/TypeZero) v0.5.8 by nasadunadu, released under the MIT license. By default, speech recognition runs on the Mac and text cleanup uses a local model through Ollama. There is no account, no telemetry and no automatic update check.

- Version 0.1.0
- Apple Silicon, macOS 14 or later
- [MIT license](LICENSE)

## How it works

1. **Press your shortcut.** The default is the Fn (Globe) key. Tap it once to start and again to stop. In Settings you can switch to hold-to-talk, or pick another key: Left or Right Option, Command, Control or Shift, Option + Space, or a combination you record yourself. Esc cancels a recording.
2. **Speak.** A small pill near the text field shows a waveform while you talk. By default, Nevertype mutes your speakers while you record and restores the volume when you stop.
3. **Speech to text.** NVIDIA Parakeet TDT 0.6B v2 turns your speech into text on the Mac, through sherpa-onnx.
4. **Cleanup.** The pill shows "Thinking" while a language model tidies the transcript. It removes filler words and false starts. When you correct yourself, it keeps only the final wording. It fixes misheard words with help from your dictionary, adds punctuation, and starts new paragraphs or numbered lists where your speech calls for them. By default the model is `gemma4:12b-mlx`, running in Ollama on your Mac. Short phrases that already read well (under about 28 characters) skip this step.
5. **Typing.** The text is typed into the app you are using. By default the words appear as you speak and are replaced by the cleaned-up text when you stop. A setting changes this to a single paste when you finish. If no text field has focus when the text is ready, Nevertype does not type or paste it, and leaves the clipboard alone. The pill shows a one-line preview of the text and a **Copy** button for 8 seconds. Hover over the pill to pause the countdown. Click Copy to put the text on the clipboard; the pill then says "Copied". The text is saved to History whether or not you click Copy.

If the cleanup model cannot be reached, Nevertype inserts the raw transcript and shows a warning.

### Rewrite selection

Select some text, then start dictating. Your speech is treated as an instruction for that text, for example "make this shorter" or "change Tuesday to Wednesday". The result replaces the selection.

### Formatting styles

Settings → Output → Formatting style:

- **Structured** (default). Fixes grammar and organizes what you said into paragraphs and numbered lists.
- **Light.** Removes filler words and fixes typos, but keeps your sentences as spoken.
- **Verbatim.** Calls no cleanup model. Your words are inserted as transcribed, with dictionary fixes only.

### The app window

Nevertype lives in the menu bar. Its window has four pages:

- **Home.** Totals for words dictated, time saved, average speed and dictation time, a calendar of your activity, the apps you dictate into most, and a box where you can try dictation. Average speed counts only the time you were speaking: pauses of 0.3 seconds or more are left out. Dictations saved before Nevertype measured speaking time have none, and once newer ones have it, the older ones are not part of the speed.
- **History.** Your latest 1,000 dictations, with the raw transcript available for each one. They are kept on your Mac.
- **Dictionary.** Names and terms you say often, plus the forms they are often misheard as. Add them by hand, import them from pasted text, a notes folder or your browser's page titles (see [Privacy](#privacy)), or let Nevertype learn from the corrections you make.
- **Settings.** Speech model, cleanup model, shortcut, output options and permissions.

## Requirements

- A Mac with Apple Silicon (M1 or later) running macOS 14 (Sonoma) or later.
- Microphone and Accessibility permission. Accessibility lets Nevertype type into other apps and read the text field you are using.
- About 480 MB of free disk space for the default speech model, and about 890 MB more if you add SenseVoice.
- For the default cleanup setup: [Ollama](https://ollama.com) and the `gemma4:12b-mlx` model.
- To build from source: Xcode 16 or later, or the matching Command Line Tools (Swift 6.0 or later).

## Setup

1. **Get the app.** Build it from source. See [Building](#building).
2. **Install Ollama** from [ollama.com](https://ollama.com) and start it.
3. **Pull the cleanup model.**

   ```bash
   ollama pull gemma4:12b-mlx
   ```

   Nevertype sends cleanup requests to Ollama at `http://127.0.0.1:11434/v1`. It turns the model's thinking mode off. It also asks Ollama to keep the model loaded, so the first dictation after a pause is not slow. Ollama then holds the model in memory until Ollama quits.
4. **Open Nevertype.** The setup guide has three steps: grant Microphone and Accessibility permission, choose your speech and cleanup engines, and pick a shortcut and download the speech model. The speech model (about 480 MB) comes from the sherpa-onnx release on GitHub and is checked against a pinned SHA-256 checksum.
5. **Try it.** Click into any text field, press the shortcut, speak, and press it again.

**Other cleanup models.** In Settings → Cleanup model, you can point Nevertype at any OpenAI-compatible endpoint, such as another local server or SiliconFlow. You can also choose a cloud provider and add your own API key: OpenAI, Anthropic, Gemini, DeepSeek, Volcengine or DashScope. Keys are stored in the macOS Keychain.

**Other languages.** The default speech model is English only. For Chinese, English, Japanese, Korean or Cantonese, download SenseVoice (about 890 MB) in Settings → Speech recognition. The cleanup instructions are written for English.

### Troubleshooting

- **The Fn (Globe) key opens the emoji picker or another macOS action.** In System Settings → Keyboard, set the Globe key action to Do Nothing. Or pick a different shortcut in Nevertype.
- **Nothing is typed.** Check that Nevertype is switched on in System Settings → Privacy & Security → Accessibility. A build with an ad hoc signature looks like a new app to macOS after every rebuild. In Nevertype, Settings → Permissions → Reset Accessibility cache clears the old entry.
- **The Copy pill appears even though you are in a text field.** Some apps do not report their text fields to Accessibility, so Nevertype cannot tell that one has focus. Click Copy and paste with ⌘V, then open an issue that names the app. Include the last `focusCheck` line from `injection-trace.log` (in `~/Library/Application Support/Nevertype`). It shows the kind of element Nevertype saw, and it contains no text.
- **You get the raw transcript and a warning.** The cleanup model could not be reached. Check that Ollama is running and that you pulled the model.

## Building

```bash
git clone https://github.com/zczhuang/Nevertype.git
cd Nevertype
./scripts/build-app.sh
open build/Nevertype.app
```

`scripts/build-app.sh`:

- fetches the sherpa-onnx runtime into `Vendor/` if it is not there yet, and checks it against a pinned SHA-256 checksum;
- builds a release binary with Swift Package Manager;
- assembles `build/Nevertype.app`, with the sherpa-onnx and ONNX Runtime libraries inside, and the license texts in `Contents/Resources/Licenses`;
- signs the app with an Apple Development (or Developer ID) identity if one is in your keychain, and ad hoc otherwise.

`Vendor/` and `build/` are not committed. The build does not download a speech model. The app does that itself.

To run the tests:

```bash
./scripts/run-tests.sh
```

This builds a release binary and runs it with `--self-test`. That runs the built-in test suites: core logic (dictionary matching, cleanup rules, settings, model download), the interface helpers and the Typeless import. The tests use temporary files and fixtures. They need no microphone and no running Ollama. They do need the sherpa-onnx runtime in `Vendor/`. If you have not built the app yet, fetch it first with `./scripts/setup-vendor.sh`.

## Privacy

Audio and text stay on your Mac unless you choose a cloud provider.

- **Speech.** The speech model runs on your Mac, and Nevertype does not save recordings. Until a speech model is installed, dictation uses macOS's own on-device speech recognition, which also stays on your Mac. Nevertype asks macOS for on-device recognition only. If macOS cannot do that for your language, dictation stops with a message to download a speech model in Settings. It never switches to server recognition.
- **Cleanup.** The transcript goes to the cleanup endpoint you configure. The default is Ollama on `127.0.0.1`, which is your own Mac. A cleanup request contains the transcript, a label for the kind of app you are typing in (chat, email, terminal or notes), a short excerpt of the text before your cursor, the end of your last two dictations, and some of your dictionary entries: the ones that match what you said or the title of the window you are in, your always-prioritized words, and your highest-priority entries when few match. For Rewrite selection it contains the selected text and your spoken instruction instead of the excerpt. If you import dictionary words from pasted text with the cleanup model, that text goes to the endpoint too.
- **Cloud providers.** They are optional. If you add a key and choose a provider, the data for that feature goes to it: the cleanup request for a cleanup provider, or your audio for a cloud speech engine (OpenAI, Groq or Volcengine), together with a short list of recognition hints. The hints are your highest-ranked dictionary terms, plus up to 12 acronyms and capitalized words taken from the name of the app you are using, your last two dictations and, when you dictate in Nevertype's own window, the text in its Try it here box. The hints never include clipboard text. Volcengine also receives context: the last 100 characters of each of your last two dictations. When you dictate in Nevertype's own window and the Try it here box on the Home page has text, the last 100 characters of that text take the place of the older dictation. The provider's terms apply. Your key is stored in the macOS Keychain.
- **Dictionary imports.** Each one runs only when you choose it from the menu on the Dictionary page. Importing from a notes folder reads the `.md`, `.txt` and `.csv` files in the folder you pick (up to 400) on your Mac, and keeps up to 120 names and terms that repeat, not the text. Pasting text with "Extract with AI" is the import described under Cleanup. Learning from browser history is described next.
- **Browser history.** "Learn terms from browser history" never runs by itself. It uses the first history file it finds, in this order: Chrome (Default profile), Arc (Default profile), Safari. It copies that file to a temporary file, reads only the page titles from the copy (up to 500: the pages you visited at least twice, most visited first, in Chrome and Arc, or the most recent visits in Safari), and deletes the copy. From the titles it keeps up to 60 words and short phrases that appear in at least two of them, skipping a short list of generic site names, and adds them to your dictionary under "Frequent sites". Titles and URLs are not stored. The import itself sends nothing anywhere. The added terms are ordinary dictionary entries in `lexicon.json`: you can delete them on the Dictionary page, and, like any entry, a term can go to the cleanup endpoint when it matches what you say, or to a cloud speech engine as a hint. macOS may block access to Safari's history, and Nevertype does not ask for Full Disk Access.
- **Network.** Apart from the cleanup endpoint and any cloud provider you set up, the only connection Nevertype makes is the speech model download from GitHub. There is no account, no telemetry and no automatic update check. New versions are published on the project's [Releases](https://github.com/zczhuang/Nevertype/releases) page.
- **On disk.** Your history (the latest 1,000 dictations), dictionary, settings and downloaded speech models live in `~/Library/Application Support/Nevertype`. They are plain files. A small debug log, `injection-trace.log`, records app bundle IDs, text lengths and the kind of element that had focus (its accessibility role and flags), never your text or page addresses. Delete the folder to remove everything, or use Clear history on the History page. API keys are in the Keychain, not in that folder.
- **Clipboard.** To paste text, Nevertype copies it to the clipboard and then restores what was there before. It also writes to the clipboard when you click Copy, for example on the pill. If no text field has focus, it does not change the clipboard. Nevertype reads the clipboard when a dictation starts only if the speech engine runs on this Mac: the local speech model, macOS on-device recognition or an OpenAI-compatible server on this Mac. If it then holds one line of up to 42 characters, Nevertype uses that line to pick hints: dictionary terms that appear in it rank higher, and its acronyms and capitalized words can become hints themselves. A single word of up to 14 characters becomes a hint. With a cloud speech engine, Nevertype does not read the clipboard, so no clipboard text goes to the provider. It ignores clipboard contents that password managers and similar apps mark as concealed or transient.
- **Permissions.** Microphone, to hear you. Accessibility, to type into other apps, to check whether a text field has focus and to read the focused text field: the selected text, the text before your cursor and, if "Learn from my corrections" is on, the fixes you make right after dictating. The focus check reads the role of the focused element and, in browsers and Electron apps, the page address, only to recognize Google Docs. The address is not saved or logged. Speech Recognition, only when no speech model is installed and dictation uses macOS's recognizer.

## Importing from Typeless

If Typeless is installed on this Mac, Nevertype can copy your past dictations into its History. This is off until you turn it on.

- **Turning it on.** When `~/Library/Application Support/Typeless/typeless.db` exists, Settings shows **Import history from Typeless** in an Import section. Turning it on imports your past dictations right away. After that, Nevertype checks for new ones when it starts and when you open History, and the menu on the History page gets **Sync from Typeless** for a manual sync. Turning it off stops all of this.
- **While it is off,** Nevertype does not open the Typeless database or its recordings. It only checks that the database file exists, to decide whether to show the switch.
- It reads the database read-only and never writes to it. If the database cannot be opened read-only, for example because it is locked, Nevertype reads a temporary copy and deletes the copy afterwards.
- Only finished voice dictations that have text are imported: the text, the length of the recording and the date.
- **Speaking time.** Besides the text, the length of the recording and the date, Nevertype measures how long you spoke in each dictation, from Typeless's recording of it in `~/Library/Application Support/Typeless/Recordings`. It reads the file on your Mac, read-only, and never copies, keeps or sends the audio. If a recording is missing or macOS cannot read it, the dictation is still imported, without a speaking time. Dictations imported before Nevertype measured speaking time get it at the next sync.
- Each dictation is imported once. If you delete an imported dictation in Nevertype, it does not come back.
- Imported entries show "Typeless" as their app in History.

## Differences from TypeZero

- Speech recognition and cleanup default to local models (Parakeet and Ollama).
- The interface and the cleanup instructions are in English.
- It can import your dictation history from Typeless, if you turn that on.
- When no text field has focus, a Copy pill replaces the clipboard fallback: the text is offered on the pill and copied only when you click Copy.
- A cloud speech engine never receives clipboard text. Nevertype reads the clipboard as a hint only when speech recognition runs on this Mac, and it skips contents that password managers mark as private.
- The average speed on the Home page counts only the time you were speaking, not the pauses.
- There is no account or sign-in, and no update check. The Windows app, the website and the cloud backend of the original project are not part of this repository.

## Credits

Nevertype builds on the work of others. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the licenses.

- [TypeZero](https://github.com/nasadunadu/TypeZero) by nasadunadu (MIT). Nevertype is a fork of v0.5.8.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0). Runs the speech models.
- [ONNX Runtime](https://onnxruntime.ai) (MIT). Bundled inside the sherpa-onnx libraries.
- [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (CC-BY-4.0). The default speech model.
- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) (under its own model license). The optional multilingual speech model.

The speech models are downloaded by the app from the sherpa-onnx release. The cleanup model is pulled by you through Ollama under its own terms. Nevertype does not distribute any of them.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a vulnerability, use GitHub's private vulnerability reporting. See [SECURITY.md](SECURITY.md).

## License

Nevertype is released under the [MIT License](LICENSE). The license keeps the original TypeZero copyright line and adds Nevertype's.

## Disclaimer

Nevertype is an independent project. It is not affiliated with or endorsed by the TypeZero authors or by Typeless.
