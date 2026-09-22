"""Prepare only new RAW8 IDF inputs; native ip_generate owns generated HDL."""
import argparse
import json
from pathlib import Path
from prepare_ips import prepare


def main():
    """Reuse the version-specific generator without regenerating existing IPs."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--pds', default='E:/PDS_Pangu/PDS_2022.2-SP6.4')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / 'config/raw8_ip_catalog.json').read_text(encoding='utf-8'))
    for spec in config['ips']:
        target = root / 'ip' / spec['name'] / (spec['name'] + '.idf')
        if target.exists():
            raise FileExistsError(f'Preserve native output; review before regenerating {target}')
        print(prepare(spec, Path(args.pds), root))


if __name__ == '__main__':
    main()
