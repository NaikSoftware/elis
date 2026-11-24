import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A row's place in its list's content, so the user's own scrolling does not count as a shift; safe inside layout,
/// where a dropped row's element is already inactive but its render object reads detached.
double? listOffset(RenderObject? row) {
  var o = row;
  while (o != null && o.parentData is! SliverMultiBoxAdaptorParentData) {
    o = o.parent;
  }
  return o != null && o.attached ? (o.parentData as SliverMultiBoxAdaptorParentData).layoutOffset : null;
}

/// Applies [shift] when the list's content settles in a layout pass, before that frame paints.
class KeepController extends ScrollController {
  KeepController(this.shift);

  final double Function() shift;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _KeepPosition(shift, physics: physics, context: context, oldPosition: oldPosition);
}

class _KeepPosition extends ScrollPositionWithSingleContext {
  _KeepPosition(this.shift, {required super.physics, required super.context, super.oldPosition});

  final double Function() shift;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final by = shift();
    if (by == 0) return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    // correctBy keeps a drag or fling going, which a jump would end; false lays the viewport out again
    correctBy(by);
    return false;
  }
}
