import 'package:elis_mobile/assistant/assistant_model.dart';
import 'package:elis_mobile/assistant/elis_bar.dart';
import 'package:elis_mobile/assistant/elis_sheet.dart';
import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/main.dart';
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/screens/home.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model extends ElisModel {
  _Model({bool assistant = true, int unread = 0, int extra = 0}) : super(Pairing(name: 'MacBook', host: '10.0.0.2', port: 1, token: 't', fingerprint: 'f')) {
    state = LinkState.connected;
    loaded = true;
    workspaces = [
      Workspace({
        'id': 'w',
        'name': 'elis',
        'sessions': [
          {'id': 's1', 'handle': 'side-filter', 'name': 'Sidebar filter', 'agent': 'claude'},
          for (var i = 0; i < extra; i++) {'id': 'x$i', 'name': 'extra $i', 'flagged': true},
        ],
      }),
    ];
    if (assistant) this.assistant = AssistantState.fromJson({'provider': 'codex', 'providers': ['codex'], 'unread': unread});
  }

  void changed() => notifyListeners(); // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

  final calls = <String>[];
  List<Map> transcript = [];
  Iterable<String> get assistantCalls => calls.where((c) => c.startsWith('assistant.'));

  @override
  Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args, bool windowed = true}) async {
    calls.add(cmd);
    return cmd == 'assistant.read' ? {'assistant': {'entries': transcript}} : {};
  }

  @override
  Future<void> refresh() async {}
}

const _ask = Key('askElis'), _new = Key('newSession');

void _phone(WidgetTester t, {double height = 844}) {
  t.view.physicalSize = Size(390 * 3, height * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _home(WidgetTester t, ElisModel m) async {
  _phone(t);
  await t.pumpWidget(MaterialApp(theme: buildTheme(), home: const Scaffold(body: Text('root'))));
  t.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute(builder: (_) => HomeScreen(model: m, computers: Computers())));
  await t.pumpAndSettle();
}

Future<void> _bar(WidgetTester t, ElisModel m, {void Function(Session)? openSession, bool reduceMotion = false, double height = 844}) async {
  _phone(t, height: height);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(),
    builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(disableAnimations: reduceMotion), child: child!),
    home: Scaffold(body: Stack(children: [Positioned.fill(child: ElisBar(model: m, onNewSession: () {}, openSession: openSession ?? (_) {}, child: const SizedBox()))])),
  ));
}

double _newOpacity(WidgetTester t) => t.widget<Opacity>(find.ancestor(of: find.byKey(_new), matching: find.byType(Opacity)).first).opacity;

void main() {
  testWidgets('bar hidden without assistant', (t) async {
    await _home(t, _Model(assistant: false));
    expect(find.byKey(_ask), findsNothing);
    expect(t.getSize(find.byKey(_new)).width, 390 - 24);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('bar shows unread', (t) async {
    await _home(t, _Model(unread: 2));
    expect(find.descendant(of: find.byKey(_ask), matching: find.byType(UnreadBadge)), findsOneWidget);
    expect(find.descendant(of: find.byKey(_ask), matching: find.text('2')), findsOneWidget);
    expect(t.getRect(find.byKey(_ask)).right, lessThan(t.getRect(find.byKey(_new)).left));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tap opens the sheet and marks seen', (t) async {
    final m = _Model(unread: 2);
    await _home(t, m);
    expect(find.byType(ElisSheet), findsNothing);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    expect(find.byType(ElisSheet), findsOneWidget);
    expect(_newOpacity(t), 0);
    expect(m.assistantOpen, isTrue);
    expect(m.assistantCalls, ['assistant.read', 'assistant.seen']);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a route over Home stops marking seen, and coming back re-reads', (t) async {
    final m = _Model();
    await _home(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    m.calls.clear();
    t.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('session'))));
    await t.pumpAndSettle();
    expect(m.assistantOpen, isFalse);
    m.onEvent({'kind': 'assistant.message'});
    await t.pump();
    expect(m.assistantCalls, isEmpty);
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();
    expect(m.assistantOpen, isTrue);
    expect(m.assistantCalls, ['assistant.read', 'assistant.seen']);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('back closes the sheet', (t) async {
    final m = _Model();
    await _home(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ElisSheet), findsNothing);
    expect(_newOpacity(t), 1);
    expect(m.assistantOpen, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a scrim tap closes the sheet', (t) async {
    final m = _Model();
    await _bar(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(195, 30));
    await t.pumpAndSettle();
    expect(find.byType(ElisSheet), findsNothing);
    expect(m.assistantOpen, isFalse);
  });

  testWidgets('the open sheet keeps its top and lifts its composer over the keyboard', (t) async {
    await _bar(t, _Model());
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(ElisSheet)).top, 72 + 48);
    t.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(ElisSheet)).top, 72 + 48);
    expect(t.getRect(find.byKey(const Key('composer'))).bottom, lessThanOrEqualTo(844 - 300));
  });

  testWidgets('a session link closes the sheet at once and opens the session', (t) async {
    final m = _Model()..transcript = [{'id': 'r', 'kind': 'reply', 'text': '4 files changed.', 'from': 's1'}];
    final opened = <Session>[];
    await _bar(t, m, openSession: opened.add);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    await t.tap(find.text('4 files changed.'));
    await t.pump();
    expect(opened.single.id, 's1');
    expect(find.byType(ElisSheet), findsNothing);
    expect(m.assistantOpen, isFalse);
  });

  testWidgets('reduced motion opens without a transition', (t) async {
    await _bar(t, _Model(), reduceMotion: true);
    await t.tap(find.byKey(_ask));
    await t.pump();
    expect(find.byType(ElisSheet), findsOneWidget);
    expect(_newOpacity(t), 0);
    await t.pump(const Duration(seconds: 1)); // the seen refresh
  });

  testWidgets('the handle closes on a tap, and on a long enough drag', (t) async {
    final m = _Model();
    await _bar(t, m);
    Future<void> open() async {
      await t.tap(find.byKey(_ask));
      await t.pumpAndSettle();
    }

    await open();
    await t.tapAt(const Offset(195, 72 + 24));
    await t.pumpAndSettle();
    expect(m.assistantOpen, isFalse);
    await open();
    await t.timedDragFrom(const Offset(300, 72 + 24), const Offset(0, 40), const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(m.assistantOpen, isTrue);
    await t.timedDragFrom(const Offset(300, 72 + 24), const Offset(0, 120), const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(m.assistantOpen, isFalse);
    expect(find.byType(ElisSheet), findsNothing);
  });

  testWidgets('the open sheet follows a drag down and back up, and snaps back when let go early', (t) async {
    final m = _Model();
    await _bar(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    final surface = find.byKey(const ValueKey('surface'));
    final top = t.getRect(surface).top;
    final g = await t.startGesture(const Offset(195, 72 + 24));
    await g.moveBy(const Offset(0, 50));
    await g.moveBy(const Offset(0, 50));
    await t.pump();
    expect(t.getRect(surface).top, moreOrLessEquals(top + 100, epsilon: 1));
    expect(m.assistantOpen, isTrue);
    await g.moveBy(const Offset(0, -60));
    await t.pump();
    expect(t.getRect(surface).top, moreOrLessEquals(top + 40, epsilon: 1));
    await t.pump(const Duration(seconds: 1));
    await g.up();
    await t.pumpAndSettle();
    expect(t.getRect(surface).top, top);
    expect(m.assistantOpen, isTrue);
    await t.flingFrom(const Offset(195, 72 + 24), const Offset(0, 60), 1500);
    await t.pumpAndSettle();
    expect(m.assistantOpen, isFalse);
    expect(find.byType(ElisSheet), findsNothing);
  });

  testWidgets('the Ask Elis bar follows an upward drag, snaps back early without marking seen, and opens past threshold or on a fling', (t) async {
    final m = _Model(unread: 2);
    await _bar(t, m);
    final surface = find.byKey(const ValueKey('surface'));
    final closedTop = t.getRect(surface).top;

    final g = await t.startGesture(t.getCenter(find.byKey(_ask)));
    await g.moveBy(const Offset(0, -30));
    await g.moveBy(const Offset(0, -30));
    await t.pump();
    expect(t.getRect(surface).top, moreOrLessEquals(closedTop - 60, epsilon: 1));
    expect(m.assistantOpen, isFalse);
    expect(m.assistantCalls, isEmpty);
    await t.pump(const Duration(seconds: 1));
    await g.up();
    await t.pumpAndSettle();
    expect(t.getRect(surface).top, closedTop);
    expect(find.byType(ElisSheet), findsNothing);
    expect(m.assistantCalls, isEmpty);

    final openDrag = await t.startGesture(t.getCenter(find.byKey(_ask)));
    await openDrag.moveBy(const Offset(0, -70));
    await openDrag.moveBy(const Offset(0, -70));
    await t.pump();
    expect(t.getRect(surface).top, moreOrLessEquals(closedTop - 140, epsilon: 1));
    await t.pump(const Duration(seconds: 1));
    await openDrag.up();
    await t.pumpAndSettle();
    expect(t.getRect(surface).top, 72);
    expect(find.byType(ElisSheet), findsOneWidget);
    expect(m.assistantOpen, isTrue);
    expect(m.assistantCalls, ['assistant.read', 'assistant.seen']);

    await t.tapAt(const Offset(195, 72 + 24));
    await t.pumpAndSettle();
    await t.fling(find.byKey(_ask), const Offset(0, -50), 1500);
    await t.pumpAndSettle();
    expect(m.assistantOpen, isTrue);
    expect(t.getRect(surface).top, 72);
  });

  testWidgets('dragging inside a scrollable transcript scrolls it instead of dragging the sheet', (t) async {
    final m = _Model()..transcript = [for (var i = 0; i < 30; i++) {'id': 'e$i', 'kind': 'assistant', 'text': 'line $i', 'ts': i}];
    await _bar(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    final surface = find.byKey(const ValueKey('surface'));
    final top = t.getRect(surface).top;
    final list = find.byType(ListView);
    final g = await t.startGesture(t.getCenter(list));
    await g.moveBy(const Offset(0, 100));
    await g.moveBy(const Offset(0, 100));
    await t.pump();
    expect(t.getRect(surface).top, top);
    await g.up();
    await t.pumpAndSettle();
    expect(m.assistantOpen, isTrue);
    expect(t.getRect(surface).top, top);
  });

  testWidgets('Ask Elis is a screen reader button', (t) async {
    final h = t.ensureSemantics();
    await _bar(t, _Model(unread: 2));
    expect(t.getSemantics(find.bySemanticsLabel('Ask Elis, 2 unread')).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    h.dispose();
  });

  testWidgets('closing the sheet drops the @ popup at once', (t) async {
    await _bar(t, _Model());
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('composer')), '@');
    await t.pump();
    expect(find.byKey(const Key('tag-@all')), findsOneWidget);
    await t.tapAt(const Offset(195, 72 + 24));
    await t.pump();
    expect(find.byKey(const Key('tag-@all')), findsNothing);
    await t.pumpAndSettle();
  });

  testWidgets('the @ popup stays inside the sheet on a short screen with the keyboard up', (t) async {
    await _bar(t, _Model(), height: 640);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    t.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await t.enterText(find.byKey(const Key('composer')), '@');
    await t.pumpAndSettle();
    final popup = find.ancestor(of: find.byKey(const Key('tag-@all')), matching: find.byType(ListView));
    expect(t.getRect(popup).top, greaterThanOrEqualTo(t.getRect(find.byType(ElisSheet)).top));
  });

  testWidgets('a dropped link keeps the open sheet and its draft', (t) async {
    final m = _Model();
    await _home(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('composer')), 'draft');
    m.state = LinkState.connecting;
    m.changed();
    await t.pump(const Duration(seconds: 1)); // the connecting spinner never settles
    expect(find.byType(ElisSheet), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text, 'draft');
    expect(m.assistantOpen, isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a loaded tree without the assistant closes the sheet', (t) async {
    final m = _Model();
    await _home(t, m);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    m.assistant = null;
    m.changed();
    await t.pumpAndSettle();
    expect(find.byType(ElisSheet), findsNothing);
    expect(find.byKey(_ask), findsNothing);
    expect(m.assistantOpen, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the open sheet hides the list from screen readers', (t) async {
    final h = t.ensureSemantics();
    await _home(t, _Model());
    expect(find.semantics.byLabel(RegExp('Sidebar filter')), findsOne);
    await t.tap(find.byKey(_ask));
    await t.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp('Sidebar filter')), findsNothing);
    expect(find.semantics.byLabel('Close Elis'), findsAtLeast(1));
    h.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the last row clears the fade above the bar', (t) async {
    await _home(t, _Model(extra: 30));
    await t.ensureVisible(find.byKey(const Key('filter-flagged')));
    await t.tap(find.byKey(const Key('filter-flagged'))); // a filtered list ends at its last row, with no card around it
    await t.pump();
    await t.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await t.pumpAndSettle();
    expect(t.getRect(find.byKey(const Key('row-x29'))).bottom, lessThanOrEqualTo(844 - 64 - 24));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a bar that never showed disposes cleanly', (t) async {
    await _home(t, _Model(assistant: false)..state = LinkState.offline);
    expect(find.byKey(_new), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
