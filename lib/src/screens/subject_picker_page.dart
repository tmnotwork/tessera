import 'package:flutter/material.dart';

import '../database/local_database.dart';
import 'english_example_list_screen.dart';
import 'knowledge_list_screen.dart';
import 'memorization_list_screen.dart';

/// 知識DB / 暗記DB 用の科目選択ページで使う DB 種別
enum TeacherDbType { knowledge, memorization }

/// 知識DB / 暗記DB 用の科目選択ページ
class SubjectPickerPage extends StatelessWidget {
  const SubjectPickerPage({
    super.key,
    required this.subjects,
    required this.title,
    required this.dbType,
    this.localDatabase,
  });

  final List<Map<String, dynamic>> subjects;
  final String title;
  final TeacherDbType dbType;
  final LocalDatabase? localDatabase;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: subjects.isEmpty
          ? const Center(child: Text('科目がありません'))
          : ListView.separated(
              itemCount: subjects.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = subjects[index];
                final subjectId = s['id'] as String?;
                final subjectName = s['name']?.toString() ?? '科目';
                if (subjectId == null) return const SizedBox.shrink();
                return ListTile(
                  title: Text(subjectName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (dbType == TeacherDbType.knowledge) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => KnowledgeListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                            localDatabase: localDatabase,
                          ),
                        ),
                      );
                    } else if (dbType == TeacherDbType.memorization) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => MemorizationListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => EnglishExampleListScreen(
                            subjectId: subjectId,
                            subjectName: subjectName,
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}
