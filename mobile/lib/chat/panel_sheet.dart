import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/answer_bar.dart';
import '../screens/prompt.dart';
import '../terminal/key_bar.dart';
import '../terminal/term_keyboard.dart';
import '../terminal/terminal_view.dart';
import '../terminal/vt.dart';
import '../theme.dart';
import 'grid.dart';

/// Claude's live rows with the key bar and the answer bar, for a screen Chat does not draw; its keys bypass the gate.
class PanelSheet extends StatefulWidget {
  const PanelSheet(
      {super.key, required this.grid, required this.onKey, required this.onAnswer, required this.onHide, this.stopped, this.hidden = false});

  final Grid? grid;
  final void Function(String? seq, VtKey? key, int mods) onKey;
  final void Function(String key) onAnswer;
  final VoidCallback onHide;
  final String? stopped; // shown verbatim at the top
  final bool hidden; // swiped down: kept offstage so tapping Open slides it back up

  @override
  State<PanelSheet> createState() => _PanelSheetState();
}

class _PanelSheetState extends State<PanelSheet> with SingleTickerProviderStateMixin {
  // how far down the sheet is, in its own heights: a drag of its handle moves it, a release finishes the move
  late final _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  final _sheetKey = GlobalKey();
  // owned here, so the soft keyboard's input closes with the panel and never types past the gate
  final _keyboard = FocusNode();
  late bool _hidden = widget.hidden;

  double get _height => max(_sheetKey.currentContext?.size?.height ?? 1, 1);

  @override
  void initState() {
    super.initState();
    if (_hidden) _slide.value = 1;
  }

  @override
  void didUpdateWidget(PanelSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hidden && !_hidden) _keyboard.unfocus();
    if (!widget.hidden && _hidden) unawaited((_slide..value = 1).animateTo(0, curve: Curves.easeOutCubic));
    _hidden = widget.hidden;
  }

  @override
  void dispose() {
    _slide.dispose();
    _keyboard.dispose();
    super.dispose();
  }

  // as Term's key: a focused field whose keyboard the user hid gets it back only by asking the platform
  void _toggleKeyboard() {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return _keyboard.unfocus();
    if (!_keyboard.hasPrimaryFocus) return _keyboard.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dy;
    if (v > 700 || (v > -700 && _slide.value > 0.25)) {
      unawaited(
        _slide.animateTo(1, curve: Curves.easeOut).then((_) {
          if (mounted && _slide.isCompleted) widget.onHide();
        }),
      );
    } else {
      unawaited(_slide.animateTo(0, curve: Curves.easeOutCubic));
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.grid;
    final text = g == null ? '' : [for (var r = 0; r < g.rows.length; r++) g.text(r)].join('\n');
    final options = promptOptions(text);
    final snapshot = g?.snapshot;
    return Offstage(
      offstage: widget.hidden,
      child: ExcludeFocus(
        excluding: widget.hidden,
        child: ClipRect(
          child: SlideTransition(
            key: _sheetKey,
            position: _slide.drive(Tween(begin: Offset.zero, end: const Offset(0, 1))),
            child: Material(
              key: const Key('panelSheet'),
              color: C.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: Column(children: [
                  // the rows scroll, so only the handle takes the swipe
                  GestureDetector(
                    key: const Key('panelHandle'),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down, // the sheet stays under the finger from the touch
                    onVerticalDragStart: (_) => _slide.stop(),
                    onVerticalDragUpdate: (d) => _slide.value += d.delta.dy / _height,
                    onVerticalDragEnd: _dragEnd,
                    onVerticalDragCancel: () => unawaited(_slide.animateTo(0, curve: Curves.easeOutCubic)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                          child: Container(width: 36, height: 4, decoration: BoxDecoration(color: C.muted, borderRadius: BorderRadius.circular(2)))),
                    ),
                  ),
                  if (widget.stopped case final s?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Align(alignment: Alignment.centerLeft, child: Text(s, key: const Key('panelStopped'), style: const TextStyle(fontSize: 13))),
                    ),
                  Expanded(
                    child: ColoredBox(
                      color: C.term,
                      // bottom first: Claude draws its panels at the end of the grid
                      child: SingleChildScrollView(
                        reverse: true,
                        child: snapshot != null
                            ? TerminalView(snapshot: snapshot, hold: false)
                            : Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(text, key: const Key('panelText'), style: const TextStyle(fontFamily: mono, fontSize: 11, color: C.termText)),
                              ),
                      ),
                    ),
                  ),
                  if (options.isNotEmpty) AnswerBar(options: options, onAnswer: widget.onAnswer),
                  // Chat never sends Ctrl+C: Claude Code clears its input or exits on it
                  KeyBar(onKey: widget.onKey, onKeyboard: _toggleKeyboard, omit: const {'Control C'}),
                  // text goes as onAnswer's typed keys; a free-text panel (the /resume filter) reads it like the answer digits
                  TermKeyboard(
                      focus: _keyboard,
                      onKey: (k, mods) => widget.onKey(xtermSeq(k, mods), k, mods),
                      onText: widget.onAnswer,
                      onPaste: widget.onAnswer),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
