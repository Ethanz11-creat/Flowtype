# Bundled ASR validation speech

These short formant-synthesized samples test explicit recognition connectivity and
runtime availability. They are not recordings of a person, reference transcriptions
for an accuracy score, or evidence that any ASR model understands either sample.
Listening and actual model/service quality validation remain Pending. The user sees
the destination and possible cost before explicitly sending a sample. No microphone,
foreground context, dictionary or clipboard is used. `auto` chooses the Chinese sample.

| File | Input text | PCM format | Duration | WAV SHA256 |
| --- | --- | --- | --- | --- |
| en.wav | Hello, this is a speech recognition test. | PCM signed 16-bit LE, 16000 Hz, mono | 3.045438 s | 0341fa437d4e93a039780bc1f9dc7783e37a09598e5e4a774a9ca73913a86813 |
| zh.wav | 你好，这是语音识别测试。 | PCM signed 16-bit LE, 16000 Hz, mono | 3.4610625 s | 10deb420ab53319fb8a0f14ae17a17e61b2e206136963a874d2b71455da912af |

Generated locally on 2026-11-10 using npm `mespeak@2.0.2` (wrapper's embedded
meSpeak version 1.9.6), from the unchanged short text above. Mandarin voice input
is Pinyin: `ni3 hao3, zhe4 shi4 yu3 yin1 shi2 bie2 ce4 shi4.`. Original output
was 22050 Hz, signed 16-bit mono. No engine, JS, configuration, voice data or
third-party recorded speech is included in the application resources.

Source package: https://registry.npmjs.org/mespeak/-/mespeak-2.0.2.tgz
Official project / voice and GPLv3 documentation: https://www.masswerk.at/mespeak/
Formant-synthesis description: https://espeak.sourceforge.net/
GPLv3 section 2: https://www.gnu.org/licenses/gpl-3.0.html#section2

Redistribution basis: GPLv3 §2 says output from running a covered work is covered
only if the output, given its content, constitutes a covered work. These are
formant-generated audio output of our own short text, not copies of program code,
voice definitions, or recorded third-party speech. We redistribute the resulting
WAVs on that output basis. Upstream did not separately grant CC0 for these WAVs;
we do not claim such a grant or rely on macOS `say` redistribution assumptions.
The generator and voice definitions remain subject to their upstream terms and
are not bundled. The generation input consists solely of the short original test sentences shown
above, created for this project. No third-party literary text was used.

Reproduce in a temporary generation directory after extracting the package:

```js
const fs = require('fs');
const speech = require('./mespeak/src/index.js');
speech.loadConfig(require('./mespeak/src/mespeak_config.json'));
speech.loadVoice(require('./mespeak/voices/en/en-us.json'));
fs.writeFileSync('en-probe.wav', speech.speak('Hello, this is a speech recognition test.', {rawdata:'buffer', speed:155}));
speech.loadVoice(require('./mespeak/voices/zh.json'));
fs.writeFileSync('zh-probe.wav', speech.speak('ni3 hao3, zhe4 shi4 yu3 yin1 shi2 bie2 ce4 shi4.', {rawdata:'buffer', speed:155}));
```

Resample with FFmpeg 8.1.2 (libswresample), for each `sample_language=en` and `sample_language=zh`:

```sh
ffmpeg -hide_banner -loglevel error -i "$sample_language-probe.wav" -ac 1 -ar 16000 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact -flags:a +bitexact "$sample_language.wav"
shasum -a 256 en.wav zh.wav
```

The store checks the container SHA256, RIFF size, PCM type, channel count, rate,
block alignment, and ≤8-second duration before converting to canonical mono
Float32 PCM. ASRValidationSample computes a separate canonical PCM fingerprint.
