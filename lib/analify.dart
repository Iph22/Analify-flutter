/// Analify for Flutter: screens, events and signed-in users, privately. https://analify.dev/docs#apps
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Analify.start(key: 'AN-XXXXXXXX', appVersion: '1.0.0');
///   runApp(MaterialApp(navigatorObservers: [AnalifyObserver()], home: const Home()));
/// }
///
/// Analify.track('note_saved', {'words': 120});
/// Analify.identify(user.id); // after sign-in; Analify.identify(null) on sign-out
/// ```
///
/// What it sends: screen and event names, your properties, the app version, the operating system and whether it's
/// a phone or a computer. One random install ID stays in the app's own storage (no name, email, advertising ID or
/// device identifier) so a returning user is counted once. Unsent events are kept while offline (up to 7 days) and
/// go out in small batches every 10 seconds and when the app moves to the background.
library analify;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Analify with WidgetsBindingObserver {
  Analify._(this._key, this._endpoint, this._appVersion, this._model, this._debug, this._client, this._prefs, this._install);

  static Analify? _shared;

  static const _installKey = 'analify_install';
  static const _queueKey = 'analify_queue';
  static const _batch = 20;
  static const _perRequest = 50;
  static const _maxQueue = 500;
  static const _maxAge = Duration(days: 7);

  final String _key;
  final Uri _endpoint;
  final String? _appVersion;
  final String? _model;
  final bool _debug;
  final http.Client _client;
  final SharedPreferences _prefs;
  final String _install;

  final List<Map<String, Object?>> _events = [];
  String? _uid;
  String? _currentScreen;
  Map<String, String?>? _campaign;
  Future<void>? _sending;
  Timer? _timer;

  /// Starts Analify. Call once, after `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// [key] is your app's key from Analify (AN-...). [appVersion] is shown as the app version in reports.
  /// [model] is the phone or computer model if you know it (for example from device_info_plus).
  /// [host] is your Analify address. [debug] prints what's sent.
  static Future<void> start({
    required String key,
    String? appVersion,
    String? model,
    String host = 'https://analify.dev',
    bool debug = false,
    @visibleForTesting http.Client? client,
  }) async {
    if (_shared != null) return;
    final prefs = await SharedPreferences.getInstance();
    var install = prefs.getString(_installKey);
    if (install == null || install.length < 8) {
      final r = Random.secure();
      install = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString(_installKey, install);
    }
    final a = Analify._(key, Uri.parse('${host.replaceAll(RegExp(r'/+$'), '')}/api/app/events'), appVersion, model,
        debug, client ?? http.Client(), prefs, install);
    a._load();
    a._timer = Timer.periodic(const Duration(seconds: 10), (_) => a._send());
    WidgetsBinding.instance.addObserver(a);
    _shared = a;
  }

  /// A screen came into view, e.g. "Home". [AnalifyObserver] calls this for you on every route change.
  static void screen(String name, [Map<String, Object?>? props]) => _shared?._screen(name, props);

  /// Something happened, e.g. `Analify.track('purchase', {'plan': 'pro'})`.
  static void track(String name, [Map<String, Object?>? props]) => _shared?._track(name, props);

  /// The person signed in: your own user ID (Analify scrambles it before saving). `null` when they sign out.
  static void identify(String? userId) => _shared?._identify(userId);

  /// The app was opened from a link (deep link or universal link): its campaign counts for the next screen.
  static void openedFrom(Uri uri) {
    final q = uri.queryParameters;
    _shared?._campaign = {
      'referrer': q['ref'] ?? q['referrer'],
      'utm_source': q['utm_source'],
      'utm_medium': q['utm_medium'],
      'utm_campaign': q['utm_campaign'],
    };
  }

  /// Sends what's waiting now.
  static Future<void> flush() => _shared?._send() ?? Future.value();

  @visibleForTesting
  static Future<void> stopForTesting() async {
    final a = _shared;
    if (a == null) return;
    a._timer?.cancel();
    WidgetsBinding.instance.removeObserver(a);
    _shared = null;
  }

  // ---- app lifecycle ----

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _push({'type': 'engagement'}, sendIfFull: false);
      _send();
    } else if (state == AppLifecycleState.resumed) {
      _send();
    }
  }

  // ---- events ----

  void _screen(String name, Map<String, Object?>? props) {
    final screen = name.length > 300 ? name.substring(0, 300) : name;
    _currentScreen = screen;
    final e = <String, Object?>{'type': 'screen', 'screen': screen, 'props': _clean(props)};
    final c = _campaign;
    if (c != null) {
      e.addAll(c);
      _campaign = null;
    }
    _push(e);
  }

  void _track(String name, Map<String, Object?>? props) {
    final n = name.trim();
    if (n.isEmpty) return;
    _push({'type': 'event', 'name': n.length > 120 ? n.substring(0, 120) : n, 'screen': _currentScreen, 'props': _clean(props)});
  }

  void _identify(String? userId) {
    if (userId == null || userId.isEmpty) {
      _uid = null;
      return;
    }
    _uid = userId.length > 255 ? userId.substring(0, 255) : userId;
    _push({'type': 'identify'});
  }

  void _push(Map<String, Object?> e, {bool sendIfFull = true}) {
    e['at'] = DateTime.now().toUtc().toIso8601String();
    if (_uid != null) e['uid'] = _uid;
    e.removeWhere((_, v) => v == null);
    _events.add(e);
    if (_events.length > _maxQueue) _events.removeRange(0, _events.length - _maxQueue);
    _save();
    if (sendIfFull && _events.length >= _batch) _send();
  }

  /// Keeps text, numbers and true/false (at most 30, text up to 500 characters).
  static Map<String, Object>? _clean(Map<String, Object?>? props) {
    if (props == null) return null;
    final out = <String, Object>{};
    for (final k in (props.keys.toList()..sort())) {
      if (out.length >= 30) break;
      final v = props[k];
      if (v is bool || v is int) {
        out[k] = v!;
      } else if (v is double && v.isFinite) {
        out[k] = v;
      } else if (v is String) {
        out[k] = v.length > 500 ? v.substring(0, 500) : v;
      }
    }
    return out.isEmpty ? null : out;
  }

  // ---- sending ----

  Future<void> _send() {
    // One round at a time; a second call waits for the one in progress.
    return _sending ??= _sendAll().whenComplete(() => _sending = null);
  }

  Future<void> _sendAll() async {
    while (_events.isNotEmpty) {
      final batch = _events.take(_perRequest).toList();
      final body = jsonEncode({
        'key': _key,
        'install': _install,
        if (_appVersion != null) 'app_version': _appVersion,
        'os': _os(),
        'device': _device(),
        if (_model != null) 'model': _model,
        'events': batch,
      });
      int status;
      try {
        final r = await _client
            .post(_endpoint, headers: {'Content-Type': 'text/plain'}, body: body)
            .timeout(const Duration(seconds: 15));
        status = r.statusCode;
        if (status >= 400 && status < 500 && status != 429) {
          debugPrint('[analify] events refused: $status ${r.body}');
        }
      } catch (e) {
        _log('offline, will retry ($e)');
        return;
      }
      if (status == 429 || status >= 500) {
        _log('server busy ($status), will retry');
        return;
      }
      _events.removeRange(0, min(batch.length, _events.length));
      _save();
      _log('sent ${batch.length}');
    }
  }

  static String _os() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return kIsWeb ? 'web' : 'unknown';
    }
  }

  static String _device() {
    final p = defaultTargetPlatform;
    if (p != TargetPlatform.iOS && p != TargetPlatform.android) return 'desktop';
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return 'mobile';
    final shortest = view.physicalSize.shortestSide / view.devicePixelRatio;
    return shortest >= 600 ? 'tablet' : 'mobile';
  }

  // ---- offline queue ----

  void _save() {
    _prefs.setString(_queueKey, jsonEncode(_events));
  }

  void _load() {
    final raw = _prefs.getString(_queueKey);
    if (raw == null) return;
    try {
      final cutoff = DateTime.now().toUtc().subtract(_maxAge);
      for (final e in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
        final at = DateTime.tryParse('${e['at']}');
        if (at != null && at.isAfter(cutoff)) _events.add(Map<String, Object?>.from(e));
      }
    } catch (_) {
      // A damaged queue is dropped.
    }
  }

  void _log(String message) {
    if (_debug) debugPrint('[analify] $message');
  }
}

/// Records a screen every time the route changes. Name your routes (`RouteSettings(name: 'Home')` or named
/// routes) and add it to your app: `MaterialApp(navigatorObservers: [AnalifyObserver()])`.
class AnalifyObserver extends NavigatorObserver {
  void _record(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (route is PageRoute && name != null && name.isNotEmpty) Analify.screen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _record(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _record(newRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _record(previousRoute);
}
