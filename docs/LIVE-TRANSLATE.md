# Live Translate system audio

Live Translate captures the system output mix with a private, unmuted Core Audio
process tap. It does not enumerate displays, capture pixels, or open a microphone.
The tap-only private aggregate has no physical input subdevices. The user's normal
output remains audible. The current process is excluded using its HAL process
object, and a process-list listener updates that exclusion if the object appears
after startup. No app selector is needed for V1.

## Compatibility and architecture

Minimum deployment remains macOS 15.0 and Swift 5 language mode. Apple's
AudioHardwareCreateProcessTap/DestroyProcessTap APIs and audio-capture privacy key
are available from macOS 14.2. CI prints the actual SDK declaration and compiles
the implementation with a macOS 15 minimum. CATapDescription's stereo global tap
includes audio from output-producing apps, including browser meeting processes.

System output → CATapDescription → private tap-only aggregate → IOProc →
bounded C11 SPSC PCM queue → serial audio worker → AVAudioConverter (16 kHz,
mono Float32) → en-US streaming Speech → macOS 15 TranslationSession.Configuration
and SwiftUI translationTask → EN → ID notch teleprompter.

The IOProc copies borrowed HAL buffers into preallocated queue slots. There are
no callback allocations, locks, Speech appends, actor hops, or transcript logs.
Release/acquire atomics publish complete buffers. Worker-owned PCM is converted
before appending to Speech; HAL memory never escapes its callback. Planar and
interleaved PCM use the actual ASBD, not assumed 48 kHz stereo strides. Overflow
drops new chunks, with bounded technical diagnostics. Malformed/oversized PCM
fails safely. CI tests buffer reuse, both layouts, three sample rates, overflow
and malformed input under AddressSanitizer.

Start cancellation uses session tokens. Stop invalidates callbacks immediately;
worker cleanup stops/destroys IOProc, aggregate and tap, removes property
listeners, ends Speech input, and releases buffers. App termination waits for
cleanup. Default output, output sample-rate/aliveness, and tap-format changes
rebuild capture with a fresh converter and Speech request. Online Speech requests
rotate every 50 seconds and after final results; service failures are reported,
rather than showing an apparently listening but dead engine.

Translation partials are coalesced to at most four requests per second. Existing
translations remain readable while a new partial is processed. The hosted task
continues when the panel is suppressed. NotchSurfaceManager remains the visual
owner; Terminal, Pocketbook and Command Center hide subtitles without stopping
capture, recognition or translation. Stop clears configuration and pending
translation work. Wing width 154, depth 124, optional English, Indonesian line
limits, feature settings and shortcut persistence remain unchanged.

## Privacy and signing

Required for Live Translate:
- System Audio Recording Only, initiated by starting the tap aggregate.
  Info.plist includes NSAudioCaptureUsageDescription.
- Speech Recognition, with NSSpeechRecognitionUsageDescription. Online Apple
  Speech can send audio to Apple's recognition service.

Live Translate does not require Screen & System Audio Recording or Microphone.
Finder Apple Events permission and the existing automation entitlement remain
because File Shelf needs them. The application is not sandboxed. No invented
system-audio-capture entitlement or private TCC API is used.

A successful AudioDeviceStart is **not** proof that TCC consent was granted or
that audible meeting audio is arriving. There is no supported public tap-specific
TCC preflight here. HAL errors retain operation and OSStatus; silence may mean
silence, muted source, unsupported/protected audio, or missing audio consent.
Test actual permissions and audio on a real Mac; never reset TCC in a retry loop.

The old ScreenCaptureKit display-filter capture used broader display/window TCC
even though the feature wanted only audio. SCStream -3801 identifies that refusal;
source inspection cannot establish the exact state of an individual user's TCC
database. Switching APIs removes that display capture requirement and SCStream
path. It does **not** fix changing code identities.

Developer ID signing and notarization remain the production path. Ad-hoc signing
remains a verified beta fallback, with no TeamIdentifier and a build-dependent
designated requirement. Replacing an ad-hoc binary may require granting audio and
Speech access again. Stable Developer ID signing can preserve the code requirement
across updates; initial consent is still required. Sparkle and its signing key/
feed are preserved. CI PR packaging uses ad-hoc signing without repository
certificate secrets; it does not prove Developer ID/notarization credentials work.

## Validation and release gate

PR CI builds Debug and Release, checks the native icon and privacy metadata,
tests the actual PCM queue/converter, packages and verifies the DMG, verifies the
packaged code signature, and uploads checksum plus build provenance. It publishes
no release and changes no public version/trigger.

CI cannot prove TCC prompts, system-audio access, meeting recognition quality,
device switching, or visual ownership on actual hardware. Brief recognition gaps
may occur at request rotation/device rebuild; Apple Speech network limits and
translation-model availability still apply. System-wide capture can include
other apps/notification audio; per-app selection is future work.

After green CI, install the PR DMG into Applications, allow system audio and
Speech, play English YouTube and verify Indonesian subtitles. Toggle Ctrl+Option+L
off/on several times, open/close Terminal, Pocketbook and Command Center (one
notch only, processing continues), toggle Show English Source and Enable, change
output to a headset, then quit/relaunch and start again. Validate against the
artifact's recorded PR head and signature. Do not publish the next version until
this runtime acceptance succeeds.

## Apple references

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [AudioDeviceCreateIOProcIDWithBlock](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:))
