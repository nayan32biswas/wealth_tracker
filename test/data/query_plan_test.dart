import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/repositories/drift_transactions.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String> plan(String sql, [List<Variable> variables = const []]) async {
    final rows = await db.customSelect('EXPLAIN QUERY PLAN $sql', variables: variables).get();
    return rows.map((r) => r.read<String>('detail')).join('\n');
  }

  test('newest-first search walks the time index instead of sorting every row', () async {
    final search = await plan('SELECT * FROM "transaction" ORDER BY time DESC, id DESC LIMIT 200');

    expect(search, contains('idx_transaction_time'));
    expect(search, isNot(contains('USE TEMP B-TREE FOR ORDER BY')));
  });

  test('a month of activity is found through the date index', () async {
    final month = await plan(
      'SELECT * FROM "transaction" WHERE date >= \'2026-09-01\' AND date < \'2026-10-01\' ORDER BY time DESC',
    );

    expect(month, contains('idx_transaction_date'));
  });

  test('note suggestions read only the last year through the date index', () async {
    final suggestions = await plan(DriftTransactionRepository.noteSuggestionsSql, [
      Variable.withInt(-1),
      Variable.withString('2025-10-03'),
      Variable.withString('lu'),
      Variable.withString('lu%'),
      Variable.withString('% lu%'),
      Variable.withInt(8),
    ]);

    expect(suggestions, contains('idx_transaction_date'));
  });
}
