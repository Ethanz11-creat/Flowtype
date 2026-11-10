import CryptoKit
import Foundation
import SwiftUI

/// Only bundled, fingerprinted speech is read. No capture, permission, network or user-state access.
enum ASRValidationSampleStore {
    enum ResourceError: Error { case unavailable, invalidResource }
    static func load(language: WhisperLanguage) throws -> ASRValidationSample {
        let code = language == .en ? "en" : "zh" // auto follows the app's existing Chinese default.
        guard let url = Bundle.module.url(forResource: code, withExtension: "wav", subdirectory: "ASRValidation") else {
            throw ResourceError.unavailable
        }
        let expected = code == "en" ? "0341fa437d4e93a039780bc1f9dc7783e37a09598e5e4a774a9ca73913a86813"
            : "10deb420ab53319fb8a0f14ae17a17e61b2e206136963a874d2b71455da912af"
        return try decode(Data(contentsOf: url), expectedSHA256: expected,
            label: code == "en" ? "English synthesized speech: Hello, this is a speech recognition test." : "中文合成语音：你好，这是语音识别测试。")
    }
    static func decode(_ data: Data, expectedSHA256: String, label: String) throws -> ASRValidationSample {
        guard data.count <= 256_100, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw ResourceError.invalidResource
        }
        let bytes = [UInt8](data)
        func text(_ offset: Int, _ count: Int) -> String { String(decoding: bytes[offset..<(offset + count)], as: UTF8.self) }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count >= 44, text(0, 4) == "RIFF", text(8, 4) == "WAVE", u32(4) == bytes.count - 8 else {
            throw ResourceError.invalidResource
        }
        var offset = 12, hasFormat = false, pcm: Range<Int>?
        while offset + 8 <= bytes.count {
            let size = u32(offset + 4), start = offset + 8
            guard size <= bytes.count - start else { throw ResourceError.invalidResource }
            switch text(offset, 4) {
            case "fmt ":
                guard !hasFormat, size == 16, u16(start) == 1, u16(start + 2) == 1,
                      u32(start + 4) == 16_000, u32(start + 8) == 32_000,
                      u16(start + 12) == 2, u16(start + 14) == 16 else { throw ResourceError.invalidResource }
                hasFormat = true
            case "data":
                guard pcm == nil, size > 0, size <= 256_000, size % 2 == 0 else { throw ResourceError.invalidResource }
                pcm = start..<(start + size)
            default: break
            }
            offset = start + size + size % 2
        }
        guard offset == bytes.count, hasFormat, let pcm else { throw ResourceError.invalidResource }
        let samples = stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map {
            Float(Int16(bitPattern: UInt16(u16($0)))) / 32768
        }
        return try ASRValidationSample(samples: samples, sampleRate: 16_000, label: label)
    }
}

/// C3 displays this BEFORE either Test or service/cloud select-with-test, alongside result text.
struct ASRValidationDisclosure: Equatable {
    let destination: String
    let sampleLabel: String
    let notice: String
    init(destination: String, language: WhisperLanguage, isCloud: Bool) {
        self.destination = destination
        sampleLabel = language == .en ? "English 合成语音（约 3 秒）" : "中文合成语音（约 3.5 秒）"
        notice = "仅在点击测试或试用并选择时，向上述地址发送此内置样本和该服务凭据。"
            + (isCloud ? "云端服务可能收费。" : "本机服务由你自行运行；服务本身可能联网或产生费用。")
            + "不读取麦克风、前台上下文、词典或剪贴板。非空转写仅验证运行可用，请查看输出判断质量；不提供准确率评分。"
    }
}

struct ASRValidationNotice: View {
    let disclosure: ASRValidationDisclosure
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("测试目的地：" + disclosure.destination).textSelection(.enabled)
            Text("测试样本：" + disclosure.sampleLabel)
            Text(disclosure.notice)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
