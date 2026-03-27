import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

class ExcelLikeTitleCell extends StatefulWidget {
  final TextEditingController controller;
  final double rowHeight;
  final Color borderColor;
  final VoidCallback onCommit;
  final ValueChanged<String> onChanged;
  final String placeholder;

  const ExcelLikeTitleCell({
    super.key,
    required this.controller,
    required this.rowHeight,
    required this.borderColor,
    required this.onCommit,
    required this.onChanged,
    this.placeholder = '',
  });

  @override
  State<ExcelLikeTitleCell> createState() => _ExcelLikeTitleCellState();
}

class _ExcelLikeTitleCellState extends State<ExcelLikeTitleCell> {
  late final FocusNode _focusNode;
  bool _editing = false;
  Timer? _deferCommitTimer;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'inbox_title_cell_focus');
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final hasFocus = _focusNode.hasFocus;
    if (_editing != hasFocus) {
      setState(() => _editing = hasFocus);
    }
    if (hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final text = widget.controller.text;
        widget.controller.selection =
            TextSelection.collapsed(offset: text.length);
      });
    }
    _deferCommitTimer?.cancel();
    if (!hasFocus) {
      // 少し遅らせてTextField内のonSubmitted等と競合しないようにする
      _deferCommitTimer = Timer(const Duration(milliseconds: 30), () {
        widget.onCommit();
      });
    }
  }

  @override
  void dispose() {
    _deferCommitTimer?.cancel();
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodyMedium?.color ??
        theme.colorScheme.onSurface;
    final cursorColor =
        theme.textSelectionTheme.cursorColor ?? theme.colorScheme.primary;
    final selectionColor = theme.textSelectionTheme.selectionColor ??
        theme.colorScheme.primary.withOpacity(0.25);
    final textDirection = Directionality.of(context);
    final baseTextStyle = theme.textTheme.bodyMedium;
    final fallbackFamily =
        baseTextStyle?.fontFamily ?? theme.textTheme.bodySmall?.fontFamily ?? 'NotoSansJP';
    final textStyle = TextStyle(
      fontSize: 12,
      height: 1.0,
      color: textColor,
      fontFamily: fallbackFamily,
    );
    final double glyphHeight = textStyle.fontSize ?? 12;
    final double textHeight = (textStyle.height ?? 1.0) * glyphHeight;
    final double verticalPadding =
        math.max(0, (widget.rowHeight - textHeight) / 2);
    const double horizontalPadding = 8;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: widget.borderColor),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        height: widget.rowHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_editing,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 100),
                  opacity: _editing ? 1 : 0,
                  child: SizedBox(
                    height: widget.rowHeight,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: verticalPadding,
                        horizontal: horizontalPadding,
                      ),
                      child: EditableText(
                        controller: widget.controller,
                        focusNode: _focusNode,
                        style: textStyle,
                        cursorColor: cursorColor,
                        backgroundCursorColor: const Color(0x00000000),
                        selectionColor: selectionColor,
                        textAlign: TextAlign.left,
                        textDirection: textDirection,
                        maxLines: 1,
                        minLines: 1,
                        expands: false,
                        strutStyle: const StrutStyle(
                          forceStrutHeight: true,
                          height: 1.0,
                          leading: 0,
                        ),
                        cursorWidth: 1,
                        cursorHeight: glyphHeight,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        onChanged: widget.onChanged,
                        onSubmitted: (_) => _focusNode.unfocus(),
                        selectionControls: materialTextSelectionControls,
                        scrollPadding: EdgeInsets.zero,
                        enableInteractiveSelection: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _editing,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    final trimmed = value.text.trim();
                    final isEmpty = trimmed.isEmpty;
                    final isPlaceholderValue = trimmed == widget.placeholder;
                    final display = isEmpty ? widget.placeholder : value.text;
                    final isPlaceholder = (isEmpty || isPlaceholderValue) && widget.placeholder.isNotEmpty;
                    final displayStyle = isPlaceholder
                        ? textStyle.copyWith(
                            color: theme.hintColor,
                          )
                        : textStyle;
                    return AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _editing ? 0 : 1,
                      child: Padding(
                        padding:
                            const EdgeInsets.only(left: horizontalPadding),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            display,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: displayStyle,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            if (!_editing)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _focusNode.requestFocus(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
