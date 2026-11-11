"""Pinned, explicitly downloaded assets; inference never invokes this module."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
from .schema import sha, write_json

Q06 = 'aufklarer/Qwen3-ASR-0.6B-MLX-4bit'
REV = 'bc441bd1e4295c1f42d9879f056049a925b6e013'
W_SHA = 'ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e'
S_REV = '84768cefdf5a3852400e9d8237f7315d14b64a08'
S_BLOB = '63cb73be394528ef8d4936fdaa4884890754d065'
Q_SHA = '70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf'


def download(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temp = path.with_suffix(path.suffix + '.part')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--connect-timeout', '15', '--max-time', '3600',
                        '--silent', '--show-error', url, '-o', str(temp)], check=True)
        if url.startswith('https://api.github.com/'):
            temp.write_bytes(base64.b64decode(json.loads(temp.read_text())['content']))
        temp.rename(path)


def assets(root, allow_download=False):
    directory = root / 'models'; directory.mkdir(parents=True, exist_ok=True)
    qdir = directory / 'qwen-0.6b'
    files = ['README.md', 'config.json', 'merges.txt', 'model.safetensors',
             'model.safetensors.index.json', 'tokenizer_config.json', 'vocab.json']
    sources = [(qdir / f, f'https://hf-mirror.com/{Q06}/resolve/{REV}/{f}') for f in files]
    sources += [(directory / 'whisper-base/base.pt', f'https://openaipublic.azureedge.net/main/whisper/models/{W_SHA}/base.pt'),
                (directory / 'silero-v5.1/silero_vad.jit', f'https://api.github.com/repos/snakers4/silero-vad/git/blobs/{S_BLOB}'),
                (directory / 'silero-v5.1/LICENSE', f'https://api.github.com/repos/snakers4/silero-vad/contents/LICENSE?ref={S_REV}'),
                (directory / 'whisper-base/LICENSE', 'https://api.github.com/repos/openai/whisper/contents/LICENSE?ref=v20250625'),
                (qdir / 'LICENSE', 'https://www.apache.org/licenses/LICENSE-2.0.txt')]
    # Qwen derivative's pinned card declares Apache-2.0; copy standard text if upstream commit differs.
    for path, url in sources:
        if allow_download:
            download(url, path)
        if not path.is_file():
            raise FileNotFoundError(path)
    if sha(qdir / 'model.safetensors') != Q_SHA:
        raise ValueError('Qwen weight checksum mismatch')
    if sha(directory / 'whisper-base/base.pt') != W_SHA:
        raise ValueError('Whisper weight checksum mismatch')
    silero = (directory / 'silero-v5.1/silero_vad.jit').read_bytes()
    if len(silero) != 2269612 or hashlib.sha1(f'blob {len(silero)}\0'.encode() + silero).hexdigest() != S_BLOB:
        raise ValueError('Silero Git blob mismatch')
    existing = Path.home() / 'Library/Application Support/Flowtype/models/aufklarer/Qwen3-ASR-1.7B-MLX-4bit'
    if not (existing / 'config.json').exists():
        raise FileNotFoundError(existing)
    record = dict(qwen_06_revision=REV, silero_revision=S_REV,
                  paths={'qwen-0.6b': str(qdir.resolve()), 'qwen-1.7b': str(existing),
                         'whisper-base': str((directory / 'whisper-base/base.pt').resolve())},
                  licenses={'qwen-0.6b': 'Apache-2.0 (pinned model card)', 'qwen-1.7b': 'Apache-2.0', 'whisper-base': 'MIT', 'silero-v5.1': 'MIT'},
                  files=[dict(path=str(p.resolve()), source=u, sha256=sha(p), bytes=p.stat().st_size) for p,u in sources],
                  existing_17_files={p.name: sha(p) for p in sorted(existing.iterdir()) if p.is_file()})
    write_json(directory / 'assets.json', record)
    return directory / 'assets.json'
