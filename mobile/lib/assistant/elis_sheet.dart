import 'dart:math';

import 'package:flutter/material.dart';

import '../chat/items.dart' show chatMarkdown, copyMenu, userBubble;
import '../chat/keep_scroll.dart';
import '../model.dart';
import '../theme.dart';
import 'assistant_model.dart';
import 'elis_composer.dart';

const _body = TextStyle(fontSize: 14, height: 20 / 14);
const _name = TextStyle(fontSize: 13, color: C.muted);
final _cardLine = BorderSide(color: C.text.withValues(alpha: .14));

/// The Elis chat: its header, the transcript and the composer.
class ElisSheet extends StatefulWidget {
  const ElisSheet({super.key, required this.model, required this.openSession});
  final ElisModel model;
  final void Function(Session) openSession;

  @override
  State<ElisSheet> createState() => _ElisSheetState();
}

class _ElisSheetState extends State<ElisSheet> {
  late final _scroll = KeepController(_shift);
  late List<AssistantEntry> _entries;
  final _built = <String, BuildContext>{}; // an entry's row while built, to anchor on
  (RenderObject, double)? _keep; // the newest built row and its content offset before the entries changed

  ElisModel get model => widget.model;
  void Function(Session) get openSession => widget.openSession;

  @override
  void initState() {
    super.initState();
    _entries = model.assistantEntries;
    model.addListener(_changed);
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  // scrolled up, new entries keep the rows on screen where they are, as the session chat does
  void _changed() {
    if (identical(model.assistantEntries, _entries)) return;
    _entries = model.assistantEntries;
    final away = _scroll.hasClients && _scroll.position.pixels > 0;
    final row = !away
        ? null
        : _built.values.map((c) => c.mounted ? c.findRenderObject() : null).where((r) => listOffset(r) != null).fold<RenderObject?>(
            null, (m, r) => m == null || listOffset(r)! < listOffset(m)! ? r : m);
    _keep = row == null ? null : (row, listOffset(row)!);
    WidgetsBinding.instance.addPostFrameCallback((_) => _keep = null);
  }

  // runs inside the viewport's layout, before the frame paints
  double _shift() {
    final k = _keep;
    _keep = null;
    final now = k == null ? null : listOffset(k.$1);
    return now == null ? 0 : now - k!.$2;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: model,
        builder: (context, _) {
          final entries = model.assistantEntries;
          final index = {for (final (i, e) in entries.indexed) e.id: entries.length - 1 - i};
          _built.removeWhere((id, c) => !index.containsKey(id) || !c.mounted);
          return Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(spacing: 10, children: [AppMark(size: 28), Text('Elis', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))]),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
                itemCount: entries.length,
                findChildIndexCallback: (k) => k is ValueKey<String> ? index[k.value] : null,
                itemBuilder: (_, i) {
                  final e = entries[entries.length - 1 - i];
                  return Builder(
                    key: ValueKey(e.id),
                    builder: (c) {
                      _built[e.id] = c;
                      return Padding(padding: const EdgeInsets.only(top: 10), child: _entry(c, e));
                    },
                  );
                },
              ),
            ),
            if (model.assistant?.running ?? false)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Align(alignment: Alignment.centerLeft, child: Text('Elis is working…', style: TextStyle(fontSize: 13, color: C.muted))),
              ),
            ElisComposer(model: model),
          ]);
        },
      );

  Widget _entry(BuildContext c, AssistantEntry e) => switch (e.kind) {
        'user' => userBubble(c, e.text, child: taggedText(model, e.text, const TextStyle(fontSize: 15))),
        'assistant' => copyMenu(c, e.text, chatMarkdown(e.text)),
        'sent' => _sent(e),
        'reply' => _reply(c, e),
        'error' => Text(e.text, style: const TextStyle(fontSize: 14, color: C.danger)),
        _ => const SizedBox.shrink(),
      };

  // a session the phone cannot see (another window's, or closed) shows its id's start, as the desktop's tag does
  List<Widget> _who(String id) => switch (model.session(id)) {
        final s? => [
            if (s.handle.isNotEmpty) TagChip('@${s.handle}', tagTint(model, '@${s.handle}') ?? C.active),
            Expanded(child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _name)),
            const Icon(Icons.arrow_forward, size: 16, color: C.accent),
          ],
        null => [TagChip('@${id.substring(0, min(8, id.length))}', C.muted)],
      };

  Widget _reply(BuildContext c, AssistantEntry e) {
    final s = e.from == null ? null : model.session(e.from!);
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: .8,
        child: Material(
          color: C.hover,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            side: _cardLine,
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12), topRight: Radius.circular(12), bottomRight: Radius.circular(12), bottomLeft: Radius.circular(4)),
          ),
          child: InkWell(
            onTap: s == null ? null : () => openSession(s),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 11, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 8, children: [
                if (e.from case final from?) Row(spacing: 8, children: [const Text('FROM', style: sectionLabel), ..._who(from)]),
                copyMenu(c, e.text, Text(e.text, style: _body)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sent(AssistantEntry e) {
    final to = e.to;
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: .8,
        child: Container(
          padding: EdgeInsets.fromLTRB(14, to.isEmpty ? 12 : 4, 11, 12),
          decoration: BoxDecoration(
            border: Border.fromBorderSide(_cardLine),
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12), topRight: Radius.circular(12), bottomRight: Radius.circular(4), bottomLeft: Radius.circular(12)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, id) in to.indexed)
              InkWell(
                key: Key('to-$id'),
                borderRadius: BorderRadius.circular(8),
                onTap: switch (model.session(id)) {
                  final s? => () => openSession(s),
                  null => null,
                },
                child: SizedBox(
                  height: 44,
                  child: Row(spacing: 8, children: [
                    SizedBox(width: 22, child: i == 0 ? const Text('TO', style: sectionLabel) : null),
                    ..._who(id),
                  ]),
                ),
              ),
            if (to.isNotEmpty) const SizedBox(height: 8),
            Text(e.text, style: _body.copyWith(color: C.muted)),
          ]),
        ),
      ),
    );
  }
}
