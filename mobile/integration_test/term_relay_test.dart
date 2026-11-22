// On a device or emulator against the computer `tool/term-relay-host.sh up` sets up (Linux), which prints the link:
//   flutter test integration_test/term_relay_test.dart -d emulator-5554 --dart-define=PAIR_LINK='elis://pair?h=10.0.2.2&...'
// with `tool/term-relay-host.sh takeback` running beside it: once phone-target shows `typed-42` it takes the lead back.
import 'package:elis_mobile/client.dart';
import 'package:elis_mobile/main.dart' as app;
import 'package:elis_mobile/model.dart';
import 'package:elis_mobile/terminal/terminal_view.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'app_test.dart' show pumpUntil;

// the computer's tree, read on a connection of its own: whether the phone leads phone-target
Future<bool> phoneLeads(Connection c) async {
  final tree = (await c.call('tree'))['tree'] as Map<String, dynamic>;
  for (final w in tree['workspaces'] as List) {
    for (final s in (w as Map)['sessions'] as List) {
      if ((s as Map)['name'] != 'phone-target') continue;
      return (s['surfaces'] as List? ?? []).any((f) => (f as Map)['phoneLead'] == true);
    }
  }
  throw TestFailure('no session named phone-target');
}

Future<void> waitLead(WidgetTester t, Connection c, bool want) async {
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(end)) {
    if (await phoneLeads(c) == want) return;
    await t.pump(const Duration(milliseconds: 500));
  }
  throw TestFailure('phoneLead never became $want');
}

VtSnapshot? termSnapshot(WidgetTester t) {
  final view = find.byType(TerminalView);
  return view.evaluate().isEmpty ? null : t.widget<TerminalView>(view).snapshot;
}

bool redCell(VtSnapshot s) => s.lines.any((l) {
      final i = l.text.indexOf('RED');
      final fg = i < 0 ? null : l.cells[i].fg;
      if (fg == null) return false;
      final r = fg >> 16 & 0xff, g = fg >> 8 & 0xff, b = fg & 0xff;
      return r > g + 0x40 && r > b + 0x40;
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const link = String.fromEnvironment('PAIR_LINK');

  testWidgets('a Live pane over the relay: colour, lead, typing, take-back, then a prompt card from the coloured grid', (t) async {
    expect(link, isNotEmpty, reason: 'pass --dart-define=PAIR_LINK=...');
    final computer = await Connection.open(Pairing.parse(link)!);
    addTearDown(computer.close);
    await PairingStore.save([]);
    await ComposerPref.set(true);
    app.main();
    await pumpUntil(t, find.byKey(const Key('pairLink')));
    await t.enterText(find.byKey(const Key('pairLink')), link);
    await t.ensureVisible(find.byKey(const Key('connect')));
    await t.tap(find.byKey(const Key('connect')));
    await pumpUntil(t, find.text('phone-target'));

    await t.tap(find.text('phone-target').last); // the row; a Needs-you card may show it too
    await pumpUntil(t, find.byKey(const Key('composer')));
    await waitLead(t, computer, true); // the phone leads the Live pane it opens

    // the full-screen grid: RED in red, the typed arithmetic's answer, and a numbered question in colour at the bottom
    await t.enterText(find.byKey(const Key('composer')),
        r"printf '\e[?1049h\e[2J\e[H\e[31mRED\e[0m typed-%s%s\e[99;1H\e[3A\e[36m1. Yes\n2. No\e[0m\n' 4 2");
    await t.tap(find.byKey(const Key('send')));
    await pumpUntil(t, find.byType(TerminalView));
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!(termSnapshot(t)?.lines.any((l) => l.text.contains('typed-42')) ?? false)) {
      if (DateTime.now().isAfter(end)) throw TestFailure('typed text never reached the grid');
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(redCell(termSnapshot(t)!), isTrue, reason: 'RED is drawn in red');
    await pumpUntil(t, find.byKey(const Key('answer-1')));
    expect(find.byKey(const Key('answer-2')), findsOneWidget);

    await pumpUntil(t, find.text('The computer took the lead back.'), timeout: const Duration(seconds: 90));
    await waitLead(t, computer, false);

    // Chat over claude-target reads the dialog from the pane's vt grid; session.text alone carries no colours for it
    await t.binding.handlePopRoute();
    await pumpUntil(t, find.text('claude-target'));
    await t.tap(find.text('claude-target').last);
    await pumpUntil(t, find.byKey(const Key('promptCard')));
  });
}
