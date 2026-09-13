// Unit tests for the workout HR analysis builder (rest recovery + guards).

import 'package:flutter_test/flutter_test.dart';
import 'package:repforge/models/models.dart';
import 'package:repforge/services/interfaces/health_connect_service_interface.dart';
import 'package:repforge/services/utils/workout_hr_builder.dart';

class _Hc implements IHealthConnectService {
  final List<HealthSample> hr;
  _Hc(this.hr);

  @override
  Future<List<HealthSample>> readHeartRateSamples(DateTime start, DateTime end) async =>
      hr.where((s) => !s.time.isBefore(start) && !s.time.isAfter(end)).toList();

  @override
  Future<Set<HealthReadType>> grantedReadTypes() async => {HealthReadType.heartRate};
  @override
  Future<List<SleepPeriod>> readSleepSessions(DateTime s, DateTime e) async => const [];
  @override
  Future<List<HealthSample>> readRestingHeartRate(DateTime s, DateTime e) async => const [];
  @override
  Future<List<HealthSample>> readHrvRmssd(DateTime s, DateTime e) async => const [];
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

DateTime _t(int h, int m, [int s = 0]) => DateTime(2026, 6, 9, h, m, s);

WorkoutSet _set(DateTime ts, {int timeTaken = 30}) =>
    WorkoutSet(weight: 100, reps: 8, timestamp: ts, timeTaken: timeTaken);

void main() {
  final session = WorkoutSession(
    id: 'w1',
    date: _t(18, 0),
    duration: 20, // ends 18:20
    exercises: [
      ExerciseLog(exerciseId: 'bench', sets: [_set(_t(18, 2)), _set(_t(18, 5))]),
      ExerciseLog(exerciseId: 'row', sets: [_set(_t(18, 10)), _set(_t(18, 14))]),
    ],
  );

  // Crafted HR: drops during the first two rests, stays high in the third.
  final samples = [
    HealthSample(time: _t(18, 2), value: 160), // set A1 end (peak)
    HealthSample(time: _t(18, 3), value: 140), // rest 1 trough
    HealthSample(time: _t(18, 4), value: 142),
    HealthSample(time: _t(18, 5), value: 158), // set A2 end
    HealthSample(time: _t(18, 7), value: 130), // rest 2 trough
    HealthSample(time: _t(18, 10), value: 162), // set B1 end
    HealthSample(time: _t(18, 12), value: 159), // rest 3 stays high
    HealthSample(time: _t(18, 14), value: 150), // set B2 end
  ];

  test('computes per-rest recovery and flags short rests', () async {
    final a = await buildWorkoutHrAnalysis(_Hc(samples), session, {HealthReadType.heartRate});
    expect(a, isNotNull);
    expect(a!.peakBpm, 162);
    expect(a.minBpm, 130);
    expect(a.hasRestAnalysis, true);

    expect(a.restCount, 3);
    expect(a.restsRecovered, 2);
    expect(a.rests[0].recoveryBpm, 20); // 160 → 140
    expect(a.rests[0].recovered, true);
    expect(a.rests[2].recoveryBpm, 3); // 162 → 159
    expect(a.rests[2].recovered, false);
    expect(a.avgRecoveryBpm, 24); // (20 + 28) / 2

    expect(a.exercises.length, 2);
    expect(a.exercises.first.setCount, 2);
  });

  test('guards against placeholder timestamps (no per-set timing)', () async {
    final flat = WorkoutSession(
      id: 'w2',
      date: _t(18, 0),
      duration: 20,
      exercises: [
        ExerciseLog(exerciseId: 'bench', sets: [_set(_t(18, 0)), _set(_t(18, 0))]),
      ],
    );
    final a = await buildWorkoutHrAnalysis(_Hc(samples), flat, {HealthReadType.heartRate});
    expect(a, isNotNull);
    expect(a!.hasRestAnalysis, false);
    expect(a.rests, isEmpty);
    expect(a.exercises, isEmpty);
    expect(a.curve, isNotEmpty); // curve still renders
  });

  test('returns null without HR permission', () async {
    final a = await buildWorkoutHrAnalysis(_Hc(samples), session, {HealthReadType.sleep});
    expect(a, isNull);
  });

  test('returns null when too few samples cover the window', () async {
    final sparse = _Hc([HealthSample(time: _t(18, 5), value: 150)]);
    final a = await buildWorkoutHrAnalysis(sparse, session, {HealthReadType.heartRate});
    expect(a, isNull);
  });
}
