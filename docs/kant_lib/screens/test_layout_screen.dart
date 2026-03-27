import 'package:flutter/material.dart';
import '../widgets/routine_task_block_name_input.dart';
import '../widgets/routine_task_name_input.dart';
import '../widgets/project_input_field.dart';

class TestLayoutScreen extends StatefulWidget {
  const TestLayoutScreen({super.key});

  @override
  State<TestLayoutScreen> createState() => _TestLayoutScreenState();
}

class _TestLayoutScreenState extends State<TestLayoutScreen> {
  final TextEditingController _blockController = TextEditingController();
  final TextEditingController _taskController = TextEditingController();
  final TextEditingController _projectController = TextEditingController();

  @override
  void dispose() {
    _blockController.dispose();
    _taskController.dispose();
    _projectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('レイアウトテスト'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'レイアウト問題の検証（表形式）',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),

            // 単純な表形式のテスト（TextFieldを敷き詰め）
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  // ヘッダー行
                  Container(
                    height: 35,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(8),
                        topRight: Radius.circular(8),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right:
                                    BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary
                                          .withOpacity(0.7),
                                      width: 1,
                                    ),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'ブロック名',
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right:
                                    BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary
                                          .withOpacity(0.7),
                                      width: 1,
                                    ),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'タスク名',
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            child: Center(
                              child: Text(
                                'プロジェクト',
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // テスト行1: 単純なTextField（敷き詰め）
                  Container(
                    height: 35,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom:
                            BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: const TextField(
                              style: TextStyle(fontSize: 12),
                              textAlignVertical: TextAlignVertical.center,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                filled: false,
                                isDense: true,
                                constraints: BoxConstraints(maxHeight: 35),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: const TextField(
                              style: TextStyle(fontSize: 12),
                              textAlignVertical: TextAlignVertical.center,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                filled: false,
                                isDense: true,
                                constraints: BoxConstraints(maxHeight: 35),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            child: const TextField(
                              style: TextStyle(fontSize: 12),
                              textAlignVertical: TextAlignVertical.center,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                filled: false,
                                isDense: true,
                                constraints: BoxConstraints(maxHeight: 35),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // テスト行2: カスタムウィジェット
                  Container(
                    height: 35,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom:
                            BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: RoutineTaskBlockNameInput(
                              controller: _blockController,
                              onBlockNameSubmitted: (value) {},
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: RoutineTaskNameInput(
                              controller: _taskController,
                              onNameSubmitted: (value) {},
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            child: ProjectInputField(
                              controller: _projectController,
                              onProjectChanged: (projectId) {},
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // テスト行3: 実際のルーティン画面と同じ構造
                  Container(
                    height: 35,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom:
                            BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: RoutineTaskBlockNameInput(
                              controller: _blockController,
                              onBlockNameSubmitted: (value) {},
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Container(
                            height: 35,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor),
                              ),
                            ),
                            child: RoutineTaskNameInput(
                              controller: _taskController,
                              onNameSubmitted: (value) {},
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Container(
                            height: 35,
                            child: ProjectInputField(
                              controller: _projectController,
                              onProjectChanged: (projectId) {
                                print(
                                    'ProjectInputField in table changed: $projectId');
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // PlutoGridを使ったテスト表
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DataTableテスト表:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  SizedBox(
                    height: 200,
                    child: DataTableTest(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // 問題の説明
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '問題の確認:',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 10),
                    Text('• 非アクティブ時: 入力欄が下揃えになっているか？'),
                    Text('• アクティブ時: 入力欄が極端に細くなっていないか？'),
                    Text('• 文字が中央に表示されているか？'),
                    Text('• 高さが35pxで統一されているか？'),
                    Text('• 候補機能が正常に動作するか？'),
                    Text('• カーソルでの移動が正常に動作するか？'),
                    Text('• DataTable内での入力欄の動作は正常か？'),
                  ]),
            ),

            const SizedBox(height: 20),

            // 使用方法の説明
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '使用方法:',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 10),
                    Text('• 各入力欄をタップしてフォーカスを確認'),
                    Text('• 文字を入力して中央揃えを確認'),
                    Text('• プロジェクト欄で候補を選択'),
                    Text('• キーボードの矢印キーで移動を確認'),
                  ]),
            ),
          ],
        ),
      ),
    );
  }
}

class DataTableTest extends StatefulWidget {
  const DataTableTest({super.key});

  @override
  State<DataTableTest> createState() => _DataTableTestState();
}

class _DataTableTestState extends State<DataTableTest> {
  final TextEditingController _blockController1 = TextEditingController();
  final TextEditingController _taskController1 = TextEditingController();
  final TextEditingController _projectController1 = TextEditingController();
  final TextEditingController _blockController2 = TextEditingController();
  final TextEditingController _taskController2 = TextEditingController();
  final TextEditingController _projectController2 = TextEditingController();

  @override
  void dispose() {
    _blockController1.dispose();
    _taskController1.dispose();
    _projectController1.dispose();
    _blockController2.dispose();
    _taskController2.dispose();
    _projectController2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DataTable(
      columns: const [
        DataColumn(label: Text('ブロック名')),
        DataColumn(label: Text('タスク名')),
        DataColumn(label: Text('プロジェクト')),
      ],
      rows: [
        DataRow(
          cells: [
            DataCell(
              Container(
                height: 35,
                child: TextField(
                  controller: _blockController1,
                  style: const TextStyle(fontSize: 12),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    filled: false,
                  ),
                ),
              ),
            ),
            DataCell(
              Container(
                height: 35,
                child: TextField(
                  controller: _taskController1,
                  style: const TextStyle(fontSize: 12),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    filled: false,
                  ),
                ),
              ),
            ),
            DataCell(
              Container(
                height: 35,
                child: ProjectInputField(
                  controller: _projectController1,
                  onProjectChanged: (projectId) {},
                ),
              ),
            ),
          ],
        ),
        DataRow(
          cells: [
            DataCell(
              Container(
                height: 35,
                child: TextField(
                  controller: _blockController2,
                  style: const TextStyle(fontSize: 12),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    filled: false,
                  ),
                ),
              ),
            ),
            DataCell(
              Container(
                height: 35,
                child: TextField(
                  controller: _taskController2,
                  style: const TextStyle(fontSize: 12),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    filled: false,
                  ),
                ),
              ),
            ),
            DataCell(
              Container(
                height: 35,
                child: ProjectInputField(
                  controller: _projectController2,
                  onProjectChanged: (projectId) {},
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
