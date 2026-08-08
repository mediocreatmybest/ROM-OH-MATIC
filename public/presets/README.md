# Build presets

Each `*.json` file here becomes an entry in the advanced wizard's "Start
from a preset" dropdown, served by `../presets.php`.

A preset is a named set of deviations from iPXE's own defaults. Applying
one fills the form in; nothing is locked afterwards, and editing any
option switches the dropdown to "Custom".

The easiest way to write one is to not write it by hand: configure the
advanced wizard the way you want it, then use **Save preset** next to the
build button. That names the configuration and downloads it in this
format, already including the output format and any embedded script.

To add one, drop the file in this directory -- for the container, bind
mount over it:

```bash
docker run --detach \
  --publish 8080:80 \
  --volume /path/to/my-presets:/opt/rom-o-matic/public/presets \
  mediocreatmybest/ipxe-buildweb:latest
```

Note that a bind mount *replaces* this directory, so the bundled presets
disappear unless you copy them into yours first.

A file that is not valid JSON, or is missing `name`/`options`, is skipped
with a message in the web server's error log rather than breaking the
dropdown for every other preset.

Presets are served to the browser, so treat anything in one as public.
In particular an `embed` script is readable by anyone who can reach the
app -- don't put credentials or internal-only URLs in a preset. A
certificate is never carried in one; it is per-site input supplied
through the wizard's own certificate-trust section.

## Format

```jsonc
{
  // Required.
  "name": "My deployment",
  "options": {
    // Keys are "<header>.h/<DEFINE>", exactly as the wizard names them.
    // Booleans take 0/1; value options take a string.
    "general.h/NET_PROTO_IPV6": 0,
    "general.h/PING_CMD": 1,
    "console.h/KEYBOARD_MAP": "uk"
  },

  // All optional.
  "description": "Shown under the dropdown.",
  "source": "Where these values came from.",
  "notes": "Not displayed -- for whoever maintains the file.",
  "trust_note": "Shown under the dropdown, for certificate guidance.",
  "outputformat": "bin-x86_64-efi/snponly.efi",
  "revision": "<a value from the revision dropdown>",
  "embed": "#!ipxe\n...",
  "requires_trust_cert": false
}
```

`outputformat` and `revision` are checked against what the wizard
actually offers; a value that is not in the list is reported rather than
applied silently. Option keys naming something absent from the iPXE
revision being parsed are listed as skipped, so a preset written against
an older revision says so instead of quietly applying a subset.

## A note on defaults

Options a preset sets are always sent to the build, even when they look
like they already match the default shown on screen. `parseheaders.py`
reports one default per option, taken from the header's top level, but a
platform block can override it for the target actually being built --
upstream's `general.h` defines `PARAM_CMD` and seven others at the top
level and then `#undef`s them under `#if defined ( PLATFORM_pcbios )`.
Relying on the displayed default would leave those off in a BIOS build,
which for `PARAM_CMD` means every legacy-BIOS client fails to boot.
