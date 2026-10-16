# Third-party notices

COS Control includes code from the following projects. Their licenses ship in the app at
`COS Control.app/Contents/Resources/ThirdParty/`.

## PermissionFlow

- https://github.com/jaywcjlove/PermissionFlow, commit cb96db4b
- MIT License, Copyright (c) 2026 小弟调调
- Used in: `Sources/PermissionFlowVendored.swift` (the System Settings window tracker, the floating helper panel and
  the app drag source behind the permission guide). Details: `Resources/ThirdParty/PermissionFlow/ATTRIBUTION.md`.

## FluidAudio (bundled command line tool)

- https://github.com/FluidInference/FluidAudio, tag v0.17.4, commit 21493f8d
- Apache License 2.0. Its statically linked components (fastcluster, NeMo text processing, VBx, text frontends) keep
  their own licenses, all in `Resources/ThirdParty/FluidAudio/`.
- Used as: `COS Control.app/Contents/Helpers/fluidaudiocli`, built unmodified by `scripts/build-fluidaudio-cli.sh`
  and signed by COS. Details: `Resources/ThirdParty/FluidAudio/ATTRIBUTION.md`.

## Parakeet Ultra speech model (downloaded when you install Parakeet)

- https://huggingface.co/FluidInference/parakeet-ultra-coreml, revision 95eaa59a
- CC BY 4.0. A Core ML build by FluidInference of moondream/parakeet-ultra, itself a post-training of NVIDIA's
  parakeet-tdt-0.6b-v3. Not bundled in the app and not modified by COS.
