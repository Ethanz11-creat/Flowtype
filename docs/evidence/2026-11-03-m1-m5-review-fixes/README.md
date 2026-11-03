# M1–M5 独立审查修复证据

日期：2026-11-03。用户授权使用 `receiving-code-review` 修复[独立审查](../2026-11-03-m1-m5-independent-review.md)的 IR-01 / IR-02。先核实，再按项行为 RED→GREEN；实施与独立复审串行，最多一个活跃子智能体。

**两项源码问题已关闭；限定复审未发现新的 Critical / Important。新候选24个技术阶段全部Pass，整体release仍exit2/Pending：41个人工叶子与远端CI均Pending。**

## 修复与定向回归

| 发现 | 修复提交与行为 | 实际回归 |
| --- | --- | --- |
| IR-01 | `9c20e31bd5a9b13418a4b9131299e07e8ba7972c`；CLI删除缓存发现，缺失/空串显式shader直接shaderInvalid | 真实CLI main+合成home/cache，RED9/3→GREEN12/0；显式输入fixture止于sourceInvalid，真实成功打包见下方release |
| IR-02 | `bb8b5bf671b94ca8f4c5ac5256583b4550ff88e2`；自然结束和CancellationError共用终态处理，全会话取消优先；冻结取消实时识别并返回录音中断，健康Stop继续音频 | 真实RecordingStage/SessionContext、160个非零PCM、异步gate，RED19772/3→GREEN19777/0；正常Stop/全取消/冻结自然结束/冻结+Stop四种路径 |

IR-02缺陷早于M1，不改写为本次开发新引入。测试在preview gate后的取消检查进入真实catch，未重演所有spectrum调度；阶段返回suspend阻断下游，不冒充真实拔麦或落字实验。新增窄注入只替换硬件/preview/route/context/realtime/device边界，生产默认实现保留。

[实施报告](focused/implementation-report.md)列完整命令与限制；[限定独立复审](focused/scoped-rereview.md)核对两个提交和原始RED/GREEN，均ADDRESSED。首次夹具编译错误单列，不计行为RED；skip-update弃用提示和旧文件警告保留原日志。新CLI独立回归入口：`ruby scripts/verification/ArtifactPackagingCLIInputTests.rb /absolute/repo/build/owned-scratch`；录音回归接入现有M4/full入口。

## 一次新候选技术门禁

在clean `bb8b5bf`上执行一次：

```sh
MLX_METALLIB_PATH="$PWD/build/FlowType.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" scripts/verify.sh --lane release
```

仅使用明确提供的既有shader，不发现用户缓存。该lane内完成build/full及artifact/smoke，没有在外围重跑完整套件。

- Run：`761FBC46-7432-4C5D-A5FF-7D6FB67D71A5`；[typed报告](release/verify-report.json)、[父进程输出/退出码](focused/final-release.stdout)、[身份与文件哈希复核](final-identity-check.json)。父stderr为空，exit2符合缺真实验收的合同。
- 24技术阶段全部Pass，无Fail/Skip/timeout；build26512ms，full188333ms，**24364 passed / 0 failed**，两者stderr均空。
- artifact-build120528ms，strict/deep签名130ms，移位资源/实际Metal与MLX6080ms；[移位检查结果](artifact-check-result.json)中资源恢复和前后哈希一致。
- 十次独立smoke全部Pass，外部耗时6298–7793ms；各自内部报告约6秒、两个timer各1次、tap禁用。新runID/独立根，候选始终一致。
- source-start/end均clean且一致。后续文档归档提交不冒充被测源码身份。Package.resolved仍为blob `702ce34b917f9fdf9927b1b428f431125c28970c`。

| 候选字段 | 值 |
| --- | --- |
| 版本 / build / 架构 | 1.0.0 / 358 / arm64 |
| 被测SHA | `bb8b5bf671b94ca8f4c5ac5256583b4550ff88e2` |
| Sources tree | `5d4772afcd862c9048ccf5d0ad65971cb6fae21f` |
| builtAt | `2026-11-03T06:39:15Z` |
| binary SHA256 | `e3732eba9b9c1360f2132420a62a2d93d7e7043b36a4a4e591e83ec5a12a9158` |
| metadata SHA256 | `1ed9598db11ce520d3396d960d4a0ace2f90c40d944cc6328428c752db6f5607` |
| shader SHA256 | `f36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f` |

当前本地app路径为 `build/FlowType.app`；[manifest](FlowType.manifest.json)与报告artifactIdentity及14项资源文件哈希已独立核对。

## 证据边界

`focused/`只归档选定文本、JSON、合成trace、RED源快照与诊断日志；`release/`由既有白名单导出器导出45个文件；`process-results/`补存本run受控进程结果。没有复制二进制、合成shader、配置/DB/模型目录或真实用户数据。首次导出因未先创建空目标目录失败，创建后成功；没有重跑技术门禁。原始首次编译stdout含一处诊断行尾空格，按原字节保留，文档/源码diff检查排除该原始日志。`SHA256SUMS`覆盖本目录除自身外所有文件。

本轮无普通GUI启动、真实录音/权限/剪贴板/输入、云端ASR/LLM或远端CI；无Python/下载/安装/依赖更改/push/merge/发布。真实设备恢复、模型推理与声学校准、跨应用交付和V1–V5仍按原矩阵Pending。技术与源码修复通过不等于产品可发布；旧4cdfaf4/build353证据保持其历史身份。
