import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:robot_stream_core/robot_stream_core.dart';

/// Result of a WHEP offer `POST`: the SDP answer and optional session resource
/// URI (from the `Location` header) used to `DELETE` the session on teardown.
final class WhepAnswer {
  /// Creates a [WhepAnswer] with the returned [sdp] and optional [session] URI.
  const WhepAnswer({required this.sdp, this.session});

  /// Remote SDP answer string returned by the WHEP server.
  final String sdp;

  /// Resolved session URI from the HTTP `Location` header, if provided.
  final Uri? session;
}

/// Exception thrown when a WHEP HTTP signaling request fails or returns an
/// invalid response.
final class WhepException implements Exception {
  /// Creates a [WhepException] with diagnostic [message] and optional HTTP
  /// [statusCode].
  const WhepException(this.message, {this.statusCode});

  /// Human-readable error description.
  final String message;

  /// HTTP status code if returned by the server, or `null` for protocol errors.
  final int? statusCode;

  @override
  String toString() =>
      'WhepException(${statusCode == null ? '' : '$statusCode: '}$message)';
}

/// Pure-HTTP WHEP signaling client (`draft-ietf-wish-whep`).
///
/// Sends an SDP offer via `POST` expecting `201 Created` with an SDP answer,
/// and sends `DELETE` to tear down the session on disconnect. Decoupled from
/// `flutter_webrtc` so it can be unit-tested against a local fake server.
class WhepSignaling {
  /// Creates a [WhepSignaling] client using an optional custom HTTP
  /// [clientFactory].
  WhepSignaling({http.Client Function()? clientFactory})
    : _client = (clientFactory ?? http.Client.new)();

  /// Creates an HTTPS signaling client pinned to the SHA-256 certificate
  /// fingerprint [certSha256] (for self-signed robot TLS certificates).
  ///
  /// Example:
  /// ```dart
  /// WhepSource(
  ///   robotId: 'robot1',
  ///   signalingFactory: () => WhepSignaling.pinned(certSha256),
  /// );
  /// ```
  WhepSignaling.pinned(String certSha256)
    : _client = IOClient(pinnedHttpClient(certSha256));

  final http.Client _client;

  /// Posts an SDP [sdp] offer to [endpoint] and returns the server's
  /// [WhepAnswer].
  ///
  /// Throws [WhepException] if the response status is not `201 Created` or the
  /// body is not a valid SDP document.
  Future<WhepAnswer> offer(
    Uri endpoint,
    String sdp, {
    String? token,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await _client
        .post(
          endpoint,
          headers: {
            'Content-Type': 'application/sdp',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: sdp,
        )
        .timeout(timeout);
    if (response.statusCode != 201) {
      throw WhepException(
        response.reasonPhrase ?? 'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final answer = response.body;
    if (!answer.trimLeft().startsWith('v=0')) {
      throw const WhepException('Phản hồi 201 nhưng không phải SDP answer');
    }
    final location = response.headers['location'];
    return WhepAnswer(
      sdp: answer,
      session: location == null ? null : endpoint.resolve(location),
    );
  }

  /// Sends a best-effort `DELETE` to close [session] on the server.
  ///
  /// Errors are ignored because the server also cleans up on ICE timeout.
  Future<void> delete(Uri session, {String? token}) async {
    try {
      await _client
          .delete(
            session,
            headers: {if (token != null) 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Closes the underlying HTTP client.
  void close() => _client.close();
}
