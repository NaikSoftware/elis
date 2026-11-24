import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../model.dart';
import '../notice.dart';
import '../screens/actions.dart';
import '../screens/composer.dart';
import '../theme.dart';
import 'assistant_model.dart';
import 'tags.dart';

final _tag = RegExp(r'(?<=^|\s)@(?:ws:)?[a-z0-9-]+', caseSensitive: false);
const _popupFill = Color(0xFF38383F);
const _lucideLayoutDashboard = '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/>'
    '<rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>';

/// The chip colour for [tag]: the accent for `@all`, its workspace's tint for a known handle, null for an unknown one.
Color? tagTint(ElisModel m, String tag) {
  if (tag == '@all') return C.accent;
  final h = tag.substring(1);
  if (h.isEmpty) return null;
  for (final w in m.workspaces) {
    if (h == 'ws:${w.handle}' || w.sessions.any((s) => s.handle == h)) return tintColor(w.tint) ?? C.active;
  }
  return null;
}

/// [text] split around its known tags, each drawn by [chip].
List<InlineSpan> _split(String text, Color? Function(String) tint, InlineSpan Function(String tag, Color c) chip) {
  final out = <InlineSpan>[];
  var at = 0;
  for (final t in _tag.allMatches(text)) {
    final c = tint(t[0]!);
    if (c == null) continue;
    if (t.start > at) out.add(TextSpan(text: text.substring(at, t.start)));
    out.add(chip(t[0]!, c));
    at = t.end;
  }
  if (at < text.length) out.add(TextSpan(text: text.substring(at)));
  return out;
}

/// [text] with its known `@` tags as chips, for read-only text.
Widget taggedText(ElisModel m, String text, TextStyle style) => Text.rich(
    TextSpan(
        children: _split(text, (t) => tagTint(m, t),
            (t, c) => WidgetSpan(alignment: PlaceholderAlignment.middle, child: TagChip(t, c)))),
    style: style);

class TagChip extends StatelessWidget {
  const TagChip(this.tag, this.tint, {super.key});
  final String tag;
  final Color tint;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: .22),
          border: Border.all(color: tint.withValues(alpha: .45)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(tag, style: const TextStyle(fontFamily: mono, fontSize: 12, height: 1.5, color: C.text)),
      );
}

// a WidgetSpan counts as one character and would move the caret off the plain text, so a field's chip is a painted background
class _TagController extends TextEditingController {
  _TagController(this.tint);
  final Color? Function(String) tint;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final spans = _split(
        text,
        tint,
        (t, c) => TextSpan(
            text: t, style: TextStyle(fontFamily: mono, fontSize: 12, color: C.text, background: Paint()..color = c.withValues(alpha: .22))));
    // the keyboard keeps a composing word while typing: underline it inside the chip split rather than drop the chips
    return TextSpan(style: style, children: withComposing && value.isComposingRangeValid ? _underlined(spans, value.composing) : spans);
  }
}

/// [spans] (all plain `TextSpan`s) cut at [r]'s ends, the part inside [r] underlined.
List<InlineSpan> _underlined(List<InlineSpan> spans, TextRange r) {
  final out = <InlineSpan>[];
  var at = 0;
  for (final s in spans.cast<TextSpan>()) {
    final a = at, b = at += s.text!.length;
    final cuts = {a, r.start.clamp(a, b), r.end.clamp(a, b), b}.toList()..sort();
    for (var i = 0; i + 1 < cuts.length; i++) {
      final inside = cuts[i] >= r.start && cuts[i + 1] <= r.end;
      out.add(TextSpan(
          text: s.text!.substring(cuts[i] - a, cuts[i + 1] - a),
          style: inside ? (s.style ?? const TextStyle()).copyWith(decoration: TextDecoration.underline) : s.style));
    }
  }
  return out;
}

/// The Elis chat's composer: `@` completion, tag chips and the provider chip over the session chat's field.
class ElisComposer extends StatefulWidget {
  const ElisComposer({super.key, required this.model});
  final ElisModel model;

  @override
  State<ElisComposer> createState() => _ElisComposerState();
}

class _ElisComposerState extends State<ElisComposer> {
  late final _field = _TagController((t) => tagTint(widget.model, t));
  final _focus = FocusNode();
  final _portal = OverlayPortalController(), _link = LayerLink(), _box = GlobalKey();
  bool _sending = false, _picking = false;

  @override
  void initState() {
    super.initState();
    _portal.show(); // the popup's own builder is empty without a match
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _field.text.trim();
    setState(() => _sending = true);
    final error = await widget.model.askAssistant(text);
    if (error == null) unawaited(widget.model.readAssistant()); // the user's own bubble shows before the next event
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (error == null && _field.text.trim() == text) _field.clear();
    });
    if (error != null) showNotice(context, error);
  }

  void _insert(String tag) {
    final v = _field.value;
    final caret = v.selection.baseOffset;
    final query = tagQuery(v.text, caret);
    if (query == null) return;
    final start = caret - query.length - 1;
    final text = v.text.replaceRange(start, caret, '$tag ');
    _field.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start + tag.length + 1));
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([_field, _focus, widget.model]),
        builder: (context, _) {
          final v = _field.value;
          // unfocused, as in a closing sheet, the field has no popup
          final query = _focus.hasFocus && v.selection.isCollapsed ? tagQuery(v.text, v.selection.baseOffset) : null;
          final tags = query == null ? const <TagCandidate>[] : tagCandidates(query, widget.model.workspaces);
          final a = widget.model.assistant;
          final offline = widget.model.state != LinkState.connected;
          return OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (_) => _popup(tags),
            child: CompositedTransformTarget(
              key: _box,
              link: _link,
              child: Composer(
                controller: _field,
                focus: _focus,
                onSend: v.text.trim().isEmpty || _sending || offline ? null : _send,
                reason: offline ? 'Not connected' : null,
                maxLines: 6,
                autocorrect: true,
                mono: false,
                hint: 'Message Elis… @ to tag',
                fill: C.bg,
                accessory: a == null || a.providers.isEmpty ? null : _provider(a),
              ),
            ),
          );
        },
      );

  // the menu opens above the chip, which stays in view with its chevron turned up
  Future<void> _pick(BuildContext chip, AssistantState a) async {
    final box = chip.findRenderObject()! as RenderBox, overlay = Overlay.of(chip).context.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset.zero, ancestor: overlay);
    const pad = 8.0, header = 32.0, row = 48.0, gap = 8.0;
    final height = 2 * pad + header + row * a.providers.length;
    setState(() => _picking = true);
    final name = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy - gap - height, overlay.size.width - at.dx - box.size.width, overlay.size.height - at.dy + gap),
      menuPadding: const EdgeInsets.symmetric(vertical: pad),
      items: [
        const PopupMenuItem(enabled: false, height: header, child: Text('FOUND ON THIS SYSTEM', style: sectionLabel)),
        for (final name in a.providers)
          PopupMenuItem(
            value: name,
            height: row,
            child: Row(children: [
              AgentLogo(name, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(agentNames[name] ?? name, style: const TextStyle(fontSize: 15))),
              if (name == a.provider) const Icon(Icons.check, size: 20, color: C.accent),
            ]),
          ),
      ],
    );
    if (!mounted) return;
    setState(() => _picking = false);
    if (name != null && name != widget.model.assistant?.provider) unawaited(reportOf(context, widget.model.setProvider(name)));
  }

  Widget _provider(AssistantState a) {
    final p = a.provider;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Builder(
          builder: (chip) => ActionChip(
            key: const Key('provider-chip'),
            avatar: p == null ? null : AgentLogo(p, size: 16),
            label: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(p == null ? 'Provider' : agentNames[p] ?? p, style: const TextStyle(fontSize: 12)),
              Icon(_picking ? Icons.expand_less : Icons.expand_more, size: 16, color: C.muted),
            ]),
            visualDensity: VisualDensity.compact,
            onPressed: () => _pick(chip, a),
          ),
        ),
      ]),
    );
  }

  // laid out after the composer, as the session chat's slash menu is
  Widget _popup(List<TagCandidate> tags) => tags.isEmpty
      ? const SizedBox.shrink()
      : LayoutBuilder(builder: (context, _) {
          final box = _box.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return const SizedBox.shrink();
          // the popup stays inside the sheet's column, under the drag handle
          final sheet = _box.currentContext?.findAncestorRenderObjectOfType<RenderFlex>();
          final top = sheet == null ? MediaQuery.paddingOf(context).top + kToolbarHeight : sheet.localToGlobal(Offset.zero).dy;
          final room = box.localToGlobal(Offset.zero).dy - top - 8;
          final width = box.size.width - 24; // the field and send button, inside the composer's padding
          return Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              offset: const Offset(12, 6), // 4 px above the composer's first row, under its 10 px top padding
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: width, maxWidth: width, maxHeight: max(0, min(220, room))),
                child: Material(
                  color: _popupFill,
                  elevation: 6,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: C.text.withValues(alpha: .2))),
                  child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [for (final c in tags) _row(c)]),
                ),
              ),
            ),
          );
        });

  Widget _row(TagCandidate c) => InkWell(
        key: Key('tag-${c.tag}'),
        onTap: () => _insert(c.tag),
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              SizedBox(
                width: 18,
                child: Center(
                  child: switch (c.icon) {
                    'all' => const Lucide(_lucideLayoutDashboard),
                    'workspace' => Lucide(lucideSquareStack, color: tintColor(c.tint) ?? C.muted),
                    _ => AgentLogo(c.icon),
                  },
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 112),
                child: Text(c.tag, style: const TextStyle(fontFamily: mono, fontSize: 14)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(c.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: C.muted))),
              if (c.status == 'blocked' || c.status == 'active') ...[const SizedBox(width: 8), StatusShape(c.status!)],
            ]),
          ),
        ),
      );
}
