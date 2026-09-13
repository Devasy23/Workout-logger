// Unit tests for HealthHistoryManager (windowing + aggregation).

import 'package:flutter_test/flutter_test.dart';
import 'package:repforge/models/models.dart';
import 'package:repforge/models/sleep_hr_models.dart';
import 'package:repforge/services/interfaces/health_connect_service_interface.dart';
import 'package:repforge/services/managers/health_history_manager.dart';
import 'test_utils/mock_storage_service.dart';

class _StubHc implements IHealthConnectService {
  Set<HealthReadType> granted;
  List<SleepPeriod> sleep;
  List<HealthSample> resting;
  List<HealthSample> heartRate;

  _StubHc({
    this.granted = const {},
    this.sleep = const [],
    this.resting = const [],
    this.heartRate = const [],
  });

  @override
  Future<Set<HealthReadType>> grantedReadTypes() async => granted;

  @override
  Future<List<SleepPeriod>> readSleepSessions(DateTime start, DateTime end) async =>
      sleep.where((p) => p.end.isAfter(start) && p.start.isBefore(end)).toList();

  @override
  Future<List<HealthSample>> readRestingHeartRate(DateTime start, DateTime end) async =>
      resting.where((s) => !s.time.isBefore(start) && s.time.isBefore(end)).toList();

  @override
  Future<List<HealthSample>> readHeartRateSamples(DateTime start, DateTime end) async =>
      heartRate.where((s) => !s.time.isBefore(start) && s.time.isBefore(end)).toList();

  @override
  Future<List<HealthSample>> readHrvRmssd(DateTime start, DateTime end) async => const [];

  // Unused by these tests.
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

SleepPeriod _night(DateTime end, {int deep = 0, int rem = 0, int light = 0, int awake = 0}) {
  final total = deep + rem + light;
  return SleepPeriod(
    start: end.subtract(Duration(minutes: total + awake)),
    end: end,
    deepMinutes: deep,
    remMinutes: rem,
    lightMinutes: light,
    awakeMinutes: awake,
  );
}

void main() {
  group('rangeFor / stepBy', () {
    final anchor = DateTime(2026, 6, 14); // a Sunday

    test('day window is the single day', () {
      final r = HealthHistoryManager.rangeFor(anchor, HealthGranularity.day);
      expect(r.start, DateTime(2026, 6, 14));
      expect(r.end, DateTime(2026, 6, 15));
    });

    test('week is the 7 days ending on the anchor', () {
      final r = HealthHistoryManager.rangeFor(anchor, HealthGranularity.week);
      expect(r.start, DateTime(2026, 6, 8));
      expect(r.end, DateTime(2026, 6, 15));
    });

    test('month is the calendar month', () {
      final r = HealthHistoryManager.rangeFor(anchor, HealthGranularity.month);
      expect(r.start, DateTime(2026, 6, 1));
      expect(r.end, DateTime(2026, 7, 1));
    });

    test('year is the calendar year', () {
      final r = HealthHistoryManager.rangeFor(anchor, HealthGranularity.year);
      expect(r.start, DateTime(2026, 1, 1));
      expect(r.end, DateTime(2027, 1, 1));
    });

    test('stepBy moves by the active unit', () {
      expect(HealthHistoryManager.stepBy(anchor, HealthGranularity.day, 1),
          DateTime(2026, 6, 15));
      expect(HealthHistoryManager.stepBy(anchor, HealthGranularity.week, -1),
          DateTime(2026, 6, 7));
      expect(HealthHistoryManager.stepBy(anchor, HealthGranularity.month, 1),
          DateTime(2026, 7, 14));
      expect(HealthHistoryManager.stepBy(anchor, HealthGranularity.year, -1),
          DateTime(2025, 6, 14));
    });
  });

  group('sleepBars', () {
    test('sums fragmented same-night records into one bar and zero-fills', () async {
      // Two fragments ending the morning of Jun 14.
      final hc = _StubHc(
        granted: {HealthReadType.sleep},
        sleep: [
          _night(DateTime(2026, 6, 14, 3, 0), deep: 40, rem: 30, light: 60),
          _night(DateTime(2026, 6, 14, 6, 30), deep: 20, rem: 50, light: 90),
        ],
      );
      final mgr = HealthHistoryManager(hc, MockStorageService());

      final bars = await mgr.sleepBars(DateTime(2026, 6, 14), HealthGranularity.week);
      expect(bars.length, 7);

      final night = bars.firstWhere((b) => b.date == DateTime(2026, 6, 14));
      expect(night.deepMin, 60); // 40 + 20
      expect(night.remMin, 80); // 30 + 50
      expect(night.lightMin, 150); // 60 + 90
      expect(night.totalMinutes, 290);

      // Other nights are zero-filled, keeping a stable 7-slot axis.
      final empty = bars.firstWhere((b) => b.date == DateTime(2026, 6, 10));
      expect(empty.totalMinutes, 0);
    });

    test('year view returns 12 monthly average bars', () async {
      final hc = _StubHc(
        granted: {HealthReadType.sleep},
        sleep: [
          // Two nights in March averaging to 400 total min.
          _night(DateTime(2026, 3, 10, 6), deep: 60, rem: 60, light: 180), // 300
          _night(DateTime(2026, 3, 20, 6), deep: 100, rem: 100, light: 300), // 500
        ],
      );
      final mgr = HealthHistoryManager(hc, MockStorageService());

      final bars = await mgr.sleepBars(DateTime(2026, 6, 14), HealthGranularity.year);
      expect(bars.length, 12);
      final march = bars[2];
      expect(march.date, DateTime(2026, 3, 1));
      expect(march.totalMinutes, 400); // (300 + 500) / 2
      expect(bars[0].totalMinutes, 0); // January empty
    });
  });

  group('hrBars (week, full-sample path)', () {
    test('builds per-day min/max from HR samples and zero-fills', () async {
      final hc = _StubHc(
        granted: {HealthReadType.heartRate},
        heartRate: [
          HealthSample(time: DateTime(2026, 6, 13, 9), value: 70),
          HealthSample(time: DateTime(2026, 6, 13, 14), value: 120),
          HealthSample(time: DateTime(2026, 6, 13, 22), value: 60),
        ],
      );
      final mgr = HealthHistoryManager(hc, MockStorageService());

      final bars = await mgr.hrBars(DateTime(2026, 6, 14), HealthGranularity.week);
      expect(bars.length, 7);

      final d13 = bars.firstWhere((b) => b.date == DateTime(2026, 6, 13));
      expect(d13.minBpm, 60);
      expect(d13.maxBpm, 120);

      final empty = bars.firstWhere((b) => b.date == DateTime(2026, 6, 9));
      expect(empty.maxBpm, 0);
    });
  });

  group('hrBars (month, resting-HR path)', () {
    test('yields one range bar per day from resting records', () async {
      final hc = _StubHc(
        granted: {HealthReadType.restingHeartRate},
        resting: [
          HealthSample(time: DateTime(2026, 6, 5, 8), value: 56),
          HealthSample(time: DateTime(2026, 6, 5, 9), value: 60),
          HealthSample(time: DateTime(2026, 6, 12, 8), value: 52),
        ],
      );
      final mgr = HealthHistoryManager(hc, MockStorageService());

      final bars = await mgr.hrBars(DateTime(2026, 6, 14), HealthGranularity.month);
      expect(bars.length, 30); // June

      final d5 = bars[4];
      expect(d5.minBpm, 56);
      expect(d5.maxBpm, 60);
      expect(d5.restingBpm, 58); // mean of 56 & 60

      final d1 = bars[0];
      expect(d1.maxBpm, 0); // no data → empty bar
    });
  });
}
