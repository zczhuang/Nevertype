# Contributing to Nevertype

Thanks for your interest. Bug reports, fixes and small features are welcome.

- Open an issue first for anything larger than a small fix, so we can agree on the approach.
- Report security problems privately. See [SECURITY.md](SECURITY.md).

## Set up

You need an Apple Silicon Mac on macOS 14 or later, and Xcode 16 or later (or the matching Command Line Tools) for Swift 6.0 or later.

```bash
git clone https://github.com/zczhuang/Nevertype.git
cd Nevertype
./scripts/setup-vendor.sh   # fetches the sherpa-onnx runtime into Vendor/
./scripts/run-tests.sh      # builds a release binary and runs the self-tests
./scripts/build-app.sh      # builds build/Nevertype.app
open build/Nevertype.app
```

`setup-vendor.sh` checks the runtime against a pinned SHA-256 checksum. `build-app.sh` runs it for you when the runtime is missing, so you can skip that step if you only want the app. It fetches only the runtime: the app downloads its own speech models. To test other languages you can also fetch the SenseVoice model (about 890 MB) into `~/Library/Application Support/Nevertype/Models` with `DOWNLOAD_SENSEVOICE=1 ./scripts/setup-vendor.sh`. `Vendor/` and `build/` are not committed.

The app also needs Ollama and the `gemma4:12b-mlx` model for cleanup. See the [README](README.md#setup).

### Release builds

`./scripts/package-dmg.sh` is for maintainers. It builds the app, runs its self-tests, and packages `dist/Nevertype-v<version>-macOS-arm64.dmg`. If a Developer ID certificate is in the keychain, it signs the DMG. It then notarizes the DMG with a `notarytool` keychain profile (`NevertypeNotary` by default, or set `NOTARY_PROFILE`) and stops with an error if there is no profile. Set `ALLOW_UNNOTARIZED=1` to skip notarization for a local test build.

The license texts ship with every build. `build-app.sh` copies `LICENSE`, `THIRD_PARTY_NOTICES.md` and everything in `licenses/` into `Nevertype.app/Contents/Resources/Licenses/` before it signs the app, so the app, and the DMG made from it, carry them. If you bundle another third-party component, add its license text to `licenses/` and list it in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Command-line flags

For development, the app binary has headless modes that do not start the app or register a shortcut:

- `--self-test` runs every test suite (what `run-tests.sh` runs).
- `--render-ui <dir>` draws each page of the window to PNG files, with sample data, in a throw-away home folder.
- `--dictate-file <file.wav>` runs a recording through the speech model and the cleanup model and prints both results. It calls the configured cleanup endpoint: a warm-up, then one cleanup request.
- `--typeless-import-dry-run` prints counts (no text) from the Typeless database, read-only. It ignores the import switch in Settings, because you run it yourself.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/TypeZero/Audio` | Microphone capture, speech engines, speech model download |
| `Sources/TypeZero/Core` | App state, models, settings, self-tests, Typeless import |
| `Sources/TypeZero/LLM` | Cleanup engine and its prompts |
| `Sources/TypeZero/Lexicon` | Personal dictionary |
| `Sources/TypeZero/System` | Shortcuts, typing into other apps, screen context |
| `Sources/TypeZero/UI` | SwiftUI interface and the floating pill |
| `Sources/CSherpaOnnx` | C bridge to sherpa-onnx |
| `scripts` | Build, test and icon scripts |
| `licenses` | License texts of sherpa-onnx and ONNX Runtime, bundled into the app |

The Swift module is still called `TypeZero`. The app bundle is `Nevertype.app`.

## Guidelines

1. **Keep it local-first.** No telemetry, accounts or analytics. Discuss any new network connection in an issue first. Anything that sends data off the Mac must be opt-in and listed in the Privacy section of the README.
2. **Keep secrets out.** Never commit API keys, `.env` files, dictation history, personal dictionary files or machine-specific paths. Keys belong in the macOS Keychain.
3. **Tests and warnings.** The build must not produce new compiler warnings, and `./scripts/run-tests.sh` must pass. Add tests for your change in `Sources/TypeZero/Core/SelfTestSuite.swift`. Interface helpers are tested in `Sources/TypeZero/UI/TZUISelfTests.swift` and the Typeless import in `Sources/TypeZero/Core/TypelessImportSelfTests.swift`.
4. **Keep the main thread free.** Do not block it with audio or Accessibility calls. The pill and live typing need to stay smooth.
5. **One change per pull request.** Say what changed and how you tested it. Update the README in the same pull request if you change documented behavior.

## Licensing

By contributing, you agree that your contribution is licensed under the project's [MIT License](LICENSE). If you add a third-party component, add it to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), with its license text in `licenses/` if the app bundles or contains it.
