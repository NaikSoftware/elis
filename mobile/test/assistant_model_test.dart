import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/model.dart';
import 'package:flutter_test/flutter_test.dart';

class CallLog extends ElisModel {
  CallLog() : super(Pairing(name: 'MacBook', host: '10.0.0.2', port: 1, token: 't', fingerprint: 'f')) {
    state = LinkState.connected;
  }
  final calls = <(String, Map<String, dynamic>?)>[];
  Map<String, dynamic> tree = {};

  @override
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, bool windowed = true}) async {
    calls.add((cmd, args));
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

  test('assistant.message event re-reads the transcript', () async {
    final m = CallLog();
    m.onEvent({'kind': 'assistant.message'});
    await Future(() {});
    expect(m.calls.where((c) => c.$1 == 'assistant.read').map((c) => c.$2), [
      {'last': 100},
    ]);
    expect(m.calls.any((c) => c.$1 == 'assistant.seen'), isFalse);
    expect(m.assistantEntries.single.to, ['s1']);
    m.assistantOpen = true;
    m.onEvent({'kind': 'assistant.message'});
    await Future(() {});
    await Future(() {});
    expect(m.calls.last.$1, 'assistant.seen');
  });

  test('askAssistant sends text verbatim', () async {
    final m = CallLog();
    expect(await m.askAssistant('@side-filter push'), isNull);
    expect(m.calls.first.$1, 'assistant.ask');
    expect(m.calls.first.$2, {'text': '@side-filter push'});
  });
}
