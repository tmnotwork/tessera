import 'package:sqflite/sqflite.dart';

/// ローカルDBのバージョン（双方向同期用スキーマ）
const int kLocalDbVersion = 4;

/// 既存の knowledge_local はバージョン2で作成。バージョン3で local_* テーブルを追加。
Future<void> createLocalSyncTables(Database db) async {
  // 1) 科目
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_subjects (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      name TEXT NOT NULL,
      display_order INTEGER NOT NULL DEFAULT 0
    )
  ''');

  // 2) 知識
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_knowledge (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      subject_local_id INTEGER,
      subject TEXT,
      unit TEXT,
      content TEXT NOT NULL,
      description TEXT,
      display_order INTEGER,
      type TEXT DEFAULT 'grammar',
      construction INTEGER NOT NULL DEFAULT 0,
      author_comment TEXT,
      FOREIGN KEY (subject_local_id) REFERENCES local_subjects(local_id)
    )
  ''');

  // 3) 暗記カード
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_memorization_cards (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      subject_local_id INTEGER,
      knowledge_local_id INTEGER,
      unit TEXT,
      front_content TEXT NOT NULL,
      back_content TEXT,
      display_order INTEGER,
      FOREIGN KEY (subject_local_id) REFERENCES local_subjects(local_id),
      FOREIGN KEY (knowledge_local_id) REFERENCES local_knowledge(local_id)
    )
  ''');

  // 4) 問題
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_questions (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      knowledge_local_id INTEGER,
      question_type TEXT NOT NULL DEFAULT 'text_input',
      question_text TEXT NOT NULL,
      correct_answer TEXT NOT NULL,
      explanation TEXT,
      reference TEXT,
      choices TEXT,
      FOREIGN KEY (knowledge_local_id) REFERENCES local_knowledge(local_id)
    )
  ''');

  // 5) 四択選択肢
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_question_choices (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      question_local_id INTEGER NOT NULL,
      position INTEGER NOT NULL,
      choice_text TEXT NOT NULL,
      is_correct INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (question_local_id) REFERENCES local_questions(local_id)
    )
  ''');

  // 6) 知識タグマスタ
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_knowledge_tags (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      name TEXT NOT NULL UNIQUE,
      synced_at TEXT,
      created_at TEXT NOT NULL
    )
  ''');

  // 7) 知識-タグ 中間
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_knowledge_card_tags (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_knowledge_id INTEGER NOT NULL,
      tag_name TEXT NOT NULL,
      supabase_tag_id TEXT,
      synced INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (local_knowledge_id) REFERENCES local_knowledge(local_id)
    )
  ''');

  // 8) 暗記タグマスタ
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_memorization_tags (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      name TEXT NOT NULL UNIQUE,
      synced_at TEXT,
      created_at TEXT NOT NULL
    )
  ''');

  // 9) 暗記カード-タグ 中間
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_memorization_card_tags (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_memorization_card_id INTEGER NOT NULL,
      tag_name TEXT NOT NULL,
      supabase_tag_id TEXT,
      synced INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (local_memorization_card_id) REFERENCES local_memorization_cards(local_id)
    )
  ''');

  // 10) 問題-知識 中間
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_question_knowledge (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      question_local_id INTEGER NOT NULL,
      knowledge_local_id INTEGER NOT NULL,
      is_core INTEGER NOT NULL DEFAULT 0,
      synced INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (question_local_id) REFERENCES local_questions(local_id),
      FOREIGN KEY (knowledge_local_id) REFERENCES local_knowledge(local_id)
    )
  ''');

  // インデックス（supabase_id 照合用）
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_knowledge_supabase_id ON local_knowledge(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_subjects_supabase_id ON local_subjects(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_questions_supabase_id ON local_questions(supabase_id)');
}
