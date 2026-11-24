import 'package:elis_mobile/assistant/tags.dart';
import 'package:elis_mobile/model.dart';
import 'package:flutter_test/flutter_test.dart';

Session session(String id, String handle, {String agent = '', String status = 'idle'}) =>
    Session({'id': id, 'handle': handle, 'name': 'Name $id', 'agent': agent, 'status': status}, 'w', 'W');

Workspace workspace(String handle, List<Session> sessions, {String tint = '#abc'}) => Workspace({
      'id': 'w-$handle',
      'handle': handle,
      'name': 'WS $handle',
      'tint': tint,
      'sessions': [
        for (final s in sessions)
          {'id': s.id, 'handle': s.handle, 'name': s.name, 'agent': s.agent, 'status': s.status},
      ],
    });

final workspaces = [
  workspace('elis', [session('s1', 'side-filter', agent: 'claude', status: 'blocked'), session('s2', '')]),
  workspace('', [session('s3', 'zeta', agent: 'codex')]),
  workspace('other', [session('s4', 'alpha')]),
];

void main() {
  test('empty query lists all, then workspaces, then sessions', () {
    final tags = tagCandidates('', workspaces).map((c) => c.tag).toList();
    expect(tags, ['@all', '@ws:elis', '@ws:other', '@side-filter', '@zeta', '@alpha']);
  });

  test('prefix filters case-insensitively', () {
    expect(tagCandidates('SIDE', workspaces).map((c) => c.tag), ['@side-filter']);
  });

  test('sessions without handle are skipped', () {
    expect(tagCandidates('', workspaces).where((c) => c.label == 'Name s2'), isEmpty);
  });

  test('a blocked session keeps its status and workspace tint', () {
    final c = tagCandidates('side', workspaces).single;
    expect((c.icon, c.status, c.tint), ('claude', 'blocked', '#abc'));
  });

  test('tagQuery finds the word at the caret', () {
    expect(tagQuery('ask @si', 7), 'si');
    expect(tagQuery('mail a@b', 8), isNull);
  });

  test('tagQuery is empty right after a bare at sign', () {
    expect(tagQuery('ask @', 5), '');
  });

  test('a colon in the query filters to the workspace tag', () {
    expect(tagCandidates('ws:el', workspaces).map((c) => c.tag), ['@ws:elis']);
  });
}
