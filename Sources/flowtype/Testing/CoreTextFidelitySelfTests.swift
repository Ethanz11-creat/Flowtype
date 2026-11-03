import Foundation
import os

enum CoreTextFidelitySelfTests {
    /// These expectations are the ASR text itself, before either production stage.
    /// A successful LLM echo must not hide damage done by preprocessing.
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        let examples = [
            "金额是10000元", "编号是12121212", "变量是 `aaaa`",
            "请打开这个地址 https://a.co/?x=1", "请运行 foo()",
            "请调用 foo(a, b)", "文件在 /tmp/aaaa.txt", "版本是 v1.0.0000",
            "参数是 --label=aaaa", "代码是 `let aaaa = 10000;\nprint(aaaa)`",
            "名称为 aaaa", "路径为 /tmp/然后然后然后.txt",
            "打开 https://a.co/回头回头回头?次数=10000",
            "这个10000元的预算", "字段值为 \"回头回头回头\"", "字段值为 '回头回头回头'",
            "代码是 {\"count\":10000,\"text\":\"回头回头回头\"}",
            "打开 https://a.co/?q=it's&重复=回头回头回头",
            "打开 https://a.co/?q='回头回头回头", "打开 'https://a.co/?x=10000'",
        ]
        let fixtures = examples.map { ($0, $0) } + [
            ("预算(10000)", "预算（10000）"), ("进度10000!", "进度10000！"),
            ("请调用 foo()!", "请调用 foo()！"), ("设置 --debug 然后呢?", "设置 --debug 然后呢？"),
        ]
        var config = Configuration()
        config.llmProviders = [LLMProvider(name: "Synthetic", provider: "custom",
            baseURL: "https://example.invalid/v1", model: "synthetic", isActive: true)]
        config.providerAPIKeys[config.llmProviders[0].id.uuidString] = "synthetic-key"
        let capturedConfig = config
        for (example, expected) in fixtures {
            for mode in ["raw", "echo", "failed"] {
                let context = SessionContext(sessionID: 990)
                context.usePolish = mode != "raw"
                let processed = await PostProcessStage().execute(payload: .transcript(example), context: context)
                guard case .continue(let processedPayload) = processed else {
                    r.check(false, "CORE01: postprocess continues"); continue
                }
                let polish = PolishStage(configuration: { capturedConfig }, streamFactory: { text, _, _ in
                    AsyncThrowingStream { continuation in
                        if mode == "failed" { continuation.finish(throwing: LLMError.apiError("synthetic")) }
                        else { continuation.yield(text); continuation.finish() }
                    }
                })
                let polished = await polish.execute(payload: processedPayload, context: context)
                guard case .continue(let deliveryPayload) = polished else {
                    r.check(false, "CORE01: polish continues"); continue
                }
                let delivered = OSAllocatedUnfairLock(initialState: [String]())
                let secure = DeliveryTargetSnapshot(pid: 42,
                    signals: .init(secureInputActive: true, focus: .editableText))
                context.deliveryTarget = secure
                let injection = InjectionStage(settle: {}, accessibilityTrusted: { true },
                    currentTarget: { secure }, copy: { text in delivered.withLock { $0.append(text) } })
                _ = await injection.execute(payload: deliveryPayload, context: context)
                r.eq(delivered.withLock { $0 }, [expected], "CORE01 \(mode): preserve \(example)")
                r.eq(context.deliveryOutcome, .clipboard, "CORE01: real delivery boundary retains outcome")
            }
        }
        r.eq(ASRPostProcessor.process("回头回头回头回头我们开始"), "回头我们开始",
             "CORE01: ordinary Chinese decoder repetition cleanup remains effective")
        r.eq(ASRPostProcessor.process("你好,世界!"), "你好，世界！",
             "CORE01: ordinary Chinese prose punctuation remains effective")
    }
}
