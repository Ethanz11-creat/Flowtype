import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description='FlowType interview-only ASR evaluation')
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare')
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    p = commands.add_parser('assets')
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--download', action='store_true')
    p = commands.add_parser('models')
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--models', default='qwen-1.7b,qwen-0.6b,whisper-base')
    p.add_argument('--admission-only', action='store_true')
    p = commands.add_parser('replay')
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--prepare-annotations', action='store_true')
    p.add_argument('--import-annotations', type=Path)
    p.add_argument('--split', choices=['dev','eval'], default='eval')
    p = commands.add_parser('correction')
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--allow-cloud', action='store_true')
    args = parser.parse_args()
    if args.command == 'correction':
        if not args.allow_cloud: parser.error('Cloud requests require --allow-cloud')
        from .correction import run_correction
        print(run_correction(args.root))
    elif args.command == 'replay':
        from .annotate import prepare_annotations, import_annotations
        from .replay import run_sessions
        print(import_annotations(args.root,args.import_annotations) if args.import_annotations else prepare_annotations(args.root) if args.prepare_annotations else run_sessions(args.root,args.split))
    elif args.command == 'assets':
        from .assets import assets
        print(assets(args.root, args.download))
    elif args.command == 'models':
        from .models import run_models
        print(run_models(args.root, args.models.split(','), args.admission_only))
    elif args.command == 'prepare':
        from .prepare import prepare
        print(json.dumps({'manifest': str(prepare(args.root, args.source_root))}))


if __name__ == '__main__':
    main()
