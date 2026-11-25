# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting. Do not open a public issue or pull request for a security problem.

1. Open the [Security tab](https://github.com/zczhuang/Nevertype/security) of the repository.
2. Choose **Report a vulnerability**.
3. Describe the problem. Include the Nevertype version, your macOS version and the steps to reproduce it.

Nevertype is an independent project, so replies are best effort. If you cannot use private reporting, open an issue that says you have a security report, and leave out the details. A maintainer will arrange a private channel.

## Supported versions

Security fixes go into the latest release.

## What Nevertype does with your data

This is the intended behavior. A report that shows Nevertype doing something else is in scope.

- Audio is processed on the Mac by the speech model. Nevertype does not save recordings. Until a speech model is installed, dictation uses macOS on-device speech recognition: the request is marked on-device only. If macOS cannot recognize speech on-device for the language, dictation stops with a message; it never falls back to server recognition.
- Text goes to the cleanup endpoint you configure. The default is Ollama on `127.0.0.1`. A request holds the transcript, an app-type label, a short excerpt before the cursor, the end of the last two dictations and some dictionary entries (those matching what you said or the window title, always-prioritized ones, and the top ones when few match).
- Cloud providers, for cleanup or for speech, are optional. They are used only when you add your own API key and choose them. A cloud speech engine also receives a short list of the highest-ranked dictionary terms as recognition hints. If the clipboard holds a single word of up to 14 characters when a dictation starts, that word is one of the hints.
- API keys are stored in the macOS Keychain.
- History, dictionary and settings are plain files in `~/Library/Application Support/Nevertype`.
- Apart from the cleanup endpoint and any cloud provider you set up, the only network connection is the speech model download from the sherpa-onnx GitHub release. It is checked against a pinned SHA-256 checksum. The build script checks the sherpa-onnx runtime it downloads in the same way.
- There is no account, no telemetry and no automatic update check.
- The Typeless import is off by default. Settings offers it only when `~/Library/Application Support/Typeless/typeless.db` exists. While it is off, Nevertype does not open that file; it only checks that the file exists. After you turn it on, Nevertype opens the database read-only (or reads a temporary copy, which it deletes) and never writes to it. The developer flag `--typeless-import-dry-run` reads the database only when you run it yourself from a terminal.
- Dictionary imports run only when you choose them on the Dictionary page. "Learn terms from browser history" copies the first history file it finds (Chrome, then Arc, then Safari) to a temporary file, reads only the page titles from the copy (up to 500), deletes the copy, and adds up to 60 recurring words or short phrases from the titles to the dictionary. Titles and URLs are not stored and the import sends nothing anywhere, but the added terms are ordinary dictionary entries, so they can reach the cleanup endpoint or a cloud speech engine like any other entry. Importing from a notes folder reads the `.md`, `.txt` and `.csv` files in the folder you pick on the Mac and keeps terms, not text. Pasting text with "Extract with AI" sends that text to the cleanup endpoint.
- Nevertype needs Microphone and Accessibility permission. Accessibility lets it type into other apps, check whether a text field has focus and read the focused text field. Speech Recognition permission is needed only for the macOS on-device fallback.

## Scope

In scope:

- Ways to read or leak dictation text, history or API keys.
- Network requests other than those listed above.
- Weaknesses in how models or the runtime are downloaded, verified or unpacked.
- Ways for another app, or crafted input, to abuse Nevertype's Microphone or Accessibility access.

Out of scope:

- Problems in Ollama, sherpa-onnx, ONNX Runtime or a cloud provider. Report those to their own projects.
- Attacks that need a Mac that is already compromised, or physical access to an unlocked Mac.
