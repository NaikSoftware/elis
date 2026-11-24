import 'package:flutter/material.dart';

import '../chat/items.dart' show userBubble;
import '../model.dart';
import '../theme.dart';
import 'assistant_model.dart';
import 'elis_composer.dart';

const _body = TextStyle(fontSize: 14, height: 20 / 14);
const _name = TextStyle(fontSize: 13, color: C.muted);
final _cardLine = BorderSide(color: C.text.withValues(alpha: .14));

/// The Elis chat: its header, the transcript and the composer.
class ElisSheet extends StatelessWidget {
  const ElisSheet({super.key, required this.model, required this.openSession});
  final ElisModel model;
  final void Function(Session) openSession;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: model,
        builder: (context, _) {
          final entries = model.assistantEntries;
          return Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(spacing: 10, children: [AppMark(size: 28), Text('Elis', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))]),
            ),
            Expanded(
              child: ListView.separated(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (c, i) => _entry(c, entries[entries.length - 1 - i]),
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
        'assistant' => taggedText(model, e.text, _body),
        'sent' => _sent(e),
        'reply' => _reply(e),
        'error' => Text(e.text, style: const TextStyle(fontSize: 14, color: C.danger)),
        _ => const SizedBox.shrink(),
      };

  List<Widget> _who(Session s) => [
        if (s.handle.isNotEmpty) TagChip('@${s.handle}', tagTint(model, '@${s.handle}') ?? C.active),
        Expanded(child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _name)),
      ];

  Widget _reply(AssistantEntry e) {
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
                if (s != null)
                  Row(spacing: 8, children: [
                    const Text('FROM', style: sectionLabel),
                    ..._who(s),
                    const Icon(Icons.arrow_forward, size: 16, color: C.accent),
                  ]),
                Text(e.text, style: _body),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sent(AssistantEntry e) {
    final to = [for (final id in e.to) ?model.session(id)];
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
            for (final (i, s) in to.indexed)
              InkWell(
                key: Key('to-${s.id}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => openSession(s),
                child: SizedBox(
                  height: 44,
                  child: Row(spacing: 8, children: [
                    SizedBox(width: 22, child: i == 0 ? const Text('TO', style: sectionLabel) : null),
                    ..._who(s),
                    const Icon(Icons.arrow_forward, size: 16, color: C.accent),
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
