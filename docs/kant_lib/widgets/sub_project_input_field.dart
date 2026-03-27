// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/sub_project.dart';
import '../services/app_settings_service.dart';
import '../services/selection_frequency_service.dart';
import '../services/sub_project_service.dart';
import '../services/auth_service.dart';
import '../utils/input_method_guard.dart';
import '../utils/text_normalizer.dart';

extension FirstWhereOrNullExtension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (var element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

class SubProjectInputField extends StatefulWidget {
  final TextEditingController controller;
  final Function(String?, String?)? onSubProjectChanged;
  final String? projectId;
  final String? currentSubProjectId;
  final VoidCallback? onAutoSave;
  final String? hintText;
  final String? labelText;
  final FloatingLabelBehavior? floatingLabelBehavior;
  final bool withBackground;
  final bool useOutlineBorder;
  // true の場合、枠線/塗り等は InputDecorationTheme（Material3の状態別デフォルト）に寄せる
  // ※ 画面内の他TextFieldと見た目を揃えたいケース向け
  final bool useThemeDecoration;
  // true の場合、従来の「固定高さ(デフォルト36)」を使わず、InputDecorationの標準レイアウトに任せる
  // （ラベル付きフォーム等で高さが見切れないようにするため）
  final bool allowIntrinsicHeight;
  final EdgeInsetsGeometry? contentPadding;
  final double? height; // 入力欄の高さ（未指定時はデフォルト36）
  // 文字サイズ（未指定なら従来値=12を維持）
  final double? fontSize;
  /// 指定時は入力欄の背景にこの色を使う（タイムラインで行背景と一致させる用）
  final Color? fillColor;

  const SubProjectInputField({
    super.key,
    required this.controller,
    this.onSubProjectChanged,
    this.projectId,
    this.currentSubProjectId,
    this.onAutoSave,
    this.hintText,
    this.labelText,
    this.floatingLabelBehavior,
    this.withBackground = true,
    this.useOutlineBorder = true,
    this.useThemeDecoration = false,
    this.allowIntrinsicHeight = false,
    this.contentPadding,
    this.height,
    this.fontSize,
    this.fillColor,
  });

  @override
  State<SubProjectInputField> createState() => _SubProjectInputFieldState();
}

class _SubProjectInputFieldState extends State<SubProjectInputField> {
  List<SubProject> _subProjectCandidates = [];
  OverlayEntry? _overlayEntry;
  final FocusNode _focusNode = FocusNode();
  final FocusNode _keyboardFocusNode = FocusNode(
    skipTraversal: true,
    canRequestFocus: false,
  );
  int _selectedIndex = -1;
  bool _isSubmitting = false;
  bool _wasComposing = false;
  bool _suppressControllerListener = false;
  String _lastTextSnapshot = '';
  bool _ignoreNextSubmit = false;

  @override
  void initState() {
    super.initState();
    _updateSubProjectCandidates();
    _wasComposing = isImeComposing(widget.controller);
    _lastTextSnapshot = widget.controller.text;
    widget.controller.addListener(_handleControllerChange);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            _removeOverlay();
            // フォーカスアウト時に自動クリアしない（明示操作のみでクリア）
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _removeOverlay();
    widget.controller.removeListener(_handleControllerChange);
    _focusNode.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SubProjectInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChange);
      _wasComposing = isImeComposing(widget.controller);
      _lastTextSnapshot = widget.controller.text;
      widget.controller.addListener(_handleControllerChange);
    }
    if (oldWidget.projectId != widget.projectId) {
      _updateSubProjectCandidates();
      _updateOverlay();
    }
  }

  void _handleControllerChange() {
    if (!mounted) return;
    if (_suppressControllerListener) {
      _lastTextSnapshot = widget.controller.text;
      _wasComposing = isImeComposing(widget.controller);
      return;
    }
    // IME確定直後は composing 状態の取りこぼしで候補再表示が走らないことがあるため、
    // composing終了を検知して候補のみ再表示する。
    final bool composing = isImeComposing(widget.controller);
    final currentText = widget.controller.text;
    final bool textChanged = currentText != _lastTextSnapshot;
    if (_focusNode.hasFocus && _wasComposing && !composing) {
      _updateSubProjectCandidates();
      _removeOverlay();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_focusNode.hasFocus) return;
        if (isImeComposing(widget.controller)) return;
        _showSubProjectCandidatesOverlay();
      });
    } else if (_focusNode.hasFocus && textChanged && !composing) {
      _updateSubProjectCandidates();
      _removeOverlay();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_focusNode.hasFocus) return;
        if (isImeComposing(widget.controller)) return;
        _showSubProjectCandidatesOverlay();
      });
    }
    _lastTextSnapshot = currentText;
    _wasComposing = composing;
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _selectedIndex = -1;
  }

  void _updateSubProjectCandidates() {
    if (widget.projectId == null) {
      _subProjectCandidates = [];
      return;
    }

    final all = SubProjectService.getSubProjectsByProjectId(widget.projectId!);
    final rawInput = widget.controller.text.trim();
    final input = rawInput.toLowerCase();
    final hasExact = all.any(
      (p) => p.name.trim().toLowerCase() == input && input.isNotEmpty,
    );
    // 部分一致: 未アーカイブ→アーカイブの順
    final Iterable<SubProject> active = all.where((p) => !p.isArchived);
    final Iterable<SubProject> archived = all.where((p) => p.isArchived);
    final List<SubProject> activeFiltered = input.isEmpty
        ? active.toList()
        : active.where((p) => matchesQuery(p.name, input)).toList();
    final List<SubProject> archivedFiltered = input.isEmpty
        ? archived.toList()
        : archived.where((p) => matchesQuery(p.name, input)).toList();

    void sortByFrequency(List<SubProject> list) {
      list.sort((a, b) {
        final fa = SelectionFrequencyService.getSubProjectCount(a.id);
        final fb = SelectionFrequencyService.getSubProjectCount(b.id);
        if (fb != fa) return fb.compareTo(fa);
        return a.name.compareTo(b.name);
      });
    }

    sortByFrequency(activeFiltered);
    sortByFrequency(archivedFiltered);

    final archivedMode =
        AppSettingsService.archivedInSelectDisplayNotifier.value;
    final showArchived = archivedMode == 'dimmed';

    _subProjectCandidates = [
      if (!hasExact && input.isNotEmpty)
        SubProject(
          id: '__new__',
          name: '$rawInput を登録する',
          description: null,
          projectId: widget.projectId!,
          createdAt: DateTime.now(),
          lastModified: DateTime.now(),
          isArchived: false,
          userId: '',
        ),
      ...activeFiltered,
      if (showArchived) ...archivedFiltered,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double effectiveHeight = widget.height ?? 48.0;
        final double effectiveFontSize = widget.fontSize ?? 12.0;
        final theme = Theme.of(context);

        final InputBorder border = widget.useOutlineBorder
            ? const OutlineInputBorder()
            : InputBorder.none;

        final InputBorder? enabledBorder = widget.useThemeDecoration
            ? null
            : (widget.useOutlineBorder
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: theme.dividerColor),
                  )
                : InputBorder.none);

        final InputBorder? focusedBorder = widget.useThemeDecoration
            ? null
            : (widget.useOutlineBorder
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 1.5,
                    ),
                  )
                : InputBorder.none);

        final textField = KeyboardListener(
              focusNode: _keyboardFocusNode,
              autofocus: false,
              includeSemantics: false,
              onKeyEvent: (KeyEvent event) {
                if (!shouldHandleImeShortcut(event, widget.controller)) {
                  return;
                }
                if (event is! KeyDownEvent) {
                  return;
                }

                if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                    _overlayEntry == null) {
                  _updateSubProjectCandidates();
                  if (_subProjectCandidates.isNotEmpty) {
                    setState(() {
                      _selectedIndex = 0;
                    });
                    _showSubProjectCandidatesOverlay();
                  }
                  return;
                }

                // EnterでIME確定した直後に候補が消えるケースへの保険:
                // 未登録の入力がある場合は、まず「〜を登録する」を表示して明示選択させる。
                if (event.logicalKey == LogicalKeyboardKey.enter &&
                    _overlayEntry == null &&
                    !_isSubmitting) {
                  _updateSubProjectCandidates();
                  if (_subProjectCandidates.isNotEmpty &&
                      _subProjectCandidates.first.id == '__new__') {
                    // Enterでオーバーレイを開いた直後にTextField側のonSubmittedも
                    // 発火しうるため、次のonSubmittedを1回だけ無視して候補を残す。
                    _ignoreNextSubmit = true;
                    setState(() {
                      _selectedIndex = 0;
                    });
                    _showSubProjectCandidatesOverlay();
                    return;
                  }
                }

                if (_overlayEntry != null &&
                    _subProjectCandidates.isNotEmpty) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    setState(() {
                      _selectedIndex = _selectedIndex <= 0
                          ? _subProjectCandidates.length - 1
                          : _selectedIndex - 1;
                    });
                    _updateOverlay();
                  } else if (event.logicalKey ==
                      LogicalKeyboardKey.arrowDown) {
                    setState(() {
                      _selectedIndex =
                          _selectedIndex >= _subProjectCandidates.length - 1
                              ? 0
                              : _selectedIndex + 1;
                    });
                    _updateOverlay();
                  } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                    if (_selectedIndex >= 0 &&
                        _selectedIndex < _subProjectCandidates.length &&
                        !_isSubmitting) {
                      _isSubmitting = true;
                      _selectSubProject(_subProjectCandidates[_selectedIndex])
                          .whenComplete(() {
                        _isSubmitting = false;
                      });
                    }
                  } else if (event.logicalKey == LogicalKeyboardKey.escape) {
                    _removeOverlay();
                  }
                }
              },
              child: LayoutBuilder(
                builder: (context, textFieldConstraints) {
                  return TextField(
                    focusNode: _focusNode,
                    controller: widget.controller,
                    maxLines: 1,
                    // NOTE: `height: 1.0` や強制constraintsは環境によって文字の下側が欠けることがあるため使わない
                    // （フォントサイズ自体は維持）。
                    style: TextStyle(fontSize: effectiveFontSize),
                    textAlign: TextAlign.left,
                    textAlignVertical: TextAlignVertical.center, // 垂直中央配置を有効化
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      border: border,
                      enabledBorder: enabledBorder,
                      focusedBorder: focusedBorder,
                      labelText: widget.labelText,
                      floatingLabelBehavior: widget.floatingLabelBehavior,
                      // NOTE: ラベル付きフォーム等では標準レイアウトを使う（見切れ防止）。
                      isCollapsed: widget.allowIntrinsicHeight ? false : true,
                      contentPadding: widget.allowIntrinsicHeight
                          ? widget.contentPadding
                          : (widget.contentPadding ??
                              EdgeInsets.symmetric(
                                horizontal: 10.0,
                                vertical: effectiveHeight >= 44 ? 12.0 : 16.0,
                              )), // 描画領域をRow高さいっぱいに拡大
                      filled: widget.withBackground,
                      fillColor: widget.fillColor ??
                          (widget.useThemeDecoration
                              ? null
                              : (widget.withBackground
                                  ? (theme.inputDecorationTheme.fillColor ??
                                      theme.colorScheme.surface)
                                  : Colors.transparent)),
                      hintText: widget.hintText,
                      hintStyle: TextStyle(
                          fontSize: effectiveFontSize,
                          color: theme.hintColor),
                      suffixIcon: const Icon(Icons.arrow_drop_down),
                    ),
                    onChanged: (value) {
                      _updateSubProjectCandidates();
                      _removeOverlay();
                      if (isImeComposing(widget.controller)) {
                        return;
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _showSubProjectCandidatesOverlay();
                        }
                      });
                    },
                    onTap: () {
                      _updateSubProjectCandidates();
                      _removeOverlay();
                      if (isImeComposing(widget.controller)) {
                        return;
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _showSubProjectCandidatesOverlay();
                        }
                      });
                    },
                    onSubmitted: (value) async {
                      if (_ignoreNextSubmit) {
                        _ignoreNextSubmit = false;
                        return;
                      }
                      if (isImeComposing(widget.controller)) {
                        return;
                      }
                      if (_isSubmitting) return;
                      _isSubmitting = true;

                      // ソフトキーボード等で候補表示中に確定された場合も、選択処理に寄せる
                      if (_overlayEntry != null &&
                          _selectedIndex >= 0 &&
                          _selectedIndex < _subProjectCandidates.length) {
                        await _selectSubProject(
                          _subProjectCandidates[_selectedIndex],
                        );
                        _isSubmitting = false;
                        if (!isImeComposing(widget.controller)) {
                          FocusScope.of(context).nextFocus();
                        }
                        return;
                      }

                      _removeOverlay();

                      final input = value.trim();
                      if (input.isEmpty) {
                        widget.onSubProjectChanged?.call(null, null);
                        _isSubmitting = false;
                        return;
                      }

                      if (widget.projectId == null) {
                        widget.controller.clear();
                        widget.onSubProjectChanged?.call(null, null);
                        _isSubmitting = false;
                        return;
                      }

                      final all = SubProjectService.getSubProjectsByProjectId(
                        widget.projectId!,
                      );
                      final existing = all.firstWhereOrNull(
                        (p) =>
                            p.name.trim().toLowerCase() == input.toLowerCase(),
                      );
                      if (existing != null) {
                        widget.onSubProjectChanged?.call(
                          existing.id,
                          existing.name,
                        );
                        _suppressControllerListener = true;
                        widget.controller.text = existing.name;
                        _suppressControllerListener = false;
                        _isSubmitting = false;
                        if (!isImeComposing(widget.controller)) {
                          FocusScope.of(context).nextFocus();
                        }
                        return;
                      }

                      // 未登録の場合は即作成せず、「〜を登録する」候補を出して明示選択させる
                      _updateSubProjectCandidates();
                      setState(() {
                        _selectedIndex = 0;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (!_focusNode.hasFocus) return;
                        if (isImeComposing(widget.controller)) return;
                        _showSubProjectCandidatesOverlay();
                      });
                      _isSubmitting = false;
                    },
                    onEditingComplete: () {
                      if (isImeComposing(widget.controller)) {
                        return;
                      }
                      _removeOverlay();
                    },
                    autofocus: false,
                  );
                },
              ),
          );

        if (widget.allowIntrinsicHeight) {
          return SizedBox(width: double.infinity, child: textField);
        }

        return SizedBox(
          width: double.infinity,
          height: effectiveHeight,
          child: textField,
        );
      },
    );
  }

  void _showSubProjectCandidatesOverlay() {
    _removeOverlay();

    if (_subProjectCandidates.isEmpty) return;
    // build() 内の effectiveFontSize と同じ決定ロジックをここでも使う（スコープ外参照を避ける）
    final double overlayFontSize = widget.fontSize ?? 12.0;

    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final fieldWidth = renderBox.size.width;
    // NOTE: allowIntrinsicHeight=true の場合、widget.height では実サイズとズレるため
    // RenderBox の実サイズを優先する（オーバーレイ位置ズレ防止）。
    final fieldHeight = renderBox.size.height > 0
        ? renderBox.size.height
        : (widget.height ?? 48.0);
    final overlayWidth = fieldWidth < 300 ? 300.0 : fieldWidth;
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx,
        top: position.dy + fieldHeight,
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
              itemCount: _subProjectCandidates.length,
              itemBuilder: (context, idx) {
                final subProject = _subProjectCandidates[idx];
                final isNew = subProject.id == '__new__';
                final isSelected = idx == _selectedIndex;
                final isArchivedDimmed = !isNew &&
                    subProject.isArchived &&
                    AppSettingsService.archivedInSelectDisplayNotifier.value ==
                        'dimmed';

                return Container(
                  height: 36,
                  width: double.infinity,
                  color: isSelected
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity( 0.12)
                      : const Color(0x00000000),
                  child: Material(
                    color: const Color(0x00000000),
                    child: InkWell(
                      onTapDown: (_) {
                        if (_isSubmitting) return;
                        _isSubmitting = true;
                        _selectSubProject(subProject).whenComplete(() {
                          _isSubmitting = false;
                        });
                      },
                      onTap: () {
                        if (_isSubmitting) return;
                        _isSubmitting = true;
                        _selectSubProject(subProject).whenComplete(() {
                          _isSubmitting = false;
                        });
                      },
                      splashColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity( 0.2),
                      highlightColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity( 0.1),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: double.infinity,
                        height: 36,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            if (isNew)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Icon(
                                  Icons.add,
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                  size: 16,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                subProject.name,
                                style: TextStyle(
                                  fontSize: overlayFontSize,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: subProject.name.contains('を登録する')
                                      ? Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color
                                      : (isArchivedDimmed
                                          ? (Theme.of(context)
                                                  .textTheme
                                                  .bodyLarge
                                                  ?.color
                                              ?.withOpacity(0.5) ??
                                              Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withOpacity(0.5))
                                          : Theme.of(context)
                                              .textTheme
                                              .bodyLarge
                                              ?.color),
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
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

  void _updateOverlay() {
    if (_overlayEntry?.mounted ?? false) {
      _overlayEntry!.markNeedsBuild();
    }
  }

  Future<void> _selectSubProject(SubProject subProject) async {
    if (isImeComposing(widget.controller)) {
      return;
    }
    final isNew = subProject.id == '__new__';

    if (isNew) {
      await _handleNewSubProjectCreation();
      // 新規作成後はオーバーレイを再表示
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.hasFocus) {
          _showSubProjectCandidatesOverlay();
        }
      });
    } else {
      widget.onSubProjectChanged?.call(subProject.id, subProject.name);
      _suppressControllerListener = true;
      widget.controller.text = subProject.name;
      _suppressControllerListener = false;
      setState(() {
        _updateSubProjectCandidates();
      });
      _removeOverlay();
    }
  }

  Future<void> _handleSubProjectSubmission(String value) async {
    final input = value.trim();
    if (input.isEmpty) {
      // 入力が空ならサブプロジェクトを解除
      widget.onSubProjectChanged?.call(null, null);
      return;
    }

    if (widget.projectId == null) {
      widget.controller.clear();
      widget.onSubProjectChanged?.call(null, null);
      return;
    }

    final all = SubProjectService.getSubProjectsByProjectId(widget.projectId!);
    final exists = all.any(
      (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
    );

    if (exists) {
      final existing = all.firstWhere(
        (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
      );
      widget.onSubProjectChanged?.call(existing.id, existing.name);
      widget.controller.text = existing.name;
      return;
    }

    await _createNewSubProject(input);
  }

  Future<void> _handleNewSubProjectCreation() async {
    final input = widget.controller.text.trim();
    if (input.isEmpty) {
      widget.onSubProjectChanged?.call(null, null);
      return;
    }

    if (widget.projectId == null) {
      widget.controller.clear();
      widget.onSubProjectChanged?.call(null, null);
      return;
    }

    final all = SubProjectService.getSubProjectsByProjectId(widget.projectId!);
    final exists = all.any(
      (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
    );

    if (exists) {
      final existing = all.firstWhere(
        (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
      );
      widget.onSubProjectChanged?.call(existing.id, existing.name);
      widget.controller.text = existing.name;
      return;
    }

    await _createNewSubProject(input);
  }

  Future<void> _createNewSubProject(String name) async {
    if (widget.projectId == null) return;

    final newSubProject = SubProject(
      id: 'subproject_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      description: null,
      projectId: widget.projectId!,
      createdAt: DateTime.now(),
      lastModified: DateTime.now(),
      isArchived: false,
      userId: AuthService.getCurrentUserId() ?? '',
    );

    await SubProjectService.addSubProject(newSubProject);
    widget.onSubProjectChanged?.call(newSubProject.id, newSubProject.name);
    widget.controller.text = newSubProject.name;

    // 候補リストを更新
    setState(() {
      _updateSubProjectCandidates();
    });

    // オーバーレイを再表示
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.hasFocus) {
        _showSubProjectCandidatesOverlay();
      }
    });

    widget.onAutoSave?.call();
  }
}
