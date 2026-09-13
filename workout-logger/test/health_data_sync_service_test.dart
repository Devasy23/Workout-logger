import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:repforge/models/models.dart';
import 'package:repforge/services/health_data_sync_service.dart';
import 'package:repforge/services/interfaces/health_connect_service_interface.dart';
import 'package:repforge/services/sqlite_storage_service.dart';

class _RecordingHcService implements IHealthConnectService {
  final List<({String method, DateTime from, DateTime to})> calls = [];
  List<HealthSample> heartRateSamples = const [];
  List<HealthSample> restingHrSamples = const [];
  bool throwOnHeartRate = false;
  Set<HealthReadType> grantedTypes = HealthReadType.values.toSet();

  @override
  Future<List<SleepPeriod>> readSleepSessions(DateTime start, DateTime end) async {
    calls.add((method: 'sleep', from: start, to: end));
    return const [];
  }

  @override
  Future<List<HealthSample>> readHeartRateSamples(DateTime start, DateTime end) async {
    calls.add((method: 'heart_rate', from: start, to: end));
    if (throwOnHeartRate) throw Exception('boom');
    return heartRateSamples;
  }

  @override
  Future<List<HealthSample>> readRestingHeartRate(DateTime start, DateTime end) async {
    calls.add((method: 'resting_heart_rate', from: start, to: end));
    return restingHrSamples;
  }

  @override
  Future<List<HealthSample>> readHrvRmssd(DateTime start, DateTime end) async {
    calls.add((method: 'hrv_rmssd', from: start, to: end));
    return const [];
  }

  @override
  Future<Set<HealthReadType>> grantedReadTypes() async => grantedTypes;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> requestPermissions() async => true;
  @override
  Future<bool> hasPermissions() async => true;
  @override
  Future<bool> requestReadPermissions() async => true;
  @override
  Future<bool> syncWorkoutSession(
    WorkoutSession session, {
    String? title,
    Map<String, String>? exerciseNames,
  }) async => true;
}

Future<List<Map<String, Object?>>> _rawQuery(
  SqliteStorageService s,
  String sql, [
  List<Object?>? args,
]) async {
  final db = await openReadOnlyDatabase(s.databasePath, singleInstance: false);
  final rows = await db.rawQuery(sql, args);
  await db.close();
  return rows;
}

void main() {
  late SqliteStorageService storage;
  late _RecordingHcService hc;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    storage = SqliteStorageService(databasePathOverride: inMemoryDatabasePath);
    await storage.init();
    hc = _RecordingHcService();
  });

  tearDown(() async {
    final path = storage.databasePath;
    await storage.close();
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  });

  test('first sync backfills 90 days plus the 3-day lookback', () async {
    final now = DateTime(2026, 8, 11, 9);
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => now);

    await service.sync();

    final sleepCall = hc.calls.firstWhere((c) => c.method == 'sleep');
    expect(sleepCall.to, now);
    expect(sleepCall.from, now.subtract(const Duration(days: 93)));
  });

  test('second sync only re-fetches from watermark minus the 3-day lookback', () async {
    final firstRun = DateTime(2026, 8, 1, 9);
    final secondRun = DateTime(2026, 8, 11, 9);
    var current = firstRun;
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => current);

    await service.sync(force: true);
    hc.calls.clear();
    current = secondRun;
    await service.sync(force: true);

    final sleepCall = hc.calls.firstWhere((c) => c.method == 'sleep');
    expect(sleepCall.from, firstRun.subtract(const Duration(days: 3)));
    expect(sleepCall.to, secondRun);
  });

  test('a sync within the 30-minute throttle window is skipped unless forced', () async {
    final firstRun = DateTime(2026, 8, 11, 9, 0);
    final soonAfter = DateTime(2026, 8, 11, 9, 10);
    var current = firstRun;
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => current);

    await service.sync();
    hc.calls.clear();
    current = soonAfter;
    await service.sync();

    expect(hc.calls, isEmpty);
  });

  test('force:true bypasses the throttle', () async {
    final firstRun = DateTime(2026, 8, 11, 9, 0);
    final soonAfter = DateTime(2026, 8, 11, 9, 10);
    var current = firstRun;
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => current);

    await service.sync();
    hc.calls.clear();
    current = soonAfter;
    await service.sync(force: true);

    expect(hc.calls, isNotEmpty);
  });

  test('re-syncing the same sample does not duplicate rows', () async {
    final now = DateTime(2026, 8, 11, 9);
    hc.heartRateSamples = [HealthSample(time: DateTime(2026, 8, 10, 22), value: 62)];
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => now);

    await service.sync(force: true);
    await service.sync(force: true);

    final rows = await _rawQuery(
      storage,
      "SELECT COUNT(*) AS c FROM health_samples WHERE type = 'heart_rate'",
    );
    expect(rows.first['c'], 1);
  });

  test('a stream that throws does not block the others and leaves its watermark untouched', () async {
    final now = DateTime(2026, 8, 11, 9);
    hc.throwOnHeartRate = true;
    hc.restingHrSamples = [HealthSample(time: now, value: 55)];
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => now);

    await service.sync(force: true);

    expect(await storage.getSetting('health_sync.heart_rate'), isNull);
    expect(await storage.getSetting('health_sync.resting_heart_rate'), now.toIso8601String());

    final rows = await _rawQuery(
      storage,
      "SELECT COUNT(*) AS c FROM health_samples WHERE type = 'resting_heart_rate'",
    );
    expect(rows.first['c'], 1);
  });

  test('an ungranted stream is skipped entirely and its watermark never advances', () async {
    final now = DateTime(2026, 8, 11, 9);
    // Permission not yet granted for heart rate — simulates first launch
    // before the user has opened Health Connect settings.
    hc.grantedTypes = {
      HealthReadType.sleep,
      HealthReadType.restingHeartRate,
      HealthReadType.hrv,
    };
    final service = HealthDataSyncService(healthConnectService: hc, storage: storage, now: () => now);

    await service.sync(force: true);

    // The reader for the ungranted stream must never even be called.
    expect(hc.calls.any((c) => c.method == 'heart_rate'), isFalse);
    // And critically, its watermark must stay unset so a later grant still
    // triggers the full 90-day backfill instead of resuming from `now`.
    expect(await storage.getSetting('health_sync.heart_rate'), isNull);
  });
}
