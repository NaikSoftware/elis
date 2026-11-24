import 'dart:async';

import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/model.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class CallLog extends ElisModel {
  // the link never opens: a test that resumes stays on its stubbed calls
  CallLog() : super(Pairing(name: 'MacBook', host: '10.0.0.2', port: 1, token: 't', fingerprint: 'f'), open: (_, {preferBluetooth = false}) => Completer<Connection>().future) {
    state = LinkState.connected;
  }
  final calls = <(String, Map<String, dynamic>?, bool)>[];
  Map<String, dynamic> tree = {};
  Object? treeError, readError;

  Iterable<String> get assistantCalls => calls.map((c) => c.$1).where((c) => c.startsWith('assistant.'));

  @override
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, bool windowed = true}) async {
    calls.add((cmd, args, windowed));
    if (treeError case final e? when cmd == 'tree') throw e;
    if (readError case final e? when cmd == 'assistant.read') throw e;
    return switch (cmd) {
      'window.list' => {'windows': []},
      'tree' => {'tree': tree},
      'assistant.read' => {
          'assistant': {
            'entries': [
              {'id': 'e1', 'kind': 'sent', 'from': 'a', 'to': ['s1'], 'text': 'push', 'ts': 1.5},
            ],
          },
        },
      _ => {},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('parses assistant state and handles', () async {
    final m = CallLog()
      ..tree = {
        'assistant': {'provider': 'codex', 'providers': ['claude', 'codex'], 'running': false, 'unread': 2},
        'workspaces': [
          {'id': 'w', 'handle': 'elis', 'sessions': [{'id': 's1', 'handle': 'side-filter'}]},
        ],
      };
    await m.refresh();
    expect(m.assistant!.unread, 2);
    expect(m.assistant!.providers, ['claude', 'codex']);
    expect(m.workspaces.single.handle, 'elis');
    expect(m.workspaces.single.sessions.single.handle, 'side-filter');
  });

  test('no assistant key leaves it null', () async {
    final m = CallLog();
    await m.refresh();
    expect(m.assistant, isNull);
  });

  test('assistant.message event re-reads an open transcript and marks it seen', () async {
    final m = CallLog();
    m.onEvent({'kind': 'assistant.message'});
    await pumpEventQueue();
    expect(m.assistantCalls, isEmpty);
    m.assistantOpen = true;
    m.onEvent({'kind': 'assistant.message'});
    await pumpEventQueue();
    expect(m.calls.where((c) => c.$1 == 'assistant.read').map((c) => c.$2), [
      {'last': 100},
    ]);
    expect(m.assistantEntries.single.to, ['s1']);
    expect(m.assistantCalls, ['assistant.read', 'assistant.seen']);
    m.dispose();
  });

  test('a failed read marks nothing seen', () async {
    final m = CallLog()
      ..assistantOpen = true
      ..readError = TimeoutException('slow');
    m.onEvent({'kind': 'assistant.message'});
    await pumpEventQueue();
    expect(m.assistantCalls, ['assistant.read']);
    m.dispose();
  });

  test('a backgrounded app does not mark an open transcript seen', () async {
    final m = CallLog()
      ..assistantOpen = true
      ..background = true;
    m.onEvent({'kind': 'assistant.message'});
    await pumpEventQueue();
    expect(m.assistantCalls, isNot(contains('assistant.seen')));
    m.dispose();
  });

  test('resume re-reads an open transcript and marks it seen', () async {
    AndroidFlutterLocalNotificationsPlugin.registerWith(); // resume asks it whether notifications are on
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (_) async => null);
    final m = CallLog()
      ..assistantOpen = true
      ..background = true;
    m.resume();
    await pumpEventQueue();
    expect(m.assistantCalls, ['assistant.read', 'assistant.seen']);
    m.dispose();
  });

  test('a failed tree read keeps polling while Elis runs', () {
    fakeAsync((async) {
      final m = CallLog()
        ..tree = {
          'assistant': {'providers': [], 'running': true, 'unread': 0},
        };
      int trees() => m.calls.where((c) => c.$1 == 'tree').length;
      m.refresh();
      async.flushMicrotasks();
      m.treeError = TimeoutException('slow');
      async.elapse(const Duration(seconds: 2));
      expect(trees(), 2);
      m.treeError = ElisError('busy');
      async.elapse(const Duration(seconds: 2));
      expect(trees(), 3);
      async.elapse(const Duration(seconds: 2));
      expect(trees(), 4);
    });
  });

  test('polls tree while running', () {
    fakeAsync((async) {
      final m = CallLog()
        ..tree = {
          'assistant': {'providers': [], 'running': true, 'unread': 0},
        };
      int trees() => m.calls.where((c) => c.$1 == 'tree').length;
      m.refresh();
      async.flushMicrotasks();
      expect(trees(), 1);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(trees(), 2);
    });
  });

  test('stops polling tree once the turn is no longer running', () {
    fakeAsync((async) {
      final m = CallLog()
        ..tree = {
          'assistant': {'providers': [], 'running': false, 'unread': 0},
        };
      int trees() => m.calls.where((c) => c.$1 == 'tree').length;
      m.refresh();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(trees(), 1);
    });
  });

  test('markAssistantSeen re-reads the tree so unread is not stale', () {
    fakeAsync((async) {
      final m = CallLog();
      m.markAssistantSeen();
      async.flushMicrotasks();
      expect(m.calls.map((c) => c.$1), ['assistant.seen']);
      async.elapse(const Duration(milliseconds: 250));
      async.flushMicrotasks();
      expect(m.calls.map((c) => c.$1), ['assistant.seen', 'window.list', 'tree']);
    });
  });

  test('assistant requests are app-wide, not window-addressed', () async {
    final m = CallLog();
    await m.readAssistant();
    await m.askAssistant('hi');
    await m.setProvider('claude');
    await m.markAssistantSeen();
    final assistant = m.calls.where((c) => c.$1.startsWith('assistant.'));
    expect(assistant.map((c) => c.$1), ['assistant.read', 'assistant.ask', 'assistant.provider', 'assistant.seen']);
    expect(assistant.every((c) => c.$3 == false), isTrue);
  });

  test('askAssistant sends text verbatim', () async {
    final m = CallLog();
    expect(await m.askAssistant('@side-filter push'), isNull);
    expect(m.calls.first.$1, 'assistant.ask');
    expect(m.calls.first.$2, {'text': '@side-filter push'});
  });
}
