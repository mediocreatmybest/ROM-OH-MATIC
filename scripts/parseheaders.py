import os
import re
import json
import argparse

# Initialize argument parser / trying to follow the original perl script
parser = argparse.ArgumentParser(description="Generate iPXE build options as a JSON file.")
parser.add_argument("directory", nargs="?", default="/opt/rom-o-matic/ipxe/src/config", help="Directory containing the .h files")

# parse arguments
args = parser.parse_args()

# create the options list
options = []

# Use the directory from argparse otherwise fallback to the default
directory = args.directory

# List all header files in the directory, excluding some
files = [f for f in os.listdir(directory) if f.endswith('.h') and not f.endswith(('defaults.h', 'colour.h', 'named.h'))]

# iterate through files in the directory
for file in files:
    with open(os.path.join(directory, file), 'r') as fh:
        lines = fh.readlines()

    # Copied from original perl, might need to fix
    for line in lines:
        regex_pattern = r'^(?P<Disabled>\*)?#(?P<Type>\w+)\s+(?P<Name>\w+)(?:(?!\s+/\*)\s+(?P<Value>"[^"]*"|[A-Za-z0-9_-]+|\d+))?(?:\s+/\*\s+(?P<Description>(?:.(?!\*/))+))?'

        match = re.match(regex_pattern, line)
        if match:
            groups = match.groupdict()
            value = (groups.get('Value') or '').strip('"')
            type = 'input' if value else groups['Type'].lower()

            # Add the options to the list
            options.append({
                'file': file,
                'type': type,
                'name': groups['Name'],
                'value': value,
                'description': groups.get('Description', '')
            })

# Sort the options by name
sorted_options = sorted(options, key=lambda x: x['name'])

# Output the options pretty JSON
output_json = json.dumps(sorted_options, indent=4, ensure_ascii=False)
print(output_json)
