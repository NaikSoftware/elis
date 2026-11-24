/// One transcript line; `kind` is user | assistant | sent | reply | error.
class AssistantEntry {
  AssistantEntry.fromJson(Map m)
      : id = m['id'] ?? '',
        kind = m['kind'] ?? '',
        text = m['text'] ?? '',
        from = m['from'],
        to = (m['to'] as List?)?.cast<String>() ?? const [],
        ts = (m['ts'] as num?)?.toDouble() ?? 0;

  final String id, kind, text;
  final String? from;
  final List<String> to;
  final double ts; // seconds
}

class AssistantState {
  AssistantState.fromJson(Map m)
      : provider = m['provider'],
        providers = (m['providers'] as List?)?.cast<String>() ?? const [],
        running = m['running'] == true,
        unread = (m['unread'] as num?)?.toInt() ?? 0;

  final String? provider;
  final List<String> providers;
  final bool running;
  final int unread;
}
