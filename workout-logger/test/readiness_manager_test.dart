// Unit tests for ReadinessManager (orchestration, caching, degradation)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:repforge/models/models.dart';
import 'package:repforge/services/interfaces/health_connect_service_interface.dart';
import 'package:repforge/services/interfaces/readiness_manager_interface.dart';
import 'package:repforge/services/managers/readiness_manager.dart';
import 'package:repforge/services/settings_provider.dart';
import 'package:repforge/services/utils/readiness_calculator.dart';
import 'test_utils/mock_storage_service.dart';

// ── Mocks ──────────────────────────────────────────────────────────────────────

class _MockHcService implements IHealthConnectService {
  Set<HealthReadType> granted;
  List<SleepPeriod> sleepPeriods;
  List<HealthSample> restingHr;
  List<HealthSample> hrv = const [];
  List<HealthSample> heartRate;
  bool shouldThrow;

  int grantedCallCount = 0;
  int sleepReadCount = 0;
  int rhrReadCount = 0;
  int hrvReadCount = 0;
  int hrReadCount = 0;

  _MockHcService({
    this.granted = const {},
    this.sleepPeriods = const [],
    this.restingHr = const [],
    this.heartRate = const [],
    this.shouldThrow = false,
  });

  void _maybeThrow() {
    if (shouldThrow) throw Exception('mock HC error');
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> hasPermissions() async => true;

  @override
  Future<bool> requestReadPermissions() async => granted.isNotEmpty;

  @override
  Future<Set<HealthReadType>> grantedReadTypes() async {
    _maybeThrow();
    grantedCallCount++;
    return granted;
  }

  @override
  Future<List<SleepPeriod>> readSleepSessions(DateTime start, DateTime end) async {
    _maybeThrow();
    sleepReadCount++;
    return sleepPeriods
        .where((p) => p.end.isAfter(start) && p.start.isBefore(end))
        .toList();
  }

  @override
  Future<List<HealthSample>> readRestingHeartRate(DateTime start, DateTime end) async {
    _maybeThrow();
    rhrReadCount++;
    return restingHr
        .where((s) => !s.time.isBefore(start) && s.time.isBefore(end))
        .toList();
  }

  @override
  Future<List<HealthSample>> readHrvRmssd(DateTime start, DateTime end) async {
    _maybeThrow();
    hrvReadCount++;
    return hrv
        .where((s) => !s.time.isBefore(start) && s.time.isBefore(end))
        .toList();
  }

  @override
  Future<List<HealthSample>> readHeartRateSamples(DateTime start, DateTime end) async {
    _maybeThrow();
    hrReadCount++;
    return heartRate
        .where((s) => !s.time.isBefore(start) && s.time.isBefore(end))
        .toList();
  }

  @override
  Future<bool> syncWorkoutSession(
    WorkoutSession session, {
    String? title,
    Map<String, String>? exerciseNames,
  }) async => true;
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/// 15 nights of 23:00–06:00 sleep (420 min each): 14 baseline nights plus
/// last night, which the manager scores against that baseline.
List<SleepPeriod> _twoWeeksOfSleep(DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  return [
    for (var i = 0; i <= 14; i++)
      SleepPeriod(
        start: day.subtract(Duration(days: i)).subtract(const Duration(hours: 1)),
        end: day.subtract(Duration(days: i)).add(const Duration(hours: 6)),
      ),
  ];
}

List<HealthSample> _dailyRhr(DateTime now, double value, {double? todayValue}) {
  final day = DateTime(now.year, now.month, now.day);
  return [
    for (var i = 1; i <= 14; i++)
      HealthSample(time: day.subtract(Duration(days: i, hours: -7)), value: value),
    // "Today's" reading is stamped at test-setup time so it always falls
    // inside the manager's trailing-24h query regardless of wall clock.
    if (todayValue != null) HealthSample(time: now, value: todayValue),
  ];
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  late MockStorageService storage;
  late SettingsProvider settings;

  Future<ReadinessManager> makeManager(
    _MockHcService hc, {
    bool enabled = true,
  }) async {
    storage = MockStorageService();
    settings = SettingsProvider(storage);
    if (enabled) await storage.saveSetting('readinessEnabled', 'true');
    await settings.init();
    return ReadinessManager(hc, storage, settings);
  }

  group('ReadinessManager.refresh', () {
    test('is a no-op when the readiness setting is disabled', () async {
      final hc = _MockHcService(granted: {HealthReadType.sleep});
      final manager = await makeManager(hc, enabled: false);

      await manager.refresh();

      expect(manager.status, ReadinessStatus.idle);
      expect(hc.grantedCallCount, 0);
    });

    test('goes to noData when no read permissions are granted', () async {
      final hc = _MockHcService();
      final manager = await makeManager(hc);

      await manager.refresh();

      expect(manager.status, ReadinessStatus.noData);
      expect(manager.snapshot, isNull);
    });

    test('computes a sleep-only snapshot with partial permissions', () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        sleepPeriods: _twoWeeksOfSleep(now),
      );
      final manager = await makeManager(hc);

      await manager.refresh();

      expect(manager.status, ReadinessStatus.ready);
      final s = manager.snapshot!;
      expect(s.sleepScore, isNotNull);
      expect(s.rhrScore, isNull);
      expect(s.hrvScore, isNull);
      expect(s.score, isNotNull);
      // Persisted for instant render next launch.
      final cached = await storage.getSetting('readiness.snapshot');
      expect(cached, isNotNull);
    });

    test('serves the same-day cache inside the TTL without re-fetching', () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        sleepPeriods: _twoWeeksOfSleep(now),
      );
      final manager = await makeManager(hc);

      await manager.refresh();
      final fetchesAfterFirst = hc.sleepReadCount;
      await manager.refresh();

      expect(hc.sleepReadCount, fetchesAfterFirst);
      expect(manager.status, ReadinessStatus.ready);
    });

    test('force=true bypasses the snapshot cache', () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        sleepPeriods: _twoWeeksOfSleep(now),
      );
      final manager = await makeManager(hc);

      await manager.refresh();
      final fetchesAfterFirst = hc.sleepReadCount;
      await manager.refresh(force: true);

      expect(hc.sleepReadCount, greaterThan(fetchesAfterFirst));
    });

    test('reuses the same-day baseline instead of recomputing', () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        sleepPeriods: _twoWeeksOfSleep(now),
      );
      final manager = await makeManager(hc);

      await manager.refresh();
      // First refresh: 1 baseline read + 1 last-night read.
      expect(hc.sleepReadCount, 2);
      await manager.refresh(force: true);
      // Forced refresh re-reads last night only — baseline is cached for today.
      expect(hc.sleepReadCount, 3);
    });

    test('uses latest resting HR record and skips the minute-level fallback',
        () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {
          HealthReadType.restingHeartRate,
          HealthReadType.heartRate,
        },
        restingHr: _dailyRhr(now, 55, todayValue: 60.5),
      );
      final manager = await makeManager(hc);

      await manager.refresh();

      expect(manager.snapshot!.restingHr, 60.5);
      expect(manager.snapshot!.rhrScore, 50);
      // The one HR-sample read is the all-day Heart-rate-card snapshot; the
      // scoring path still uses the RHR record and skips its minute-level
      // fallback (verified by restingHr above coming from the RHR record).
      expect(hc.hrReadCount, 1);
    });

    test('falls back to minimum morning heart rate when no RHR record today',
        () async {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final hc = _MockHcService(
        granted: {
          HealthReadType.restingHeartRate,
          HealthReadType.heartRate,
        },
        // Baseline records exist on past days but none in the last 24h.
        restingHr: _dailyRhr(day.subtract(const Duration(days: 2)), 55),
        heartRate: [
          HealthSample(time: day.add(const Duration(hours: 3)), value: 62),
          HealthSample(time: day.add(const Duration(hours: 4)), value: 55),
          HealthSample(time: day.add(const Duration(hours: 5)), value: 58),
        ],
      );
      final manager = await makeManager(hc);

      await manager.refresh();

      // Two HR-sample reads now: the all-day HR snapshot (for the Heart-rate
      // card) plus the morning-RHR fallback used for scoring.
      expect(hc.hrReadCount, 2);
      expect(manager.snapshot?.restingHr, 55);
    });

    test('goes to noData when permissions exist but no data is scorable',
        () async {
      final hc = _MockHcService(granted: {HealthReadType.sleep});
      final manager = await makeManager(hc);

      await manager.refresh();

      expect(manager.status, ReadinessStatus.noData);
      expect(manager.snapshot, isNull);
    });

    test('never throws: HC errors degrade to noData', () async {
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        shouldThrow: true,
      );
      final manager = await makeManager(hc);

      await manager.refresh();

      expect(manager.status, ReadinessStatus.noData);
    });

    test('ignores a corrupt cached snapshot', () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        sleepPeriods: _twoWeeksOfSleep(now),
      );
      final manager = await makeManager(hc);
      await storage.saveSetting('readiness.snapshot', 'not json');

      await manager.refresh();

      expect(manager.status, ReadinessStatus.ready);
    });

    test('discards a stale snapshot from a previous day', () async {
      final now = DateTime.now();
      final hc = _MockHcService(
        granted: {HealthReadType.sleep},
        sleepPeriods: _twoWeeksOfSleep(now),
      );
      final manager = await makeManager(hc);
      final yesterday = now.subtract(const Duration(days: 1));
      await storage.saveSetting(
        'readiness.snapshot',
        jsonEncode(
          ReadinessSnapshot(
            dateKey: ReadinessCalculator.dateKey(yesterday),
            score: 12,
            band: ReadinessBand.low,
            computedAt: yesterday,
          ).toJson(),
        ),
      );

      await manager.refresh();

      expect(manager.snapshot!.dateKey, ReadinessCalculator.dateKey(now));
      expect(manager.snapshot!.score, isNot(12));
    });
  });
}
