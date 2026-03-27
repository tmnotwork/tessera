import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/mode.dart';
import '../services/mode_service.dart';
import '../services/selection_frequency_service.dart';
import '../services/mode_sync_service.dart';
import '../services/auth_service.dart';
import '../utils/input_method_guard.dart';

class ModeInputField extends StatefulWidget {
  final TextEditingController controller;
  final Function(String?)? onModeChanged;
  final VoidCallback? onAutoSave;
  final String? hintText;
  final bool useOutlineBorder;
  final bool withBackground;
  final double height;
  // 文字サイズ（未指定なら従来値=12を維持）
  final double? fontSize;
  /// 指定時は入力欄の背景にこの色を使う（タイムラインで行背景と一致させる用）
  final Color? fillColor;

  const ModeInputField({
    super.key,
    required this.controller,
    this.onModeChanged,
    this.onAutoSave,
    this.hintText,
    this.useOutlineBorder = true,
    this.withBackground = true,
    this.height = 36,
    this.fontSize,
    this.fillColor,
  });

  @override
  State<ModeInputField> createState() => _ModeInputFieldState();
}

class _ModeInputFieldState extends State<ModeInputField> {
  List<Mode> _modeCandidates = [];
  OverlayEntry? _overlayEntry;
  final FocusNode _focusNode = FocusNode();
  final FocusNode _keyboardFocusNode =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  int _selectedIndex = -1;

  @override
  void initState() {
    super.initState();
    _updateModeCandidates();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _removeOverlay();
        });
      }
    });
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _selectedIndex = -1;
  }

  void _updateModeCandidates() {
    final all = ModeService.getAllModes();
    final inputRaw = widget.controller.text.trim();
    final input = inputRaw.toLowerCase();
    final hasExact = all
        .any((m) => m.name.trim().toLowerCase() == input && input.isNotEmpty);
    final allSorted = all.toList()
      ..sort((a, b) {
        final fa = SelectionFrequencyService.getModeCount(a.id);
        final fb = SelectionFrequencyService.getModeCount(b.id);
        if (fb != fa) return fb.compareTo(fa);
        return a.name.compareTo(b.name);
      });
    // 検索しない: 常に全モードを表示。「〜を登録する」は常に先頭
    _modeCandidates = [
      if (!hasExact && input.isNotEmpty)
        Mode(
          id: '__new__',
          name: '$inputRaw を登録する',
          description: null,
          userId: AuthService.getCurrentUserId() ?? '',
          createdAt: DateTime.now(),
          lastModified: DateTime.now(),
        ),
      ...allSorted,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final double effectiveFontSize = widget.fontSize ?? 12.0;
    return SizedBox(
      width: double.infinity,
      height: widget.height,
      child: KeyboardListener(
        focusNode: _keyboardFocusNode,
        includeSemantics: false,
        onKeyEvent: (event) {
          if (!shouldHandleImeShortcut(event, widget.controller)) {
            return;
          }
          if (event is! KeyDownEvent) {
            return;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
              _overlayEntry == null) {
            _updateModeCandidates();
            if (_modeCandidates.isNotEmpty) {
              setState(() => _selectedIndex = 0);
              _showOverlay();
            }
            return;
          }
          if (_overlayEntry != null && _modeCandidates.isNotEmpty) {
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              setState(() {
                _selectedIndex = _selectedIndex <= 0
                    ? _modeCandidates.length - 1
                    : _selectedIndex - 1;
              });
              _overlayEntry!.markNeedsBuild();
            } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              setState(() {
                _selectedIndex = _selectedIndex >= _modeCandidates.length - 1
                    ? 0
                    : _selectedIndex + 1;
              });
              _overlayEntry!.markNeedsBuild();
            } else if (event.logicalKey == LogicalKeyboardKey.enter) {
              if (_selectedIndex >= 0 &&
                  _selectedIndex < _modeCandidates.length) {
                _selectMode(_modeCandidates[_selectedIndex]);
              }
            } else if (event.logicalKey == LogicalKeyboardKey.escape) {
              _removeOverlay();
            }
          }
        },
        child: TextField(
          focusNode: _focusNode,
          controller: widget.controller,
          maxLines: 1,
          // NOTE: `height: 1.0` や強制constraintsは環境によって文字の下側が欠けることがあるため使わない
          // （フォントサイズ自体は維持）。
          style: TextStyle(fontSize: effectiveFontSize),
          textAlign: TextAlign.left,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            border: widget.useOutlineBorder
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide:
                        BorderSide(color: Theme.of(context).dividerColor),
                  )
                : InputBorder.none,
            enabledBorder: widget.useOutlineBorder
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide:
                        BorderSide(color: Theme.of(context).dividerColor),
                  )
                : InputBorder.none,
            focusedBorder: widget.useOutlineBorder
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5),
                  )
                : InputBorder.none,
            isCollapsed: true,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 10.0,
              vertical: widget.height >= 44 ? 12.0 : 8.0,
            ),
            filled: widget.withBackground,
            fillColor: widget.fillColor ??
                (widget.withBackground
                    ? (Theme.of(context).inputDecorationTheme.fillColor ??
                        Theme.of(context).colorScheme.surface)
                    : const Color(0x00000000)),
            hintText: widget.hintText ?? 'モード',
            hintStyle: TextStyle(
              fontSize: effectiveFontSize,
              color: Theme.of(context).hintColor,
            ),
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          onChanged: (value) {
            _updateModeCandidates();
            _removeOverlay();
            if (isImeComposing(widget.controller)) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showOverlay();
            });
          },
          onTap: () {
            _updateModeCandidates();
            _removeOverlay();
            if (isImeComposing(widget.controller)) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showOverlay();
            });
          },
          onSubmitted: (value) async {
            if (isImeComposing(widget.controller)) {
              return;
            }
            _removeOverlay();
            await _handleSubmission(value);
            if (!isImeComposing(widget.controller)) {
              FocusScope.of(context).nextFocus();
            }
          },
          onEditingComplete: () {
            if (isImeComposing(widget.controller)) {
              return;
            }
            _removeOverlay();
          },
        ),
      ),
    );
  }

  void _showOverlay() {
    _removeOverlay();
    if (_modeCandidates.isEmpty) return;
    final double overlayFontSize = widget.fontSize ?? 12.0;
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final position = renderBox.localToGlobal(Offset.zero);
    final fieldWidth = renderBox.size.width;
    final overlayWidth = fieldWidth < 300 ? 300.0 : fieldWidth;
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx,
        top: position.dy + widget.height,
        width: overlayWidth,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _modeCandidates.length,
              itemBuilder: (context, idx) {
                final mode = _modeCandidates[idx];
                final isNew = mode.id == '__new__';
                final isSelected = idx == _selectedIndex;
                return Material(
                  color: isSelected
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity( 0.1)
                      : const Color(0x00000000),
                  child: InkWell(
                    onTap: () => _selectMode(mode),
                    child: Container(
                      width: double.infinity,
                      height: 36,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          if (isNew)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Icon(Icons.add,
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                  size: 16),
                            ),
                          Expanded(
                            child: Text(
                              mode.name,
                              style: TextStyle(
                                fontSize: overlayFontSize,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: mode.name.contains('を登録する')
                                    ? Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.color
                                    : Theme.of(context)
                                        .textTheme
                                        .bodyLarge
                                        ?.color,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  Future<void> _handleSubmission(String value) async {
    final input = value.trim();
    if (input.isEmpty) return;
    final all = ModeService.getAllModes();
    final exists =
        all.any((m) => m.name.trim().toLowerCase() == input.toLowerCase());
    if (exists) {
      final existing = all.firstWhere(
          (m) => m.name.trim().toLowerCase() == input.toLowerCase());
      widget.onModeChanged?.call(existing.id);
      widget.controller.text = existing.name;
      widget.onAutoSave?.call();
      return;
    }
    await _createNewMode(input);
  }

  Future<void> _selectMode(Mode mode) async {
    if (isImeComposing(widget.controller)) {
      return;
    }
    final isNew = mode.id == '__new__';
    if (isNew) {
      await _handleNewCreation();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.hasFocus) _showOverlay();
      });
    } else {
      widget.onModeChanged?.call(mode.id);
      widget.controller.text = mode.name;
      setState(() => _updateModeCandidates());
      _removeOverlay();
      widget.onAutoSave?.call();
    }
  }

  Future<void> _handleNewCreation() async {
    final input = widget.controller.text.trim();
    if (input.isEmpty) return;
    final all = ModeService.getAllModes();
    final exists =
        all.any((m) => m.name.trim().toLowerCase() == input.toLowerCase());
    if (exists) {
      final existing = all.firstWhere(
          (m) => m.name.trim().toLowerCase() == input.toLowerCase());
      widget.onModeChanged?.call(existing.id);
      widget.controller.text = existing.name;
      widget.onAutoSave?.call();
      return;
    }
    await _createNewMode(input);
  }

  Future<void> _createNewMode(String name) async {
    final newMode = await ModeSyncService().createModeWithSync(name: name);
    widget.onModeChanged?.call(newMode.id);
    widget.controller.text = newMode.name;
    setState(() => _updateModeCandidates());
    widget.onAutoSave?.call();
  }
}
