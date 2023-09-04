#!/usr/bin/env python3

import argparse
import json
import os
import re

parser = argparse.ArgumentParser(description='Parse .h files')
parser.add_argument('directory', nargs='?', default='/opt/rom-o-matic/ipxe/src/config', help='directory for header files')
args = parser.parse_args()

bool_list = []

for file in os.listdir(args.directory):
    if file.startswith('.') or not file.endswith('.h') or 'colour' in file:
        continue
    with open(os.path.join(args.directory, file)) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if '#define' in line:
                match = re.search(r'([a-zA-Z_\/\/\#]*)\s+(\w+)\s+(\W+)\s+([a-zA-Z0-9_\-\'\:\=\,\>\(\)\!\/ ]+)', line)
                if match:
                    type, name, _, desc = match.groups()
                    if 'define' in type:
                        if type.startswith('//'):
                            bool_list.append({'file': file, 'type': 'undef', 'name': name, 'description': desc})
                        else:
                            bool_list.append({'file': file, 'type': 'define', 'name': name, 'description': desc})
                    elif 'define' not in type:
                        bool_list.append({'file': file, 'type': 'input', 'name': type, 'value': name, 'description': desc})
                else:
                    match = re.search(r'([a-zA-Z_]*)\s+([a-zA-Z0-9\:\/\"\.\% ]+)$', line)
                    if match:
                        name, value = match.groups()
                        bool_list.append({'file': file, 'type': 'input', 'name': name, 'value': value, 'description': name})
            elif '#undef' in line:
                match = re.search(r'([a-zA-Z]*)\s+(\w+)\s+(\W+)\s+([a-zA-Z0-9_\- ]+)', line)
                if match:
                    type, name, _, desc = match.groups()
                    bool_list.append({'file': file, 'type': type, 'name': name, 'description': desc})
                    if 'undef' not in type:
                        bool_list.pop()

print(json.dumps(bool_list, indent=4))