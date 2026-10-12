// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'history_db.dart';

// ignore_for_file: type=lint
class $HistoryEntriesTable extends HistoryEntries
    with TableInfo<$HistoryEntriesTable, HistoryEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cleanedMeta = const VerificationMeta(
    'cleaned',
  );
  @override
  late final GeneratedColumn<String> cleaned = GeneratedColumn<String>(
    'cleaned',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _verbatimMeta = const VerificationMeta(
    'verbatim',
  );
  @override
  late final GeneratedColumn<String> verbatim = GeneratedColumn<String>(
    'verbatim',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _engineMeta = const VerificationMeta('engine');
  @override
  late final GeneratedColumn<String> engine = GeneratedColumn<String>(
    'engine',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fellBackMeta = const VerificationMeta(
    'fellBack',
  );
  @override
  late final GeneratedColumn<bool> fellBack = GeneratedColumn<bool>(
    'fell_back',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("fell_back" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _stylePresetMeta = const VerificationMeta(
    'stylePreset',
  );
  @override
  late final GeneratedColumn<String> stylePreset = GeneratedColumn<String>(
    'style_preset',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('casual'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    durationMs,
    cleaned,
    verbatim,
    engine,
    fellBack,
    stylePreset,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<HistoryEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    } else if (isInserting) {
      context.missing(_durationMsMeta);
    }
    if (data.containsKey('cleaned')) {
      context.handle(
        _cleanedMeta,
        cleaned.isAcceptableOrUnknown(data['cleaned']!, _cleanedMeta),
      );
    } else if (isInserting) {
      context.missing(_cleanedMeta);
    }
    if (data.containsKey('verbatim')) {
      context.handle(
        _verbatimMeta,
        verbatim.isAcceptableOrUnknown(data['verbatim']!, _verbatimMeta),
      );
    }
    if (data.containsKey('engine')) {
      context.handle(
        _engineMeta,
        engine.isAcceptableOrUnknown(data['engine']!, _engineMeta),
      );
    } else if (isInserting) {
      context.missing(_engineMeta);
    }
    if (data.containsKey('fell_back')) {
      context.handle(
        _fellBackMeta,
        fellBack.isAcceptableOrUnknown(data['fell_back']!, _fellBackMeta),
      );
    }
    if (data.containsKey('style_preset')) {
      context.handle(
        _stylePresetMeta,
        stylePreset.isAcceptableOrUnknown(
          data['style_preset']!,
          _stylePresetMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      cleaned: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cleaned'],
      )!,
      verbatim: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}verbatim'],
      ),
      engine: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}engine'],
      )!,
      fellBack: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}fell_back'],
      )!,
      stylePreset: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}style_preset'],
      )!,
    );
  }

  @override
  $HistoryEntriesTable createAlias(String alias) {
    return $HistoryEntriesTable(attachedDatabase, alias);
  }
}

class HistoryEntry extends DataClass implements Insertable<HistoryEntry> {
  /// Same id as the recording in RecordingVault.
  final String id;
  final DateTime createdAt;
  final int durationMs;
  final String cleaned;

  /// Word-for-word transcript, filled lazily by "show original".
  final String? verbatim;

  /// `onDevice` or `gemini`.
  final String engine;
  final bool fellBack;
  final String stylePreset;
  const HistoryEntry({
    required this.id,
    required this.createdAt,
    required this.durationMs,
    required this.cleaned,
    this.verbatim,
    required this.engine,
    required this.fellBack,
    required this.stylePreset,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['duration_ms'] = Variable<int>(durationMs);
    map['cleaned'] = Variable<String>(cleaned);
    if (!nullToAbsent || verbatim != null) {
      map['verbatim'] = Variable<String>(verbatim);
    }
    map['engine'] = Variable<String>(engine);
    map['fell_back'] = Variable<bool>(fellBack);
    map['style_preset'] = Variable<String>(stylePreset);
    return map;
  }

  HistoryEntriesCompanion toCompanion(bool nullToAbsent) {
    return HistoryEntriesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      durationMs: Value(durationMs),
      cleaned: Value(cleaned),
      verbatim: verbatim == null && nullToAbsent
          ? const Value.absent()
          : Value(verbatim),
      engine: Value(engine),
      fellBack: Value(fellBack),
      stylePreset: Value(stylePreset),
    );
  }

  factory HistoryEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryEntry(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      cleaned: serializer.fromJson<String>(json['cleaned']),
      verbatim: serializer.fromJson<String?>(json['verbatim']),
      engine: serializer.fromJson<String>(json['engine']),
      fellBack: serializer.fromJson<bool>(json['fellBack']),
      stylePreset: serializer.fromJson<String>(json['stylePreset']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'durationMs': serializer.toJson<int>(durationMs),
      'cleaned': serializer.toJson<String>(cleaned),
      'verbatim': serializer.toJson<String?>(verbatim),
      'engine': serializer.toJson<String>(engine),
      'fellBack': serializer.toJson<bool>(fellBack),
      'stylePreset': serializer.toJson<String>(stylePreset),
    };
  }

  HistoryEntry copyWith({
    String? id,
    DateTime? createdAt,
    int? durationMs,
    String? cleaned,
    Value<String?> verbatim = const Value.absent(),
    String? engine,
    bool? fellBack,
    String? stylePreset,
  }) => HistoryEntry(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    durationMs: durationMs ?? this.durationMs,
    cleaned: cleaned ?? this.cleaned,
    verbatim: verbatim.present ? verbatim.value : this.verbatim,
    engine: engine ?? this.engine,
    fellBack: fellBack ?? this.fellBack,
    stylePreset: stylePreset ?? this.stylePreset,
  );
  HistoryEntry copyWithCompanion(HistoryEntriesCompanion data) {
    return HistoryEntry(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      cleaned: data.cleaned.present ? data.cleaned.value : this.cleaned,
      verbatim: data.verbatim.present ? data.verbatim.value : this.verbatim,
      engine: data.engine.present ? data.engine.value : this.engine,
      fellBack: data.fellBack.present ? data.fellBack.value : this.fellBack,
      stylePreset: data.stylePreset.present
          ? data.stylePreset.value
          : this.stylePreset,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryEntry(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('cleaned: $cleaned, ')
          ..write('verbatim: $verbatim, ')
          ..write('engine: $engine, ')
          ..write('fellBack: $fellBack, ')
          ..write('stylePreset: $stylePreset')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    durationMs,
    cleaned,
    verbatim,
    engine,
    fellBack,
    stylePreset,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryEntry &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.durationMs == this.durationMs &&
          other.cleaned == this.cleaned &&
          other.verbatim == this.verbatim &&
          other.engine == this.engine &&
          other.fellBack == this.fellBack &&
          other.stylePreset == this.stylePreset);
}

class HistoryEntriesCompanion extends UpdateCompanion<HistoryEntry> {
  final Value<String> id;
  final Value<DateTime> createdAt;
  final Value<int> durationMs;
  final Value<String> cleaned;
  final Value<String?> verbatim;
  final Value<String> engine;
  final Value<bool> fellBack;
  final Value<String> stylePreset;
  final Value<int> rowid;
  const HistoryEntriesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.cleaned = const Value.absent(),
    this.verbatim = const Value.absent(),
    this.engine = const Value.absent(),
    this.fellBack = const Value.absent(),
    this.stylePreset = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HistoryEntriesCompanion.insert({
    required String id,
    required DateTime createdAt,
    required int durationMs,
    required String cleaned,
    this.verbatim = const Value.absent(),
    required String engine,
    this.fellBack = const Value.absent(),
    this.stylePreset = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       durationMs = Value(durationMs),
       cleaned = Value(cleaned),
       engine = Value(engine);
  static Insertable<HistoryEntry> custom({
    Expression<String>? id,
    Expression<DateTime>? createdAt,
    Expression<int>? durationMs,
    Expression<String>? cleaned,
    Expression<String>? verbatim,
    Expression<String>? engine,
    Expression<bool>? fellBack,
    Expression<String>? stylePreset,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (cleaned != null) 'cleaned': cleaned,
      if (verbatim != null) 'verbatim': verbatim,
      if (engine != null) 'engine': engine,
      if (fellBack != null) 'fell_back': fellBack,
      if (stylePreset != null) 'style_preset': stylePreset,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HistoryEntriesCompanion copyWith({
    Value<String>? id,
    Value<DateTime>? createdAt,
    Value<int>? durationMs,
    Value<String>? cleaned,
    Value<String?>? verbatim,
    Value<String>? engine,
    Value<bool>? fellBack,
    Value<String>? stylePreset,
    Value<int>? rowid,
  }) {
    return HistoryEntriesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      durationMs: durationMs ?? this.durationMs,
      cleaned: cleaned ?? this.cleaned,
      verbatim: verbatim ?? this.verbatim,
      engine: engine ?? this.engine,
      fellBack: fellBack ?? this.fellBack,
      stylePreset: stylePreset ?? this.stylePreset,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (cleaned.present) {
      map['cleaned'] = Variable<String>(cleaned.value);
    }
    if (verbatim.present) {
      map['verbatim'] = Variable<String>(verbatim.value);
    }
    if (engine.present) {
      map['engine'] = Variable<String>(engine.value);
    }
    if (fellBack.present) {
      map['fell_back'] = Variable<bool>(fellBack.value);
    }
    if (stylePreset.present) {
      map['style_preset'] = Variable<String>(stylePreset.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryEntriesCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('cleaned: $cleaned, ')
          ..write('verbatim: $verbatim, ')
          ..write('engine: $engine, ')
          ..write('fellBack: $fellBack, ')
          ..write('stylePreset: $stylePreset, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$HistoryDb extends GeneratedDatabase {
  _$HistoryDb(QueryExecutor e) : super(e);
  $HistoryDbManager get managers => $HistoryDbManager(this);
  late final $HistoryEntriesTable historyEntries = $HistoryEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [historyEntries];
}

typedef $$HistoryEntriesTableCreateCompanionBuilder =
    HistoryEntriesCompanion Function({
      required String id,
      required DateTime createdAt,
      required int durationMs,
      required String cleaned,
      Value<String?> verbatim,
      required String engine,
      Value<bool> fellBack,
      Value<String> stylePreset,
      Value<int> rowid,
    });
typedef $$HistoryEntriesTableUpdateCompanionBuilder =
    HistoryEntriesCompanion Function({
      Value<String> id,
      Value<DateTime> createdAt,
      Value<int> durationMs,
      Value<String> cleaned,
      Value<String?> verbatim,
      Value<String> engine,
      Value<bool> fellBack,
      Value<String> stylePreset,
      Value<int> rowid,
    });

class $$HistoryEntriesTableFilterComposer
    extends Composer<_$HistoryDb, $HistoryEntriesTable> {
  $$HistoryEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cleaned => $composableBuilder(
    column: $table.cleaned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get verbatim => $composableBuilder(
    column: $table.verbatim,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get engine => $composableBuilder(
    column: $table.engine,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get fellBack => $composableBuilder(
    column: $table.fellBack,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stylePreset => $composableBuilder(
    column: $table.stylePreset,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HistoryEntriesTableOrderingComposer
    extends Composer<_$HistoryDb, $HistoryEntriesTable> {
  $$HistoryEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cleaned => $composableBuilder(
    column: $table.cleaned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get verbatim => $composableBuilder(
    column: $table.verbatim,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get engine => $composableBuilder(
    column: $table.engine,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get fellBack => $composableBuilder(
    column: $table.fellBack,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stylePreset => $composableBuilder(
    column: $table.stylePreset,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HistoryEntriesTableAnnotationComposer
    extends Composer<_$HistoryDb, $HistoryEntriesTable> {
  $$HistoryEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cleaned =>
      $composableBuilder(column: $table.cleaned, builder: (column) => column);

  GeneratedColumn<String> get verbatim =>
      $composableBuilder(column: $table.verbatim, builder: (column) => column);

  GeneratedColumn<String> get engine =>
      $composableBuilder(column: $table.engine, builder: (column) => column);

  GeneratedColumn<bool> get fellBack =>
      $composableBuilder(column: $table.fellBack, builder: (column) => column);

  GeneratedColumn<String> get stylePreset => $composableBuilder(
    column: $table.stylePreset,
    builder: (column) => column,
  );
}

class $$HistoryEntriesTableTableManager
    extends
        RootTableManager<
          _$HistoryDb,
          $HistoryEntriesTable,
          HistoryEntry,
          $$HistoryEntriesTableFilterComposer,
          $$HistoryEntriesTableOrderingComposer,
          $$HistoryEntriesTableAnnotationComposer,
          $$HistoryEntriesTableCreateCompanionBuilder,
          $$HistoryEntriesTableUpdateCompanionBuilder,
          (
            HistoryEntry,
            BaseReferences<_$HistoryDb, $HistoryEntriesTable, HistoryEntry>,
          ),
          HistoryEntry,
          PrefetchHooks Function()
        > {
  $$HistoryEntriesTableTableManager(_$HistoryDb db, $HistoryEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<String> cleaned = const Value.absent(),
                Value<String?> verbatim = const Value.absent(),
                Value<String> engine = const Value.absent(),
                Value<bool> fellBack = const Value.absent(),
                Value<String> stylePreset = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HistoryEntriesCompanion(
                id: id,
                createdAt: createdAt,
                durationMs: durationMs,
                cleaned: cleaned,
                verbatim: verbatim,
                engine: engine,
                fellBack: fellBack,
                stylePreset: stylePreset,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required DateTime createdAt,
                required int durationMs,
                required String cleaned,
                Value<String?> verbatim = const Value.absent(),
                required String engine,
                Value<bool> fellBack = const Value.absent(),
                Value<String> stylePreset = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HistoryEntriesCompanion.insert(
                id: id,
                createdAt: createdAt,
                durationMs: durationMs,
                cleaned: cleaned,
                verbatim: verbatim,
                engine: engine,
                fellBack: fellBack,
                stylePreset: stylePreset,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HistoryEntriesTable, HistoryEntry>(table),
                  BaseReferences<
                    _$HistoryDb,
                    $HistoryEntriesTable,
                    HistoryEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HistoryEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$HistoryDb,
      $HistoryEntriesTable,
      HistoryEntry,
      $$HistoryEntriesTableFilterComposer,
      $$HistoryEntriesTableOrderingComposer,
      $$HistoryEntriesTableAnnotationComposer,
      $$HistoryEntriesTableCreateCompanionBuilder,
      $$HistoryEntriesTableUpdateCompanionBuilder,
      (
        HistoryEntry,
        BaseReferences<_$HistoryDb, $HistoryEntriesTable, HistoryEntry>,
      ),
      HistoryEntry,
      PrefetchHooks Function()
    >;

class $HistoryDbManager {
  final _$HistoryDb _db;
  $HistoryDbManager(this._db);
  $$HistoryEntriesTableTableManager get historyEntries =>
      $$HistoryEntriesTableTableManager(_db, _db.historyEntries);
}
