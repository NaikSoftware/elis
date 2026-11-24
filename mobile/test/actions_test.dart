import 'package:elis_mobile/screens/actions.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _openPrompt(WidgetTester t, Size size, {String initial = ''}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: Scaffold(
      body: Builder(
        builder: (c) => TextButton(
          onPressed: () => promptText(c, 'Rename session', initial: initial),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

double _dialogWidth(WidgetTester t) =>
    t.getSize(find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first).width;

void main() {
  testWidgets('prompt dialog fills mobile width and stays fixed while typing', (t) async {
    await _openPrompt(t, const Size(390, 844), initial: 'a');
    expect(_dialogWidth(t), 390 - 48);

    await t.enterText(find.byKey(const Key('promptField')), 'a very long session name that keeps growing');
    await t.pump();
    expect(_dialogWidth(t), 390 - 48);

    await t.enterText(find.byKey(const Key('promptField')), '');
    await t.pump();
    expect(_dialogWidth(t), 390 - 48);
  });

  testWidgets('prompt dialog caps width at Material max on larger screens', (t) async {
    await _openPrompt(t, const Size(900, 1200), initial: 'a');
    expect(_dialogWidth(t), 560);

    await t.enterText(find.byKey(const Key('promptField')), 'a very long session name that keeps growing');
    await t.pump();
    expect(_dialogWidth(t), 560);
  });
}
