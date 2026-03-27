import 'package:flutter/material.dart';

class RoutineTaskBlockNameInput extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String) onBlockNameSubmitted;

  const RoutineTaskBlockNameInput({
    super.key,
    required this.controller,
    required this.onBlockNameSubmitted,
  });

  @override
  State<RoutineTaskBlockNameInput> createState() =>
      _RoutineTaskBlockNameInputState();
}

class _RoutineTaskBlockNameInputState extends State<RoutineTaskBlockNameInput> {
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
          widget.onBlockNameSubmitted(currentValue);
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // フォントメトリクスは現在使用していない

        return SizedBox(
          width: double.infinity,
          height: 36,
          child: Container(
            height: 36,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  autofocus: false,
                  style: const TextStyle(fontSize: 12, height: 1.0), // 行間をなくす
                  textAlign: TextAlign.left,
                  textAlignVertical: TextAlignVertical.center, // 垂直中央配置を有効化
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true, // 必須設定に戻す
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 0.0, vertical: 16.0), // 描画領域をRow高さいっぱいに拡大
                    filled: true, // 背景を親の空間いっぱいに広げる
                    fillColor:
                        Theme.of(context).inputDecorationTheme.fillColor ??
                            Theme.of(context).colorScheme.surface,
                    constraints: const BoxConstraints(
                        minHeight: 36, maxHeight: 36), // 強制的に高さ制御
                  ),
                  onChanged: (value) {
                    // onChangedは多数回発生するので、ここでは更新しない
                  },
                  onSubmitted: (value) {
                    widget.onBlockNameSubmitted(value);
                  },
                  onEditingComplete: () {
                    widget.onBlockNameSubmitted(widget.controller.text);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}
