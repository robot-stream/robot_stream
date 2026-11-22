import 'dart:io';

import 'package:crypto/crypto.dart';

/// Creates a `dart:io` [HttpClient] that only trusts certificates matching the
/// SHA-256 fingerprint [sha256Hex].
///
/// Intended for self-signed robot TLS certificates (printed by
/// `robot_node/scripts/make_cert.sh`) shared between rosbridge (`wss://`) and
/// WHEP (`https://`). Accepts hex strings with or without colons/spaces (for
/// example, `ab12...` or `AB:12:...`).
///
/// Uses `dart:io` and is not supported on Flutter Web.
HttpClient pinnedHttpClient(String sha256Hex) {
  final want = normalizeFingerprint(sha256Hex);
  return HttpClient()
    ..badCertificateCallback = (cert, host, port) =>
        certFingerprint(cert.der) == want;
}

/// Computes the lowercase hex SHA-256 fingerprint (without colons) of a
/// DER-encoded certificate.
String certFingerprint(List<int> der) => sha256.convert(der).toString();

/// Normalizes a SHA-256 fingerprint string to lowercase hex without colons or
/// whitespace.
String normalizeFingerprint(String s) =>
    s.replaceAll(':', '').replaceAll(' ', '').trim().toLowerCase();
