import 'dart:convert';

import 'package:analify/analify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> bodies;
  late int status;

  MockClient server() => MockClient((request) async {
        if (status < 300) bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(status >= 400 ? '{"detail":"nope"}' : '', status);
      });

  setUp(() async {
    bodies = [];
    status = 202;
    SharedPreferences.setMockInitialValues({});
    await Analify.stopForTesting();
  });

  test('screens, events and users go out in one batch', () async {
    await Analify.start(key: 'AN-TEST', appVersion: '2.0.1', model: 'Pixel 8', client: server());
    Analify.openedFrom(Uri.parse('myapp://open?utm_source=newsletter&utm_campaign=launch'));
    Analify.screen('Home');
    Analify.track('note_saved', {'words': 120, 'draft': true, 'ratio': 0.5, 'title': 'Hi', 'skipped': [1, 2]});
    Analify.identify('user-9');
    Analify.screen('Editor');
    await Analify.flush();

    expect(bodies, hasLength(1));
    final body = bodies.single;
    expect(body['key'], 'AN-TEST');
    expect(body['app_version'], '2.0.1');
    expect(body['model'], 'Pixel 8');
    expect((body['install'] as String).length, 32);
    final events = (body['events'] as List).cast<Map<String, dynamic>>();
    expect(events.map((e) => e['type']), ['screen', 'event', 'identify', 'screen']);
    expect(events[0]['utm_campaign'], 'launch');
    expect(events[3].containsKey('utm_campaign'), isFalse);
    expect(events[1]['screen'], 'Home');
    expect(events[1]['props'], {'draft': true, 'ratio': 0.5, 'title': 'Hi', 'words': 120});
    expect(events[3]['uid'], 'user-9');
    expect(events[0].containsKey('uid'), isFalse);
    expect(DateTime.tryParse(events[0]['at'] as String), isNotNull);
  });

  test('the install ID stays the same between launches', () async {
    await Analify.start(key: 'AN-TEST', client: server());
    final prefs = await SharedPreferences.getInstance();
    final first = prefs.getString('analify_install');
    await Analify.stopForTesting();
    await Analify.start(key: 'AN-TEST', client: server());
    expect(prefs.getString('analify_install'), first);
  });

  test('offline events are kept and sent later, even after a restart', () async {
    status = 503;
    await Analify.start(key: 'AN-TEST', client: server());
    Analify.screen('Home');
    await Analify.flush();
    expect(bodies, isEmpty);

    await Analify.stopForTesting();  // the app restarts with the queue still saved
    status = 202;
    await Analify.start(key: 'AN-TEST', client: server());
    await Analify.flush();
    expect((bodies.single['events'] as List).single['screen'], 'Home');
  });

  test('refused events are dropped', () async {
    status = 400;
    await Analify.start(key: 'AN-TEST', client: server());
    Analify.track('x');
    await Analify.flush();
    status = 202;
    await Analify.flush();
    expect(bodies, isEmpty);
  });

  test('long queues go in requests of fifty', () async {
    status = 503;
    await Analify.start(key: 'AN-TEST', client: server());
    for (var i = 0; i < 70; i++) {
      Analify.track('e$i');
    }
    await Analify.flush();
    status = 202;
    await Analify.flush();
    expect(bodies.map((b) => (b['events'] as List).length), [50, 20]);
  });

  test('signing out stops sending the user', () async {
    await Analify.start(key: 'AN-TEST', client: server());
    Analify.identify('user-9');
    Analify.identify(null);
    Analify.screen('Home');
    await Analify.flush();
    expect((bodies.single['events'] as List).last.containsKey('uid'), isFalse);
  });
}
