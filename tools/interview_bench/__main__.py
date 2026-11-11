import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description='FlowType interview-only ASR evaluation')
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare')
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        from .prepare import prepare
        print(json.dumps({'manifest': str(prepare(args.root, args.source_root))}))


if __name__ == '__main__':
    main()
