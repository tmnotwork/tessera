import 'package:flutter/material.dart';

class RoutineTaskNameInput extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String) onNameSubmitted;

  const RoutineTaskNameInput({
    super.key,
    required this.controller,
    required this.onNameSubmitted,
  });

  @override
  State<RoutineTaskNameInput> createState() => _RoutineTaskNameInputState();
}

class _RoutineTaskNameInputState extends State<RoutineTaskNameInput> {
  final FocusNode _focusNode = FocusNode();
  String _lastValue = '';

  @override
  void initState() {
    super.initState();
    _lastValue = widget.controller.text;
    _focusNode.addListener(() {
      // フォーカスが外れた時の処理
      if (!_focusNode.hasFocus) {
        final currentValue = widget.controller.text;

        // 値が変更されていれば、コールバックを呼ぶ
        if (currentValue != _lastValue) {
          widget.onNameSubmitted(currentValue);
          _lastValue = currentValue;
        }
      } else {
        // フォーカスを得た時に現在の値を記録
        _lastValue = widget.controller.text;
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  // RoutineTaskNameInputのbuildメソッド
  @override
  Widget build(BuildContext context) {
    // このウィジェットはTextFieldを返すだけ。SizedBoxで囲まない。
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: double.infinity,
          height: 36,
          child: TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            autofocus: false,
            style: const TextStyle(fontSize: 12, height: 1.0), // 行間をなくす
            textAlign: TextAlign.left,
            textAlignVertical: TextAlignVertical.center, // 垂直中央配置を有効化
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true, // 隠れた内部余白を無効化（必須）
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10.0, vertical: 16.0), // 描画領域をRow高さいっぱいに拡大
              filled: true, // 背景を親の空間いっぱいに広げる
              fillColor: Theme.of(context).inputDecorationTheme.fillColor ??
                  Theme.of(context).colorScheme.surface,
              constraints: const BoxConstraints(
                  minHeight: 36, maxHeight: 36), // 強制的に高さ制御
            ),
            onChanged: (value) {
              // onChangedは多数回発生するので、ここでは更新しない
            },
            onSubmitted: (value) {
              widget.onNameSubmitted(value);
            },
            onEditingComplete: () {
              widget.onNameSubmitted(widget.controller.text);
            },
          ),
        );
      },
    );
  }
}
