import '../model.dart';

/// One `@` completion row for the assistant composer.
class TagCandidate {
  const TagCandidate({
    required this.tag,
    required this.label,
    required this.icon,
    required this.tint,
    this.status,
  });

  final String tag; // includes the leading `@`
  final String label;
  final String icon; // all | workspace | an agent id | terminal
  final String tint;
  final String? status;
}

/// Tags whose text after `@` starts with [query] (case-insensitive), in sidebar order.
List<TagCandidate> tagCandidates(String query, List<Workspace> workspaces) {
  final q = query.toLowerCase();
  final all = [
    const TagCandidate(tag: '@all', label: 'every agent session', icon: 'all', tint: ''),
    for (final w in workspaces)
      if (w.handle.isNotEmpty)
        TagCandidate(tag: '@ws:${w.handle}', label: w.name, icon: 'workspace', tint: w.tint),
    for (final w in workspaces)
      for (final s in w.sessions)
        if (s.handle.isNotEmpty)
          TagCandidate(
            tag: '@${s.handle}',
            label: s.name,
            icon: s.agent.isNotEmpty ? s.agent : 'terminal',
            tint: w.tint,
            status: s.status,
          ),
  ];
  return [for (final c in all) if (c.tag.substring(1).toLowerCase().startsWith(q)) c];
}

/// The word ending at [caret] when it starts with `@`, without the `@`; null otherwise.
String? tagQuery(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final word = text.substring(0, caret).split(RegExp(r'\s')).last;
  return word.startsWith('@') ? word.substring(1) : null;
}
