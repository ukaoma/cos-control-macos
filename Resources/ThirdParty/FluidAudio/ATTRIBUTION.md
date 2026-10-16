# FluidAudio command line tool (bundled)

- Upstream: https://github.com/FluidInference/FluidAudio
- License: Apache License 2.0 (LICENSE in this folder, copied unchanged). Upstream ships no NOTICE file.
- Pinned source: tag v0.17.4, commit 21493f8dac5a97e65742e6ff26f42f164c2fda0f (Resources/fluidaudio-cli.json)
- Statically linked components, each with its license in this folder as upstream ships it: fastcluster, NeMo text
  processing (text-processing-rs, a prebuilt xcframework pinned by checksum in upstream's Package.swift), VBx, and the
  Japanese and Spanish/French text frontends.

## What COS Control ships

`COS Control.app/Contents/Helpers/fluidaudiocli` is upstream's `fluidaudiocli` product built unmodified from the
pinned commit by `scripts/build-fluidaudio-cli.sh` (`swift build -c release --product fluidaudiocli`). The only
addition is an Info.plist linked into the binary's `__TEXT,__info_plist` section (identifier
`com.gotcos.control.fluidaudiocli`, version 0.17.4, the source commit), because 0.17.4 has no version command. COS
Control signs it with its Developer ID and the hardened runtime, and it is notarized with the app.

COS's glasses server runs it for Parakeet Ultra transcription and speaker separation, always with a local model
folder, inside a sandbox, with no network access.

## Speech model (downloaded, not bundled)

Installing Parakeet downloads the Parakeet Ultra Core ML model from Hugging Face at a pinned revision, each file
checked by SHA-256:

- FluidInference/parakeet-ultra-coreml (https://huggingface.co/FluidInference/parakeet-ultra-coreml), revision
  95eaa59a39d4394f047a4dc5cce480388a60d1b6, licensed CC BY 4.0
  (https://creativecommons.org/licenses/by/4.0/). A Core ML build of moondream/parakeet-ultra, a post-training of
  NVIDIA's parakeet-tdt-0.6b-v3. Converted by FluidInference; not modified by COS.
