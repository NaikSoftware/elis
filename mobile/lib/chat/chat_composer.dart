import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../link/mux.dart' show UploadChannel, UploadFailed;
import '../screens/composer.dart';
import '../terminal/vt.dart';
import '../theme.dart';
import 'attachments.dart';
import 'checks.dart';
import 'claude_screen.dart';
import 'feed.dart';
import 'grid.dart';
import 'transcript.dart';
import 'write_gate.dart';

const _checks = checks; // the field below shadows the constant in its own default
const _instant = {'model', 'effort', 'fast', 'status', 'tasks', 'usage'}; // run at once, never queued

/// [all] matching [typed] (with or without its `/`): prefix matches first, then substring ones, ignoring case.
List<SlashCommand> slashMatches(List<SlashCommand> all, String typed) {
  final t = (typed.startsWith('/') ? typed.substring(1) : typed).toLowerCase();
  bool prefix(SlashCommand c) => c.name.toLowerCase().startsWith(t);
  return [...all.where(prefix), ...all.where((c) => !prefix(c) && c.name.toLowerCase().contains(t))];
}

/// Claude's draft shows [text]: its first 40 characters, whitespace ignored, or a paste placeholder.
bool pasteShown(ClaudeScreen s, String text) {
  final k = norm(text);
  return s.pastePlaceholder || norm(s.draft).contains(k.substring(0, min(40, k.length)));
}

// the input block's rows as drawn: a Ctrl+U that only removes a newline changes no trimmed text
String _inputRows(Grid g) => switch (ClaudeScreen.read(g).inputRows) {
      (final a, final b) => [for (var r = a; r < b; r++) g.text(r)].join('\n'),
      null => '',
    };

/// Chat's composer: adopts Claude's draft, sends through [gate], and offers the "/" menu.
class ChatComposer extends StatefulWidget {
  const ChatComposer(
      {super.key,
      required this.feed,
      required this.screen,
      required this.colours,
      required this.remote,
      this.server = false,
      required this.gate,
      this.disabledBy,
      this.held,
      this.onOpen,
      this.onSending,
      this.agent = 'Claude',
      this.checks = _checks,
      this.pick,
      this.upload,
      this.attachBlocked,
      this.session});

  final TranscriptFeed feed;
  final ClaudeScreen? Function() screen;
  final bool colours; // a Live pane's grid: dim text tells a placeholder from a draft
  final bool remote, server;
  final WriteGate gate;
  final String? disabledBy;
  final String? held; // a prompt or panel owns Claude's input: the composer is disabled with this line
  final VoidCallback? onOpen; // shows the hidden panel again
  final VoidCallback? onSending; // a send the gate takes
  final String agent; // named in the composer's messages
  final Checks checks;
  final PickFiles? pick; // null: the system picker
  final UploadFile? upload; // null disables attaching
  final String? attachBlocked; // disables attaching, and is the button's tooltip
  final String? session; // keys [AttachBlocks]

  @override
  State<ChatComposer> createState() => ChatComposerState();
}

class ChatComposerState extends State<ChatComposer> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _menuPortal = OverlayPortalController(), _menuLink = LayerLink(), _box = GlobalKey();
  String? _adopted; // the draft taken from Claude's row, which Send clears there first
  bool _seen = false, _sending = false, _running = false, _stopRun = false, _readopt = false;
  String? _offer, _offerDraft; // the text a changed row stopped, and that row
  final _chips = <_Attachment>[];
  bool _picking = false, _uploading = false;

  String get _changed => "${widget.agent}'s input changed on the computer";

  @override
  void initState() {
    super.initState();
    widget.gate.addListener(_onGate);
    _menuPortal.show(); // the menu's own builder is empty without a match
    _adopt();
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gate != widget.gate) {
      oldWidget.gate.removeListener(_onGate);
      widget.gate.addListener(_onGate);
    }
    _adopt();
    if (_offer != null && (widget.disabledBy != null || norm(widget.screen()?.draft ?? '') != _offerDraft)) _offer = null;
  }

  @override
  void dispose() {
    for (final a in _chips) {
      a.channel?.cancel();
    }
    dropPicked([for (final a in _chips) a.file]);
    widget.gate.removeListener(_onGate);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  // another run started while Claude works is a Stop or Cancel: an Esc before any output puts the prompt back (check 13)
  void _onGate() {
    final running = widget.gate.running;
    if (running == _running) return;
    _running = running;
    if (running) {
      _stopRun = !_sending && (widget.screen()?.busy ?? false);
    } else if (_stopRun) {
      _stopRun = false;
      _readopt = true;
      _adopt();
    }
  }

  void _adopt() {
    final s = widget.colours ? widget.screen() : null;
    if (s == null || !s.bottomStack) return;
    final now = !_seen || (_readopt && !s.busy);
    _seen = true;
    if (!now) return;
    _readopt = false;
    if (_field.text.isNotEmpty || s.pastePlaceholder || s.draft.isEmpty) return;
    _field.text = _adopted = s.draft;
  }

  /// Puts [text] in the field, the cursor at its end.
  void insert(String text) {
    _field.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  String? _blocked(ClaudeScreen? s) =>
      widget.disabledBy ??
      widget.checks.writeBlockedOn(remote: widget.remote, server: widget.server) ??
      (s != null && s.dialog
          ? '${widget.agent} shows a dialog'
          : s == null || !s.bottomStack
              ? "Waiting for ${widget.agent}'s screen"
              // a polled colourless grid can miss a dialog raised since: its typed digit or Enter would answer it
              : !widget.colours && s.busy
                  ? '${widget.agent} is working: this pane sends only while ${widget.agent} is idle'
                  : null);

  /// Sends [text] to Claude through the gate; the field clears when it held [text]. The chips stay: only
  /// [sendField] sends them.
  Future<void> send(String text, {bool replace = false}) => _send(text, replace: replace);

  // [chips], uploaded, are named in the line and clear with it
  Future<void> _send(String text, {bool replace = false, List<_Attachment> chips = const []}) async {
    text = text.trimRight();
    final paths = [for (final a in chips) a.hostPath!];
    // an image inside a command, a `!` shell line or a `#` memory entry would split it
    final split = widget.screen()?.agy != true && !RegExp(r'^\s*[/!#]').hasMatch(text);
    final images = split ? paths.where(isPicture).toList() : const <String>[];
    final line = attachedLine(text, [for (final p in paths) if (!images.contains(p)) p]);
    if (line.isEmpty && images.isEmpty) return;
    if (_blocked(widget.screen()) case final why?) return _tell(why);
    widget.onSending?.call();
    setState(() {
      _sending = true;
      _offer = null;
    });
    // the live path types a space between the text and the images as a step of its own
    final steps = (line.isEmpty ? 1 : 2) + (images.isEmpty ? 0 : 1) + (widget.colours && line.isNotEmpty && images.isNotEmpty ? 1 : 0);
    final r = await widget.gate.run(steps, (q) => widget.colours ? _live(q, line, replace, images) : _typed(q, line, images));
    if (!mounted) return;
    final draft = norm(widget.screen()?.draft ?? '');
    final offer = r.reason == _changed && draft.isNotEmpty;
    setState(() {
      _sending = false;
      if (r.ok && _field.text.trimRight() == text) _field.clear();
      if (r.ok && chips.isNotEmpty) {
        _chips.removeWhere(chips.contains);
        dropPicked([for (final a in chips) a.file]);
      }
      if (offer) {
        _offer = text;
        _offerDraft = draft;
      }
    });
    if (!r.ok && !offer) _tell(r.reason);
  }

  void _tell(String why) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(why)));

  Future<void> _pick() async {
    setState(() => _picking = true);
    var got = const <PickedFile>[];
    try {
      got = await (widget.pick ?? pickFiles)();
    } on Object catch (e) {
      if (mounted) _tell('$e');
    }
    if (!mounted) return;
    final fit = got.where((f) => f.size <= uploadMaxBytes).toList();
    final room = uploadMaxFiles - _chips.length;
    setState(() {
      _picking = false;
      _chips.addAll(fit.take(room).map(_Attachment.new));
    });
    if (fit.length < got.length) {
      _tell(tooLarge);
    } else if (fit.length > room) {
      _tell(tooMany);
    }
  }

  void _remove(_Attachment a) {
    a.channel?.cancel();
    setState(() => _chips.remove(a));
    dropPicked([a.file]);
  }

  /// The field's Send and the offer's Replace: uploads the chips not yet on the host, one at a time, then sends
  /// [text] with their paths. A failure keeps the text and the chips; uploaded chips keep their host path.
  Future<void> sendField(String text, {bool replace = false}) async {
    if (_chips.isEmpty) return send(text, replace: replace);
    if (_uploading || _picking) return; // a pick in progress would add a chip with no host path
    if (_blocked(widget.screen()) case final why?) return _tell(why);
    final upload = widget.upload;
    if (upload == null) return _tell('Disconnected');
    setState(() {
      _uploading = true;
      _offer = null;
    });
    try {
      for (final a in [..._chips]) {
        if (a.hostPath != null || !_chips.contains(a)) continue;
        final ch = a.channel = upload(a.file);
        setState(() => a.sent = 0);
        ch.progress.listen((n) => mounted ? setState(() => a.sent += n) : null);
        unawaited(ch.send(File(a.file.path).openRead()).catchError((Object _) {})); // its failure is [done]'s
        final path = await ch.done;
        if (!mounted) return;
        setState(() {
          a.hostPath = path;
          a.channel = null;
        });
      }
    } on UploadFailed catch (e) {
      if (!mounted) return;
      if (e.tooOld && widget.session != null) AttachBlocks.tooOld[widget.session!] = e.reason;
      if (e.reason != 'cancelled') _tell(e.reason);
      return;
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          for (final a in _chips) {
            a.channel = null;
          }
        });
      }
    }
    if (_blocked(widget.screen()) case final why?) return _tell(why);
    await _send(text, replace: replace, chips: [..._chips]);
  }

  String? get _attachBlocked => widget.attachBlocked ?? AttachBlocks.tooOld[widget.session];

  Widget _tile(_Attachment a) {
    final f = a.file;
    final doc = Container(
      color: C.surface2,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.description_outlined, size: 20, color: C.muted),
        const SizedBox(height: 3),
        Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5)),
        Text(humanSize(f.size), style: const TextStyle(fontSize: 10, color: C.muted)),
      ]),
    );
    return KeyedSubtree(
      key: ObjectKey(a), // two picks can share a name
      // the badge stays inside the Stack's bounds: a Stack takes no hit outside them
      child: Stack(key: Key('tile-${f.name}'), children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, right: 10),
          child: Container(
            width: 64,
            height: 64,
            foregroundDecoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(fit: StackFit.expand, children: [
                if (isPicture(f.name))
                  Image.file(File(f.path), fit: BoxFit.cover, cacheWidth: 192, semanticLabel: f.name, errorBuilder: (_, _, _) => doc)
                else
                  doc,
                if (a.channel != null)
                  Container(
                    color: const Color(0x99000000),
                    alignment: Alignment.center,
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                          value: f.size == 0 ? 0 : min(1, a.sent / f.size), strokeWidth: 2.5, backgroundColor: C.line),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: Semantics(
            button: true,
            label: 'Remove ${f.name}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _remove(a),
              child: SizedBox.square(
                dimension: 28,
                child: Center(
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: C.surface2, shape: BoxShape.circle, border: Border.all(color: C.line)),
                    child: const Icon(Icons.close, size: 12, color: C.text),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _live(GateSequence q, String text, bool replace, List<String> images) async {
    final draft = ClaudeScreen.read(q.grid).draft;
    if (draft.isNotEmpty) {
      if (!replace && norm(draft) != norm(_adopted ?? '')) throw GateStop(GateOutcome.mismatch, _changed);
      await _clear(q);
    }
    final c = widget.checks;
    final bang = !c.pastedBangSwitches && text.length > 1 && (text.startsWith('!') || text.startsWith('#'));
    var shown = text;
    if (!c.pastedCommandRuns && text.startsWith('/')) {
      if (text.contains('\n')) throw const GateStop(GateOutcome.mismatch, 'A command is one line');
      await q.send(_write(TextWrite(text), text));
    } else if (bang) {
      q.addSteps(1);
      String? before;
      await q.send(GateStep(TextWrite(text[0]), ready: (g) {
        before = _inputRows(g);
        return _empty(ClaudeScreen.read(g));
      }, done: (g) => _inputRows(g) != before));
      shown = text.substring(1);
      await q.send(GateStep(PasteWrite(shown), ready: (g) => ClaudeScreen.read(g).bottomStack, done: (g) => pasteShown(ClaudeScreen.read(g), shown)));
    } else if (text.isNotEmpty) {
      await q.send(_write(PasteWrite(text), text));
    }
    if (images.isNotEmpty) {
      // its own key, not in the paste: a paste holding more than quoted paths stays text
      if (text.isNotEmpty) {
        // the draft reads trimmed, so the space shows no change: any repaint after it will do
        await q.send(GateStep(TextWrite(' '), ready: (g) => ClaudeScreen.read(g).bottomStack, done: (_) => true));
      }
      await _imageStep(q, PasteWrite(imagePaste(images)), images.length, (g) => ClaudeScreen.read(g).draft,
          (g) => ClaudeScreen.read(g).bottomStack);
    }
    bool human(ChatItem i) => i.kind == 'user' && i.isHumanPrompt;
    final humans = widget.feed.items.where(human).length;
    await q.send(GateStep(KeyWrite(VtKey.enter), ready: (g) {
      final s = ClaudeScreen.read(g);
      return s.bottomStack && pasteShown(s, shown);
    }, done: (g) {
      final s = ClaudeScreen.read(g);
      // a panel command leaves the bottom stack
      return s.dialog || s.busy || (s.bottomStack && s.draft.isEmpty && !s.pastePlaceholder) || widget.feed.items.where(human).length > humans;
    }));
    _adopted = null;
  }

  /// Writes [w] and waits until [read] shows [n] more `[Image #`: the text can hold some itself, and a wrap can split one.
  Future<void> _imageStep(GateSequence q, GateWrite w, int n, String Function(Grid g) read, bool Function(Grid g) ready) async {
    int count(Grid g) => '[Image#'.allMatches(norm(read(g))).length;
    var before = 0;
    try {
      await q.send(GateStep(w, ready: (g) {
        before = count(g);
        return ready(g);
      }, done: (g) => count(g) - before >= n));
    } on GateStop catch (e) {
      if (e.outcome != GateOutcome.timeout) rethrow;
      throw GateStop(e.outcome, '${widget.agent} did not attach the image');
    }
  }

  static bool _empty(ClaudeScreen s) => s.bottomStack && s.draft.isEmpty && !s.pastePlaceholder;

  GateStep _write(GateWrite w, String text) =>
      GateStep(w, ready: (g) => _empty(ClaudeScreen.read(g)), done: (g) => pasteShown(ClaudeScreen.read(g), text));

  // check 5: one press per visual row plus one per newline, so it repeats until the row reads empty
  Future<void> _clear(GateSequence q) async {
    final key = widget.checks.clearInput;
    if (key == null) throw GateStop(GateOutcome.mismatch, "${widget.agent}'s input is not empty");
    for (var n = 0; ClaudeScreen.read(q.grid).draft.isNotEmpty; n++) {
      if (n == 40) throw GateStop(GateOutcome.mismatch, "${widget.agent}'s input did not clear");
      q.addSteps(1);
      String? before;
      await q.send(GateStep(KeyWrite(key.$1, key.$2), ready: (g) {
        before = _inputRows(g);
        final s = ClaudeScreen.read(g);
        return s.bottomStack && s.draft.isNotEmpty;
      }, done: (g) => _inputRows(g) != before));
    }
    _adopted = null;
  }

  // a `session.text` grid has no SGR: a placeholder reads as text, so no draft check and no clear
  Future<void> _typed(GateSequence q, String text, List<String> images) async {
    String? before;
    String all(Grid g) => [for (var r = 0; r < g.rows.length; r++) g.text(r)].join('\n');
    bool ready(Grid g) {
      before = all(g);
      return ClaudeScreen.read(g).bottomStack;
    }

    if (text.isNotEmpty) await q.send(GateStep(PasteWrite(text), ready: ready, done: (g) => all(g) != before));
    // Claude Code always enables bracketed paste, and `session.type` sends the text as is; the space after the text is a
    // key outside the paste, in this write because a polled grid shows no change for it
    if (images.isNotEmpty) {
      final space = text.isEmpty ? '' : ' ';
      await _imageStep(q, TextWrite('$space\x1b[200~${imagePaste(images)}\x1b[201~'), images.length, all, ready);
    }
    await q.send(GateStep(KeyWrite(VtKey.enter), ready: ready, done: (g) => all(g) != before));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([_field, widget.gate, widget.feed]),
        builder: (context, _) {
          final s = widget.screen();
          final text = _field.text;
          final blocked = _blocked(s);
          final command = RegExp(r'^/(\S+)').firstMatch(text.trim())?.group(1);
          final queue = (s?.busy ?? false) && !_instant.contains(command);
          final menu = text.startsWith('/') && !text.contains(RegExp(r'\s')) ? slashMatches(widget.feed.commands, text) : const <SlashCommand>[];
          final held = widget.held;
          final some = text.trim().isNotEmpty || _chips.isNotEmpty;
          final reason = _uploading
              ? 'Uploading ${_chips.indexWhere((a) => a.channel != null) + 1}/${_chips.length}'
              : _sending && widget.gate.running
                  ? widget.gate.progress
                  : some && _offer == null && held == null
                      ? blocked
                      : null;
          final canSend = some && blocked == null && !widget.gate.running && !_uploading && !_picking;
          // the menu floats above the composer, over the list, so the bottom area's scroll never clips its first rows
          return OverlayPortal(
            controller: _menuPortal,
            overlayChildBuilder: (_) => _menu(menu),
            child: CompositedTransformTarget(
              key: _box,
              link: _menuLink,
              child: Composer(
                  controller: _field,
                  focus: _focus,
                  onSend: canSend ? () => sendField(_field.text) : null,
                  maxLines: 6,
                  autocorrect: true,
                  mono: false,
                  sendLabel: queue ? 'Queue' : 'Send',
                  sendIcon: queue ? Icons.schedule : Icons.arrow_forward,
                  reason: reason,
                  enabled: held == null && !_uploading,
                  prefix: ComposerMenu(
                      screen: s,
                      meta: widget.feed.meta,
                      gate: widget.gate,
                      remote: widget.remote,
                      server: widget.server,
                      disabledBy: widget.disabledBy,
                      checks: widget.checks,
                      onAttach: held != null ||
                              blocked != null ||
                              _picking ||
                              _uploading ||
                              widget.gate.running ||
                              widget.upload == null ||
                              _attachBlocked != null
                          ? null
                          : _pick,
                      attachWhy: _attachBlocked ?? blocked),
                  accessory: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_chips.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(children: [for (final a in _chips) _tile(a)]),
                      ),
                    if (_offer != null) _offerRow(),
                    if (held != null)
                      Row(key: const Key('composerHeld'), children: [
                        Flexible(child: Text(held, style: const TextStyle(fontSize: 12, color: C.muted))),
                        if (widget.onOpen != null) ...[
                          const Text(' · ', style: TextStyle(fontSize: 12, color: C.muted)),
                          TextButton(key: const Key('panelOpen'), onPressed: widget.onOpen, child: const Text('Open')),
                        ],
                      ]),
                  ]),
                ),
              ),
          );
        },
      );

  Widget _offerRow() => Row(children: [
        Expanded(child: Text(_changed, style: const TextStyle(fontSize: 12, color: C.muted))),
        TextButton(onPressed: () => sendField(_offer!, replace: true), child: const Text('Replace')),
        TextButton(onPressed: () => setState(() => _offer = null), child: const Text('Keep')),
      ]);

  // laid out after the composer: a build-time read misses a reason line the same frame adds
  Widget _menu(List<SlashCommand> commands) => commands.isEmpty
      ? const SizedBox.shrink()
      : LayoutBuilder(builder: (context, _) {
          final box = _box.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return const SizedBox.shrink();
          // below the app bar, its subtitle line included
          final bar = Scaffold.maybeOf(context)?.appBarMaxHeight ?? MediaQuery.paddingOf(context).top + kToolbarHeight;
          final room = box.localToGlobal(Offset.zero).dy - bar - 8;
          return Align(
            alignment: Alignment.topLeft,
            child: CompositedTransformFollower(
              link: _menuLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.size.width, minWidth: box.size.width, maxHeight: max(0, min(220, room))),
                child: Material(
                  color: C.surface,
                  elevation: 6,
                  child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                    for (final c in commands)
                      ListTile(
                        key: Key('slash-${c.name}'),
                        dense: true,
                        title: Text('/${c.name}', style: const TextStyle(fontFamily: mono)),
                        subtitle: c.description.isEmpty ? null : Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: c.panel ? const Text('opens in panel', style: TextStyle(fontSize: 12, color: C.muted)) : null,
                        onTap: () => insert('/${c.name} '),
                      ),
                  ]),
                ),
              ),
            ),
          );
        });
}

// Claude's own mode-line wording: the picker shows it verbatim (card rule 10)
const _modeLabels = {
  ClaudeMode.manual: 'manual mode on',
  ClaudeMode.acceptEdits: 'accept edits on',
  ClaudeMode.plan: 'plan mode on',
  ClaudeMode.auto: 'auto mode on',
  ClaudeMode.bypass: 'bypass permissions on',
};
const _modeNames = {
  ClaudeMode.manual: 'manual',
  ClaudeMode.acceptEdits: 'accept edits',
  ClaudeMode.plan: 'plan',
  ClaudeMode.auto: 'auto',
  ClaudeMode.bypass: 'bypass',
};

/// The composer's `+` menu: Attach files, then Claude's modes (Shift+Tab through [gate] until Claude shows the picked one)
/// and its shell count. agy's modes differ: its menu holds Attach alone.
class ComposerMenu extends StatefulWidget {
  const ComposerMenu(
      {super.key,
      required this.screen,
      required this.meta,
      required this.gate,
      required this.remote,
      this.server = false,
      this.disabledBy,
      this.checks = _checks,
      this.onAttach,
      this.attachWhy});

  final ClaudeScreen? screen;
  final TranscriptMeta? meta;
  final WriteGate gate;
  final bool remote, server;
  final String? disabledBy;
  final Checks checks;
  final VoidCallback? onAttach; // null disables the Attach row
  final String? attachWhy; // shown under a disabled Attach row

  @override
  State<ComposerMenu> createState() => ComposerMenuState();
}

class ComposerMenuState extends State<ComposerMenu> {
  bool _bypassSeen = false;

  List<ClaudeMode> get _cycle =>
      [ClaudeMode.manual, ClaudeMode.acceptEdits, ClaudeMode.plan, ClaudeMode.auto, if (_bypassSeen) ClaudeMode.bypass];

  /// One Shift+Tab per step until Claude shows [target]; stops when the start mode returns, after at most 5 steps.
  Future<GateResult> cycleTo(ClaudeMode target) {
    final cycle = _cycle;
    final start = widget.screen?.mode;
    var total = start == null || !cycle.contains(target) ? 1 : (cycle.indexOf(target) - cycle.indexOf(start)) % cycle.length;
    total = max(1, total);
    return widget.gate.run(total, (q) async {
      final from = ClaudeScreen.read(q.grid).mode;
      try {
        await _steps(q, target, from, total);
      } on GateStop catch (e) {
        // a stop on the way can leave a mode that auto-approves calls: name it
        final now = ClaudeScreen.read(q.grid).mode;
        if (now == null || now == from) rethrow;
        throw GateStop(e.outcome, '${e.reason}. Claude is now in ${_modeNames[now]} mode');
      }
    });
  }

  Future<void> _steps(GateSequence q, ClaudeMode target, ClaudeMode? from, int total) async {
    var mode = from;
    for (var n = 0; mode != target; n++) {
      if (n == 5 || (n > 0 && mode == from)) throw GateStop(GateOutcome.mismatch, 'Claude did not reach ${_modeLabels[target]}');
      if (n >= total) {
        total++;
        q.addSteps(1);
      }
      final expected = mode;
      await q.send(GateStep(KeyWrite(VtKey.tab, vtShift), ready: (g) {
        final s = ClaudeScreen.read(g);
        return s.idle && s.mode != null && s.mode == expected;
      }, done: (g) => switch (ClaudeScreen.read(g).mode) { final m? => m != expected, null => false }));
      unawaited(HapticFeedback.selectionClick());
      mode = ClaudeScreen.read(q.grid).mode;
    }
  }

  /// The modes Shift+Tab shows on the way from [from] to [to] (spec: the picker names them).
  List<ClaudeMode> _passed(ClaudeMode? from, ClaudeMode to) {
    final c = _cycle;
    if (from == null || !c.contains(from) || from == to) return const [];
    return [for (var i = (c.indexOf(from) + 1) % c.length; c[i] != to; i = (i + 1) % c.length) c[i]];
  }

  Future<void> _pick({required bool agy, required bool modes}) async {
    final current = widget.screen?.mode;
    final shells = widget.screen?.shells ?? 0;
    final attach = widget.onAttach;
    final target = await showModalBottomSheet<ClaudeMode>(
        context: context,
        isScrollControlled: true, // the default 9/16 cap cuts the last modes on a short screen
        builder: (context) {
          ClaudeMode? armed;
          return StatefulBuilder(
              builder: (context, setSheet) => SafeArea(
                    child: SingleChildScrollView(
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      ListTile(
                        key: const Key('attach'),
                        leading: const Icon(Icons.attach_file, color: C.muted),
                        title: const Text('Attach files'),
                        subtitle: attach == null ? switch (widget.attachWhy) { final w? => Text(w), null => null } : null,
                        enabled: attach != null,
                        minTileHeight: 52,
                        onTap: () {
                          Navigator.pop(context);
                          attach!();
                        },
                      ),
                      if (!agy) ...[
                        const Divider(),
                        const Padding(padding: EdgeInsets.fromLTRB(20, 14, 20, 4), child: Text('PERMISSION MODE', style: sectionLabel)),
                      ],
                      for (final m in agy ? const <ClaudeMode>[] : _cycle)
                        ListTile(
                          key: Key('mode-${m.name}'),
                          enabled: modes,
                          title: Text(_modeLabels[m]!),
                          subtitle: armed == m
                              ? const Text('Tap again to switch')
                              : switch (_passed(current, m)) {
                                  final p when p.isNotEmpty => Text('Passes ${p.map((x) => _modeNames[x]).join(', ')}'),
                                  _ => null,
                                },
                          trailing: m == current ? const Icon(Icons.check) : null,
                          selected: armed == m,
                          onTap: () {
                            if (m == current) return Navigator.pop(context);
                            // a mode that auto-approves calls needs a second tap
                            if ((m == ClaudeMode.auto || m == ClaudeMode.bypass) && armed != m) return setSheet(() => armed = m);
                            Navigator.pop(context, m);
                          },
                        ),
                      if (!agy && shells > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                          child: Text('$shells shell${shells == 1 ? '' : 's'}',
                              key: const Key('shell-badge'), style: const TextStyle(fontSize: 12, color: C.muted)),
                        ),
                    ])),
                  ));
        });
    if (target == null || !mounted) return;
    final r = await cycleTo(target);
    if (!r.ok && mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(r.reason)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.screen;
    if (s?.mode == ClaudeMode.bypass || widget.meta?.permissionMode == 'bypassPermissions') _bypassSeen = true;
    final agy = s?.agy == true;
    final modes = !agy &&
        s != null &&
        s.idle &&
        s.mode != null &&
        widget.disabledBy == null &&
        widget.checks.writeBlockedOn(remote: widget.remote, server: widget.server) == null &&
        !widget.gate.running;
    final on = modes || widget.onAttach != null;
    final label = agy ? 'Attach files' : 'Attach files, permission mode';
    return IconButton(
      key: const Key('composerMenu'),
      icon: const Icon(Icons.add),
      // the field's decorator gives its prefix one colour for both states
      color: C.muted,
      disabledColor: C.muted.withValues(alpha: .38),
      tooltip: on ? label : widget.attachWhy ?? label,
      onPressed: on ? () => _pick(agy: agy, modes: modes) : null,
    );
  }
}

class _Attachment {
  _Attachment(this.file);
  final PickedFile file;
  String? hostPath; // kept across a failed send, so a re-send uploads only the rest
  UploadChannel? channel; // while uploading
  int sent = 0; // credited bytes
}
