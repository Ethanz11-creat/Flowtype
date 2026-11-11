#!/usr/bin/env python3
"""Link the research runner against existing `swift build` dependency objects.

Does not edit Package.swift or the app. Uses the current debug build's module maps
and link settings, so results must record that dependency build mode explicitly.
"""
import json
from pathlib import Path
import shlex
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / "build/asr-baseline-20261111"
    output.mkdir(parents=True, exist_ok=True)
    build = (root / ".build/debug").resolve()
    object_list = build / "FlowType.product/Objects.LinkFileList"
    if not object_list.exists():
        raise SystemExit("Run swift build first to produce the app's pinned dependency objects")
    objects = [x for x in object_list.read_text().splitlines() if "/FlowType.build/" not in x]
    # SPM quotes linker paths containing spaces. Retain that quoting in the
    # response file, but decode it before checking the corresponding files.
    parsed = [shlex.split(x) for x in objects]
    if not objects or any(len(x) != 1 or not Path(x[0]).is_file() for x in parsed):
        raise SystemExit("Dependency object list incomplete; run swift build")
    link_list = output / "dependency-objects.txt"
    link_list.write_text("\n".join(objects) + "\n")
    args = None
    for line in (root / ".build/debug.yaml").read_text().splitlines():
        if line.lstrip().startswith("args: [") and "FlowType.product/Objects.LinkFileList" in line:
            args = json.loads(line.strip()[6:])
            break
    if args is None:
        raise SystemExit("Cannot locate current SPM link command")
    for index in range(len(args) - 5):
        if args[index:index + 2] == ["-Xlinker", "-alias"]:
            del args[index:index + 6]
            break
    for index, value in enumerate(args):
        if value == "-o":
            args[index + 1] = str(build / "asr-baseline")
        if value.startswith("@") and "FlowType.product" in value:
            args[index] = "@" + str(link_list)
    args += ["-parse-as-library", "-I", str(build / "Modules"), str(root / "tools/NativeASRBaseline.swift")]
    description = json.loads((build / "description.json").read_text())
    qwen = next(v for k, v in description["swiftCommands"].items() if k.startswith("C.Qwen3ASR-"))
    compile_args = qwen["otherArguments"]
    index = 0
    while index < len(compile_args):
        if compile_args[index] == "-Xcc":
            args += compile_args[index:index + 2]
            index += 2
        else:
            index += 1
    (output / "build-command.json").write_text(json.dumps(args, indent=2) + "\n")
    with (output / "build.log").open("w") as handle:
        result = subprocess.run(args, stdout=handle, stderr=subprocess.STDOUT, cwd=root)
    print((output / "build.log").read_text())
    if result.returncode:
        raise SystemExit(result.returncode)
    print(f"Built {build / 'asr-baseline'} using {len(objects)} dependency objects")


if __name__ == "__main__":
    main()
