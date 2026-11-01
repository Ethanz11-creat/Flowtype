import Foundation
import NaturalLanguage
import Tokenizers
import WhisperKit

/// Public-protocol adapter. No upstream internal initializer or guessed special IDs.
final class LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: any Tokenizer) throws {
        func required(_ token: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(token), id >= 0,
                  tokenizer.convertIdToToken(id) == token else { throw OfflineWhisperError.incompatibleTokenizer }
            return id
        }
        let space = try required("Ġ")
        guard tokenizer.decode(tokens: [space]) == " " else {
            throw OfflineWhisperError.incompatibleTokenizer
        }
        // Hugging Face uses nocaptions; other Whisper exports use nospeech.
        // Accept an explicit, exact token only, and reject conflicting aliases.
        let noSpeechIDs = Set(["<|nospeech|>", "<|nocaptions|>"].compactMap { Self.exactTokenID($0, in: tokenizer) })
        guard noSpeechIDs.count == 1, let noSpeechID = noSpeechIDs.first else {
            throw OfflineWhisperError.incompatibleTokenizer
        }
        specialTokens = try SpecialTokens(endToken: required("<|endoftext|>"), englishToken: required("<|en|>"),
            noSpeechToken: noSpeechID, noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: required("<|endoftext|>"), startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"), timeTokenBegin: required("<|0.00|>"),
            transcribeToken: required("<|transcribe|>"), translateToken: required("<|translate|>"), whitespaceToken: space)
        self.tokenizer = tokenizer
        allLanguageTokens = Set(Constants.languages.values.compactMap { Self.exactTokenID("<|\($0)|>", in: tokenizer) })
    }

    func validate(for graph: WhisperRuntimeMetadata) throws {
        let end = graph.isMultilingual ? 50257 : 50256
        let languageCount = graph.logitsSize == 51866 ? 100 : 99
        let translate = end + 2 + languageCount
        let s = specialTokens
        guard s.endToken == end, s.startOfTranscriptToken == end + 1, s.englishToken == end + 2,
              s.translateToken == translate, s.transcribeToken == translate + 1,
              s.startOfPreviousToken == translate + 3, s.noSpeechToken == translate + 4,
              s.noTimestampsToken == translate + 5, s.timeTokenBegin == translate + 6,
              s.whitespaceToken < end,
              allLanguageTokens == Set((end + 2)..<translate),
              tokenizer.convertIdToToken(graph.logitsSize) == nil else {
            throw OfflineWhisperError.incompatibleTokenizer
        }
        // Every model output ID must decode and round-trip; holes/duplicates cannot silently
        // become unknown tokens. This is a bounded ~52K metadata check, not model inference.
        for id in 0..<graph.logitsSize {
            guard let token = tokenizer.convertIdToToken(id), tokenizer.convertTokenToId(token) == id else {
                throw OfflineWhisperError.incompatibleTokenizer
            }
        }
        for index in 0...1500 {
            let token = String(format: "<|%.2f|>", locale: Locale(identifier: "en_US_POSIX"), Double(index) * 0.02)
            guard tokenizer.convertTokenToId(token) == s.timeTokenBegin + index else {
                throw OfflineWhisperError.incompatibleTokenizer
            }
        }
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    // BPE lookup can return unknownTokenId for an absent token. Whisper uses this
    // API to test special/language-token presence, so require an exact round-trip.
    private static func exactTokenID(_ token: String, in tokenizer: any Tokenizer) -> Int? {
        guard let id = tokenizer.convertTokenToId(token), tokenizer.convertIdToToken(id) == token else { return nil }
        return id
    }

    func convertTokenToId(_ token: String) -> Int? { Self.exactTokenID(token, in: tokenizer) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let full = Array(decode(tokens: tokenIds).unicodeScalars)
        var offset = 0
        var pending: [Int] = []
        var units: [(String, [Int])] = []
        for (position, token) in tokenIds.enumerated() {
            pending.append(token)
            let decoded = decode(tokens: pending)
            let scalars = Array(decoded.unicodeScalars)
            // Compare scalar offsets in the *full* decoded string. Never reuse an index
            // created for another Swift String; byte fragments and emoji invalidate it.
            let matchesFull = scalars.enumerated().allSatisfy { index, scalar in
                scalar.value != 0xfffd || (offset + index < full.count && full[offset + index].value == 0xfffd)
            }
            // A literal U+FFFD also spans three UTF-8 bytes. Matching its scalar in the
            // full text alone would emit each incomplete byte as a replacement character.
            // Only split at a boundary whose independently decoded suffix is stable.
            let suffix = Array(tokenIds.dropFirst(position + 1))
            let complete = matchesFull && (!scalars.contains(where: { $0.value == 0xfffd }) ||
                decoded + decode(tokens: suffix) == decode(tokens: pending + suffix))
            if complete && !scalars.isEmpty {
                units.append((decoded, pending)); pending = []; offset += scalars.count
            }
        }
        if !pending.isEmpty { units.append((decode(tokens: pending), pending)) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let unspaced = ["zh", "ja", "th", "lo", "my", "yue"].contains(recognizer.dominantLanguage?.rawValue ?? "")
        var words: [String] = [], groups: [[Int]] = []
        for (word, tokens) in units {
            let stripped = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuation = !stripped.isEmpty && stripped.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if unspaced || words.isEmpty || word.first?.isWhitespace == true || punctuation || tokens[0] >= specialTokens.specialTokenBegin {
                words.append(word); groups.append(tokens)
            } else {
                words[words.count - 1] += word; groups[groups.count - 1] += tokens
            }
        }
        return (words, groups)
    }
}
