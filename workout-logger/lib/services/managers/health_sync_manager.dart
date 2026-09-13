// Health Sync Manager (Single Responsibility Principle)
//
// Responsible ONLY for orchestrating Health Connect sync after a workout session
// is saved. It:
// - Checks the user's HC-enabled setting via SettingsProvider (in-memory, sync).
// - Calls IHealthConnectService.syncWorkoutSession in a fire-and-forget pattern.
// - On success, invokes the optional onSynced callback with the updated session.
// - Swallows all errors so callers are never affected.
// - Reads storage once, on first sync, to cache exercise names for the notes.

import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/models.dart';
import '../interfaces/health_connect_service_interface.dart';
import '../interfaces/health_sync_manager_interface.dart';
import '../interfaces/storage_service_interface.dart';
import '../settings_provider.dart';

/// Orchestrates Health Connect sync after a workout session is saved.
///
/// Following Single Responsibility Principle: this class only manages
/// the HC sync concern. History persistence and active workout state
/// are handled by other managers. The one exception is a cached, one-time
/// exercise-name lookup used to label the Health Connect notes.
class HealthSyncManager implements IHealthSyncManager {
  final IHealthConnectService _hc;
  final SettingsProvider _settings;
  final IStorageService? _storage;

  Map<String, String>? _exerciseNames;

  HealthSyncManager(this._hc, this._settings, {IStorageService? storage})
      : _storage = storage;

  @override
  void syncSession(
    WorkoutSession session, {
    String? routineName,
    void Function(WorkoutSession updated)? onSynced,
  }) {
    // Synchronous in-memory flag check — no I/O, no await.
    if (!_settings.healthConnectEnabled) return;

    _resolveExerciseNames()
        .then((names) => _hc.syncWorkoutSession(
              session,
              title: routineName,
              exerciseNames: names,
            ))
        .then((success) {
          if (success) {
            onSynced?.call(session.copyWith(hcSyncedAt: DateTime.now()));
          }
        })
        .catchError((Object e) {
          debugPrint('HealthSyncManager: sync error: $e');
        });
  }

  /// Loaded once per process; exercise names only change when the user adds a
  /// custom exercise, and a stale name only affects the notes text.
  Future<Map<String, String>> _resolveExerciseNames() async {
    final cached = _exerciseNames;
    if (cached != null) return cached;
    final storage = _storage;
    if (storage == null) return const {};
    try {
      final exercises = await storage.getAllExercises();
      return _exerciseNames = {for (final e in exercises) e.id: e.name};
    } catch (_) {
      return const {};
    }
  }
}
