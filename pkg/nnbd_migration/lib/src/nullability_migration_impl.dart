// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:nnbd_migration/instrumentation.dart';
import 'package:nnbd_migration/nnbd_migration.dart';
import 'package:nnbd_migration/src/decorated_class_hierarchy.dart';
import 'package:nnbd_migration/src/decorated_type.dart';
import 'package:nnbd_migration/src/edge_builder.dart';
import 'package:nnbd_migration/src/edit_plan.dart';
import 'package:nnbd_migration/src/fix_aggregator.dart';
import 'package:nnbd_migration/src/fix_builder.dart';
import 'package:nnbd_migration/src/messages.dart';
import 'package:nnbd_migration/src/node_builder.dart';
import 'package:nnbd_migration/src/nullability_node.dart';
import 'package:nnbd_migration/src/postmortem_file.dart';
import 'package:nnbd_migration/src/variables.dart';

/// Implementation of the [NullabilityMigration] public API.
class NullabilityMigrationImpl implements NullabilityMigration {
  /// Set this constant to a pathname to cause nullability migration to output
  /// a post-mortem file that can be later examined by tool/postmortem.dart.
  static const String _postmortemPath = null;

  final NullabilityMigrationListener listener;

  Variables _variables;

  final NullabilityGraph _graph;

  final bool _permissive;

  final NullabilityMigrationInstrumentation _instrumentation;

  DecoratedClassHierarchy _decoratedClassHierarchy;

  bool _propagated = false;

  /// Indicates whether code removed by the migration engine should be removed
  /// by commenting it out.  A value of `false` means to actually delete the
  /// code that is removed.
  final bool removeViaComments;

  final _decoratedTypeParameterBounds = DecoratedTypeParameterBounds();

  /// If not `null`, the object that will be used to write out post-mortem
  /// information once migration is complete.
  final PostmortemFileWriter _postmortemFileWriter =
      _makePostmortemFileWriter();

  /// Prepares to perform nullability migration.
  ///
  /// If [permissive] is `true`, exception handling logic will try to proceed
  /// as far as possible even though the migration algorithm is not yet
  /// complete.  TODO(paulberry): remove this mode once the migration algorithm
  /// is fully implemented.
  ///
  /// Optional parameter [removeViaComments] indicates whether dead code should
  /// be removed in its entirety (the default) or removed by commenting it out.
  NullabilityMigrationImpl(NullabilityMigrationListener listener,
      {bool permissive: false,
      NullabilityMigrationInstrumentation instrumentation,
      bool removeViaComments = true})
      : this._(listener, NullabilityGraph(instrumentation: instrumentation),
            permissive, instrumentation, removeViaComments);

  NullabilityMigrationImpl._(this.listener, this._graph, this._permissive,
      this._instrumentation, this.removeViaComments) {
    _instrumentation?.immutableNodes(_graph.never, _graph.always);
    _postmortemFileWriter?.graph = _graph;
  }

  @override
  bool get isPermissive => _permissive;

  @override
  void finalizeInput(ResolvedUnitResult result) {
    _sanityCheck(result);
    if (!_propagated) {
      _propagated = true;
      _graph.propagate(_postmortemFileWriter);
    }
    var unit = result.unit;
    var compilationUnit = unit.declaredElement;
    var library = compilationUnit.library;
    var source = compilationUnit.source;
    var fixBuilder = FixBuilder(
        source,
        _decoratedClassHierarchy,
        result.typeProvider,
        library.typeSystem as TypeSystemImpl,
        _variables,
        library,
        listener,
        unit);
    try {
      DecoratedTypeParameterBounds.current = _decoratedTypeParameterBounds;
      fixBuilder.visitAll();
    } finally {
      DecoratedTypeParameterBounds.current = null;
    }
    var changes = FixAggregator.run(unit, result.content, fixBuilder.changes,
        removeViaComments: removeViaComments);
    _instrumentation?.changes(source, changes);
    final lineInfo = LineInfo.fromContent(source.contents.data);
    var offsets = changes.keys.toList();
    offsets.sort();
    for (var offset in offsets) {
      var edits = changes[offset];
      var descriptions = edits
          .map((edit) => edit.info)
          .where((info) => info != null)
          .map((info) => info.description.appliedMessage)
          .join(', ');
      var sourceEdit = edits.toSourceEdit(offset);
      listener.addSuggestion(
          descriptions, _computeLocation(lineInfo, sourceEdit, source));
      listener.addEdit(source, sourceEdit);
    }
  }

  void finish() {
    _postmortemFileWriter?.write();
  }

  void prepareInput(ResolvedUnitResult result) {
    _sanityCheck(result);
    if (_variables == null) {
      _variables = Variables(_graph, result.typeProvider,
          instrumentation: _instrumentation,
          postmortemFileWriter: _postmortemFileWriter);
      _decoratedClassHierarchy = DecoratedClassHierarchy(_variables, _graph);
    }
    var unit = result.unit;
    try {
      DecoratedTypeParameterBounds.current = _decoratedTypeParameterBounds;
      unit.accept(NodeBuilder(_variables, unit.declaredElement.source,
          _permissive ? listener : null, _graph, result.typeProvider,
          instrumentation: _instrumentation));
    } finally {
      DecoratedTypeParameterBounds.current = null;
    }
  }

  void processInput(ResolvedUnitResult result) {
    _sanityCheck(result);
    var unit = result.unit;
    try {
      DecoratedTypeParameterBounds.current = _decoratedTypeParameterBounds;
      unit.accept(EdgeBuilder(
          result.typeProvider,
          result.typeSystem,
          _variables,
          _graph,
          unit.declaredElement.source,
          _permissive ? listener : null,
          _decoratedClassHierarchy,
          instrumentation: _instrumentation));
    } finally {
      DecoratedTypeParameterBounds.current = null;
    }
  }

  @override
  void update() {
    _graph.update(_postmortemFileWriter);
  }

  void _sanityCheck(ResolvedUnitResult result) {
    final equalsParamType = result.typeProvider.objectType
        .getMethod('==')
        .parameters[0]
        .type
        .getDisplayString(withNullability: true);
    if (equalsParamType == 'Object*') {
      throw StateError(nnbdExperimentOff);
    }

    if (equalsParamType != 'Object') {
      throw StateError(sdkNnbdOff);
    }

    if (result.unit.featureSet.isEnabled(Feature.non_nullable)) {
      // TODO(jcollins-g): Allow for skipping already migrated compilation units.
      throw StateError('$migratedAlready: ${result.path}');
    }
  }

  static Location _computeLocation(
      LineInfo lineInfo, SourceEdit edit, Source source) {
    final locationInfo = lineInfo.getLocation(edit.offset);
    var location = new Location(
      source.fullName,
      edit.offset,
      edit.length,
      locationInfo.lineNumber,
      locationInfo.columnNumber,
    );
    return location;
  }

  static PostmortemFileWriter _makePostmortemFileWriter() {
    if (_postmortemPath == null) return null;
    return PostmortemFileWriter(
        PhysicalResourceProvider.INSTANCE.getFile(_postmortemPath));
  }
}
