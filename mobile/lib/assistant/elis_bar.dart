import 'package:flutter/material.dart';

import '../model.dart';
import '../theme.dart';
import 'elis_sheet.dart';

const _curve = Cubic(.2, 0, 0, 1);
const _gap = 12.0, _row = 52.0, _newWidth = 164.0, _sheetTop = 72.0;

/// The Sessions screen's bottom row over [child]: Ask Elis, which grows into the Elis chat, beside New session.
class ElisBar extends StatefulWidget {
  const ElisBar({super.key, required this.model, required this.onNewSession, required this.openSession, required this.child});
  final ElisModel model;
  final VoidCallback? onNewSession; // null hides New session
  final void Function(Session) openSession;
  final Widget child; // the list: faded above the row, and inert while the sheet is open

  @override
  State<ElisBar> createState() => _ElisBarState();
}

class _ElisBarState extends State<ElisBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final CurvedAnimation _t;
  bool _open = false, _front = true;
  double _drag = 0;

  ElisModel get m => widget.model;
  // a dropped link keeps an open sheet and its draft; only a loaded tree without the assistant closes it
  bool get _canAsk => (m.assistant != null && m.state == LinkState.connected) || _open || !_c.isDismissed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
    _t = CurvedAnimation(parent: _c, curve: _curve, reverseCurve: _curve.flipped);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _front = ModalRoute.isCurrentOf(context) ?? true;
    _look();
  }

  // the sheet is looked at only while open with no route (a session, a menu) over Home
  void _look() {
    final look = _open && _front;
    if (look == m.assistantOpen) return;
    m.assistantOpen = look;
    if (look) m.rereadAssistant();
  }

  @override
  void didUpdateWidget(ElisBar old) {
    super.didUpdateWidget(old);
    if (m.state == LinkState.connected && m.loaded && m.assistant == null) _close(animate: false);
  }

  @override
  void dispose() {
    if (_open) m.assistantOpen = false;
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  void _to(double v, {bool animate = true}) {
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
      _c.value = v;
    } else {
      v == 1 ? _c.forward() : _c.reverse();
    }
  }

  void _show() {
    setState(() => _open = true);
    _to(1);
    _look();
  }

  void _close({bool animate = true}) {
    if (!_open && _c.isDismissed) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _open = false;
    _look();
    _to(0, animate: animate);
    if (mounted) setState(() {});
  }

  void _jump(Session s) {
    _close(animate: false);
    widget.openSession(s);
  }

  @override
  Widget build(BuildContext context) {
    final onNew = widget.onNewSession;
    final pad = MediaQuery.paddingOf(context);
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) => didPop ? null : _close(),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight, bottom = h - _gap - pad.bottom;
        final slot = Rect.fromLTRB(_gap, bottom - _row, onNew == null ? w - _gap : w - _gap - _newWidth - 8, bottom);
        final sheet = Rect.fromLTRB(0, pad.top + _sheetTop, w, h);
        final content = _content(pad.bottom);
        // always masked, never rewrapped, so the list keeps its scroll state when the row comes and goes
        final list = ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => _canAsk || onNew != null
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: const [Colors.black, Colors.black, Colors.transparent],
                  stops: [0, ((slot.top - 24) / h).clamp(0, 1), (slot.top / h).clamp(0, 1)],
                ).createShader(r)
              : const LinearGradient(colors: [Colors.black, Colors.black]).createShader(r),
          child: widget.child,
        );
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final v = _c.value, t = _t.value;
            // keyed: the surface holds the draft and must not be rebuilt when a sibling comes or goes
            return Stack(children: [
              Positioned.fill(key: const ValueKey('list'), child: ExcludeFocus(excluding: _open, child: list)),
              if (v > 0)
                Positioned.fill(
                  key: const ValueKey('scrim'),
                  child: BlockSemantics(
                    child: Semantics(
                      label: 'Close Elis',
                      child: GestureDetector(
                        onTap: _close,
                        child: ColoredBox(color: Colors.black.withValues(alpha: .54 * Curves.ease.transform((v / .79).clamp(0, 1)))),
                      ),
                    ),
                  ),
                ),
              if (onNew != null)
                Positioned(
                  key: const ValueKey('new'),
                  right: _gap,
                  bottom: _gap + pad.bottom,
                  width: _canAsk ? _newWidth : w - 2 * _gap,
                  height: _row,
                  child: Transform.translate(
                    offset: Offset((_newWidth + _gap + 8) * t, 0), // off the screen's edge, as the mockup's 184 px
                    child: Opacity(
                      opacity: 1 - (v / .63).clamp(0, 1),
                      child: IgnorePointer(ignoring: v > 0, child: _newButton(onNew)),
                    ),
                  ),
                ),
              if (_canAsk)
                Positioned.fromRect(key: const ValueKey('surface'), rect: Rect.lerp(slot, sheet, t)!, child: _surface(t, v, slot.size, sheet.size, content)),
            ]);
          },
        );
      }),
    );
  }

  Widget _newButton(VoidCallback onNew) => FilledButton.icon(
        key: const Key('newSession'),
        onPressed: onNew,
        style: FilledButton.styleFrom(
          backgroundColor: C.text,
          foregroundColor: C.bg,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: const Icon(Icons.add, size: 22),
        label: const Text('New session', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      );

  // the content keeps its open-sheet size through the motion, so it never re-wraps; the surface clips it
  Widget _surface(double t, double v, Size slot, Size sheet, Widget content) {
    final radius = BorderRadius.lerp(BorderRadius.circular(16), const BorderRadius.vertical(top: Radius.circular(24)), t)!;
    return DecoratedBox(
      decoration: BoxDecoration(color: C.surface, borderRadius: radius, border: Border.all(color: Color.lerp(C.line, C.surface, t)!)),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [
            Positioned(
              left: 1,
              top: 1,
              width: slot.width - 2,
              height: slot.height - 2,
              child: IgnorePointer(ignoring: v > 0, child: Opacity(opacity: 1 - (v / .26).clamp(0, 1), child: _askButton())),
            ),
            Positioned(
              left: 0,
              top: 0,
              width: sheet.width,
              height: sheet.height,
              child: Offstage(
                offstage: v == 0,
                child: ExcludeFocus(
                  excluding: !_open,
                  child: IgnorePointer(ignoring: v < 1, child: Opacity(opacity: const Interval(.68, 1).transform(v), child: content)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _askButton() {
    final unread = m.assistant?.unread ?? 0;
    return Semantics(
      button: true,
      label: unread > 0 ? 'Ask Elis, $unread unread' : 'Ask Elis',
      onTap: _show,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('askElis'),
        onTap: _show,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
          child: Row(spacing: 10, children: [
            const AppMark(size: 32),
            const Expanded(child: Text('Ask Elis…', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: C.muted))),
            if (unread > 0) UnreadBadge(unread),
          ]),
        ),
      ),
    );
  }

  // a downward drag outside the transcript (the handle) closes the sheet
  Widget _content(double bottomInset) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => _drag = 0,
        onVerticalDragUpdate: (d) => _drag += d.delta.dy,
        onVerticalDragEnd: (d) => _drag > 80 || (d.primaryVelocity ?? 0) > 700 ? _close() : null,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(children: [
            Semantics(
              button: true,
              label: 'Close Elis',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: SizedBox(
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(color: Theme.of(context).bottomSheetTheme.dragHandleColor, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: ElisSheet(model: m, openSession: _jump)),
          ]),
        ),
      );
}
