import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/edit_intents.dart';

enum EnglishExampleEditAction { cancel, save, delete }

class EnglishExampleEditOutcome {
  const EnglishExampleEditOutcome._({
    required this.action,
    this.savePayload,
  });

  final EnglishExampleEditAction action;
  final Map<String, dynamic>? savePayload;

  const EnglishExampleEditOutcome.cancel()
    : this._(action: EnglishExampleEditAction.cancel);

  const EnglishExampleEditOutcome.delete()
    : this._(action: EnglishExampleEditAction.delete);

  const EnglishExampleEditOutcome.save(Map<String, dynamic> payload)
    : this._(action: EnglishExampleEditAction.save, savePayload: payload);
}

class EnglishExampleEditScreen extends StatefulWidget {
  const EnglishExampleEditScreen({
    super.key,
    required this.knowledgeCandidates,
    this.current,
    this.presetKnowledgeId,
  });

  final List<Map<String, dynamic>> knowledgeCandidates;
  final Map<String, dynamic>? current;
  final String? presetKnowledgeId;

  @override
  State<EnglishExampleEditScreen> createState() => _EnglishExampleEditScreenState();
}

class _EnglishExampleEditScreenState extends State<EnglishExampleEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _frontJaController;
  late final TextEditingController _backEnController;
  late final TextEditingController _explanationController;
  late final TextEditingController _supplementController;
  late final TextEditingController _promptSupplementController;
  late final TextEditingController _displayOrderController;

  String? _selectedKnowledgeId;
  bool _saving = false;

  bool get _isEdit => widget.current != null;

  @override
  void initState() {
    super.initState();

    final current = widget.current;
    _frontJaController = TextEditingController(
      text: current?['front_ja']?.toString() ?? '',
    );
    _backEnController = TextEditingController(
      text: current?['back_en']?.toString() ?? '',
    );
    _explanationController = TextEditingController(
      text: current?['explanation']?.toString() ?? '',
    );
    _supplementController = TextEditingController(
      text: current?['supplement']?.toString() ?? '',
    );
    _promptSupplementController = TextEditingController(
      text: current?['prompt_supplement']?.toString() ?? '',
    );
    _displayOrderController = TextEditingController(
      text: current?['display_order']?.toString() ?? '',
    );

    final currentKnowledgeId = current?['knowledge_id']?.toString();
    _selectedKnowledgeId = currentKnowledgeId ?? widget.presetKnowledgeId;

    if (!_hasKnowledge(_selectedKnowledgeId) && widget.knowledgeCandidates.isNotEmpty) {
      _selectedKnowledgeId = widget.knowledgeCandidates.first['id']?.toString();
    }
  }

  @override
  void dispose() {
    _frontJaController.dispose();
    _backEnController.dispose();
    _explanationController.dispose();
    _supplementController.dispose();
    _promptSupplementController.dispose();
    _displayOrderController.dispose();
    super.dispose();
  }

  bool _hasKnowledge(String? id) {
    if (id == null || id.isEmpty) return false;
    return widget.knowledgeCandidates.any((row) => row['id']?.toString() == id);
  }

  String _knowledgeLabel(Map<String, dynamic> row) {
    final unit = row['unit']?.toString().trim();
    final content = row['content']?.toString().trim();
    if (unit != null && unit.isNotEmpty && content != null && content.isNotEmpty) {
      return '$unit / $content';
    }
    if (content != null && content.isNotEmpty) return content;
    return '（無題）';
  }

  int? _parseDisplayOrder() {
    final raw = _displayOrderController.text.trim();
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_selectedKnowledgeId == null || _selectedKnowledgeId!.isEmpty) return;

    final displayOrder = _parseDisplayOrder();
    if (_displayOrderController.text.trim().isNotEmpty && displayOrder == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('表示順は整数で入力してください。')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{
        'knowledge_id': _selectedKnowledgeId,
        'front_ja': _frontJaController.text.trim(),
        'back_en': _backEnController.text.trim(),
        'explanation': _nullable(_explanationController.text),
        'supplement': _nullable(_supplementController.text),
        'prompt_supplement': _nullable(_promptSupplementController.text),
        'display_order': displayOrder,
      };
      if (!mounted) return;
      Navigator.of(context).pop(EnglishExampleEditOutcome.save(payload));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _nullable(String value) {
    final v = value.trim();
    return v.isEmpty ? null : v;
  }

  void _cancel() {
    Navigator.of(context).pop(const EnglishExampleEditOutcome.cancel());
  }

  void _delete() {
    Navigator.of(context).pop(const EnglishExampleEditOutcome.delete());
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '英語例文を編集' : '英語例文を追加'),
        leading: IconButton(
          onPressed: _saving ? null : _cancel,
          icon: const Icon(Icons.close),
          tooltip: '閉じる',
        ),
        actions: [
          Tooltip(
            message: '保存（Ctrl+S / ⌘S）',
            child: TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
          if (_isEdit)
            IconButton(
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: '削除',
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedKnowledgeId,
              decoration: const InputDecoration(
                labelText: '知識カード',
                border: OutlineInputBorder(),
              ),
              items: widget.knowledgeCandidates
                  .map(
                    (row) => DropdownMenuItem<String>(
                      value: row['id']?.toString(),
                      child: Text(
                        _knowledgeLabel(row),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _selectedKnowledgeId = value),
              validator: (v) => (v == null || v.isEmpty) ? '知識カードを選択してください' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _frontJaController,
              decoration: const InputDecoration(
                labelText: '日本語',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              validator: (v) => (v == null || v.trim().isEmpty) ? '日本語を入力してください' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _backEnController,
              decoration: const InputDecoration(
                labelText: '英語',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              validator: (v) => (v == null || v.trim().isEmpty) ? '英語を入力してください' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _promptSupplementController,
              decoration: const InputDecoration(
                labelText: 'ヒント（任意）',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _supplementController,
              decoration: const InputDecoration(
                labelText: '補足（任意）',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _explanationController,
              decoration: const InputDecoration(
                labelText: '解説（任意）',
                border: OutlineInputBorder(),
              ),
              maxLines: 6,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _displayOrderController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '表示順（任意）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            Tooltip(
              message: '保存（Ctrl+S / ⌘S）',
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? '保存中...' : '保存'),
              ),
            ),
          ],
        ),
      ),
    );

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): SaveIntent(),
      },
      child: Actions(
        actions: {
          SaveIntent: CallbackAction<SaveIntent>(
            onInvoke: (_) {
              if (_saving) return null;
              _save();
              return null;
            },
          ),
        },
        child: scaffold,
      ),
    );
  }
}
