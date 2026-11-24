import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Client for the rosbridge v2 JSON-over-WebSocket protocol.
///
/// Tracks active topic subscriptions created via [subscribe] and automatically
/// re-subscribes and re-advertises after reconnecting with exponential backoff.
/// HTTP `401`/`403` handshake rejections (missing or invalid bearer token on
/// the `robot_stream` guard) transition to [LinkRejected] and stop retrying.
class RosbridgeClient {
  /// Creates a [RosbridgeClient].
  ///
  /// Provide [httpClient] to customize TLS verification (for example,
  /// `pinnedHttpClient` for self-signed robot certificates) when using the
  /// default `dart:io` connector, or supply a custom [connector] for testing.
  RosbridgeClient({
    RosbridgeConnector? connector,
    HttpClient? httpClient,
    this.connectTimeout = const Duration(seconds: 5),
    this.minBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 5),
  }) : _connector =
           connector ??
           ((uri, headers) => IOWebSocketChannel.connect(
             uri,
             headers: headers,
             customClient: httpClient,
           ));

  final RosbridgeConnector _connector;

  /// Timeout for establishing the WebSocket connection.
  final Duration connectTimeout;

  /// Initial backoff delay before reconnecting.
  final Duration minBackoff;

  /// Maximum backoff delay between reconnect attempts.
  final Duration maxBackoff;

  final _linkCtl = StreamController<LinkState>.broadcast();

  /// Broadcast stream of [LinkState] connection transitions.
  late final Stream<LinkState> link = _linkCtl.stream;
  LinkState _link = const LinkIdle();

  /// Current [LinkState] of this client.
  LinkState get currentLink => _link;

  final _subs = <String, _Subscription>{};
  final _advertised =
      <String, String>{}; // topic -> type, re-advertised after reconnect
  final _goals = <String, RosbridgeActionGoal>{};
  final _calls = <String, Completer<Map<String, dynamic>?>>{};
  int _seq = 0;
  Uri? _uri;
  Map<String, String> _headers = const {};
  WebSocketChannel? _channel;
  int _generation = 0;
  Completer<void>? _wake;

  /// Subscribes to messages on [topic] of ROS message [type] (for example,
  /// `'std_msgs/msg/Float32'`).
  ///
  /// [throttleMs] asks rosbridge to emit at most one message per interval in
  /// milliseconds (`0` disables throttling). [queueLength] sets the rosbridge
  /// subscription queue size.
  Stream<Map<String, dynamic>> subscribe(
    String topic,
    String type, {
    int throttleMs = 0,
    int queueLength = 1,
  }) {
    final sub = _subs.putIfAbsent(
      topic,
      () => _Subscription(topic, type, throttleMs, queueLength),
    );
    if (_link is LinkConnected) _send(sub.subscribeOp());
    return sub.controller.stream;
  }

  /// Publishes [msg] to [topic] (automatically sending `advertise` on first
  /// use).
  ///
  /// Returns `false` if disconnected—messages are not queued while offline.
  bool publish(String topic, String type, Map<String, dynamic> msg) {
    if (_link is! LinkConnected) return false;
    if (_advertised[topic] == null) {
      _advertised[topic] = type;
      _send({
        'op': 'advertise',
        'id': 'adv:$topic',
        'topic': topic,
        'type': type,
      });
    }
    return _send({
      'op': 'publish',
      'id': 'pub:$topic',
      'topic': topic,
      'msg': msg,
    });
  }

  /// Sends a ROS 2 action goal (`send_action_goal`, rosbridge >= 2.0).
  ///
  /// If the connection drops before a result arrives, the goal completes with
  /// [RosbridgeActionResult.lost] (the goal is **not** resent automatically).
  RosbridgeActionGoal sendActionGoal(
    String action,
    String actionType,
    Map<String, dynamic> args,
  ) {
    final id = 'goal:${++_seq}:${DateTime.now().microsecondsSinceEpoch}';
    final goal = RosbridgeActionGoal._(this, id, action);
    final sent =
        _link is LinkConnected &&
        _send({
          'op': 'send_action_goal',
          'id': id,
          'action': action,
          'action_type': actionType,
          'args': args,
          'feedback': true,
        });
    if (sent) {
      _goals[id] = goal;
    } else {
      goal._finish(const RosbridgeActionResult.lost());
    }
    return goal;
  }

  /// Calls a ROS service [service] of [type] (for example,
  /// `'action_msgs/srv/CancelGoal'`) with [args].
  ///
  /// Resolves to the response `values` map, or `null` if disconnected, timed
  /// out after [timeout], or the service reported failure.
  Future<Map<String, dynamic>?> callService(
    String service,
    String type,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    final id = 'call:${++_seq}:${DateTime.now().microsecondsSinceEpoch}';
    final done = Completer<Map<String, dynamic>?>();
    final sent =
        _link is LinkConnected &&
        _send({
          'op': 'call_service',
          'id': id,
          'service': service,
          'type': type,
          'args': args,
        });
    if (!sent) return Future.value(null);
    _calls[id] = done;
    return done.future.timeout(
      timeout,
      onTimeout: () {
        _calls.remove(id);
        return null;
      },
    );
  }

  bool _cancelGoal(RosbridgeActionGoal g) =>
      _link is LinkConnected &&
      _send({'op': 'cancel_action_goal', 'id': g.id, 'action': g.action});

  /// Connects to [uri], optionally sending `Authorization: Bearer <token>`.
  void connect(Uri uri, {String? token}) {
    if (_link is LinkClosed) {
      throw StateError('RosbridgeClient has been disposed');
    }
    _uri = uri;
    _headers = {if (token != null) 'Authorization': 'Bearer $token'};
    final gen = _abort();
    _setLink(const LinkConnecting());
    unawaited(_run(gen));
  }

  /// Closes the WebSocket connection and all subscription streams.
  Future<void> dispose() async {
    if (_link is LinkClosed) return;
    _abort();
    _setLink(const LinkClosed());
    _loseGoals();
    for (final s in _subs.values) {
      await s.controller.close();
    }
    await _linkCtl.close();
  }

  int _abort() {
    _generation++;
    _channel?.sink.close();
    _channel = null;
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
    return _generation;
  }

  Future<void> _run(int gen) async {
    var attempt = 0;
    while (gen == _generation) {
      final result = await _session(gen);
      if (result == null || gen != _generation) return;
      final (:reason, :connected) = result;
      final status = handshakeStatus(reason);
      if (status == 401 || status == 403) {
        _setLink(
          LinkRejected(
            statusCode: status!,
            reason: status == 401
                ? 'Robot rejected connection: missing or invalid token'
                : 'Robot rejected connection: forbidden',
          ),
        );
        return;
      }
      // Reset backoff after a session that previously connected.
      attempt = connected ? 1 : attempt + 1;
      final ms = math.min(
        minBackoff.inMilliseconds * math.pow(2, attempt - 1),
        maxBackoff.inMilliseconds,
      );
      final delay = Duration(milliseconds: ms.round());
      _setLink(
        LinkReconnecting(attempt: attempt, retryIn: delay, reason: reason),
      );
      final wake = Completer<void>();
      _wake = wake;
      final t = Timer(delay, () => wake.isCompleted ? null : wake.complete());
      await wake.future;
      t.cancel();
    }
  }

  /// Runs a single WebSocket session; returns `null` if superseded.
  Future<({String reason, bool connected})?> _session(int gen) async {
    final WebSocketChannel ch;
    try {
      ch = _connector(_uri!, _headers);
      _channel = ch;
      await ch.ready.timeout(connectTimeout);
    } catch (e) {
      return gen == _generation
          ? (reason: 'Failed to connect: $e', connected: false)
          : null;
    }
    if (gen != _generation) {
      ch.sink.close();
      return null;
    }
    _setLink(const LinkConnected());
    for (final s in _subs.values) {
      _send(s.subscribeOp());
    }
    _advertised.forEach((topic, type) {
      _send({
        'op': 'advertise',
        'id': 'adv:$topic',
        'topic': topic,
        'type': type,
      });
    });
    final done = Completer<String>();
    final sub = ch.stream.listen(
      (data) => _onMessage(data),
      onError: (Object e) =>
          done.isCompleted ? null : done.complete('WebSocket error: $e'),
      onDone: () => done.isCompleted
          ? null
          : done.complete('Robot closed the connection'),
      cancelOnError: true,
    );
    final reason = await done.future;
    await sub.cancel();
    if (identical(_channel, ch)) _channel = null;
    _loseGoals();
    return gen == _generation ? (reason: reason, connected: true) : null;
  }

  /// Extracts an HTTP status code from a `dart:io` WebSocket upgrade error
  /// message, or returns `null` if none is present.
  static int? handshakeStatus(String reason) {
    final m = RegExp(r'status code: (\d{3})').firstMatch(reason);
    return m == null ? null : int.parse(m.group(1)!);
  }

  void _onMessage(Object? data) {
    if (data is! String) return;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['op']) {
      case 'publish':
        final sub = _subs[m['topic']];
        final msg = m['msg'];
        if (sub != null &&
            msg is Map<String, dynamic> &&
            !sub.controller.isClosed) {
          sub.controller.add(msg);
        }
      case 'action_feedback':
        final values = m['values'];
        if (values is Map<String, dynamic>) _goals[m['id']]?._feedback(values);
      case 'service_response':
        final call = _calls.remove(m['id']);
        final values = m['values'];
        if (call != null && !call.isCompleted) {
          call.complete(
            m['result'] == true && values is Map<String, dynamic>
                ? values
                : null,
          );
        }
      case 'action_result':
        final goal = _goals.remove(m['id']);
        final values = m['values'];
        goal?._finish(
          RosbridgeActionResult(
            status: (m['status'] as num?)?.toInt(),
            values: values is Map<String, dynamic> ? values : const {},
          ),
        );
    }
  }

  void _loseGoals() {
    final calls = [..._calls.values];
    _calls.clear();
    for (final c in calls) {
      if (!c.isCompleted) c.complete(null);
    }
    final pending = [..._goals.values];
    _goals.clear();
    for (final g in pending) {
      g._finish(const RosbridgeActionResult.lost());
    }
  }

  bool _send(Map<String, dynamic> op) {
    final ch = _channel;
    if (ch == null) return false;
    ch.sink.add(jsonEncode(op));
    return true;
  }

  void _setLink(LinkState s) {
    _link = s;
    if (!_linkCtl.isClosed) _linkCtl.add(s);
  }
}

class _Subscription {
  _Subscription(this.topic, this.type, this.throttleMs, this.queueLength);

  final String topic;
  final String type;
  final int throttleMs;
  final int queueLength;
  final controller = StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> subscribeOp() => {
    'op': 'subscribe',
    'id': 'sub:$topic',
    'topic': topic,
    'type': type,
    'throttle_rate': throttleMs,
    'queue_length': queueLength,
  };
}

/// Terminal result of a rosbridge ROS 2 action goal.
///
/// [status] follows `action_msgs/msg/GoalStatus`: `4` ([succeeded]),
/// `5` ([canceled]), `6` ([aborted]). [lost] is `true` if the WebSocket dropped
/// before a result arrived.
final class RosbridgeActionResult {
  /// Creates a completed [RosbridgeActionResult] with [status] and [values].
  const RosbridgeActionResult({required this.status, required this.values})
    : lost = false;

  /// Creates a result representing a dropped connection before completion.
  const RosbridgeActionResult.lost()
    : status = null,
      values = const {},
      lost = true;

  /// `action_msgs/msg/GoalStatus.STATUS_SUCCEEDED` (`4`).
  static const succeeded = 4;

  /// `action_msgs/msg/GoalStatus.STATUS_CANCELED` (`5`).
  static const canceled = 5;

  /// `action_msgs/msg/GoalStatus.STATUS_ABORTED` (`6`).
  static const aborted = 6;

  /// Raw `GoalStatus` integer, or `null` when [lost] is `true`.
  final int? status;

  /// Result payload fields returned by the action server.
  final Map<String, dynamic> values;

  /// `true` if the WebSocket connection was lost before the action completed.
  final bool lost;

  @override
  String toString() =>
      lost ? 'ActionResult(connection lost)' : 'ActionResult(status $status)';
}

/// Handle to an action goal submitted via [RosbridgeClient.sendActionGoal].
final class RosbridgeActionGoal {
  RosbridgeActionGoal._(this._client, this.id, this.action);

  final RosbridgeClient _client;

  /// Client-generated rosbridge operation ID for this goal.
  final String id;

  /// ROS 2 action name (for example, `'/navigate_to_pose'`).
  final String action;
  final _feedbackCtl = StreamController<Map<String, dynamic>>.broadcast();
  final _result = Completer<RosbridgeActionResult>();

  /// Stream of raw action feedback maps until the goal completes.
  Stream<Map<String, dynamic>> get feedback => _feedbackCtl.stream;

  /// Future completing with the final [RosbridgeActionResult].
  Future<RosbridgeActionResult> get result => _result.future;

  /// Whether [result] has completed.
  bool get isDone => _result.isCompleted;

  /// Sends a `cancel_action_goal` request.
  ///
  /// Returns `true` if sent; the terminal `CANCELED` status arrives on [result].
  bool cancel() => !isDone && _client._cancelGoal(this);

  void _feedback(Map<String, dynamic> v) {
    if (!_feedbackCtl.isClosed) _feedbackCtl.add(v);
  }

  void _finish(RosbridgeActionResult r) {
    if (!_result.isCompleted) _result.complete(r);
    _feedbackCtl.close();
  }
}

/// Function that opens a [WebSocketChannel] to [uri] with HTTP [headers].
///
/// Can be injected into [RosbridgeClient] for unit testing.
typedef RosbridgeConnector =
    WebSocketChannel Function(Uri uri, Map<String, String> headers);
