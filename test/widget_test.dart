// ルートは Supabase 初期化などが必要なため、ここでは最小のウィジェットのみ検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MaterialApp が描画できる', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('ok')),
      ),
    );
    expect(find.text('ok'), findsOneWidget);
  });
}
