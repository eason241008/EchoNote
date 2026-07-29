<div align="center">

# EchoNote 声译

**让英语课堂变成可检索、可回看、可引用的双语学习资料。**

A native macOS lecture companion for live English transcription, Simplified Chinese translation, timetable planning, evidence-linked notes, and private local archiving.

[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple)](https://www.apple.com/macos/)
[![Tests](https://github.com/eason241008/EchoNote/actions/workflows/swift.yml/badge.svg)](https://github.com/eason241008/EchoNote/actions/workflows/swift.yml)
[![License](https://img.shields.io/github/license/eason241008/EchoNote)](LICENSE)

</div>

> [!IMPORTANT]
> EchoNote is a study tool, not a covert recorder. Obtain consent and follow your institution's rules before recording any class. The app requires an explicit acknowledgement before recording starts.

## Why EchoNote

Fast English lectures are difficult to follow when listening, translating, and taking notes compete for attention. EchoNote keeps those jobs in one native workspace:

- **English-first live captions** powered locally by FluidAudio and Nemotron Streaming.
- **Simplified Chinese translation** performed on-device with Apple's Translation framework.
- **Editable transcript timeline** with revision history instead of destructive text replacement.
- **Evidence-linked study notes** that point back to transcript revisions.
- **Searchable lecture library** with bookmarks, questions, key concepts, and exports.
- **Weekly timetable** imported from a standard ICS subscription, with Melbourne timezone handling.

## Product Tour

| Record | Timetable |
| --- | --- |
| Live waveform, English transcript, Chinese translation, recording controls, and a detachable caption window. | Weekly grid, ICS import/sync, course location, and automatic startup refresh. |

| Library | Settings |
| --- | --- |
| Full-text search across transcripts, translations, notes, and bookmarks; export to Markdown, SRT, JSON, or PDF. | Local model status, retention policy, Apple translation status, timetable URL, storage location, and local data controls. |

## Features

### Live lecture capture

- Explicit preflight checks for microphone permission, selected input device, local model availability, and recording-policy acknowledgement.
- Local 16 kHz audio capture and streaming transcription.
- Partial captions followed by finalized segments; bounded async streams keep capture latency stable.
- Pause, resume, stop, interruption recovery, and persisted session manifests.
- A compact always-on-top caption window for following the lecture while another app is active.

### Bilingual captions

- English ASR remains the source of truth.
- Finalized English utterances are translated to Simplified Chinese on-device.
- Revision-linked batching and ordered output preserve segment alignment.
- Translation failures do not stop local recording or English transcription.

### Lecture library and study evidence

- SQLite-backed sessions, transcript revisions, translations, bookmarks, notes, and search index.
- Manual transcript edits create new revisions; previous text remains auditable.
- Search results include timestamps and source-revision references.
- Notes and exports keep evidence links to the transcript revision used to create them.
- Retention policy supports immediate cleanup, bounded day counts, or indefinite retention.

### Timetable

- Import a local `.ics` file or save an HTTPS ICS subscription URL.
- Recurring events expand into the weekly grid while preserving stable event identity.
- `TZID` values such as `Australia/Melbourne` are respected.
- The last successful calendar remains available offline.

## Requirements

| Requirement | Minimum |
| --- | --- |
| macOS | 15.0 Sequoia |
| Hardware | Apple Silicon recommended |
| Xcode | 16.0 or newer |
| Swift | 5.9 toolchain or newer |
| Disk | About 600 MB for Nemotron Streaming 0.6B, plus recordings |
| Network | Initial dependency/model download, Apple language download, and ICS sync |

EchoNote uses Apple's on-device Translation framework for English-to-Simplified-Chinese captions. Translation content stays on the Mac; the system may ask before downloading the required language models.

EchoNote uses [FluidAudio](https://github.com/FluidInference/FluidAudio) `0.15.5` with the English Nemotron Streaming 0.6B model at the 1120 ms latency tier.

## Quick Start

```bash
git clone https://github.com/eason241008/EchoNote.git
cd EchoNote
swift package resolve
swift build
swift test
swift run EchoNote
```

The first production recording also needs the Nemotron Streaming Core ML model. In the app, open **Settings → Local model** and download it. The model is validated before recording is enabled.

### Build a macOS app bundle

```bash
swift build-app.swift
open dist/EchoNote.app
```

This creates an ad-hoc-signed `dist/EchoNote.app` with the project entitlements. For distribution to other Macs, replace ad-hoc signing with your Developer ID certificate and notarize the bundle.

## Configuration

### 1. Microphone and recording policy

On first use:

1. Allow microphone access when macOS asks.
2. Select an available input device.
3. Read and acknowledge the recording policy.
4. Start a prepared lecture session explicitly.

EchoNote never starts recording merely because the app launches or a scheduled class begins.

### 2. Local speech model

The production pipeline uses English-only `Nemotron Streaming 0.6B`:

- Estimated download: approximately 600 MB.
- Streaming tier: 1120 ms chunks with recurrent encoder state.
- Inference: local Core ML through FluidAudio on the Apple Neural Engine.
- Utterance boundary: 1.2 seconds of silence, pause, or stop.
- Model storage: `~/Library/Application Support/EchoNote/Models/nemotron-streaming/1120ms/`.
- Recording is blocked until model validation succeeds.

The pipeline emits live partial captions without repeatedly decoding prior audio. Only finalized utterances create transcript revisions and enter Apple Translation.
### 3. Apple translation

EchoNote uses the macOS Translation framework for English-to-Simplified-Chinese captions. Translation runs on-device and requires no API key or provider configuration.

On first launch, macOS may ask to download the English and Simplified Chinese language assets. Keep the app open until the settings page reports **Apple local translation ready**.

> [!CAUTION]
> Never commit a private timetable token, recording, or exported lecture data. The repository ignore rules intentionally exclude build output and local environment files, but private data outside ignored paths remains your responsibility.

### 4. Timetable subscription

In **Settings → Timetable subscription**, paste your own HTTPS ICS URL and choose **Save and sync**. You can also import a local `.ics` file from the timetable page.

Subscription URLs can contain private tokens. They remain in local UserDefaults and are not part of this repository.

## Data and Privacy

EchoNote is local-first:

- Audio, manifests, SQLite data, models, and exports live under `~/Library/Application Support/EchoNote/` unless you choose another export location.
- Audio capture and English transcription run on-device.
- Finalized English text is translated on-device by Apple Translation.
- No speech or translation API keys are required.
- ICS sync contacts only the subscription URL you provide.
- No analytics or telemetry client is included.

If an older local build used `~/Library/Application Support/课堂伴侣/`, EchoNote moves that directory to the new data location on first launch when no EchoNote directory exists.

## Architecture

```mermaid
flowchart LR
    Mic[Microphone] --> Capture[AVAudioEngine capture]
    Capture --> Audio[Local session audio]
    Capture --> Nemotron[Nemotron Streaming 1120 ms]
    Nemotron --> Revision[Transcript revisions]
    Revision --> Search[SQLite full-text search]
    Revision --> Translate[Apple on-device translation]
    Translate --> Library[Lecture library]
    Revision --> Library
    ICS[ICS file or subscription] --> Schedule[Weekly timetable]
    Library --> Export[MD / SRT / JSON / PDF]
```

Key boundaries:

- `AVFoundationCapture.swift` — microphone device discovery and audio frames.
- `LiveTranscription.swift` — stateful Nemotron streaming recognition and silence finalization.
- `TranslationPipeline.swift` — ordered, revision-linked Apple translation delivery.
- `LectureDatabase.swift` and repositories — durable SQLite data and migrations.
- `CaptionWorkspace.swift` — independent caption, translation, and display state.
- `Scheduling.swift` and `WeeklyTimetableView.swift` — ICS parsing and timetable UI.
- `AppSurfaceModels.swift` — production library, search, export, and settings models.

## Development

Run the complete suite:

```bash
swift test
```

Run focused suites while iterating:

```bash
swift test --filter LiveTranscriptionTests
swift test --filter TranslationPipelineTests
swift test --filter SchedulingTests
swift test --filter AppSurfaceModelsTests
```

The suite covers database migrations and rollback, session lifecycle, bounded streams, capture timelines, streaming utterance boundaries, translation ordering, ICS recurrence/timezones, search correction, retention, exports, and real microphone/model flow behind environment gates.

Optional hardware/model validation uses environment variables defined by `RealLectureFlowTests.swift`, `RealOfflineTranscriptionTests.swift`, and `RealSpeechModelTests.swift`; it is skipped unless explicitly enabled.

## Current Limitations

- Source speech recognition is English-only in the production path.
- Nemotron Streaming requires Apple Silicon and approximately 600 MB of model storage.
- Speaker diarization is not implemented.
- The repository does not publish a notarized binary yet; build locally with the provided script.
- Recording legality and institutional consent remain the user's responsibility.

## Contributing

Issues and focused pull requests are welcome. Before submitting a change:

1. Keep user data and credentials out of fixtures and logs.
2. Preserve revision history and evidence links when changing transcript behavior.
3. Add or update a behavioral test for observable contract changes.
4. Run `swift build` and `swift test` on macOS 15+ with Xcode 16+.

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device Core ML speech recognition.
- [NVIDIA Nemotron Speech Streaming](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) for the English streaming ASR model.
- Apple Translation framework for on-device English-to-Simplified-Chinese translation.

## License

EchoNote is available under the [MIT License](LICENSE).
