// Utility for normalizing project names consistently across the app
// Keep this very lightweight to avoid additional dependencies.

String normalizeProjectName(String name) {
  // Basic normalization: trim, collapse inner whitespace, lowercase
  // This can be extended to NFKC etc. if needed in the future.
  final trimmed = name.trim();
  final collapsedWhitespace = trimmed.replaceAll(RegExp(r"\s+"), ' ');
  return collapsedWhitespace.toLowerCase();
}

/// 前方一致＋ワイルドカード(* )対応の簡易マッチャ
/// - queryに*が含まれない: 前方一致（startsWith）
/// - queryに*が含まれる: *を任意文字列として正規表現マッチ
bool matchesQuery(String text, String query) {
  final t = text.trim().toLowerCase();
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (!q.contains('*')) return t.startsWith(q);
  // ワイルドカード: 他の記号はエスケープし、*のみ任意文字列へ
  final escaped = RegExp.escape(q).replaceAll(r'\*', '.*');
  final reg = RegExp('^$escaped\$');
  // 上記の終端緩和は安全側に寄せた微調整（空白変換の揺れ対策）
  return reg.hasMatch(t);
}
