# Final actual release controller evidence review

Candidate source4cdfaf42cbea1bd04a63a4803a8d103a23e0178f, Sources tree953608b60a0349dfcd2acfc4ddeef6f6d6b39288, dirty=false. Actual sole release run3683D6F7-2BD5-4F54-A3EF-5F80A38020D0. Parent stdout records exact report path and Pending, stderr empty, exit2. Reviewed actual report, raw code/build/full/sign/check streams+bounded results, moved check-result/artifact stream, all10 raw smoke streams+bounded results and current candidate hashes; no verification rerun.

All24 technical phases Pass, no timeout/failure/skip. Code build24974ms, full195765ms normal exit0, unique original full summary24334passed/0failed, stderr empty. Artifact build38117ms, signature164ms, moved check6571ms; original and moved strict signature valid. Moved artifact149ms, actual appResources/metalLibrary/mlxOperation/resolvedInsideApp alltrue, developer resources hidden then restored, exact before/after hash equality. Source-end Pass confirms snapshot stable.

Ten independent smoke runIDs, each normal exit0, reported6237–6657ms and externally6301–8016ms, probeTimerTicks=1/windowHealthTicks=1, tap=disabledForValidation, packaged metadata exactly matching candidate. Read-only permission/readiness states are not real permission/recording acceptance.

Candidate1.0.0/build353, arm64, builtAt2026-11-03T05:45:02Z, appPath /Users/yiheng/pycode/flowtype-local/build/FlowType.app. Binaryd4ab9e5958e8853b0837c85bb1d44869c31646fb3ddeca9da2acee33fd6a32dd; metadatab872198de60a3f1ccbed0f48802f3c0c56c0a40d91b122da82bac17151637839; shaderf36b01c44dd5f2d9020deb1ac6ad53dc085de81af19396694c5963ef3a12137f. Current files independently hash-match manifest/report. Package.resolved unchanged and git status empty after run.

Technical gate approved. Overall release remains Pending by design: all41 manualCases Pending, no manualIssues, remoteCI Pending. No actual ASR/model inference, ordinary app cold launches, GUI, permissions, clipboard/input, recording, provider/device behavior or Developer ID/notarization is proven. Archive docs must preserve tested source SHA separately from later archive-only HEAD. Source fixes not required; no unchanged repeat runs.
