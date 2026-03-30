import 'package:sqflite/sqflite.dart';

/// ローカルDBのバージョン（双方向同期用スキーマ）
const int kLocalDbVersion = 12;

/// 勉強時間セッション（ローカル + SyncEngine から Supabase へ Push / Pull）
Future<void> createStudySessionsTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS study_sessions (
      local_id      INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id   TEXT UNIQUE,
      dirty         INTEGER NOT NULL DEFAULT 1,
      deleted       INTEGER NOT NULL DEFAULT 0,
      synced_at     TEXT,
      updated_at    TEXT NOT NULL DEFAULT '',
      session_type  TEXT NOT NULL,
      content_id    TEXT,
      content_title TEXT,
      unit          TEXT,
      subject_id    TEXT,
      subject_name  TEXT,
      tts_sec       INTEGER NOT NULL DEFAULT 0,
      started_at    TEXT NOT NULL,
      ended_at      TEXT,
      duration_sec  INTEGER,
      created_at    TEXT NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_study_sessions_started_at ON study_sessions(started_at)',
  );
}

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
      dev_completed INTEGER NOT NULL DEFAULT 0,
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
      dev_completed INTEGER NOT NULL DEFAULT 0,
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

  // 6) 知識タグマスタ（他テーブルと同様、Pull 時は upsertBySupabaseId が dirty/deleted/updated_at を書く）
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_knowledge_tags (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 0,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      name TEXT NOT NULL UNIQUE
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
      dirty INTEGER NOT NULL DEFAULT 0,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      name TEXT NOT NULL UNIQUE
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

  // 11) 四択解答ログ
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_question_answer_logs (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      learner_id TEXT NOT NULL,
      question_local_id INTEGER NOT NULL,
      selected_choice_text TEXT,
      selected_index INTEGER,
      is_correct INTEGER NOT NULL DEFAULT 0,
      answered_at TEXT NOT NULL,
      FOREIGN KEY (question_local_id) REFERENCES local_questions(local_id)
    )
  ''');

  // 12) 四択学習状態（忘却曲線）
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_question_learning_states (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      learner_id TEXT NOT NULL,
      question_local_id INTEGER NOT NULL,
      question_supabase_id TEXT,
      stability REAL NOT NULL DEFAULT 1.0,
      difficulty REAL NOT NULL DEFAULT 0.5,
      retrievability REAL NOT NULL DEFAULT 0.5,
      success_streak INTEGER NOT NULL DEFAULT 0,
      lapse_count INTEGER NOT NULL DEFAULT 0,
      reviewed_count INTEGER NOT NULL DEFAULT 0,
      last_is_correct INTEGER,
      last_selected_choice_text TEXT,
      last_selected_index INTEGER,
      last_review_at TEXT,
      next_review_at TEXT NOT NULL,
      FOREIGN KEY (question_local_id) REFERENCES local_questions(local_id),
      UNIQUE (learner_id, question_local_id)
    )
  ''');

  // インデックス（supabase_id 照合用）
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_knowledge_supabase_id ON local_knowledge(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_subjects_supabase_id ON local_subjects(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_questions_supabase_id ON local_questions(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_question_answer_logs_supabase_id ON local_question_answer_logs(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_question_learning_states_supabase_id ON local_question_learning_states(supabase_id)');
  await db.execute('CREATE INDEX IF NOT EXISTS ix_local_question_learning_states_due ON local_question_learning_states(learner_id, next_review_at)');

  await createEnglishExampleStateTables(db);
}

/// 英語例文 SM-2・英作文の学習状態（ローカル主、SyncEngine で Pull/Push）
Future<void> createEnglishExampleStateTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_english_example_learning_states (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      learner_id TEXT NOT NULL,
      example_supabase_id TEXT NOT NULL,
      repetitions INTEGER NOT NULL DEFAULT 0,
      e_factor REAL NOT NULL DEFAULT 2.5,
      interval_days INTEGER NOT NULL DEFAULT 0,
      next_review_at TEXT NOT NULL,
      last_quality INTEGER,
      reviewed_count INTEGER NOT NULL DEFAULT 0,
      UNIQUE (learner_id, example_supabase_id)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_local_eels_supabase_id ON local_english_example_learning_states(supabase_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_local_eels_learner_example ON local_english_example_learning_states(learner_id, example_supabase_id)',
  );

  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_english_example_composition_states (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      supabase_id TEXT UNIQUE,
      dirty INTEGER NOT NULL DEFAULT 1,
      deleted INTEGER NOT NULL DEFAULT 0,
      synced_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      learner_id TEXT NOT NULL,
      example_supabase_id TEXT NOT NULL,
      last_answer_correct INTEGER,
      last_self_remembered INTEGER,
      attempts INTEGER NOT NULL DEFAULT 0,
      correct_count INTEGER NOT NULL DEFAULT 0,
      remembered_count INTEGER NOT NULL DEFAULT 0,
      forgot_count INTEGER NOT NULL DEFAULT 0,
      UNIQUE (learner_id, example_supabase_id)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_local_eecs_supabase_id ON local_english_example_composition_states(supabase_id)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_local_eecs_learner_example ON local_english_example_composition_states(learner_id, example_supabase_id)',
  );
}
