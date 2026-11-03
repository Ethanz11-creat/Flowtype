# CI source verification (controller, 2026-11-03)

Read-only public network queries, no workflow execution/push/provider secrets.

- GitHub docs main: https://raw.githubusercontent.com/github/docs/main/content/actions/reference/runners/github-hosted-runners.md includes data/reusables/actions/supported-github-runners.md (not actions/jobs/supported-github-runners.md; that attempted URL404, corrected).
- https://raw.githubusercontent.com/github/docs/main/data/reusables/actions/supported-github-runners.md lists macos-15 as arm64 in both public/private standard tables. Local snapshot github-supported-runners.md lines83–88/177–182. Use macos-15, not macos-15-intel.
- https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-15-arm64-Readme.md snapshot image20261028.0489.1, OS15.8.2. Default Xcode16.4 is too old for Swift6.2; preinstalled Xcode26.0.1 appears at /Applications/Xcode_26.0.1.app. Use job-local DEVELOPER_DIR=/Applications/Xcode_26.0.1.app/Contents/Developer after existence check, not global xcode-select or installation. Runtime swift/version preflight is binding; docs snapshot does not prove an actual runner was used.
- git ls-remote https://github.com/actions/checkout.git refs/tags/v4 returned 11d5960a326750d5838078e36cf38b85af677262. v5 fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09; v6 d23441a48e516b6c34aea4fa41551a30e30af803. Prefer narrow established v4 unless task finds concrete incompatibility; inspect pinned action.yml before using.
- git ls-remote https://github.com/actions/upload-artifact.git refs/tags/v4 returned ea165f8d65b6e75b540449e92b4886f43607fa02. v5 330a01c490aca151604b8cf639adc76d48f6c5d4; v6 b7c566a772e6b6bfb58ed0dc250532a479d7789f. Inspect pinned action.yml. No tag drift guessing.
- Actual remote CI remains Pending: no push or remote trigger authorized. Do not claim yaml+preflight fixture is remoteCI green.
