import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/project.dart';
import '../services/app_settings_service.dart';
import '../services/project_service.dart';
import '../services/project_sync_service.dart';
import '../services/selection_frequency_service.dart';
import '../utils/input_method_guard.dart';
import '../utils/text_normalizer.dart';

class ProjectInputField extends StatefulWidget {
  final TextEditingController controller;
  final Function(String?)? onProjectChanged;
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
  final bool includeArchived;
  final bool showAllOnTap;
  final double? height; // 入力欄の高さ（未指定時はデフォルト36）
  // 文字サイズ（未指定なら従来値=12を維持）
  final double? fontSize;
  /// 指定時は入力欄の背景にこの色を使う（タイムラインで行背景と一致させる用）
  final Color? fillColor;

  const ProjectInputField({
    super.key,
    required this.controller,
    this.onProjectChanged,
    this.onAutoSave,
    this.hintText,
    this.labelText,
    this.floatingLabelBehavior,
    this.withBackground = true,
    this.useOutlineBorder = true,
    this.useThemeDecoration = false,
    this.allowIntrinsicHeight = false,
    this.contentPadding,
    this.includeArchived = true,
    this.showAllOnTap = false,
    this.height,
    this.fontSize,
    this.fillColor,
  });

  @override
  State<ProjectInputField> createState() => _ProjectInputFieldState();
}

class _ProjectInputFieldState extends State<ProjectInputField> {
  List<Project> _projectCandidates = [];
  OverlayEntry? _overlayEntry;
  final FocusNode _focusNode = FocusNode();
  final FocusNode _keyboardFocusNode = FocusNode(
    skipTraversal: true,
    canRequestFocus: false,
  );
  final ScrollController _overlayScrollController = ScrollController();

  int _selectedIndex = -1;
  bool _isSubmitting = false;
  bool _wasComposing = false;
  bool _suppressControllerListener = false;
  String _lastTextSnapshot = '';
  bool _ignoreNextSubmit = false;

  @override
  void initState() {
    super.initState();
    _updateProjectCandidates();
    _wasComposing = isImeComposing(widget.controller);
    _lastTextSnapshot = widget.controller.text;
    widget.controller.addListener(_handleControllerChange);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            _removeOverlay();
            // 入力が空ならクリアを通知
            if (widget.controller.text.trim().isEmpty) {
              widget.onProjectChanged?.call(null);
            }
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
    _overlayScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ProjectInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChange);
      _wasComposing = isImeComposing(widget.controller);
      _lastTextSnapshot = widget.controller.text;
      widget.controller.addListener(_handleControllerChange);
      _updateProjectCandidates();
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
    // IME確定(=composing終了)の直後は onChanged/onSubmitted がガードで戻り、
    // 「〜を登録する」候補の再表示が取りこぼされることがある。
    // composing → not composing の遷移を検知して候補のみ再表示する。
    final bool composing = isImeComposing(widget.controller);
    final currentText = widget.controller.text;
    // composing検出が環境によって不安定な場合でも、確定でTextが変わったタイミングで候補を再表示する。
    final bool textChanged = currentText != _lastTextSnapshot;
    if (_focusNode.hasFocus && _wasComposing && !composing) {
      _updateProjectCandidates();
      _removeOverlay();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_focusNode.hasFocus) return;
        if (isImeComposing(widget.controller)) return;
        _showProjectCandidatesOverlay();
      });
    } else if (_focusNode.hasFocus && textChanged && !composing) {
      _updateProjectCandidates();
      _removeOverlay();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_focusNode.hasFocus) return;
        if (isImeComposing(widget.controller)) return;
        _showProjectCandidatesOverlay();
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

  void _updateOverlay() {
    if (_overlayEntry?.mounted ?? false) {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _updateProjectCandidates({String? overrideInput}) {
    final all = ProjectService.getAllProjects();
    final rawInput = (overrideInput ?? widget.controller.text).trim();
    final input = rawInput.toLowerCase();
    final hasExact = all.any(
      (p) => p.name.trim().toLowerCase() == input && input.isNotEmpty,
    );
    // 部分一致: 未アーカイブ→アーカイブの順
    final Iterable<Project> active = all.where((p) => !p.isArchived);
    final Iterable<Project> archived = all.where((p) => p.isArchived);
    final List<Project> activeFiltered = input.isEmpty
        ? active.toList()
        : active.where((p) => matchesQuery(p.name, input)).toList();
    final List<Project> archivedFiltered = input.isEmpty
        ? archived.toList()
        : archived.where((p) => matchesQuery(p.name, input)).toList();

    void sortByFrequency(List<Project> list) {
      list.sort((a, b) {
        final fa = SelectionFrequencyService.getProjectCount(a.id);
        final fb = SelectionFrequencyService.getProjectCount(b.id);
        if (fb != fa) return fb.compareTo(fa);
        return a.name.compareTo(b.name);
      });
    }

    sortByFrequency(activeFiltered);
    sortByFrequency(archivedFiltered);

    final archivedMode =
        AppSettingsService.archivedInSelectDisplayNotifier.value;
    final showArchived =
        archivedMode == 'dimmed' && widget.includeArchived;

    _projectCandidates = [
      if (!hasExact && input.isNotEmpty)
        Project(
          id: '__new__',
          name: '$rawInput を登録する',
          description: null,
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
                    borderSide: BorderSide(
                      color: theme.dividerColor,
                    ),
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
                  _updateProjectCandidates();
                  if (_projectCandidates.isNotEmpty) {
                    setState(() {
                      _selectedIndex = 0;
                    });
                    _showProjectCandidatesOverlay();
                  }
                  return;
                }

                // EnterでIME確定した直後に候補が消えるケースへの保険:
                // 未登録の入力がある場合は、まず「〜を登録する」を表示して明示選択させる。
                if (event.logicalKey == LogicalKeyboardKey.enter &&
                    _overlayEntry == null &&
                    !_isSubmitting) {
                  _updateProjectCandidates();
                  if (_projectCandidates.isNotEmpty &&
                      _projectCandidates.first.id == '__new__') {
                    // このEnterは「IME確定/入力確定」であり、同じEnterでTextField側の
                    // onSubmittedも続けて発火しうる。そこで次のonSubmittedを1回だけ無視し、
                    // 「〜を登録する」を表示して明示選択させる。
                    _ignoreNextSubmit = true;
                    setState(() {
                      _selectedIndex = 0;
                    });
                    _showProjectCandidatesOverlay();
                    return;
                  }
                }

                if (_overlayEntry != null && _projectCandidates.isNotEmpty) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    setState(() {
                      _selectedIndex = _selectedIndex <= 0
                          ? _projectCandidates.length - 1
                          : _selectedIndex - 1;
                    });
                    _updateOverlay();
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _ensureSelectedVisible(),
                    );
                  } else if (event.logicalKey ==
                      LogicalKeyboardKey.arrowDown) {
                    setState(() {
                      _selectedIndex =
                          _selectedIndex >= _projectCandidates.length - 1
                              ? 0
                              : _selectedIndex + 1;
                    });
                    _updateOverlay();
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _ensureSelectedVisible(),
                    );
                  } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                    if (_selectedIndex >= 0 &&
                        _selectedIndex < _projectCandidates.length &&
                        !_isSubmitting) {
                      _isSubmitting = true;
                      _selectProject(
                        _projectCandidates[_selectedIndex],
                      ).whenComplete(() {
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
                    // 長いプロジェクト名が折り返すと高さ36pxで下が欠けるため、1行に固定して省略表示する
                    maxLines: 1,
                    // NOTE: `height: 1.0` や強制constraintsは環境によって文字の下側が欠けることがあるため使わない
                    style: TextStyle(fontSize: effectiveFontSize),
                    textAlign: TextAlign.left,
                    textAlignVertical: TextAlignVertical.center,
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
                                // 高さに応じて余白を調整（大きいほど広め）
                                vertical: effectiveHeight >= 44 ? 12.0 : 16.0,
                              )),
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
                        color: theme.hintColor,
                      ),
                      suffixIcon: const Icon(Icons.arrow_drop_down),
                    ),
                    onChanged: (value) {
                      _updateProjectCandidates();
                      _removeOverlay();
                      if (isImeComposing(widget.controller)) {
                        return;
                      }
                      if (value.trim().isEmpty) {
                        widget.onProjectChanged?.call(null);
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _showProjectCandidatesOverlay();
                        }
                      });
                    },
                    onTap: () {
                      if (widget.showAllOnTap) {
                        _updateProjectCandidates(overrideInput: '');
                      } else {
                        _updateProjectCandidates();
                      }
                      _removeOverlay();
                      if (isImeComposing(widget.controller)) {
                        return;
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _showProjectCandidatesOverlay();
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
                          _selectedIndex < _projectCandidates.length) {
                        await _selectProject(_projectCandidates[_selectedIndex]);
                        _isSubmitting = false;
                        if (!isImeComposing(widget.controller)) {
                          FocusScope.of(context).nextFocus();
                        }
                        return;
                      }

                      _removeOverlay();

                      final input = value.trim();
                      if (input.isEmpty) {
                        widget.onProjectChanged?.call(null);
                        _isSubmitting = false;
                        return;
                      }

                      // 既存があればそれを確定して次へ
                      final all = ProjectService.getAllProjects();
                      final existing = all.firstWhere(
                        (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
                        orElse: () => Project(
                          id: '__none__',
                          name: '',
                          description: null,
                          createdAt: DateTime.now(),
                          lastModified: DateTime.now(),
                          isArchived: false,
                          userId: '',
                        ),
                      );
                      if (existing.id != '__none__') {
                        widget.onProjectChanged?.call(existing.id);
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
                      _updateProjectCandidates(overrideInput: input);
                      setState(() {
                        _selectedIndex = 0;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (!_focusNode.hasFocus) return;
                        if (isImeComposing(widget.controller)) return;
                        _showProjectCandidatesOverlay();
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

  void _showProjectCandidatesOverlay() {
    _removeOverlay();

    if (_projectCandidates.isEmpty) return;
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
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              removeBottom: true,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                controller: _overlayScrollController,
                itemCount: _projectCandidates.length,
                itemBuilder: (context, idx) {
                  final project = _projectCandidates[idx];
                  final isNew = project.id == '__new__';
                  final isSelected = idx == _selectedIndex;
                  final isArchivedDimmed = !isNew &&
                      project.isArchived &&
                      AppSettingsService.archivedInSelectDisplayNotifier.value ==
                          'dimmed';

                  return Container(
                    height: 36,
                    width: double.infinity,
                    color: isSelected
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withOpacity( 0.12)
                        : const Color(0x00000000),
                    child: Material(
                      color: const Color(0x00000000),
                      child: InkWell(
                        onTapDown: (_) {
                          if (_isSubmitting) return;
                          _isSubmitting = true;
                          _selectProject(project).whenComplete(() {
                            _isSubmitting = false;
                          });
                        },
                        onTap: () {
                          if (_isSubmitting) return;
                          _isSubmitting = true;
                          _selectProject(project).whenComplete(() {
                            _isSubmitting = false;
                          });
                        },
                        splashColor: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity( 0.2),
                        highlightColor: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity( 0.1),
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
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary,
                                    size: 16,
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  project.name,
                                  style: TextStyle(
                                    fontSize: overlayFontSize,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: project.name.contains('を登録する')
                                        ? Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.color
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
                                            : Theme.of(
                                                context,
                                              ).textTheme.bodyLarge?.color),
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
      ),
    );
    overlay.insert(_overlayEntry!);
    // 初期選択を可視化
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _ensureSelectedVisible(),
    );
  }

  Future<void> _selectProject(Project project) async {
    if (isImeComposing(widget.controller)) {
      return;
    }
    final isNew = project.id == '__new__';

    if (isNew) {
      await _handleNewProjectCreation();
      // 新規作成後はオーバーレイを再表示
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.hasFocus) {
          _showProjectCandidatesOverlay();
        }
      });
    } else {
      widget.onProjectChanged?.call(project.id);
      _suppressControllerListener = true;
      widget.controller.text = project.name;
      _suppressControllerListener = false;
      setState(() {
        _updateProjectCandidates();
      });
      _removeOverlay();
    }
  }

  Future<void> _handleProjectSubmission(String value) async {
    final input = value.trim();
    if (input.isEmpty) return;

    final all = ProjectService.getAllProjects();
    final exists = all.any(
      (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
    );

    if (exists) {
      final existing = all.firstWhere(
        (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
      );
      widget.onProjectChanged?.call(existing.id);
      widget.controller.text = existing.name;
      return;
    }

    await _createNewProject(input);
  }

  Future<void> _handleNewProjectCreation() async {
    final input = widget.controller.text.trim();
    if (input.isEmpty) return;

    final all = ProjectService.getAllProjects();
    final exists = all.any(
      (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
    );

    if (exists) {
      final existing = all.firstWhere(
        (p) => p.name.trim().toLowerCase() == input.toLowerCase(),
      );
      widget.onProjectChanged?.call(existing.id);
      widget.controller.text = existing.name;
      return;
    }

    await _createNewProject(input);
  }

  Future<void> _createNewProject(String name) async {
    final created = await ProjectSyncService().createProjectWithSync(name);
    widget.onProjectChanged?.call(created.id);
    _suppressControllerListener = true;
    widget.controller.text = created.name;
    _suppressControllerListener = false;

    // 候補リストを更新
    setState(() {
      _updateProjectCandidates();
    });

    widget.onAutoSave?.call();
  }
}

extension on _ProjectInputFieldState {
  void _ensureSelectedVisible() {
    if (!_overlayScrollController.hasClients) return;
    if (_selectedIndex < 0 || _selectedIndex >= _projectCandidates.length)
      return;
    const double itemHeight = 36.0;
    final double target = _selectedIndex * itemHeight;
    final double viewTop = _overlayScrollController.offset;
    final double viewBottom = viewTop + 200.0; // maxHeight in overlay

    if (target < viewTop) {
      _overlayScrollController.animateTo(
        target.clamp(0, _overlayScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    } else if (target + itemHeight > viewBottom) {
      final desired = target + itemHeight - 200.0;
      _overlayScrollController.animateTo(
        desired.clamp(0, _overlayScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }
}
