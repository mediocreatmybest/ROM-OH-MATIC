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

                /* <label> wrapping a text <input>, then the description on
                 * its own line, then <br/><br/>. Shared by the BANNER/hex-
                 * value "define" overrides (input value comes from the
                 * description) and the "input" type (input value comes from
                 * .value, but the trailing description text is still
                 * sourced from .description, same as the original). The
                 * description is a separate block element rather than
                 * running on immediately after the input -- some iPXE
                 * header comments (e.g. PRODUCT_ERROR_URI) are long
                 * paragraphs, which read as a wall of text jammed against a
                 * 6-character-wide box when left inline. */
                function makeTextOptionLabel(name, fieldName, size, fieldValue, descriptionText, trailingPrefix) {
                        var desc = (name === descriptionText) ? '' : descriptionText;
                        var label = document.createElement('label');
                        label.setAttribute('for', name);
                        label.appendChild(document.createTextNode(name + ': '));
                        var input = document.createElement('input');
                        input.type = 'text';
                        input.size = size;
                        input.placeholder = fieldValue;
                        input.value = fieldValue;
                        input.name = fieldName;
                        label.appendChild(input);
                        var descText = trailingPrefix + desc;
                        if (descText) {
                                var descEl = document.createElement('div');
                                descEl.className = 'option-description';
                                descEl.textContent = descText;
                                label.appendChild(descEl);
                        }
                        label.appendChild(document.createElement('br'));
                        label.appendChild(document.createElement('br'));
                        return label;
                }

                /* <label> wrapping a checkbox <input> and a help link, then
                 * the description on its own line, then <br/><br/>. Shared
                 * by "define" (checked) and "undef" (unchecked) boolean
                 * options -- same rationale as makeTextOptionLabel() above
                 * for putting the description on its own line. */
                function makeCheckboxOptionLabel(name, fieldName, checked, description) {
                        var label = document.createElement('label');
                        label.setAttribute('for', name);
                        var input = document.createElement('input');
                        input.type = 'checkbox';
                        input.value = checked ? '1' : '0';
                        input.name = fieldName;
                        input.checked = checked;
                        label.appendChild(input);
                        var link = document.createElement('a');
                        link.className = 'help_buildcfg';
                        link.href = 'http://www.ipxe.org/buildcfg/' + name;
                        link.target = '_blank';
                        link.textContent = name;
                        label.appendChild(link);
                        if (description) {
                                var descEl = document.createElement('div');
                                descEl.className = 'option-description';
                                descEl.textContent = description;
                                label.appendChild(descEl);
                        }
                        label.appendChild(document.createElement('br'));
                        label.appendChild(document.createElement('br'));
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

        document.getElementById('outputformatadv').addEventListener('change', function() {
                var outputformat = document.getElementById('outputformatadv').value;
                if (outputformat.indexOf("rom", outputformat.length - 3) !== -1)
                {	/* If a ROM */
                        document.getElementById('rom').style.display = 'inline';
                        document.getElementById('iface').style.display = 'none';
                        document.getElementById('config').style.display = 'none';
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
                        document.getElementById('embedded').style.display = 'inline';
                        document.getElementById('debug').style.display = 'inline';
                        document.getElementById('gitversion').style.display = 'inline';
                        document.getElementById('build').style.display = 'inline';
                }
        });

        /* Compose build.fcgi url */
        function buildcfg() {
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
                 * UTF-8 (see the finding in ARCHITECTURE.md). */
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

                var params = new URLSearchParams();
                params.set('BINARY', binary);
                params.set('BINDIR', bindir);
                params.set('REVISION', revision);
                params.set('DEBUG', debug);
                params.set('EMBED.00script.ipxe', embed);
                optionEntries.forEach(function(entry) { params.append(entry[0], entry[1]); });

                console.log('{ BINARY: ['+ binary +'], BINDIR: ['+ bindir +'], DEBUG: ['+ debug +'], REVISION: ['+ revision +'], EMBED: ['+ embed +'] , OPTIONS: ['+ optionEntries.length +' changed]}');

                return 'build.fcgi?' + params.toString();
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
		 * than throwing on malformed input, so a legacy escape()-style
		 * saved URL (see ARCHITECTURE.md) won't crash the restore, even
		 * though characters outside plain ASCII in such a URL may not
		 * come back exactly as originally typed -- that data was already
		 * corrupted at save time by the bug this fixes. */
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

        document.getElementById('ipxeimage').addEventListener('submit', function(event) {
                /* stop form from submitting normally */
                event.preventDefault();
                var url = buildcfg();
                if (url) {
                         window.location.href = url;
                };
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
                        var config = buildcfg();
                        if (!config) { return; }
                        var data = "<h2>Direct buildcfg URL</h2><p>Use this URL to directly retreive your binary for later use:</p>";
                        data += "<br/>" + baseURI + config;
                        data += "<br/><h2>Editable Configuration URL</h2><p>Use this URL to adjust your binary's setup:</p>";
                        var editcfg = config.replace(/^[^?]*\?/,'?');
                        data += "<br/>" + baseURI + editcfg;
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

        // Check for the various File API support.
        if (!window.File && !window.FileReader) {
                alert('The File APIs are not fully supported by your browser.');
        }

}); /* End DOM ready */
