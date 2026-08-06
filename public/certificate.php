<?php
/*
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Validates and parses user-supplied X.509 public certificate material
# (an uploaded file or pasted PEM text) for the advanced "HTTPS
# certificate trust" build option.
#
# This is ingestion and parsing only. Nothing here writes certificate
# material to disk or feeds an actual iPXE build -- everything is
# validated and parsed in memory, and the only output is a JSON preview
# (subject, issuer, validity, SANs, CA status, fingerprint) for the
# advanced wizard to display. Wiring a validated certificate into a real
# `make CERT=... TRUST=...` build happens in build.fcgi's trust_cert(),
# which independently re-validates everything -- it never trusts that
# this endpoint's validation already ran.
#------------------------------------------------------------------------
*/

header('Content-Type: application/json; charset=utf-8');

const MAX_CERT_COUNT = 8;
const MAX_TOTAL_BYTES = 65536; // 64 KiB -- a conservative initial limit

function respond_error($message) {
	http_response_code(400);
	echo json_encode(array('error' => $message));
	exit;
}

// openssl_x509_parse()'s subject/issuer arrays are keyed by RDN type
// (CN, O, OU, C, ...); render as a single human-readable string in the
// conventional order, falling back to whatever else is present.
function format_dn($dn) {
	$order = array('CN', 'O', 'OU', 'L', 'ST', 'C');
	$parts = array();
	foreach ($order as $key) {
		if (isset($dn[$key])) {
			$value = $dn[$key];
			if (is_array($value)) { $value = implode(',', $value); }
			$parts[] = $key . '=' . $value;
			unset($dn[$key]);
		}
	}
	foreach ($dn as $key => $value) {
		if (is_array($value)) { $value = implode(',', $value); }
		$parts[] = $key . '=' . $value;
	}
	return implode(', ', $parts);
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
	http_response_code(405);
	echo json_encode(array('error' => 'This endpoint accepts POST only.'));
	exit;
}

// --- Gather input: an uploaded file takes priority over pasted text ---
$raw = null;
if (isset($_FILES['certfile']) && $_FILES['certfile']['error'] === UPLOAD_ERR_OK) {
	if ($_FILES['certfile']['size'] > MAX_TOTAL_BYTES) {
		respond_error('Uploaded file exceeds the ' . MAX_TOTAL_BYTES . '-byte limit.');
	}
	$raw = file_get_contents($_FILES['certfile']['tmp_name']);
} elseif (isset($_POST['certtext']) && trim($_POST['certtext']) !== '') {
	$raw = $_POST['certtext'];
}

if ($raw === null || trim($raw) === '') {
	respond_error('No certificate material provided. Upload a file or paste PEM text.');
}

if (strlen($raw) > MAX_TOTAL_BYTES) {
	respond_error('Submitted certificate data exceeds the ' . MAX_TOTAL_BYTES . '-byte limit.');
}

// --- Reject private key material outright, whole submission -- this is
// a public-certificate-trust feature, never a client-key manager. ---
$private_key_markers = array(
	'-----BEGIN PRIVATE KEY-----',
	'-----BEGIN RSA PRIVATE KEY-----',
	'-----BEGIN EC PRIVATE KEY-----',
	'-----BEGIN ENCRYPTED PRIVATE KEY-----',
	'-----BEGIN DSA PRIVATE KEY-----',
);
foreach ($private_key_markers as $marker) {
	if (strpos($raw, $marker) !== false) {
		respond_error('Private key material was detected and is not accepted. Only public certificates are supported.');
	}
}

// --- Split into individual PEM blocks, or treat as a single raw DER cert ---
$pem_blocks = array();
if (strpos($raw, '-----BEGIN CERTIFICATE-----') !== false) {
	preg_match_all(
		'/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/s',
		$raw, $matches
	);
	$pem_blocks = $matches[0];
	if (empty($pem_blocks)) {
		respond_error('Found a "BEGIN CERTIFICATE" marker but could not extract a complete PEM block.');
	}
} else {
	// Not PEM -- try treating the raw bytes as a single DER-encoded
	// certificate, wrapped into PEM so openssl_x509_read() can parse it.
	// A PKCS#12/PFX bundle would also reach this path, fail to parse as
	// a bare X.509 certificate below, and be rejected with a clear
	// message -- no separate PKCS#12 signature-sniffing is needed.
	$pem_blocks[] = "-----BEGIN CERTIFICATE-----\n"
		. chunk_split(base64_encode($raw), 64, "\n")
		. "-----END CERTIFICATE-----\n";
}

if (count($pem_blocks) > MAX_CERT_COUNT) {
	respond_error('Too many certificates (' . count($pem_blocks) . '); the limit is ' . MAX_CERT_COUNT . '.');
}

// --- Parse each block ---
$certificates = array();
foreach ($pem_blocks as $index => $pem) {
	$x509 = @openssl_x509_read($pem);
	if ($x509 === false) {
		respond_error(
			'Certificate ' . ($index + 1) . ' of ' . count($pem_blocks) . ' could not be parsed. '
			. 'Only PEM or single-certificate DER X.509 public certificates are supported '
			. '(PKCS#12/PFX bundles are not).'
		);
	}

	$parsed = openssl_x509_parse($x509, true);
	if ($parsed === false) {
		respond_error('Certificate ' . ($index + 1) . ' of ' . count($pem_blocks) . ' could not be parsed.');
	}

	// Normalise to PEM regardless of original input format (PEM in, PEM
	// out unchanged; DER in, PEM out) -- this is what a later build step
	// would actually write out for CERT=/TRUST=.
	openssl_x509_export($x509, $normalised_pem);

	$subject = format_dn($parsed['subject'] ?? array());
	$issuer = format_dn($parsed['issuer'] ?? array());

	$sans = array('dns' => array(), 'ip' => array());
	if (!empty($parsed['extensions']['subjectAltName'])) {
		foreach (explode(',', $parsed['extensions']['subjectAltName']) as $san) {
			$san = trim($san);
			if (stripos($san, 'DNS:') === 0) {
				$sans['dns'][] = substr($san, 4);
			} elseif (stripos($san, 'IP Address:') === 0) {
				$sans['ip'][] = substr($san, 11);
			}
		}
	}

	$is_ca = false;
	if (!empty($parsed['extensions']['basicConstraints'])) {
		$is_ca = (stripos($parsed['extensions']['basicConstraints'], 'CA:TRUE') !== false);
	}

	$certificates[] = array(
		'subject' => $subject,
		'issuer' => $issuer,
		'serialNumberHex' => $parsed['serialNumberHex'] ?? null,
		'validFrom' => gmdate('c', $parsed['validFrom_time_t']),
		'validTo' => gmdate('c', $parsed['validTo_time_t']),
		'expired' => (time() > $parsed['validTo_time_t']),
		'notYetValid' => (time() < $parsed['validFrom_time_t']),
		'isCa' => $is_ca,
		'selfSigned' => ($subject === $issuer),
		'subjectAltNames' => $sans,
		'sha256Fingerprint' => openssl_x509_fingerprint($x509, 'sha256'),
		'pem' => $normalised_pem,
	);
}

echo json_encode(array('certificates' => $certificates));

?>
