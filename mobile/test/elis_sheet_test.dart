import 'package:elis_mobile/assistant/assistant_model.dart';
import 'package:elis_mobile/assistant/elis_sheet.dart';
import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model extends ElisModel {
  _Model() : super(Pairing(name: 'MacBook', host: '10.0.0.2', port: 1, token: 't', fingerprint: 'f')) {
    state = LinkState.connected;
    workspaces = [
      Workspace({
        'id': 'w',
        'handle': 'elis',
        'name': 'elis',
        'tint': 'purple',
        'sessions': [
          {'id': 's1', 'handle': 'side-filter', 'name': 'Sidebar filter', 'agent': 'claude'},
          {'id': 's2', 'handle': 'pair-link', 'name': 'Pair link', 'agent': 'codex'},
        ],
      }),
    ];
    assistant = AssistantState.fromJson({'provider': 'codex', 'providers': ['claude', 'codex'], 'running': false, 'unread': 0});
  }

  final calls = <(String, Map<String, dynamic>?)>[];
  String? fail;

  @override
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, bool windowed = true}) async {
    calls.add((cmd, args));
    if (fail case final f? when cmd == 'assistant.ask') throw ElisError(f);
    return {};
  }
}

AssistantEntry _e(String kind, String text, {String? from, List<String> to = const []}) =>
    AssistantEntry.fromJson({'id': '$kind-$text', 'kind': kind, 'text': text, 'from': from, 'to': to, 'ts': 1});

void main() {
  late _Model m;
  late List<Session> opened;

  setUp(() {
    m = _Model();
    opened = [];
  });

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: ElisSheet(model: m, openSession: opened.add))));
    addTearDown(m.dispose);
  }

  String field(WidgetTester t) => t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text;

  testWidgets('renders each entry kind', (t) async {
    m.assistantEntries = [
      _e('user', '@all who has uncommitted changes?'),
      _e('assistant', 'Sent to 2 agent sessions.'),
      _e('sent', 'who has uncommitted changes?', to: ['s1', 's2']),
      _e('reply', '4 files changed.', from: 's1'),
      _e('error', 'codex exited with status 1'),
    ];
    await pump(t);
    expect(find.text('FROM'), findsOneWidget);
    expect(find.text('TO'), findsOneWidget);
    expect(t.widget<Text>(find.text('codex exited with status 1')).style!.color, C.danger);
  });

  testWidgets('reply card opens its session', (t) async {
    m.assistantEntries = [_e('reply', '4 files changed.', from: 's1')];
    await pump(t);
    await t.tap(find.text('4 files changed.'));
    expect(opened.single.id, 's1');
  });

  testWidgets('reply from a closed session does nothing', (t) async {
    m.assistantEntries = [_e('reply', 'old news', from: 'gone')];
    await pump(t);
    await t.tap(find.text('old news'));
    expect(opened, isEmpty);
    expect(find.text('FROM'), findsNothing);
  });

  testWidgets('sent card rows open their sessions', (t) async {
    m.assistantEntries = [_e('sent', 'push it', to: ['gone', 's2'])];
    await pump(t);
    expect(find.byKey(const Key('to-gone')), findsNothing);
    await t.tap(find.text('Pair link'));
    expect(opened.single.id, 's2');
  });

  testWidgets('@ popup inserts the tag', (t) async {
    await pump(t);
    await t.enterText(find.byKey(const Key('composer')), 'ask @si');
    await t.pump();
    await t.tap(find.byKey(const Key('tag-@side-filter')));
    await t.pump();
    expect(field(t), 'ask @side-filter ');
    expect(find.byKey(const Key('tag-@side-filter')), findsNothing);
  });

  testWidgets('field chips stay while the keyboard composes', (t) async {
    await pump(t);
    final c = t.widget<TextField>(find.byKey(const Key('composer'))).controller!;
    c.value = const TextEditingValue(text: '@side-filter push', composing: TextRange(start: 13, end: 17));
    final spans = <TextSpan>[];
    c.buildTextSpan(context: t.element(find.byKey(const Key('composer'))), withComposing: true).visitChildren((s) {
      if (s is TextSpan && s.text != null) spans.add(s);
      return true;
    });
    expect(spans.firstWhere((s) => s.text == '@side-filter').style!.background, isNotNull);
    expect(spans.firstWhere((s) => s.text == 'push').style!.decoration, TextDecoration.underline);
  });

  testWidgets('send calls ask and clears', (t) async {
    await pump(t);
    expect(t.widget<FilledButton>(find.byKey(const Key('send'))).onPressed, isNull);
    await t.enterText(find.byKey(const Key('composer')), 'ask @side-filter to push');
    await t.pump();
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(m.calls.where((c) => c.$1 == 'assistant.ask').single.$2, {'text': 'ask @side-filter to push'});
    expect(field(t), '');
    await t.pump(const Duration(milliseconds: 200));
  });

  testWidgets('a failed send keeps the text and tells why', (t) async {
    m.fail = 'codex is not logged in';
    await pump(t);
    await t.enterText(find.byKey(const Key('composer')), 'hello');
    await t.pump();
    await t.tap(find.byKey(const Key('send')));
    await t.pump();
    expect(field(t), 'hello');
    expect(find.text('codex is not logged in'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('provider menu sets provider', (t) async {
    await pump(t);
    await t.tap(find.byKey(const Key('provider-chip')));
    await t.pumpAndSettle();
    expect(find.text('FOUND ON THIS SYSTEM'), findsOneWidget);
    await t.tap(find.text('Claude Code'));
    await t.pumpAndSettle();
    expect(m.calls.where((c) => c.$1 == 'assistant.provider').single.$2, {'provider': 'claude'});
  });

  testWidgets('shows the running line while Elis works', (t) async {
    m.assistant = AssistantState.fromJson({'provider': 'codex', 'providers': ['codex'], 'running': true});
    await pump(t);
    expect(find.text('Elis is working…'), findsOneWidget);
  });
}
