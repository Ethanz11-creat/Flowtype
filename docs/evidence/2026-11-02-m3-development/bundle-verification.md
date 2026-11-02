# 最终 M3 产物身份与签名校验

源码 `f7554ee4dec4782a6a4fb3c137e61f1e627ce2f9`，Sources/flowtype tree `f2d097da0b9b296aca9d37fd8f15382155c19b67`。使用原 scripts/build-app.sh，exit 0；Release 编译 99.05s。可选 Python 探针通过 shell 函数返回失败，未运行 Python；Metal 资源复制自既有缓存，无安装或下载。实际执行输出见 bundle-build.log。

环境：Apple M1、16 GiB、macOS 15.7.9 (24G830)、Swift 6.2.1、arm64 macOS15。产物 `build/FlowType.app`；未启动 GUI 或声称真机验证。

下列为实际命令结果（exit_code 保留）：

## 源码 / SHA256 / 架构 / codesign identity

```json
{
  "status": "fulfilled",
  "value": {
    "chunk_id": "f80092",
    "wall_time_seconds": 0.576125458,
    "exit_code": 0,
    "original_token_count": 343,
    "output": "f7554ee4dec4782a6a4fb3c137e61f1e627ce2f9\nf2d097da0b9b296aca9d37fd8f15382155c19b67\n09a458ad6f9492c297eb5a85145407b71d539b4112a66b09349c2cc8d11d824d  build/FlowType.app/Contents/MacOS/FlowType\nf36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f  build/FlowType.app/Contents/MacOS/mlx.metallib\nb32c520cb8a98917443f86bb5f89f2e8be26b2a38399295a5aa1d6205b2fca8c  build/FlowType.app/Contents/Info.plist\nbuild/FlowType.app/Contents/MacOS/FlowType: Mach-O 64-bit executable arm64\nExecutable=/Users/yiheng/pycode/flowtype-local/build/FlowType.app/Contents/MacOS/FlowType\nIdentifier=com.flowtype.app\nFormat=app bundle with Mach-O thin (arm64)\nCodeDirectory v=20400 size=382473 flags=0x2(adhoc) hashes=11946+3 location=embedded\nVersionPlatform=1\nVersionMin=983040\nVersionSDK=1704192\nHash type=sha256 size=32\nCandidateCDHash sha256=36fd6e09c04e6a90e1f6a85c9e269b6ca5158f74\nCandidateCDHashFull sha256=36fd6e09c04e6a90e1f6a85c9e269b6ca5158f748427681f9577b87b2710da97\nHash choices=sha256\nCMSDigest=36fd6e09c04e6a90e1f6a85c9e269b6ca5158f748427681f9577b87b2710da97\nCMSDigestType=2\nExecutable Segment base=0\nExecutable Segment limit=23789568\nExecutable Segment flags=0x1\nPage size=4096\nCDHash=36fd6e09c04e6a90e1f6a85c9e269b6ca5158f74\nSignature=adhoc\nInfo.plist entries=14\nTeamIdentifier=not set\nSealed Resources version=2 rules=13 files=6\nInternal requirements count=0 size=12\n"
  }
}
```

## codesign --verify --strict --verbose=2（主可执行文件路径，包含资源检查）

```json
{
  "status": "fulfilled",
  "value": {
    "chunk_id": "ddb268",
    "wall_time_seconds": 0.0000085,
    "exit_code": 1,
    "original_token_count": 45,
    "output": "build/FlowType.app/Contents/MacOS/FlowType: code object is not signed at all\nIn subcomponent: /Users/yiheng/pycode/flowtype-local/build/FlowType.app/Contents/MacOS/mlx.metallib\n"
  }
}
```

## codesign --verify --deep --strict --verbose=2（app）

```json
{
  "status": "fulfilled",
  "value": {
    "chunk_id": "f8ffd8",
    "wall_time_seconds": 0.000007125,
    "exit_code": 1,
    "original_token_count": 39,
    "output": "build/FlowType.app: code object is not signed at all\nIn subcomponent: /Users/yiheng/pycode/flowtype-local/build/FlowType.app/Contents/MacOS/mlx.metallib\n"
  }
}
```

## Release 编译警告

```json
{
  "status": "fulfilled",
  "value": {
    "chunk_id": "070d2d",
    "wall_time_seconds": 0.000010875,
    "exit_code": 0,
    "original_token_count": 1055,
    "output": "/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioDevice.swift:95:17: warning: initialization of immutable value 'nameResult' was never used; consider replacing with assignment to '_' or removing it [#no-usage]\n    |                 `- warning: initialization of immutable value 'nameResult' was never used; consider replacing with assignment to '_' or removing it [#no-usage]\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioRecorder.swift:152:21: warning: variable 'deviceIDSize' was never mutated; consider changing to 'let' constant\n    |                     `- warning: variable 'deviceIDSize' was never mutated; consider changing to 'let' constant\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioRecorder.swift:261:25: warning: reference to captured var 'inputConsumed' in concurrently-executing code [#SendableClosureCaptures]\n    |                         `- warning: reference to captured var 'inputConsumed' in concurrently-executing code [#SendableClosureCaptures]\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioRecorder.swift:262:25: warning: mutation of captured var 'inputConsumed' in concurrently-executing code [#SendableClosureCaptures]\n    |                         `- warning: mutation of captured var 'inputConsumed' in concurrently-executing code [#SendableClosureCaptures]\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/Speech/AppleSpeechProvider.swift:196:32: warning: result of call to 'withLock' is unused [#no-usage]\n    |                                `- warning: result of call to 'withLock' is unused [#no-usage]\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/Speech/DownloadSource.swift:67:32: warning: 'regionCode' was deprecated in macOS 13: renamed to 'region.identifier' [#DeprecatedDeclaration]\n   |                                |- warning: 'regionCode' was deprecated in macOS 13: renamed to 'region.identifier' [#DeprecatedDeclaration]\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Settings/ProviderEditSheet.swift:29:9: warning: variable 'baseURL' was never mutated; consider changing to 'let' constant\n    |         `- warning: variable 'baseURL' was never mutated; consider changing to 'let' constant\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Utilities/AppLogger.swift:27:13: warning: 'nonisolated(unsafe)' is unnecessary for a constant with 'Sendable' type 'DispatchQueue', consider removing it\n    |             `- warning: 'nonisolated(unsafe)' is unnecessary for a constant with 'Sendable' type 'DispatchQueue', consider removing it\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioDevice.swift:84:97: warning: forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'; this is likely incorrect because 'Optional<CFString>' may contain an object reference.\n    |                                                                                                 `- warning: forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'; this is likely incorrect because 'Optional<CFString>' may contain an object reference.\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioDevice.swift:95:100: warning: forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'; this is likely incorrect because 'Optional<CFString>' may contain an object reference.\n    |                                                                                                    `- warning: forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'; this is likely incorrect because 'Optional<CFString>' may contain an object reference.\n/Users/yiheng/pycode/flowtype-local/Sources/flowtype/Services/AudioDevice.swift:130:90: warning: forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'; this is likely incorrect because 'Optional<CFString>' may contain an object reference.\n    |                                                                                          `- warning: forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'; this is likely incorrect because 'Optional<CFString>' may contain an object reference.\n"
  }
}
```

## 单独验证主代码

`codesign --verify --strict --ignore-resources --verbose=2 build/FlowType.app/Contents/MacOS/FlowType`：exit 0；`valid on disk (not all contents verified)`、`satisfies its Designated Requirement`。这只验证主代码，不能替代完整 bundle 校验。

完整校验仍因 MacOS/mlx.metallib 未签名而 exit 1，与此前记录一致。保留为 M5 打包/签名护栏问题，不将 app 构建成功等同分发就绪。全部警告来自本轮未修改文件；已用 git diff 8d5d6bd..HEAD 对照为空，包括 AudioRecorder 并发捕获及 AudioDevice CFString 指针警告，不宣称构建输出无警告。
