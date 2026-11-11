"""Link an isolated benchmark binary against existing pinned dependency objects."""
import json
from pathlib import Path
import shlex
import shutil
import subprocess
from .schema import sha, write_json


def build_native(output):
    root = Path(__file__).resolve().parents[2]
    build = (root / '.build/debug').resolve()
    output.mkdir(parents=True, exist_ok=True)
    objects = [x for x in (build / 'FlowType.product/Objects.LinkFileList').read_text().splitlines() if '/FlowType.build/' not in x]
    if not objects or any(len(shlex.split(x)) != 1 or not Path(shlex.split(x)[0]).is_file() for x in objects):
        raise ValueError('Missing dependency objects; run swift build')
    links = output.resolve() / 'dependency-objects.txt'; links.write_text('\n'.join(objects) + '\n')
    args = next(json.loads(line.strip()[6:]) for line in (root / '.build/debug.yaml').read_text().splitlines()
                if line.lstrip().startswith('args: [') and 'FlowType.product/Objects.LinkFileList' in line)
    for i in range(len(args) - 5):
        if args[i:i+2] == ['-Xlinker', '-alias']:
            del args[i:i+6]; break
    binary = output.resolve() / 'native-asr-bench'
    for i, value in enumerate(args):
        if value == '-o': args[i+1] = str(binary)
        if value.startswith('@') and 'FlowType.product' in value: args[i] = '@' + str(links)
    args += ['-parse-as-library', '-I', str(build / 'Modules'), str(Path(__file__).parent.resolve() / 'swift/NativeASRBench.swift')]
    desc = json.loads((build / 'description.json').read_text())
    qwen = next(v for k,v in desc['swiftCommands'].items() if k.startswith('C.Qwen3ASR-'))
    for i, value in enumerate(qwen['otherArguments'][:-1]):
        if value == '-Xcc': args += qwen['otherArguments'][i:i+2]
    write_json(output / 'build-command.json', args)
    with (output / 'build.log').open('w') as log:
        subprocess.run(args, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copyfile(build / 'mlx.metallib', output / 'mlx.metallib')
    write_json(output / 'identity.json', {'sha256':sha(binary), 'metal_sha256':sha(output/'mlx.metallib'), 'objects':len(objects), 'build_mode':'SPM debug dependency objects'})
    return binary
