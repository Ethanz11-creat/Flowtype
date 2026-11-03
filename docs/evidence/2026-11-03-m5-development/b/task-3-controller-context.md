# B3 integration attention

Read task-3-brief first; this note carries prior-task interfaces and concrete platform facts.

- B1 BoundedProcess/ProcessCLI are committed at7488553. Each consumer CLI must call dispatchChildIfNeeded before its own option parser. External runner cleans only its handshaken group; Foundation Process can create a new group even for normal child tool calls. Nested watchdog/tools/recovery owners must implement bounded owned cleanup/restoration instead of assuming outer group kill covers them.
- A BuildInfo generator is an independent Swift script and has no Python/Keychain/model work. Its internal git Process waits require an enclosing owner; report any concrete unbounded surviving group issue instead of calling it sandboxed.
- B2 resource entry and live runtime check are committed before B3 dispatch; inspect exact committed source. No direct MLX dependency promotion was necessary. Package.swift/resolved must stay unchanged.
- Existing shader is documented in mlx-packaging-notes.md. Use explicit local input and copy it into staging before any final candidate replacement; no scan of model caches or installation/download.
- Keep the no-replacement-of-running-normal-app constraint. Candidate publication must refuse/preserve an in-use final bundle rather than terminating an existing normal app. Do not start normal app, modify TCC or clear quarantine. Use existing candidate only as a shader input if safe.
- Tests must exercise the actual packaging control flow via test-driver-only injected dependencies, never add release env flags to skip signing/source identity/resources. No second subagent. C owns final10 smoke.
