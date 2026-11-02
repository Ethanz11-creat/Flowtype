# M4 fixed app identity and verification

The final source was independently re-reviewed before closeout. Product source commit: `5dc1693c81d96fb4faaad006bdf31d6182e204c0`. Sources tree: `872e9038b8def8ed720d9cc6370c57ed12d76794`. No source edits occurred between the final sequential build/full self-test and app packaging; subsequent changes are evidence/docs only.

| Item | Actual result |
| --- | --- |
| Focused M4 | 19747 passed / 0 failed |
| Sequential debug build + full | exit0; 23872 passed / 0 failed |
| Release/app build | exit0, release build93.56s, existing scripts/build-app.sh |
| App | `/Users/yiheng/pycode/flowtype-local/build/FlowType.app` |
| Executable SHA-256 | `ceded28e359918d8d66f8ed1090107fb4a8bffb46aa1b8b9e0278c94a5ccc250` |
| Architecture / identifier | arm64 / com.flowtype.app |
| Signature | ad-hoc, CDHash40fb9d27fb107c9fbc484ebb706f950a791cf9e1 |
| Main-code verify ignoring resources | exit0 |
| Strict verify | exit1, unsigned mlx.metallib subcomponent |
| Deep/strict verify | exit1, same unsigned mlx.metallib |
| GUI/app launch/smoke/inference/cloud | Not executed; Pending |

Packaging command from the worktree: `bash .superpowers/sdd/2026-11-02-m4-failure-recovery/package-final.sh`. The archived helper defines an exported python3 shell function returning1, then runs the existing script; no Python interpreter, installation or conversion was invoked. Existing compiled shader library was copied read-only from the already cached MLX wheel (`146852000` bytes); no ASR model was read/downloaded. Raw output is [bundle-build.log](sdd/bundle-build.log).

Actual read-only verification commands/results:

```text
shasum -a 256 build/FlowType.app/Contents/MacOS/FlowType
ceded28e359918d8d66f8ed1090107fb4a8bffb46aa1b8b9e0278c94a5ccc250
file build/FlowType.app/Contents/MacOS/FlowType
Mach-O 64-bit executable arm64
codesign -dv --verbose=4 build/FlowType.app
Identifier=com.flowtype.app; Signature=adhoc
codesign --verify --ignore-resources --verbose=2 build/FlowType.app
exit0: valid on disk (not all contents verified); satisfies its Designated Requirement
codesign --verify --strict --verbose=2 build/FlowType.app
exit1: code object is not signed at all
In subcomponent: .../FlowType.app/Contents/MacOS/mlx.metallib
codesign --verify --deep --strict --verbose=2 build/FlowType.app
exit1: same unsigned mlx.metallib
```

The strict/deep failure is the already documented M3/M5 packaging limitation, reproduced on this artifact. Main-code verification is not full-bundle verification; neither a signed distribution nor notarization is claimed. Existing version1.0.0/build1 remain unchanged; no M5 BuildInfo/smoke feature was silently added.

Release compilation still reports warnings on unchanged lines (AudioDevice raw pointers/unused value, AudioRecorder callback capture/deviceIDSize, and other existing annotations/deprecations); raw output preserves them. This is not a warning-clean build claim. The two M4-introduced test mutable-capture warnings were fixed and checked by actual recompilation in final-fix logs; final scoped rereview confirmed that distinction. No real microphone, target application, key/provider, network impairment, GUI or model runtime acceptance is inferred from this build.
