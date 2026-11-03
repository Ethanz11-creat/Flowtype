# M5-A Task 2 implementation report

Status: DONE — M5-A Task 2 only; ready for controller review.

Base: `aea7dc9396b2020d2372c85af0d4da20f10394cf`.

Commit: `ffd4ba473cf871617caaebdd65061b06642ee8e9` — `fix: isolate self-test persistence and startup effects`.

## Implementation

Task 2 routes automatically reachable persistence through the bootstrapped runtime and guards actual external effects, preserving injected model/session/transport transitions.

- `ConfigurationStore.shared` explicitly receives runtime defaults and log backup directory. Ordinary injected constructors remain usable; omitted defaults and nil backup directories also use runtime boundaries. Legacy Keychain migration accepts a minimal `KeychainAccess` adapter.
- `KeychainHelper` retains save/load/delete signatures. Its guarded adapter routes non-app calls to a locked process-memory dictionary before constructing any SecItem query. App operations retain the original Security API implementation.
- `PersistentStore` and `AppDatabaseProvider` use runtime ApplicationSupport; the generic store also accepts an explicit fixture directory. `ModelPreset` uses runtime models, preserving app `Flowtype/models` casing. App persistent support remains `FlowType` through A1's formulas.
- Env migration returns before `.env`, inherited environment, or defaults access in validation. Recorder restore sentinels, permission-guide preferences, and settings reload use runtime defaults. Every self-test exit cleans only its runtime suite.
- `SessionEffects.live.prepare` returns before scheduling tasks outside app mode. Shared router monitoring and automatic probe timers are suppressed in validation. The injected `QwenModelState` coordinator, router probe closures, transport sessions, clipboard transactions, keyboard ownership gates, and backend factories keep their semantic behavior.
- The small `ValidationEffects` gate uses closed operation cases and locked counters for validation. Independent downstream callback spies prove denial without invoking the actual OS. The default app gate avoids validation counter/observer work.
- New `--m5-isolation-only` invokes `M5IsolationSelfTests`. The full runner now includes both M5 suites and checks the external budget again after all legacy tests. Reporter counters use a lock and Sendable conformance so the reporter can cross the runner's existing actor/nonisolated async test boundaries without losing count semantics.
- Existing synthetic test directories and Whisper preparation work directories now live under runtime Tmp. The new migration fixture retains its SQLite, JSON backup, corrupt-config backup, and generic-store evidence for review.

## Concrete live boundary consumers

| Operation | Consumers guarded or split before the effect |
| --- | --- |
| Keychain | `KeychainHelper` through `KeychainAccess.guarded`; non-app memory branch precedes system adapter/query construction |
| Environment | `EnvMigration.migrateIfNeeded`; `ModelProvisionEnvironment.process` read/write |
| Implicit model scanning | `ModelLocator.knownCacheDirs` and default `resolveActiveModel`; default Qwen coordinator inspection; explicit legacy-library inspection is restricted to the validation root |
| Model download | Default `QwenModelState` metadata-preflight closure |
| Model load/compile | Default Qwen coordinator loader; `QwenASRProvider.loadModel`; `WhisperKitBackend.load`; `WhisperModelPreparation.compilePackage`; Apple one-shot recognition |
| Real network | `CloudProbe.measureLatency`; default CloudASR request; default LLM stream and connection test; default ModelMetadataPreflight request; URLSession WebSocket connect after local endpoint validation |
| Monitoring/probe startup | Shared `ASRRouter` role selection; init monitoring gate; startProbing role guard; live session preparation guard before Task scheduling |
| Recorder/device | `AudioRecorder.requestPermission`, `startEngine`, system-default-device setter; pending device restoration returns before sentinel/hardware reads outside app |
| Permission requests/UI | PermissionHelper settings openers and guide; Apple streaming-recognition entry |
| Accessibility event tap | PermissionHelper retains read-only AXIsProcessTrusted status but gates its functional tap fallback; WindowManager setup/reload/repair/install tap methods |
| Clipboard | `KeyboardInjector.copyText`; lazy guarded `SystemDeliveryPasteboard` access; InjectionStage and RecoveryEffects delegate live copy to that guarded helper |
| Input events | Default keyboard driver before CGEventSource construction; native paste dispatch preparation; WindowManager tap methods; injected TypingEvents/postIfActive semantics remain functional |
| Foreground user context | `AXContextProvider.collect`; KeyboardInjector target collection before NSWorkspace/AX access |
| Sound | `SoundFeedback.isEnabled` returns before configuration access outside app; live sound gate precedes playback in app |
| Window ordering | Live session show/hide effects; WindowManager show/hide; StatusBarController settings-window open |

Raw source audit evidence is retained in `task-2-initial-reachability.log`, `task-2-final-reachability.log`, and `task-2-gate-consumers.log`.

Injected URLSessions/URLProtocols, model loaders/inspectors, backend factories, typing drivers, pasteboards, and session effects remain explicit trusted synthetic dependencies. Their fake requests and fixture inspections are not counted as external network/model operations. Read-only permission status and passive readiness observations remain available. The real hidden-panel geometry test still requires an actual AppKit screen and fails explicitly if none exists; no assertion was removed or converted into an automatic pass.

UI-only direct pasteboard actions in `Settings/QwenModelStatusCard.swift`, `Settings/SettingsPage+ASR.swift`, and `Settings/HistoryPage.swift` remain outside automatic runner reachability: validation does not construct/open their settings windows. AppDelegate's ordinary launch/device/onboarding paths are not invoked. AudioDeviceEnumerator is not called by validation recorder paths because restoration returns first and engine startup is denied. These are scope boundaries, not claims of testing ordinary GUI/hardware behavior.

## TDD and raw verification evidence

All commands ran in `/Users/yiheng/pycode/flowtype-local`. Shell wrappers redirected stdout/stderr to the named logs, preserved `$?`, displayed log tails or the complete small output, and exited with that original status.

### Compile RED

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-red-compile.log 2>&1
```

Exit1, expected missing APIs: KeychainAccess, ValidationEffects, the keychain constructor argument, and the PersistentStore directory argument. The singleton integration function was written but disabled for the RED run; no unsafe shared construction was performed.

### Initial fixture RED and correction

After adding the minimal API, actual KeychainHelper was already guarded to deny Security API access in validation. The new configuration keychain argument was intentionally not wired yet; all RED filesystem work used explicit fixtures.

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-red-behavior-build.log 2>&1
.build/debug/FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-red-behavior.log 2>&1
```

Build exit0; focused exit1, `29 passed, 2 failed`. This first RED did not prove the intended migration behavior: the fixture used a flat llmApiKey that the current decoder ignores, and the decoder always creates at least one provider. The first implementation attempt therefore remained red (`task-2-green-focused-fixtures.log`, same 29/2). This fixture mistake was corrected rather than changing the production decoder or dropping semantic assertions.

The corrected fixture uses a fixed active provider and providerAPIKeys map at migration version zero, matching the real decoder. Only the migration save was temporarily routed back through the already-safe in-memory KeychainHelper, to demonstrate the precise broken dependency branch.

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-red-corrected-build.log 2>&1
.build/debug/FlowType --self-test --m5-isolation-only > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-red-corrected.log 2>&1
```

Build exit0; focused exit1. Complete corrected behavioral RED output:

```text
  ✗ FAIL: M5 migration uses injected legacy key storage — got nil, want Optional("synthetic-legacy-key")
=== FlowType --self-test ===
=== M5 isolation self-test: 30 passed, 1 failed ===
```

Restoring `keychain.save` then made the intended migration assertion pass. No real Keychain or production store was accessed for RED.

### Intermediate compile failure

`task-2-green-build.log` and `task-2-green-build-fixed.log` preserve Swift's `sending 'r' risks causing data races` diagnostics: adding the new MainActor M5 suites before the existing nonisolated async test methods made the shared non-Sendable reporter cross isolation boundaries. MainActor annotation on the exit helper alone did not resolve it. The minimal complete fix made Reporter Sendable with locked integer counters and unchanged passed/failed/check/eq output semantics. The successful rebuild is `task-2-green-build-sendable.log` (exit0).

### Focused GREEN

Initial complete shared integration passed 49/0 (`task-2-green-focused.log`). A nonempty JSON history migration assertion then passed 50/0 (`task-2-final-focused.log`). After adding fourteen per-operation budget assertions, final focused verification was:

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-budget-build.log 2>&1
.build/debug/FlowType --self-test --m5-isolation-only --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-budget-focused-run > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-budget-focused.log 2>&1
```

Both exit0. Complete focused output:

```text
=== FlowType --self-test ===
=== M5 isolation self-test: 64 passed, 0 failed ===
```

These tests assert migration through the injected key store, preserved provider key, version completion, redacted corrupt backup, one actual SQLite row imported from fixture JSON, retained *.json.bak evidence, fixture generic-store round trip, in-memory actual KeychainHelper behavior, zero independent downstream system/gate spies, a positive app-spy control, runtime shared paths, no selected model/keys, no scheduled model preparation after yielding/draining, nil backup-directory isolation, and fourteen zero budgets. Live recorder permission, clipboard, recovery copy, permission settings, AX context, and real probe adapters are also invoked under their deny guards.

### Sequential full lane

After final focused GREEN, this build succeeded:

```sh
swift build > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-full-lane-build.log 2>&1
```

Exit0, `Build complete! (18.96s)`.

The full runner was launched once, with its owned PID retained in `task-2-full.pid`:

```sh
.build/debug/FlowType --self-test --validation-root /Users/yiheng/pycode/flowtype-local/.superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-full-run > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-full.log 2>&1 &
validation_pid=$!
printf '%s\n' "$validation_pid" > .superpowers/sdd/2026-11-03-m5-a-build-identity-and-isolation/task-2-full.pid
wait "$validation_pid"
```

Full runner exit0, executed exactly once. Complete output from `task-2-full.log`:

```text
=== FlowType --self-test ===
=== self-test: 24046 passed, 0 failed ===
```

The owned process (PID 19051) finished normally. All fourteen external-effect budgets passed after the legacy suite. The AppKit hidden-panel/screen geometry assertions passed; no assertions were removed or skipped. These are the actual results of this run.

## Final evidence and scoped commit

Read-only inspection used Ruby/Open3 and sqlite3 against only the explicit full-run root. `task-2-full-artifacts.log` retains the resulting metadata: runtime `ApplicationSupport/flowtype.sqlite` has zero sessions and one migration marker; the isolated migration fixture SQLite database under runtime Tmp has one session and one migration marker. Two JSON backups and two corrupt-configuration backups remain as synthetic evidence.

The scoped stage contained 39 source files, with 378 additions and 83 deletions. `git diff --cached --check` passed with empty output retained in `task-2-staged-check.log`. `task-2-commit.log` records successful creation of the commit above. Final `git status --short` and `git diff HEAD --check` both produced no output. No source changed after the final focused and full verification.

### Changed files

The complete scoped source list is also retained in `task-2-scoped-files.log`:

```text
Sources/flowtype/App/RuntimeEnvironment.swift
Sources/flowtype/App/StatusBarController.swift
Sources/flowtype/App/ValidationEffects.swift
Sources/flowtype/Core/ConfigurationStore.swift
Sources/flowtype/Core/Database/AppDatabase.swift
Sources/flowtype/Core/EnvMigration.swift
Sources/flowtype/Core/Persistence.swift
Sources/flowtype/Core/Pipeline/Stages/InjectionStage.swift
Sources/flowtype/Core/PipelineOrchestrator.swift
Sources/flowtype/Core/Recovery/RecoveryEffects.swift
Sources/flowtype/Services/AudioRecorder.swift
Sources/flowtype/Services/Context/AXContextProvider.swift
Sources/flowtype/Services/KeyboardInjector.swift
Sources/flowtype/Services/LLMService.swift
Sources/flowtype/Services/Speech/ASRRouter.swift
Sources/flowtype/Services/Speech/AppleSpeechProvider.swift
Sources/flowtype/Services/Speech/CloudASRProvider.swift
Sources/flowtype/Services/Speech/CloudProbe.swift
Sources/flowtype/Services/Speech/LocalModelManager/LocalModelLibrary.swift
Sources/flowtype/Services/Speech/LocalModelManager/ModelPreset.swift
Sources/flowtype/Services/Speech/ModelLocator.swift
Sources/flowtype/Services/Speech/ModelProvisioning/ModelMetadataPreflight.swift
Sources/flowtype/Services/Speech/OfflineWhisperKit.swift
Sources/flowtype/Services/Speech/QwenASRProvider.swift
Sources/flowtype/Services/Speech/QwenModelState.swift
Sources/flowtype/Services/Speech/WebSocketTransport.swift
Sources/flowtype/Services/Speech/WhisperModelPreparation.swift
Sources/flowtype/Testing/ImportedModelUISelfTests.swift
Sources/flowtype/Testing/LocalModelImportSelfTests.swift
Sources/flowtype/Testing/M2ReviewFixSelfTests.swift
Sources/flowtype/Testing/M5IsolationSelfTests.swift
Sources/flowtype/Testing/M5RuntimeSelfTests.swift
Sources/flowtype/Testing/ModelProvisionSelfTests.swift
Sources/flowtype/Testing/SelfTest.swift
Sources/flowtype/Testing/WhisperRuntimeSelfTests.swift
Sources/flowtype/Utilities/KeychainHelper.swift
Sources/flowtype/Utilities/PermissionHelper.swift
Sources/flowtype/Utilities/SoundFeedback.swift
Sources/flowtype/WindowManager.swift
```

## Self-review and limitations

Source review checked the original app path formulas/casing, explicit defaults/backup routing, role split before SecItem queries and environment reads, early preparation return before Task creation, injected coordinator semantics, actual OS posting boundaries, lazy pasteboard access, no user-cache enumeration in non-app defaults, all exit suite cleanup, and preservation of every legacy semantic assertion.

Build logs contain existing warnings in AppLogger, AudioRecorder, AppleSpeechProvider, ProviderEditSheet, and AudioDevice when those files/dependents are rebuilt. No dependency changes or unrelated warning cleanups were made.

The isolation evidence proves the code boundaries using independent downstream gate and Keychain spies, with a positive app-spy control. Validation counters are not an external OS-monitoring sandbox.

No ordinary app, real recording, model load/download, permission request, clipboard mutation, or input-event dispatch was deliberately executed. No real config/dictionary/database/Keychain/model cache was read as a baseline. No Python, install, dependency update, swift test, acoustic benchmark, push, merge, subagent, or reviewer was used. Reports and logs remain local ignored `.superpowers` evidence. A3 identity/logger work and B1 process checks remain outside this task. Work stops for controller review after this task.
