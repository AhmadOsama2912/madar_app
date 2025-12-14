import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

mixin TvDpadUtility<T extends StatefulWidget> on State<T> {
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'tvRoot');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _rootFocusNode.dispose();
    super.dispose();
  }

  FocusNode get rootFocusNode => _rootFocusNode;

  KeyEventResult handleDpadKey(FocusNode node, RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    final direction = _getTraversalDirection(key);
    if (direction != null) {
      final didMove = node.focusInDirection(direction);
      return didMove ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    // Select/Enter/A button: عادةً خليها للـ Actions system أو للـ widget نفسه.
    if (key == LogicalKeyboardKey.select || // Android TV remote "Select"
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  TraversalDirection? _getTraversalDirection(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }
}
