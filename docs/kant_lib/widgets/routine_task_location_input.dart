import 'package:flutter/material.dart';

class RoutineTaskLocationInput extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String) onLocationSubmitted;

  const RoutineTaskLocationInput({
    super.key,
    required this.controller,
    required this.onLocationSubmitted,
  });

  @override
  State<RoutineTaskLocationInput> createState() => _RoutineTaskLocationInputState();
}

class _RoutineTaskLocationInputState extends State<RoutineTaskLocationInput> {
  final FocusNode _focusNode = FocusNode();
  String _lastValue = '';

  @override
  void initState() {
    super.initState();
    _lastValue = widget.controller.text;
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        final currentValue = widget.controller.text;
        if (currentValue != _lastValue) {
          widget.onLocationSubmitted(currentValue);
          _lastValue = currentValue;
        }
      } else {
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
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: false,
        style: const TextStyle(fontSize: 12, height: 1.0),
        textAlign: TextAlign.left,
        textAlignVertical: TextAlignVertical.center,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 16.0),
          filled: true,
          fillColor: Theme.of(context).inputDecorationTheme.fillColor ?? Theme.of(context).colorScheme.surface,
          hintText: '未設定',
          hintStyle: TextStyle(
            fontSize: 12,
            color: Theme.of(context).hintColor,
          ),
          constraints: const BoxConstraints(minHeight: 36, maxHeight: 36),
        ),
        onSubmitted: (value) => widget.onLocationSubmitted(value),
        onEditingComplete: () => widget.onLocationSubmitted(widget.controller.text),
      ),
    );
  }
}

