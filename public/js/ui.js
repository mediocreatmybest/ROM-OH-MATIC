/*
 * ================================================================================
 * Dynamic iPXE image generator
 *
 * Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
 * Website: http://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
 * License: GNU General Public License version 3 or later; see LICENSE.txt
 * ================================================================================
 */

/* $(document).ready() equivalent -- runs fn immediately if the DOM is
 * already parsed (e.g. this script were ever loaded with `defer`), otherwise
 * waits for DOMContentLoaded. */
function onReady(fn) {
        if (document.readyState !== 'loading') {
                fn();
        } else {
                document.addEventListener('DOMContentLoaded', fn);
        }
}

onReady(function() {

        var roms = []; /* Global Object for roms ID validation */

        /* Set by the "HTTPS certificate trust" section below once a
         * submitted certificate has been validated by certificate.php;
         * read by buildcfg(). Normal (non-custom-trust) builds never touch
         * this. */
        var trustCertPem = null;

        /* Build an <option>, safely -- via textContent/property assignment
         * rather than string concatenation, so a value containing HTML
         * special characters (e.g. an iPXE header comment with a stray "<"
         * or "&") displays as literal text instead of risking broken or
         * injected markup. */
        function makeOption(value, text, selected) {
                var opt = document.createElement('option');
                opt.value = value;
                opt.textContent = text;
                if (selected) { opt.selected = true; }
                return opt;
        }

        /* Shared by the initial gitversion.php load and the #gitrevision
         * change handler below, so both build the header the same, safe
         * way. */
        function renderGitAbbrevHeader(version) {
                var p = document.createElement('p');
                var h2 = document.createElement('h2');
                h2.className = 'wizard-header';
                h2.textContent = 'Generating iPXE build image version ' + version;
                p.appendChild(h2);
                document.getElementById('gitabbrev').replaceChildren(p);
        }

        /* Shared loading/error status line for the three build-data
         * fetches below, separate from #gitrevision/#nics/#options
         * themselves -- loadcfg() polls those three elements for non-empty
         * content to know the wizard is ready, so writing loading text
         * into them directly would make it proceed before the real data
         * arrives. */
        var statusEl = document.getElementById('fetch-status');
        var pendingFetches = 3;
        var fetchErrors = [];
        if (statusEl) {
                statusEl.textContent = 'Loading build options...';
                statusEl.style.display = '';
                statusEl.classList.remove('error');
        }
        function fetchSettled(ok, detail) {
                pendingFetches -= 1;
                if (!ok) { fetchErrors.push(detail); }
                if (pendingFetches > 0 || !statusEl) { return; }
                if (fetchErrors.length === 0) {
                        statusEl.style.display = 'none';
                } else {
                        statusEl.textContent = 'Some build data failed to load: ' + fetchErrors.join('; ') + '. Try reloading the page.';
                        statusEl.classList.add('error');
                }
        }

        /* Fetch JSON with a bounded timeout, shape validation, and a
         * console + on-page error on failure, instead of failing silently. */
        function fetchJSON(url, validate, onSuccess) {
                var controller = new AbortController();
                var timedOut = false;
                var timeoutId = setTimeout(function() {
                        timedOut = true;
                        controller.abort();
                }, 15000);
                fetch(url, { signal: controller.signal, headers: { 'Accept': 'application/json' } })
                        .then(function(response) {
                                if (!response.ok) { throw new Error('HTTP ' + response.status); }
                                return response.json();
                        })
                        .then(function(data) {
                                clearTimeout(timeoutId);
                                if (!validate(data)) {
                                        console.error('Unexpected response shape from ' + url, data);
                                        fetchSettled(false, url + ' returned an unexpected response');
                                        return;
                                }
                                onSuccess(data);
                                fetchSettled(true);
                        })
                        .catch(function(err) {
                                clearTimeout(timeoutId);
                                console.error('Request failed: ' + url + ' (' + (err && err.message ? err.message : err) + ')');
                                fetchSettled(false, url + ' ' + (timedOut ? 'timed out' : 'failed to load'));
                        });
        }

        fetchJSON("gitversion.php", function(data) {
                return Array.isArray(data) && data.every(function(rev) { return typeof rev === 'string'; });
        }, function(data) {
                renderGitAbbrevHeader(data[0] || '(none)');

                var revisionOptions = document.createDocumentFragment();
                revisionOptions.appendChild(makeOption('master', 'master', true));
                for (var i = 0; i < data.length; i++) {
                        revisionOptions.appendChild(makeOption(data[i], data[i]));
                }
                document.getElementById('gitrevision').replaceChildren(revisionOptions);
        })

        fetchJSON("nics.php", function(data) {
                return Array.isArray(data) && data.every(function(nic) { return nic && typeof nic.ipxe_name === 'string'; });
        }, function(listnics) {
                var nicOptions = document.createDocumentFragment();
                nicOptions.appendChild(makeOption('all', 'all-drivers', true));
                nicOptions.appendChild(makeOption('undionly', 'undionly'));
                nicOptions.appendChild(makeOption('undi', 'undi'));
                for (var i = 0; i < listnics.length; i++) {
                        nicOptions.appendChild(makeOption(listnics[i].ipxe_name, listnics[i].ipxe_name));
                        if (listnics[i].device_id != null && listnics[i].vendor_id != null) {
                                roms.push({device_id: listnics[i].device_id, vendor_id: listnics[i].vendor_id});
                        }
                }
                document.getElementById('nics').replaceChildren(nicOptions);
        })

        fetchJSON("options.php", function(data) {
                return Array.isArray(data) && data.every(function(opt) {
                        return opt && typeof opt.name === 'string' && typeof opt.type === 'string' && typeof opt.file === 'string';
                });
        }, function(custom) {
                // List of subtitle of options
                var subtitle = new Object;
                subtitle._CMD = 'Command-line commands to include:';
                subtitle.NET_PROTO = 'Network protocols:';
                subtitle.IMAGE = 'Image types:';
                subtitle.PXE_ = 'PXE support:';
                subtitle.COM = 'Serial options:';
                subtitle.DOWNLOAD_PROTO = 'Download protocols:';
                subtitle.SANBOOT_PROTO = 'SAN boot protocols:';
                subtitle.CRYPTO_80211 = 'Wireless Interface Options:';
                subtitle.CONSOLE = 'Console options:';
                subtitle.ISA = 'ISA options:';
                subtitle.PCIAPI = 'PCIAPI options:';
                subtitle.COLOR = 'Color options:';
                subtitle.DNS = 'Name resolution modules:';
                subtitle.VMWARE = 'VMware options:'
                subtitle.GDB = 'Debugger options:'
                subtitle.NONPNP = 'ROM-specific options:';
                subtitle.ERRMSG = 'Error message tables to include:';
                subtitle.BANNER = 'Timer configuration:';
                subtitle.NETDEV = 'Obscure configuration options:';
                subtitle.PRODUCT = 'Branding options:';
                subtitle.DHCP = 'DHCP timeout parameters:';
                subtitle.PXEBS = 'PXE Boot Server timeout parameters:';
                subtitle.USB = 'USB configuration:';
                subtitle.HTTP = 'HTTP extensions:';
                subtitle.VNIC = 'Virtual network devices:';
                subtitle.CRYPTO = 'Crypto configuration:';
                subtitle.TLS = 'TLS configuration:';
                subtitle.OCSP = 'OCSP Configuration:'

                /* A small "?" icon that reveals the option's description in
                 * a popover on hover, click, or keyboard focus -- CSS-only
                 * (:hover / :focus-within in ui.css), no JS event handling
                 * needed, so hover/click/keyboard-Tab all work identically
                 * without three separate code paths. `idBase` must already
                 * be a safe id fragment (fieldName is file+"/"+NAME, both
                 * always valid C-identifier-like strings from iPXE's own
                 * headers, with "/" swapped out since it's an unusual id
                 * character to carry through, even though technically legal
                 * in an HTML id). Returns null if there's nothing to show. */
                function makeHelpIcon(idBase, text) {
                        if (!text) { return null; }
                        var id = 'opthelp-' + idBase.replace(/[^A-Za-z0-9_-]/g, '-');
                        var wrap = document.createElement('span');
                        wrap.className = 'option-help-wrap';
                        var button = document.createElement('button');
                        button.type = 'button';
                        button.className = 'option-help';
                        button.textContent = '?';
                        button.setAttribute('aria-describedby', id);
                        button.setAttribute('aria-label', 'About ' + idBase);
                        var popover = document.createElement('span');
                        popover.className = 'option-description-popover';
                        popover.id = id;
                        popover.setAttribute('role', 'tooltip');
                        popover.textContent = text;
                        wrap.appendChild(button);
                        wrap.appendChild(popover);
                        return wrap;
                }

                /* <label class="option-row"> with the option name on its own
                 * line and the input + "?" icon directly below it, always in
                 * that structure regardless of name length -- previously the
                 * name, input, and icon were just inline content, so
                 * whether the input/icon wrapped onto a new line depended on
                 * how long the name text was relative to the available
                 * width, giving an inconsistent row-to-row layout. Fixed
                 * spacing/alignment now comes entirely from CSS
                 * (.option-row/.option-name/.option-control in ui.css)
                 * instead of manual <br> tags. Shared by the BANNER/hex-
                 * value "define" overrides (input value comes from the
                 * description) and the "input" type (input value comes from
                 * .value, but the help text is still sourced from
                 * .description, same as the original). */
                function makeTextOptionLabel(name, fieldName, minSize, fieldValue, descriptionText, trailingPrefix) {
                        var desc = (name === descriptionText) ? '' : descriptionText;
                        var label = document.createElement('label');
                        label.className = 'option-row';
                        label.setAttribute('for', name);

                        var nameEl = document.createElement('span');
                        nameEl.className = 'option-name';
                        nameEl.textContent = name + ':';
                        label.appendChild(nameEl);

                        var controlWrap = document.createElement('span');
                        controlWrap.className = 'option-control';
                        var input = document.createElement('input');
                        input.type = 'text';
                        input.id = name;
                        /* minSize is a floor, not the final width -- a fixed
                         * size=6 for every "short" option left symbolic
                         * values (e.g. TLS_VERSION_MIN's "TLS_VER1_2",
                         * LOG_LEVEL's "G_NONE") truncated and unreadable.
                         * Grow to fit the actual value, capped so a handful
                         * of unusually long ones (e.g. a full URL) don't
                         * blow out the layout. */
                        input.size = Math.max(minSize, Math.min(fieldValue.length + 2, 60));
                        input.placeholder = fieldValue;
                        input.value = fieldValue;
                        input.name = fieldName;
                        controlWrap.appendChild(input);
                        var helpIcon = makeHelpIcon(fieldName, trailingPrefix + desc);
                        if (helpIcon) { controlWrap.appendChild(helpIcon); }
                        label.appendChild(controlWrap);

                        return label;
                }

                /* <label class="option-row option-row-checkbox">: checkbox,
                 * help link, and "?" icon together on one line -- unlike the
                 * text-option row above, there's no separate "name" line
                 * needed here, since "[checkbox] NAME_LINK" is already short
                 * and consistent regardless of which option it is. Still
                 * uses the same .option-row spacing as the text rows so
                 * every row in the list has the same vertical rhythm. The
                 * external ipxe.org link and the local description popover
                 * are complementary, not duplicates -- the link points at
                 * the full upstream docs page, the popover shows the
                 * description already parsed out of this build's headers. */
                function makeCheckboxOptionLabel(name, fieldName, checked, description) {
                        var label = document.createElement('label');
                        label.className = 'option-row option-row-checkbox';
                        label.setAttribute('for', name);

                        var controlWrap = document.createElement('span');
                        controlWrap.className = 'option-control';
                        var input = document.createElement('input');
                        input.type = 'checkbox';
                        input.id = name;
                        input.value = checked ? '1' : '0';
                        input.name = fieldName;
                        input.checked = checked;
                        controlWrap.appendChild(input);
                        var link = document.createElement('a');
                        link.className = 'help_buildcfg';
                        link.href = 'http://www.ipxe.org/buildcfg/' + name;
                        link.target = '_blank';
                        link.textContent = name;
                        controlWrap.appendChild(link);
                        var helpIcon = makeHelpIcon(fieldName, description);
                        if (helpIcon) { controlWrap.appendChild(helpIcon); }
                        label.appendChild(controlWrap);

                        return label;
                }

                var listoptions = document.createDocumentFragment();
                var previous;
                for (var i = 0; i < custom.length; i++) {
                        for (var y in subtitle)
                        {
                                var regexp = new RegExp(y);
                                var match = regexp.exec(custom[i].name);
                                if (previous == y && match == y)
                                {
                                        break;
                                }
                                else if (match != null && previous != y)
                                {
                                        var h3 = document.createElement('h3');
                                        h3.className = 'wizard-option';
                                        h3.textContent = subtitle[y];
                                        listoptions.appendChild(h3);
                                        previous = y;
                                        break;
                                }
                        }
                        var fieldName = custom[i].file + '/' + custom[i].name;
                        if (custom[i].type == "define" && (custom[i].name.indexOf("BANNER") !== -1 || custom[i].description.indexOf("0x") !== -1)) {
                                listoptions.appendChild(makeTextOptionLabel(custom[i].name, fieldName, 6, custom[i].description, custom[i].description, 'Default: '));
                        } else if (custom[i].type == "define") {
                                listoptions.appendChild(makeCheckboxOptionLabel(custom[i].name, fieldName, true, custom[i].description));
                        } else if (custom[i].type == "undef") {
                                listoptions.appendChild(makeCheckboxOptionLabel(custom[i].name, fieldName, false, custom[i].description));
                        } else if (custom[i].type == "input") {
                                var size = (custom[i].name.indexOf("PRODUCT") !== -1) ? 50 : 6;
                                listoptions.appendChild(makeTextOptionLabel(custom[i].name, fieldName, size, custom[i].value, custom[i].description, ''));
                        } else { alert("we have an issue"); }
                }
                document.getElementById('options').replaceChildren(listoptions);
        })

        /* Reset from on reload */
        document.querySelector('input[name=wizardtype]').checked = true;
        document.getElementById('outputformatstd').selectedIndex = 0;
        document.getElementById('outputformatadv').selectedIndex = 0;

        document.getElementById('formtype').addEventListener('change', function() {
                var wizardtype = document.querySelector('input[name=wizardtype]:checked').value;
                if (wizardtype == "standard")
                {
                        document.getElementById('divstandard').style.display = 'inline';
                        document.getElementById('divadvanced').style.display = 'none';
                }
                else if (wizardtype == "advanced")
                {
                        document.getElementById('divstandard').style.display = 'none';
                        document.getElementById('divadvanced').style.display = 'inline';
                }
        });

        document.getElementById('gitrevision').addEventListener('change', function() {
                renderGitAbbrevHeader(document.getElementById('gitrevision').value);
        });

        document.getElementById('outputformatstd').addEventListener('change', function() {
                var outputformat = document.getElementById('outputformatstd').value;
                if (outputformat == "-")
                {
                        document.getElementById('embedded').style.display = 'none';
                        document.getElementById('debug').style.display = 'none';
                        document.getElementById('gitversion').style.display = 'none';
                        document.getElementById('build').style.display = 'none';
                }
                else
                {
                        document.getElementById('embedded').style.display = 'inline';
                        document.getElementById('debug').style.display = 'inline';
                        document.getElementById('gitversion').style.display = 'inline';
                        document.getElementById('build').style.display = 'inline';
                }
        });

        /* BIOS (bindir exactly "bin", not "bin-i386-efi"/"bin-x86_64-efi")
         * builds don't compile in HTTPS at all -- a long-standing iPXE
         * decision, not a bug -- so certificate trust has no effect there.
         * Warn rather than hide the section outright, since hiding it would
         * look like the feature vanished rather than explain why it
         * doesn't apply. */
        function updateTrustBiosWarning(outputformat) {
                var bindir = outputformat.split('/')[0];
                document.getElementById('trust_bios_warning').style.display =
                        (bindir === 'bin') ? 'block' : 'none';
        }

        document.getElementById('outputformatadv').addEventListener('change', function() {
                var outputformat = document.getElementById('outputformatadv').value;
                updateTrustBiosWarning(outputformat);
                if (outputformat.indexOf("rom", outputformat.length - 3) !== -1)
                {	/* If a ROM */
                        document.getElementById('rom').style.display = 'inline';
                        document.getElementById('iface').style.display = 'none';
                        document.getElementById('config').style.display = 'none';
                        document.getElementById('trust').style.display = 'inline';
                        document.getElementById('embedded').style.display = 'inline';
                        document.getElementById('debug').style.display = 'none';
                        document.getElementById('gitversion').style.display = 'inline';
                        document.getElementById('build').style.display = 'inline';
                }
                else if (outputformat == "-" || outputformat == "--")
                {	/* If default */
                        document.getElementById('rom').style.display = 'none';
                        document.getElementById('iface').style.display = 'none';
                        document.getElementById('config').style.display = 'none';
                        document.getElementById('trust').style.display = 'none';
                        document.getElementById('embedded').style.display = 'none';
                        document.getElementById('debug').style.display = 'none';
                        document.getElementById('gitversion').style.display = 'none';
                        document.getElementById('build').style.display = 'none';
                }
                else
                {
                        document.getElementById('rom').style.display = 'none';
                        document.getElementById('iface').style.display = 'inline';
                        document.getElementById('config').style.display = 'inline';
                        document.getElementById('trust').style.display = 'inline';
                        document.getElementById('embedded').style.display = 'inline';
                        document.getElementById('debug').style.display = 'inline';
                        document.getElementById('gitversion').style.display = 'inline';
                        document.getElementById('build').style.display = 'inline';
                }
        });

        /* Compose the build.fcgi parameters. `omitTrustCert`, when true,
         * leaves out TRUST_CERT even if custom trust is selected and
         * validated -- used for the "Editable Configuration URL" shown by
         * #save, since raw certificate PEM data must never end up in a
         * saved/shareable URL (a future revision could carry a certificate
         * reference instead, without embedding the certificate itself).
         * The actual build submission (see the #ipxeimage submit handler
         * below) always needs it when custom trust is selected, since
         * that's the only way the build gets the certificate. Returns a
         * URLSearchParams, or undefined if the current form state is
         * invalid (an inline error has already been shown in that case). */
        function buildcfgParams(omitTrustCert) {
                /* Get values from form */
                var wizard = document.querySelector('input[name=wizardtype]:checked').value;
                var bindir = "";
                var binary = "";
                /* [key, value] pairs for changed advanced options, applied
                 * to the URLSearchParams built below once BINARY/BINDIR are
                 * known -- keeps the fixed fields first in the generated
                 * URL, matching the previous, hand-built order. */
                var optionEntries = [];
                /* Values are left undecoded here; URLSearchParams.set()
                 * below does the percent-encoding. Previously this used
                 * escape(), which mis-encodes U+0080-U+00FF as invalid
                 * UTF-8 -- verified against the real backend: escape()
                 * sends an accented character as a raw Latin-1 byte, which
                 * the server then reads as corrupted, invalid UTF-8. */
                var debug = document.getElementById('setdebug').value;
                var revision = document.getElementById('gitrevision').value;
                var embed = document.getElementById('embed').value;
                if (embed == "#!ipxe") { embed = ""; }
                if (wizard == "standard")
                { 	/* get values from elements on the STD wizard */
                        bindir = document.getElementById('outputformatstd').value.split("/")[0];
                        binary = document.getElementById('outputformatstd').value.split("/")[1];
                }
                else if (wizard == "advanced")
                {	/* get values from elements on the ADV wizard */
                        bindir = document.getElementById('outputformatadv').value.split("/")[0];
                        binary = document.getElementById('outputformatadv').value.split("/")[1];
                        if (binary.indexOf("rom", binary.length - 3) !== -1)
                        {
                                /* Ensure device_id and vendor_id are valid */
                                var pci_vendor_code = document.getElementById('pci_vendor_code').value.toLowerCase();
                                var pci_device_code = document.getElementById('pci_device_code').value.toLowerCase();
                                var idx_nic = roms.filter(function(obj) {
                                        return obj.vendor_id == pci_vendor_code && obj.device_id == pci_device_code;
                                });
                                if (pci_vendor_code && pci_device_code && idx_nic && idx_nic.length > 0) {
                                    binary = pci_vendor_code + pci_device_code + "." + binary;
                                } else {
                                    var romsIdError = document.getElementById('pci_roms_id_error');
                                    romsIdError.style.display = 'inline';
                                    romsIdError.innerHTML = "Invalid or unsupported pci_vendor_code or pci_device_code <br/>";
                                    return;
                                }
                        }
                        /* For all Checkbox in options div. The trailing ":"
                         * on the key is part of the wire format build.fcgi
                         * expects for boolean overrides, not a typo -- see
                         * the matching strip in loadcfg(). */
                        document.querySelectorAll('#options input[type=checkbox]').forEach(function(input, index) {
                                var name = input.name;
                                var value = input.checked ? 1 : 0;
                                if (input.value != value) {
                                        console.log( "Checkbox:" + index + ": " + name + " default: " + input.value + " new: " + input.checked );
                                        optionEntries.push([name + ":", value]);
                                }
                        });
                        /* For all text field in options div */
                        document.querySelectorAll('#options input[type=text]').forEach(function(input, index) {
                                var name = input.name;
                                var placeholder = input.placeholder;
                                if (input.value != placeholder) {
                                        console.log( "Text:" + index + ": " + name + " default: " + input.placeholder + " new: " + input.value);
                                        optionEntries.push([name, input.value]);
                                }
                        });
                }

                /* Custom certificate trust -- only meaningful in the
                 * advanced wizard. If selected, a validated certificate
                 * must already be present (see the "HTTPS certificate
                 * trust" section below); otherwise block the build with an
                 * inline error, the same way an invalid PCI ID does above,
                 * rather than silently submitting standard trust instead. */
                var trustCertToSend = null;
                if (wizard == "advanced") {
                        var trustMode = document.querySelector('input[name=trustmode]:checked').value;
                        if (trustMode == "custom") {
                                if (!trustCertPem) {
                                        var trustStatus = document.getElementById('trust_cert_status');
                                        trustStatus.textContent = 'Provide and validate a certificate before building, or switch back to standard trust.';
                                        trustStatus.style.display = '';
                                        trustStatus.classList.add('error');
                                        return;
                                }
                                trustCertToSend = trustCertPem;
                        }
                }

                var params = new URLSearchParams();
                params.set('BINARY', binary);
                params.set('BINDIR', bindir);
                params.set('REVISION', revision);
                params.set('DEBUG', debug);
                params.set('EMBED.00script.ipxe', embed);
                optionEntries.forEach(function(entry) { params.append(entry[0], entry[1]); });
                if (trustCertToSend && !omitTrustCert) { params.set('TRUST_CERT', trustCertToSend); }

                console.log('{ BINARY: ['+ binary +'], BINDIR: ['+ bindir +'], DEBUG: ['+ debug +'], REVISION: ['+ revision +'], EMBED: ['+ embed +'] , OPTIONS: ['+ optionEntries.length +' changed], TRUST_CERT: ['+ (trustCertToSend ? 'set' : 'none') +']}');

                return params;
        };

        /* String form of buildcfgParams(), used only for the cert-free
         * "Editable Configuration URL" -- the actual build submission below
         * posts buildcfgParams() as form data instead, so a certificate
         * never has to travel in a URL. */
        function buildcfg(omitTrustCert) {
                var params = buildcfgParams(omitTrustCert);
                return params ? 'build.fcgi?' + params.toString() : undefined;
        };

	/* Update fields with defaults from current URL */
	function loadcfg(delay) {
		/* if the form is not ready, wait a while */
		if (!document.getElementById('gitrevision') || !document.getElementById('nics') || !document.getElementById('options')
			|| document.getElementById('gitrevision').innerHTML.trim().length == 0
			|| document.getElementById('nics').innerHTML.trim().length == 0
			|| document.getElementById('options').innerHTML.trim().length == 0
		) {
			if (typeof delay == "undefined") {
				delay = 0;
			}
			if (delay < 700) {
				delay = (delay*2)+100;
			} else if (delay < 3000) {
				delay += 100
			} else {
				delay = 3000
			}
			setTimeout(function(){loadcfg(delay);}, delay);
			return;
		}
		/* Parse querystring and generate args. URLSearchParams decodes
		 * values automatically (unlike the previous hand-rolled split,
		 * which left checkbox/text option values undecoded -- e.g. a
		 * saved "My Product Name" restored as the literal string
		 * "My%20Product%20Name"). Its decoding is also lenient rather
		 * than throwing on malformed input, so a saved URL from before
		 * the escape()-to-encodeURIComponent() fix above won't crash the
		 * restore, even though characters outside plain ASCII in such a
		 * URL may not come back exactly as originally typed -- that data
		 * was already corrupted at save time by the bug this fixes. */
		var searchParams = new URLSearchParams(window.location.search);
		if (!searchParams.toString()) return;
		var args = {};
		searchParams.forEach(function(value, key) {
			args[key.replace(/:$/, '')] = value;
		});
		/* Get values from args */
		var bindir = (args['BINDIR'] > "") ? args['BINDIR'] : "";
		var binary = (args['BINARY'] > "") ? args['BINARY'] : "";
		var debug = (args['DEBUG'] > "") ? args['DEBUG'] : "";
		var revision = (args['REVISION'] > "") ? args['REVISION'] : "";
		var embed = (args['EMBED.00script.ipxe'] > "") ? args['EMBED.00script.ipxe'] : "";
		/* parse pci id for rom images */
		if (binary.indexOf("rom", binary.length - 3) !== -1)
		{
			var pci_id_code = binary.split('.', 1)[0];
			binary = binary.substr(pci_id_code.length + 1);
			if (pci_id_code.length != 8) {
				console.error("Unknown format for pci id: ", pci_id_code);
			} else {
				/* Ensure device_id and vendor_id are valid */
				var pci_vendor_code = pci_id_code.substr(0,4);
				var pci_device_code = pci_id_code.substr(4,4);
				var pciVendorInput = document.getElementById('pci_vendor_code');
				var pciDeviceInput = document.getElementById('pci_device_code');
				pciVendorInput.value = pci_vendor_code;
				pciVendorInput.dispatchEvent(new Event('change'));
				pciDeviceInput.value = pci_device_code;
				pciDeviceInput.dispatchEvent(new Event('change'));
				var idx_nic = roms.filter(function(obj) {
					return obj.vendor_id == pci_vendor_code && obj.device_id == pci_device_code;
				});
				if (!pci_vendor_code || !pci_device_code || !idx_nic || idx_nic.length == 0) {
					var romsIdError = document.getElementById('pci_roms_id_error');
					romsIdError.style.display = 'inline';
					romsIdError.innerHTML = "Invalid or unsupported pci_vendor_code or pci_device_code <br/>";
				}
			}
		}
		/* build up full binary string */
		var fullbinary = bindir + "/" + binary;
		/* Set values in form. Already decoded by URLSearchParams above. */
		document.getElementById('setdebug').value = debug;
		document.getElementById('gitrevision').value = revision;
		document.getElementById('embed').value = embed;
		/* The standard and advanced wizards use different, only
		 * partially-overlapping sets of BINDIR/BINARY values (e.g.
		 * "undionly.kpxe" only exists in the standard wizard's list).
		 * Restore into whichever wizard's <select> actually has this
		 * value, instead of always forcing advanced mode -- setting an
		 * unmatched <select> value silently no-ops, which is why
		 * standard-wizard saved URLs previously failed to restore. */
		var isStandardValue = Array.from(document.querySelectorAll('#outputformatstd option')).some(function(opt) {
			return opt.value === fullbinary;
		});
		if (isStandardValue) {
			document.getElementById('standard').click();
			document.getElementById('outputformatstd').value = fullbinary;
			document.getElementById('outputformatstd').dispatchEvent(new Event('change'));
		} else {
			document.getElementById('advanced').click();
			document.getElementById('outputformatadv').value = fullbinary;
			document.getElementById('outputformatadv').dispatchEvent(new Event('change'));
		}
		/* For all Checkboxes in options div */
		document.querySelectorAll('#options input[type=checkbox]').forEach(function(input) {
			var name = input.name;
			var value = input.checked ? 1 : 0;
			if (typeof args[name] != "undefined" && value != args[name]) {
				input.checked = (args[name] == 1);
			}
		});
		/* For all text field in options div */
		document.querySelectorAll('#options input[type=text]').forEach(function(input) {
			var name = input.name;
			if (typeof args[name] != "undefined") {
				input.value = args[name];
			}
		});
	}

        /* Shows a build failure (build.fcgi's 500 response body) in the
         * same <dialog> the About/Save popups use, since a failed
         * background fetch() would otherwise fail silently instead of
         * leaving the user on an error page the way the old GET navigation
         * did. */
        function showBuildError(message) {
                var popup = document.getElementById('about_pop_up');
                var content = popup.querySelector('.content');
                content.innerHTML = '';
                var heading = document.createElement('h2');
                heading.textContent = 'Build failed';
                var pre = document.createElement('pre');
                pre.textContent = message;
                content.appendChild(heading);
                content.appendChild(pre);
                popup.showModal();
        }

        document.getElementById('ipxeimage').addEventListener('submit', function(event) {
                /* stop form from submitting normally */
                event.preventDefault();
                var params = buildcfgParams();
                if (!params) { return; }
                var formData = new FormData();
                params.forEach(function(value, key) { formData.append(key, value); });
                /* POST, not the previous GET navigation -- a custom trust
                 * certificate's PEM (up to 64 KiB) must never travel in a
                 * URL: query strings end up in browser history and in
                 * front-end web-server/proxy access logs before build.fcgi's
                 * own request-parameter redaction ever gets a chance to
                 * apply. */
                fetch('build.fcgi', { method: 'POST', body: formData }).then(function(response) {
                        if (!response.ok) {
                                return response.text().then(showBuildError);
                        }
                        var disposition = response.headers.get('Content-Disposition') || '';
                        var match = /filename="?([^";]+)"?/.exec(disposition);
                        var filename = match ? match[1] : 'ipxe.bin';
                        return response.blob().then(function(blob) {
                                var objectUrl = URL.createObjectURL(blob);
                                var link = document.createElement('a');
                                link.href = objectUrl;
                                link.download = filename;
                                document.body.appendChild(link);
                                link.click();
                                link.remove();
                                setTimeout(function() { URL.revokeObjectURL(objectUrl); }, 1000);
                        });
                }).catch(function(err) {
                        showBuildError(String(err));
                });
        });


        /* About / Save popup, using the native <dialog> element -- replaces
         * bPopup, which is unmaintained and only ever did two things here:
         * inject fetched content and show/hide a modal. <dialog> handles
         * Escape-to-close and focus restoration on close natively; the "x"
         * button and backdrop-click close are wired up explicitly below,
         * since showModal()'s backdrop doesn't close on click by default. */
        (function() {
                var popup = document.getElementById('about_pop_up');
                var content = popup.querySelector('.content');

                function closePopup() {
                        popup.close();
                        content.innerHTML = '';
                }

                popup.querySelector('.b-close').addEventListener('click', function(e) {
                        e.preventDefault();
                        closePopup();
                });
                popup.addEventListener('click', function(e) {
                        if (e.target === popup) { closePopup(); }
                });
                /* <dialog> is specified to close on Escape and fire 'close'
                 * on every close path natively -- testing found neither
                 * reliable in every environment, so both are handled
                 * explicitly here rather than assumed. Harmless where the
                 * native behaviour also fires; it just closes an
                 * already-closed dialog. */
                popup.addEventListener('keydown', function(e) {
                        if (e.key === 'Escape') { closePopup(); }
                });
                popup.addEventListener('close', function() {
                        content.innerHTML = '';
                });

                function showAbout(e) {
                        e.preventDefault();
                        fetch('about.html').then(function(response) {
                                return response.text();
                        }).then(function(html) {
                                content.innerHTML = html;
                                popup.showModal();
                        });
                }
                document.getElementById('about').addEventListener('click', showAbout);
                document.getElementById('about2').addEventListener('click', showAbout);

                document.getElementById('save').addEventListener('click', function(e) {
                        e.preventDefault();
                        var baseURI = document.baseURI.replace(window.location.search,'').replace(/index\.html$/,'');
                        /* Validate current form state (this is also where an
                         * invalid PCI ID or a missing/unvalidated trust
                         * certificate shows its inline error) without
                         * building a cert-bearing URL -- raw certificate PEM
                         * must never appear in a saved/shareable link, and
                         * since builds are POSTed now, there's no cert-bearing
                         * direct URL to offer anyway. */
                        var params = buildcfgParams();
                        if (!params) { return; }
                        var hasTrustCert = params.has('TRUST_CERT');
                        var data = "<h2>Editable Configuration URL</h2><p>Use this URL to adjust your binary's setup:</p>";
                        /* Built as a separate buildcfg() call (omitTrustCert),
                         * not derived from `params` above -- a custom trust
                         * certificate's raw PEM must never end up in a
                         * saved/shareable URL. If custom trust was used,
                         * reopening this URL restores everything else, but
                         * the certificate will need re-adding by hand (there's
                         * no saved-profile mechanism for it yet). */
                        var editcfg = buildcfg(true).replace(/^[^?]*\?/,'?');
                        data += "<br/>" + baseURI + editcfg;
                        if (hasTrustCert) {
                                data += "<br/><p><em>Note: the certificate you provided is not included in this URL -- you'll need to re-add it if you reopen this link.</em></p>";
                        }
                        content.innerHTML = data;
                        popup.showModal();
                });

                setTimeout(loadcfg, 50);
        })();

        /* Embedded script file handling, shared by the file picker and the
         * drop zone -- these were previously two near-identical copies. */
        (function() {
                var list = document.getElementById('list');

                /* Replace the status area with a single message. Built as a
                 * text node rather than an HTML string so a filename
                 * containing markup can't be injected -- the old code relied
                 * on escape() for that, which also meant spaces in filenames
                 * displayed as "%20". */
                function showMessage(text, isError) {
                        var ul = document.createElement('ul');
                        if (isError) { ul.style.backgroundColor = 'red'; }
                        ul.textContent = text;
                        list.replaceChildren(ul);
                }

                function showFileInfo(file) {
                        var ul = document.createElement('ul');
                        var li = document.createElement('li');
                        var strong = document.createElement('strong');
                        strong.textContent = file.name;
                        li.appendChild(strong);
                        li.appendChild(document.createTextNode(
                                ' (' + (file.type || 'n/a') + ') - ' + file.size +
                                ' bytes, last modified: ' +
                                (file.lastModified ? new Date(file.lastModified).toLocaleDateString() : 'n/a')
                        ));
                        ul.appendChild(li);
                        list.replaceChildren(ul);
                }

                function handleFile(file) {
                        // Only process text or unknown file type.
                        if (!file.type.match('text*') && file.type != "") {
                                showMessage(' Only text file are supported ', true);
                                return;
                        }

                        var reader = new FileReader();
                        reader.onload = function(e) {
                                var content = e.target.result;
                                document.getElementById('embed').value = content;
                                if (content.indexOf("#!ipxe") === -1) {
                                        showMessage(' Not a iPXE script ', true);
                                }
                        };
                        reader.readAsText(file);

                        showFileInfo(file);
                }

                document.getElementById('embedfile').addEventListener('change', function(evt) {
                        handleFile(evt.target.files[0]);
                }, false);

                var dropZone = document.getElementById('drop_zone');
                dropZone.addEventListener('dragover', function(evt) {
                        evt.stopPropagation();
                        evt.preventDefault();
                        evt.dataTransfer.dropEffect = 'copy'; // Explicitly show this is a copy.
                }, false);
                dropZone.addEventListener('drop', function(evt) {
                        evt.stopPropagation();
                        evt.preventDefault();
                        handleFile(evt.dataTransfer.files[0]);
                        document.getElementById('embedfile').value = "";
                }, false);
        })();

        /* Advanced wizard's "HTTPS certificate trust" section -- validates
         * a user-supplied certificate (file or pasted text) against
         * certificate.php and renders a metadata preview. The validated,
         * normalised PEM is stored in the outer trustCertPem variable for
         * buildcfg() to pick up; nothing here ever writes it into a URL
         * directly (see the note on buildcfg()'s omitTrustCert). */
        (function() {
                var statusEl = document.getElementById('trust_cert_status');
                var previewEl = document.getElementById('trust_cert_preview');
                var fileInput = document.getElementById('trust_cert_file');
                var textInput = document.getElementById('trust_cert_text');

                function setStatus(text, isError) {
                        if (!text) {
                                statusEl.style.display = 'none';
                                return;
                        }
                        statusEl.textContent = text;
                        statusEl.style.display = '';
                        statusEl.classList.toggle('error', !!isError);
                }

                function clearPreview() {
                        previewEl.style.display = 'none';
                        previewEl.replaceChildren();
                        trustCertPem = null;
                }

                function addField(block, label, value) {
                        var p = document.createElement('p');
                        var name = document.createElement('span');
                        name.className = 'cert-field-name';
                        name.textContent = label + ': ';
                        p.appendChild(name);
                        p.appendChild(document.createTextNode(value));
                        block.appendChild(p);
                }

                function renderPreview(certificates) {
                        var frag = document.createDocumentFragment();
                        certificates.forEach(function(cert) {
                                var block = document.createElement('div');
                                block.className = 'cert-block';
                                addField(block, 'Subject', cert.subject);
                                addField(block, 'Issuer', cert.issuer);
                                addField(block, 'Valid', new Date(cert.validFrom).toLocaleDateString() +
                                        ' to ' + new Date(cert.validTo).toLocaleDateString() +
                                        (cert.expired ? ' (EXPIRED)' : cert.notYetValid ? ' (not yet valid)' : ''));
                                addField(block, 'CA certificate', cert.isCa ? 'Yes' : 'No');
                                addField(block, 'Self-signed', cert.selfSigned ? 'Yes' : 'No');
                                var sans = cert.subjectAltNames.dns.concat(cert.subjectAltNames.ip);
                                if (sans.length) { addField(block, 'Subject Alt Names', sans.join(', ')); }
                                var fpP = document.createElement('p');
                                var fpName = document.createElement('span');
                                fpName.className = 'cert-field-name';
                                fpName.textContent = 'SHA-256: ';
                                fpP.appendChild(fpName);
                                var fpVal = document.createElement('span');
                                fpVal.className = 'cert-fingerprint';
                                fpVal.textContent = cert.sha256Fingerprint;
                                fpP.appendChild(fpVal);
                                block.appendChild(fpP);
                                frag.appendChild(block);
                        });
                        previewEl.replaceChildren(frag);
                        previewEl.style.display = '';
                }

                function validate(formData) {
                        setStatus('Validating certificate...', false);
                        clearPreview();
                        fetch('certificate.php', { method: 'POST', body: formData })
                                .then(function(response) { return response.json(); })
                                .then(function(data) {
                                        if (data.error) {
                                                setStatus(data.error, true);
                                                return;
                                        }
                                        var expired = data.certificates.some(function(c) { return c.expired; });
                                        trustCertPem = data.certificates.map(function(c) { return c.pem; }).join('\n');
                                        renderPreview(data.certificates);
                                        setStatus(expired ?
                                                'Validated, but at least one certificate has expired.' :
                                                'Certificate validated.', expired);
                                })
                                .catch(function(err) {
                                        setStatus('Could not validate certificate: ' + err.message, true);
                                });
                }

                fileInput.addEventListener('change', function(evt) {
                        var file = evt.target.files[0];
                        if (!file) { return; }
                        textInput.value = '';
                        var formData = new FormData();
                        formData.append('certfile', file);
                        validate(formData);
                });

                /* Fires when the field loses focus, not on every keystroke
                 * -- validating a certificate is a network round trip, and
                 * nothing needs live-as-you-type feedback here. */
                textInput.addEventListener('blur', function(evt) {
                        var text = evt.target.value.trim();
                        if (!text) { clearPreview(); setStatus(null); return; }
                        fileInput.value = '';
                        var formData = new FormData();
                        formData.append('certtext', text);
                        validate(formData);
                });

                document.querySelectorAll('input[name=trustmode]').forEach(function(radio) {
                        radio.addEventListener('change', function() {
                                var custom = document.querySelector('input[name=trustmode]:checked').value === 'custom';
                                document.getElementById('trust_custom_fields').style.display = custom ? '' : 'none';
                                if (!custom) {
                                        fileInput.value = '';
                                        textInput.value = '';
                                        clearPreview();
                                        setStatus(null);
                                }
                        });
                });
        })();

        // Check for the various File API support.
        if (!window.File && !window.FileReader) {
                alert('The File APIs are not fully supported by your browser.');
        }

}); /* End DOM ready */
