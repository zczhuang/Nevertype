# Third-party notices

Nevertype is released under the MIT License (see [LICENSE](LICENSE)). It is built on, bundles or downloads the components below. Each component stays under its own license.

| Component | Role in Nevertype | License | Link |
| --- | --- | --- | --- |
| TypeZero v0.5.8 | The project Nevertype is forked from. Most of the source code comes from it. | MIT | https://github.com/nasadunadu/TypeZero |
| sherpa-onnx | Runs the speech models. Bundled in the app as `libsherpa-onnx-c-api.dylib`. This repository also contains its C API header. | Apache-2.0 ([text](licenses/sherpa-onnx-LICENSE.txt)) | https://github.com/k2-fsa/sherpa-onnx |
| ONNX Runtime | Inference engine inside the sherpa-onnx libraries. Bundled in the app as `libonnxruntime.dylib`. | MIT ([text](licenses/onnxruntime-LICENSE.txt)) | https://onnxruntime.ai |
| NVIDIA Parakeet TDT 0.6B v2 | Default speech model (English, int8). Downloaded by the app. Not distributed with Nevertype. | CC-BY-4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 |
| SenseVoice | Optional speech model for Chinese, English, Japanese, Korean and Cantonese. Downloaded by the app on request. Not distributed with Nevertype. | Its own model license | https://github.com/FunAudioLLM/SenseVoice |

## Details

### TypeZero

MIT License. Copyright (c) 2026 TypeZero Contributors. The notice is kept in [LICENSE](LICENSE), as the MIT License requires, together with Nevertype's own copyright line.

### sherpa-onnx and ONNX Runtime

Nevertype loads sherpa-onnx (Apache-2.0) and ONNX Runtime (MIT) as shared libraries. `scripts/setup-vendor.sh`, which `scripts/build-app.sh` runs when needed, downloads them from the sherpa-onnx GitHub release into `Vendor/`, which is not committed. `scripts/build-app.sh` copies them into `Nevertype.app/Contents/Frameworks`.

`Sources/CSherpaOnnx/c-api-internal/c-api.h` is the sherpa-onnx C API header. It carries the notice "Copyright (c) 2023 Xiaomi Corporation" and is licensed under Apache-2.0.

The license texts are in [`licenses/`](licenses): `sherpa-onnx-LICENSE.txt` (the Apache License 2.0) and `onnxruntime-LICENSE.txt` (the MIT License, "Copyright (c) Microsoft Corporation"). `sherpa-onnx-LICENSE.txt` covers both the bundled sherpa-onnx library and the C API header above, which is part of this repository. `scripts/build-app.sh` copies `LICENSE`, this file and everything in `licenses/` into `Nevertype.app/Contents/Resources/Licenses/` before it signs the app, so every build, and the DMG made from it, carries them (the texts sit next to this file there). The sherpa-onnx release archive and project repository list further notices that apply to the code built into those libraries.

### NVIDIA Parakeet TDT 0.6B v2

The model is by NVIDIA and is licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). The app downloads the int8 ONNX conversion that the sherpa-onnx project publishes with its releases, and uses it as downloaded. Nevertype does not redistribute the model.

### SenseVoice

The model is optional. The app downloads it from the sherpa-onnx release only when you ask for it. Its weights are under the SenseVoice model license. Read the license in the SenseVoice repository and on the model card before you use it. Nevertype does not redistribute the model.

### Cleanup model

Nevertype does not include or distribute a cleanup model. By default it calls a model that you pull yourself through Ollama (`gemma4:12b-mlx`). That model's own license and terms of use apply to you. Ollama and any cloud provider you set up are separate services with their own terms.
