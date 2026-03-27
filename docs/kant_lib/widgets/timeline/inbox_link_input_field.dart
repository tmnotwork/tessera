import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/inbox_task.dart' as inbox;
import '../../providers/task_provider.dart';
import '../../services/inbox_task_service.dart';
import '../../utils/input_method_guard.dart';

class InboxLinkInputField extends StatefulWidget {
  final TextEditingController controller;
  final String blockId;
  final DateTime executionDate;
  /// 指定時は日付にかかわらずこのプロジェクトの未割り当てインボックスを候補にする
  final String? projectId;
  final String? subProjectId;
  final Future<void> Function(List<inbox.InboxTask> tasks) onLink;
  final String? hintText;
  final void Function(String value)? onSubmitText;
  /// 指定時は入力欄の背景にこの色を使う（タイムラインで行背景と一致させる用）
  final Color? fillColor;

  const InboxLinkInputField({
    super.key,
    required this.controller,
    required this.blockId,
    required this.executionDate,
    required this.onLink,
    this.projectId,
    this.subProjectId,
    this.hintText,
    this.onSubmitText,
    this.fillColor,
  });

  @override
  State<InboxLinkInputField> createState() => _InboxLinkInputFieldState();
}

class _InboxLinkInputFieldState extends State<InboxLinkInputField> {
  final FocusNode _focusNode = FocusNode();
  final FocusNode _keyboardFocusNode =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  OverlayEntry? _overlayEntry;
  List<inbox.InboxTask> _candidates = [];
  int _selectedIndex = -1;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _updateCandidates();
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
    _selectedIds.clear();
  }

  void _updateCandidates() {
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    final projectId = widget.projectId;
    final subProjectId = widget.subProjectId;

    List<inbox.InboxTask> base;
    try {
      final provider = Provider.of<TaskProvider>(context, listen: false);
      base = provider.allInboxTasks
          .where((t) => t.isDeleted != true && (t.isCompleted != true))
          .where((t) => t.isSomeday != true)
          .where((t) => t.blockId == null || t.blockId!.isEmpty)
          .toList();
    } catch (_) {
      base = InboxTaskService.getAllInboxTasks()
          .where((t) => t.isDeleted != true && (t.isCompleted != true))
          .where((t) => t.isSomeday != true)
          .where((t) => t.blockId == null || t.blockId!.isEmpty)
          .toList();
    }
    if (projectId != null && projectId.isNotEmpty) {
      // そのプロジェクトの未割り当てを日付にかかわらず候補にする
      _candidates = base
          .where((t) => t.projectId == projectId)
          .where((t) =>
              subProjectId == null ||
              subProjectId.isEmpty ||
              t.subProjectId == subProjectId)
          .toList();
    } else {
      _candidates = base
          .where((t) => sameDay(t.executionDate, widget.executionDate))
          .toList();
    }
    _candidates.sort((a, b) => a.title.compareTo(b.title));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 36,
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
            _updateCandidates();
            if (_candidates.isNotEmpty) {
              setState(() => _selectedIndex = 0);
              _showOverlay();
            }
            return;
          }
          if (_overlayEntry != null && _candidates.isNotEmpty) {
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              setState(() {
                _selectedIndex = _selectedIndex <= 0
                    ? _candidates.length - 1
                    : _selectedIndex - 1;
              });
              _overlayEntry!.markNeedsBuild();
            } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              setState(() {
                _selectedIndex = _selectedIndex >= _candidates.length - 1
                    ? 0
                    : _selectedIndex + 1;
              });
              _overlayEntry!.markNeedsBuild();
            } else if (event.logicalKey == LogicalKeyboardKey.enter) {
              if (_selectedIds.isNotEmpty) {
                _submitSelected();
                return;
              }
              if (_selectedIndex >= 0 &&
                  _selectedIndex < _candidates.length) {
                _submitSelectedList([_candidates[_selectedIndex]]);
              } else {
                _removeOverlay();
                widget.onSubmitText?.call(widget.controller.text);
              }
            } else if (event.logicalKey == LogicalKeyboardKey.escape) {
              _removeOverlay();
            }
          }
        },
        child: TextField(
          focusNode: _focusNode,
          controller: widget.controller,
          style: const TextStyle(fontSize: 12, height: 1.0),
          textAlign: TextAlign.left,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: Theme.of(context).dividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: Theme.of(context).dividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary, width: 1.5),
            ),
            isCollapsed: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10.0, vertical: 16.0),
            filled: true,
            fillColor: widget.fillColor ?? Theme.of(context).colorScheme.surface,
            hintText: widget.hintText ?? 'タスク名',
            hintStyle:
                TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            constraints: const BoxConstraints(minHeight: 36, maxHeight: 36),
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          onChanged: (value) {
            _updateCandidates();
            _removeOverlay();
            if (isImeComposing(widget.controller)) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showOverlay();
            });
          },
          onTap: () {
            _updateCandidates();
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
            widget.onSubmitText?.call(value);
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
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final position = renderBox.localToGlobal(Offset.zero);
    final fieldWidth = renderBox.size.width;
    final overlayWidth = fieldWidth < 360 ? 360.0 : fieldWidth;
    final selectedCount = _selectedIds.length;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx,
        top: position.dy + 36,
        width: overlayWidth,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _candidates.isEmpty ? 1 : _candidates.length,
                    itemBuilder: (context, idx) {
                      if (_candidates.isEmpty) {
                        return Container(
                          width: double.infinity,
                          height: 36,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '未了タスクなし',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color),
                          ),
                        );
                      }
                      final t = _candidates[idx];
                      final isKeyboardSelected = idx == _selectedIndex;
                      final isChecked = _selectedIds.contains(t.id);
                      return Material(
                        color: isKeyboardSelected
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.1)
                            : const Color(0x00000000),
                        child: InkWell(
                          onTap: () => _toggleSelection(t),
                          child: Container(
                            width: double.infinity,
                            height: 36,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 32,
                                  height: 24,
                                  child: Checkbox(
                                    value: isChecked,
                                    onChanged: (_) => _toggleSelection(t),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(Icons.inbox, size: 16),
                                ),
                                Expanded(
                                  child: Text(
                                    t.title,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.color,
                                      fontWeight: isKeyboardSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${t.estimatedDuration}分',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_candidates.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: selectedCount > 0
                            ? () => _submitSelected()
                            : null,
                        child: Text(selectedCount > 0
                            ? '選択した$selectedCount件をリンク'
                            : 'タスクを選択してからリンク'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  void _toggleSelection(inbox.InboxTask task) {
    setState(() {
      if (_selectedIds.contains(task.id)) {
        _selectedIds.remove(task.id);
      } else {
        _selectedIds.add(task.id);
      }
    });
    _overlayEntry?.markNeedsBuild();
  }

  List<inbox.InboxTask> _getSelectedTasks() {
    return _candidates.where((t) => _selectedIds.contains(t.id)).toList();
  }

  Future<void> _submitSelected() async {
    final list = _getSelectedTasks();
    if (list.isEmpty) return;
    await _submitSelectedList(list);
  }

  Future<void> _submitSelectedList(List<inbox.InboxTask> list) async {
    if (list.isEmpty) return;
    if (isImeComposing(widget.controller)) return;
    _removeOverlay();
    await widget.onLink(list);
    if (mounted) {
      setState(() {
        widget.controller.text = list.length == 1
            ? list.first.title
            : '${list.length}件をリンクしました';
      });
      if (!isImeComposing(widget.controller)) {
        FocusScope.of(context).nextFocus();
      }
    }
  }
}
