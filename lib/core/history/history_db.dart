// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/drift.dart';

part 'history_db.g.dart';

@DataClassName('HistoryEntry')
class HistoryEntries extends Table {
  /// Same id as the recording in RecordingVault.
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get durationMs => integer()();
  TextColumn get cleaned => text()();

  /// Word-for-word transcript, filled lazily by "show original".
  TextColumn get verbatim => text().nullable()();

  /// `onDevice` or `gemini`.
  TextColumn get engine => text()();
  BoolColumn get fellBack => boolean().withDefault(const Constant(false))();
  TextColumn get stylePreset => text().withDefault(const Constant('casual'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(tables: [HistoryEntries])
class HistoryDb extends _$HistoryDb {
  HistoryDb(super.executor);

  @override
  int get schemaVersion => 1;

  Future<void> upsert(HistoryEntriesCompanion entry) =>
      into(historyEntries).insertOnConflictUpdate(entry);

  /// Newest first. [query] matches cleaned or verbatim text, case-insensitive.
  Stream<List<HistoryEntry>> watch({String query = ''}) {
    final q = select(historyEntries)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    final term = query.trim();
    if (term.isNotEmpty) {
      final like = '%${term.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      q.where((t) => t.cleaned.like(like) | t.verbatim.like(like));
    }
    return q.watch();
  }

  Future<HistoryEntry?> byId(String id) =>
      (select(historyEntries)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> setVerbatim(String id, String text) =>
      (update(historyEntries)..where((t) => t.id.equals(id)))
          .write(HistoryEntriesCompanion(verbatim: Value(text)));

  Future<int> deleteEntry(String id) =>
      (delete(historyEntries)..where((t) => t.id.equals(id))).go();

  Future<int> deleteAll() => delete(historyEntries).go();
}
