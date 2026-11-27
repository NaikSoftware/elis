import 'dart:io';

import 'package:elis_mobile/chat/claude_screen.dart';
import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

Grid _g(String name) => gridFromAnsi(File('test/fixtures/grid/$name.ansi').readAsStringSync());
ClaudeScreen _s(String name) => ClaudeScreen.read(_g(name));

void main() {
  test('idleWithPlaceholderHasNoDraft', () {
    for (final f in ['idle-placeholder-45', 'idle-placeholder-100']) {
      final s = _s(f);
      expect(s.bottomStack, isTrue, reason: f);
      expect(s.idle, isTrue, reason: f);
      expect(s.input, startsWith('Try "'), reason: f);
      expect(s.draft, '', reason: f);
      expect(s.statusRows.length, 1, reason: f);
      expect(s.mode, ClaudeMode.manual, reason: f);
    }
  });
  test('typedDraftIsAdoptable', () => expect(_s('idle-draft-45').draft, 'hello there'));
  test('multilineDraftJoins', () => expect(_s('idle-draft-multiline-45').draft, 'first line\nsecond line'));
  test('wrappedDraftJoins', () {
    final d = _s('idle-draft-wrapped-45').draft;
    expect(norm(d), norm('first line\nthe middle line is long enough to wrap here ok\nthird line'));
    expect(d.split('\n').first, 'first line');
  });
  test('suggestionIsNotADraft', () {
    final s = _s('idle-suggestion-45');
    expect(s.input, 'write one about the mountains');
    expect(s.draft, '');
  });
  test('noStatuslineConfigured', () {
    final s = _s('idle-no-statusline-45');
    expect(s.statusRows, isEmpty);
    expect(s.mode, ClaudeMode.manual);
  });
  test('workingLine', () {
    final s = _s('working-thinking-45');
    expect(s.working, startsWith('Wrangling… ('));
    expect(s.busy, isTrue);
    expect(s.idle, isFalse);
    for (final f in ['working-45', 'working-100']) {
      final s = _s(f);
      expect(s.busy, isTrue, reason: f);
      expect(s.idle, isFalse, reason: f);
      expect(s.streaming, isNotNull, reason: f);
    }
    final g = _g('working-45');
    final (a, b) = _s('working-45').streaming!;
    expect(g.text(a), '⏺ The Sea Keeps Its Own Time');
    expect(g.text(b), '  Fishermen read it like a page.');
    expect(_g('working-100').text(_s('working-100').streaming!.$1), startsWith('⏺ '));
  });
  test('toolCallIsNotStreamingText', () {
    for (final f in ['working-mcp-45', 'working-mcp-100']) {
      final g = _g(f);
      final call = g.rows.indexWhere((row) => row.text.startsWith('⏺ memroot'));
      for (final blinked in [false, true]) {
        // Claude blinks a running call's ⏺ off
        if (blinked) g.rows[call] = VtRow([for (final c in '  ${g.text(call).substring(2)}'.runes) VtCell(String.fromCharCode(c))]);
        final (a, b) = ClaudeScreen.read(g).streaming!;
        expect((g.text(a), b), ("⏺ I'll check the project memory first.", a), reason: '$f blinked: $blinked');
      }
    }
  });
  test('collapsedCallGroupIsNotStreamingText', () {
    final g = _g('working-mcp-45');
    VtRow row(String t) => VtRow([for (final c in t.runes) VtCell(String.fromCharCode(c))]);
    g.rows[5] = row('  item 5 label');
    g.rows[6] = row('  ⎿  \$ flutter test 2>&1 | tail -1 (1m 23s)');
    for (final header in ['⏺ Fixing review findings via TDD; checking', '  Fixing review findings via TDD; checking']) {
      g.rows[4] = row(header);
      final (a, b) = ClaudeScreen.read(g).streaming!;
      expect((g.text(a), b), ("⏺ I'll check the project memory first.", a), reason: header);
    }
  });
  test('wrappedWorkingLineJoins', () {
    final s = _s('working-wrapped-45');
    expect(s.working, 'Incubating… (running PreToolUse hooks… 2/3 · 1s · ↓ 25 tokens)');
    expect(s.idle, isFalse);
  });
  test('queuedRows', () {
    final s = _s('queued-45');
    expect(s.queued, ['QUEUED reply with just ok']);
    expect(s.draft, '');
    expect(s.busy, isTrue);
    expect(s.working, 'Germinating…');
    expect(s.streaming, isNull);
  });
  test('wrappedQueuedRowJoins', () {
    final g = _g('queued-45');
    final r = g.rows.indexWhere((row) => row.text.startsWith('❯ QUEUED'));
    VtRow row(String t) => VtRow([for (final c in t.runes) VtCell(String.fromCharCode(c))]);
    g.rows[r - 1] = row('❯ QUEUED reply with just ok');
    g.rows[r] = row('  and nothing else');
    final s = ClaudeScreen.read(g);
    expect(s.queued, ['QUEUED reply with just ok and nothing else']);
    expect(s.busy, isTrue);
  });
  test('slashMenuAndBashModeKeepTheStack', () {
    for (final f in ['slash-menu-45', 'bash-mode-45']) {
      final s = _s(f);
      expect(s.bottomStack, isTrue, reason: f);
      expect(s.dialog, isFalse, reason: f);
    }
    expect(_s('slash-menu-45').input, '/mo');
  });
  test('modeCycle', () {
    expect(_s('mode-accept-45').mode, ClaudeMode.acceptEdits);
    expect(_s('mode-plan-45').mode, ClaudeMode.plan);
    expect(_s('mode-auto-45').mode, ClaudeMode.auto);
    expect(_s('shell-45').shells, 1);
    expect(_s('idle-placeholder-45').shells, 0);
  });
  test('pastePlaceholderSeen', () {
    expect(_s('paste-placeholder-45').pastePlaceholder, isTrue);
    final s = _s('paste-inline-45');
    expect(s.pastePlaceholder, isFalse);
    expect(s.draft, 'alpha line one\nbeta line two\ngamma line three');
  });
  test('interruptedRowFound', () {
    final s = _s('interrupted-queued-45');
    expect(s.interrupted, isNotNull);
    expect(s.working, startsWith('Computing…'));
    // working-45 still shows an older turn's Interrupted row
    expect(_s('working-100').interrupted, isNull);
  });
  test('dialogsAndPanelsAreDialogs', () {
    for (final f in [
      'dialog-bash-45', 'dialog-bash-100', 'dialog-ask-45', 'dialog-ask-100', //
      'panel-model-45', 'panel-usage-45', 'ctrl-o-45',
    ]) {
      final s = _s(f);
      expect(s.dialog, isTrue, reason: f);
      expect(s.bottomStack, isFalse, reason: f);
    }
  });
  test('classicLayout', () {
    final idle = _s('classic-idle-100');
    expect(idle.idle, isTrue);
    expect(idle.draft, '');
    expect(idle.statusRows.length, 1);
    expect(idle.mode, ClaudeMode.manual);
    final working = _s('classic-working-100');
    expect(working.bottomStack, isTrue);
    expect(working.busy, isTrue);
    expect(working.idle, isFalse);
    expect(working.streaming, isNotNull);
  });
  test('limitBanner', () => expect(_s('limit-45').limit, contains('Usage limit reached')));
  test('blankGridIsNotADialog', () {
    final s = ClaudeScreen.read(Grid.text(''));
    expect(s.dialog, isFalse);
    expect(s.bottomStack, isFalse);
  });
  test('unknownModeLineHasNoMode', () {
    final g = _g('idle-placeholder-45');
    final r = g.rows.lastIndexWhere((row) => row.text.contains('manual mode on'));
    g.rows[r] = VtRow([for (final c in '  ⏸ ручний режим'.runes) VtCell(String.fromCharCode(c))]);
    final s = ClaudeScreen.read(g);
    expect(s.mode, isNull);
    expect(s.modeText, isNotNull);
  });

  test('staleLimitAboveTheConversationIsGone', () {
    final rows = File('test/fixtures/grid/limit-45.ansi').readAsStringSync().split('\n')..insert(33, '⏺ Resumed after the reset');
    expect(ClaudeScreen.read(gridFromAnsi(rows.join('\n'))).limit, isNull);
  });

  test('spinnerAboveTheConversationIsNotWorking', () {
    final rows = File('test/fixtures/grid/idle-placeholder-45.ansi').readAsStringSync().split('\n');
    rows[5] = '· Loading…';
    rows[6] = '⏺ Loaded';
    final s = ClaudeScreen.read(gridFromAnsi(rows.join('\n')));
    expect((s.working, s.busy, s.idle), (null, false, true));
  });

  test('antigravityPlaceholderIsNoDraft', () {
    final s = _s('agy-idle-70');
    expect((s.agy, s.name, s.bottomStack, s.idle, s.draft, s.mode), (true, 'Antigravity', true, true, '', null));
    expect(s.input, startsWith('Accept-edits mode'));
  });
  test('antigravityDraftIsAdoptable', () => expect(_s('agy-draft-70').draft, 'hello there'));
  test('antigravityBusyReadsItsSpinner', () {
    final s = _s('agy-busy-70');
    expect((s.busy, s.dialog, s.draft, s.working), (true, false, '', 'Running command...'));
  });
  test('antigravityPermissionDialogIsADialog', () {
    final s = _s('agy-dialog-70');
    expect((s.dialog, s.bottomStack, s.idle), (true, false, false));
    // colourless (session.text) and narrow (<=60 cols, where both rules share a width) still read as a dialog
    final plain = [for (final r in _g('agy-dialog-70').rows) r.text].join('\n');
    expect(ClaudeScreen.read(Grid.text(plain)).dialog, isTrue);
    final narrow = plain.split('\n').map((l) => l.length > 45 ? l.substring(0, 45) : l).join('\n');
    expect(ClaudeScreen.read(Grid.text(narrow)).dialog, isTrue);
  });

  test('antigravityBackgroundTasksAndQueuedFooterKeepTheStack', () {
    final bar = '─' * 80;
    final g = Grid.text([
      '⣽ Target module requires a swipe-to-dismiss implementation... 10s',
      '└ Tip: Press ctrl+b to send a long task to the background.',
      '- Open PR (alt+m to send immediately)',
      bar,
      '> ',
      bar,
      '• [19:09:01] flutter run -d web-server --web-port=8088 running',
      'Press up to edit queued messages      accept-edits · Gemini 4 Neon · high · 1 task(s) · /tasks',
    ].join('\n'));
    final s = ClaudeScreen.read(g);
    expect((s.agy, s.bottomStack, s.dialog, s.busy, s.idle), (true, true, false, true, false));
    expect(s.working, startsWith('Target module requires'));

    // narrow screen: multiple wrapped task rows and a wrapped footer stay on the bottom stack
    final narrowBar = '─' * 45;
    final narrow = Grid.text([
      narrowBar,
      '> ',
      narrowBar,
      '• [19:09:01] flutter run -d web-server',
      '  --web-port=8088 running',
      '• [19:10:00] pytest -q running',
      'esc to cancel     accept-edits · Gemini',
      '4 Neon · high · 2 task(s) · /tasks',
    ].join('\n'));
    final ns = ClaudeScreen.read(narrow);
    expect((ns.agy, ns.bottomStack, ns.dialog, ns.busy), (true, true, false, true));
  });
}
