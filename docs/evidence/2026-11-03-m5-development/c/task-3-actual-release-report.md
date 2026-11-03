# C3 final actual release report

Result: the **single final actual release command exited2 / Pending**, with **all24 technical phases Pass**, no technical Fail/Skip/timeout, **all41 manual leaves Pending**, `manualIssues=[]`, and `ciStatus=Pending`. Missing real manual/remote CI evidence is the intended reason for nonzero; no real acceptance Pass was supplied or fabricated.

## Invocation and ownership

Approved source: `4cdfaf42cbea1bd04a63a4803a8d103a23e0178f`; whole-M5 source/task approval read from `task-3-review.md` and `final-source-review.md` before execution. Preflight porcelain was empty. Explicit shader existed146852000B with SHA256 `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`; Package.resolved blob `702ce34b917f9fdf9927b1b428f431125c28970c` unchanged.

Exactly once, from `/Users/yiheng/pycode/flowtype-local`:

```sh
MLX_METALLIB_PATH=/Users/yiheng/pycode/flowtype-local/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib scripts/verify.sh --lane release
```

No outside product build/full/artifact/smoke was run. No source/docs change occurred during the source snapshot interval. The current report is written only after completion, in ignored scratch. Controller independently reviewed actual raw code/artifact/smoke evidence and approved technical evidence; it requested no repeat checks, so this report uses that completed evidence rather than rerunning commands.

Parent capture files in this current C scratch:

- `task-3-actual-release.started-at`
- `task-3-actual-release.stdout`: one owned report path, then `Verification release: Pending`
- `task-3-actual-release.stderr`:0 bytes
- `task-3-actual-release.exit`:2

RunID **3683D6F7-2BD5-4F54-A3EF-5F80A38020D0**.
Report root `/Users/yiheng/pycode/flowtype-local/build/verification/3683D6F7-2BD5-4F54-A3EF-5F80A38020D0/`.
Parent report `verify-report.json` has schema1/lane release/status Pending.

## Final candidate identity

The source-start/end snapshots both passed, at clean identity:

- gitSHA `4cdfaf42cbea1bd04a63a4803a8d103a23e0178f`
- Sources tree `953608b60a0349dfcd2acfc4ddeef6f6d6b39288`
- dirty=false
- version1.0.0/build353; builtAt `2026-11-03T05:45:02Z`; arm64
- fixed appPath `/Users/yiheng/pycode/flowtype-local/build/FlowType.app`
- manifest `/Users/yiheng/pycode/flowtype-local/build/FlowType.manifest.json`
- binary SHA256 `d4ab9e5958e8853b0837c85bb1d44869c31646fb3ddeca9da2acee33fd6a32dd`
- BuildInfo SHA256 `b872198de60a3f1ccbed0f48802f3c0c56c0a40d91b122da82bac17151637839`
- shader SHA256 `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f`

The manifest contains14 resource records: app icon/BuildInfo; FlowType resource bundle icon, two status images and two dictionaries; GRDB plist/privacy; standard MLX bundle plist/shader; crypto privacy; transformers tokenizer configs. Shader is at `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`, not the obsolete MacOS shader location. Current final bytes were independently checked by controller against the manifest. This final candidate supersedes B3 build350 for C acceptance; B3's raw record remains historical.

## Technical stages and raw locations

All paths below are relative to the report root. Each command child has separate `stdout`, `stderr`, `process-result.json`, and a new validation root when applicable. All external commands terminated normal with exit0, timedOut=false, failureCode=null.

| Stage | Result / timing | Child root |
| --- | --- | --- |
| source-start | Pass, clean source identity | internal-E6F3387F-0EAF-431E-90DC-9B8ADFA4609B |
| platform-os | Pass, macOS15+ | children/FC05BDAA-D2CF-4E3D-A790-BA3352EC5738 |
| platform-arch | Pass, arm64 | children/EA39CE35-DAA6-463A-92DB-6B8334F1C95D |
| platform-swift | Pass, Swift6.2+ | children/635DDB3A-2480-4D99-9EC4-B23808811598 |
| code-build | Pass,24974ms | children/B5C9817D-7CF2-4BED-BDF2-19C41714363A |
| code-full | Pass,195765ms; original full24334 passed/0 failed | children/6E19B24E-53F8-4961-BEEA-C56BA945C043 |
| artifact-recovery-before | Pass | internal phase, no raw command streams |
| artifact-source | Pass, clean/nonshallow | internal phase |
| artifact-build | Pass,38117ms | children/559A3309-0AA8-4B37-B378-910446E389BF |
| artifact-manifest | Pass, source and candidate identity match | internal phase |
| artifact-signature | Pass,164ms; codesign deep/strict | children/D3C1552E-23BB-41AB-A301-C7FC14710BEF |
| artifact-check | Pass,6571ms; moved app/hidden developer resources | children/3D0029EA-511D-4ABA-8365-A5D70FF58A0D |
| artifact-recovery-after | Pass | internal phase |
| smoke-01 | Pass | children/F3CDCA5E-98F7-49A0-BB18-348EB3BDE56A |
| smoke-02 | Pass | children/3EE30EF1-3991-4756-8848-91C388A22573 |
| smoke-03 | Pass | children/57D862EE-C19F-4F84-83B3-B8383B7EF6B0 |
| smoke-04 | Pass | children/F08E2C21-88B0-4F1D-9202-25379A5A1E44 |
| smoke-05 | Pass | children/9A2F16D2-6BC9-419B-9286-1684D89FF288 |
| smoke-06 | Pass | children/FF7CCF0C-87B4-44C3-9375-8DF670B68791 |
| smoke-07 | Pass | children/64E4A88A-D3CD-4B46-8CA6-DD5F080AEBB3 |
| smoke-08 | Pass | children/6DFECB88-F6D8-4232-8E63-09FE7D1BC481 |
| smoke-09 | Pass | children/5215F995-436F-4B6C-8508-1DC1A5C1AC6D |
| smoke-10 | Pass | children/840C9ED5-B8B5-4441-A4BB-C998CC58C13C |
| source-end | Pass, identical clean source fingerprint | internal-A09923E7-20F8-423F-8504-AB144F931B30 |

Moved-check raw evidence is under `children/3D0029EA-511D-4ABA-8365-A5D70FF58A0D/check-output/`: `check-result.json`, `artifact.stdout`, `artifact.stderr`, and isolated validation logs. The inner actual artifact operation took149ms and reported all four booleans true (`appResources`, `metalLibrary`, `mlxOperation`, `resolvedInsideApp`), packaged final identity, no failure. Strict signature, resource hiding/restoration and pre/post binary/metadata/shader hash agreement were independently read by controller; this is real Metal and explicit MLX GPU micro-operation, with no ASR model loaded.

All ten raw smoke JSON lines and bounded results were independently read by controller: unique process runIDs/fresh roots, matching final packaged identity, `probeTimerTicks=1`, `windowHealthTicks=1`, `tap=disabledForValidation`, exit0, and no timeout. Reported durations6237–6657ms; external bounded durations6301–8016ms. Each satisfies≥6000ms and external timing bounds. Runtime permissions/readiness are observations only; smoke never requests permissions or creates the real hotkey tap.

## Pending and constraints

manualStatus Pending,41/41 required leaves explicitly Pending, manualIssues empty, CI Pending. There is no provided real manual/CI report, GUI acceptance, ordinary-app10 launch proof,20 mixed sessions, real model inference/accuracy calibration, permissions recovery timing, cross-app delivery/clipboard/device/cloud V1–V5 result, Developer ID or notarization acceptance. The local technical result does not authorize publishing.

No ordinary app, user config/dictionary/DB/Keychain/model cache baseline, recording/permission requests/clipboard/input/provider requests, Python/download/install/dependency/lock changes, push/merge or out-of-command validation was performed. Watchdog controls only its owned handshaken group; packaging recovery has separate live owner/inner-group/token/fingerprint checks and passed. No source fix or automatic rerun was needed.

This report stops before archive or tracked documentation commit. Follow controller's next explicit archive dispatch; preserve final tested source identity separately from subsequent archive-only HEAD.
