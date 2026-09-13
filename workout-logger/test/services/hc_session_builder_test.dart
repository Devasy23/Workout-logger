import 'package:flutter_test/flutter_test.dart';
import 'package:health_connector/health_connector.dart';
import 'package:repforge/models/models.dart';
import 'package:repforge/services/utils/hc_session_builder.dart';

WorkoutSession _session({
  required DateTime start,
  required int durationMinutes,
  required List<ExerciseLog> exercises,
  String? notes,
}) =>
    WorkoutSession(
      id: 'sess_1',
      date: start,
      duration: durationMinutes,
      exercises: exercises,
      notes: notes,
    );

/// Asserts that Health Connect's own [ExerciseSessionRecord] validation
/// accepts [segments], exercising the real invariant checks instead of a
/// hand-rolled approximation of them.
void _expectValidHcRecord({
  required List<ExerciseSessionSegmentEvent> segments,
  required DateTime sessionStart,
  required DateTime sessionEnd,
}) {
  expect(
    () => ExerciseSessionRecord(
      startTime: sessionStart,
      endTime: sessionEnd,
      exerciseType: ExerciseType.strengthTraining,
      metadata: Metadata.manualEntry(clientRecordId: 'test'),
      events: segments,
    ),
    returnsNormally,
  );
}

void main() {
  final start = DateTime(2026, 9, 4, 18);

  group('hcSegmentTypeFor', () {
    test('maps a known exercise to its Health Connect segment type', () {
      expect(hcSegmentTypeFor('bench_press'), ExerciseSegmentType.benchPress);
    });

    test('falls back to otherWorkout for an unknown custom exercise', () {
      expect(hcSegmentTypeFor('custom_abc'), ExerciseSegmentType.otherWorkout);
    });

    test('maps generic barbell and cable lifts to weightlifting', () {
      const generic = [
        'push_ups',
        'dips',
        'cable_fly',
        'pec_deck',
        'barbell_row',
        'seated_cable_row',
        't_bar_row',
        'face_pull',
        'rear_delt_fly',
        'shrugs',
        'calf_raise',
        'tricep_pushdown',
        'skull_crushers',
      ];
      for (final id in generic) {
        expect(
          hcSegmentTypeFor(id),
          ExerciseSegmentType.weightlifting,
          reason: '$id should map to weightlifting',
        );
      }
    });

    test('keeps otherWorkout only for unmapped custom exercises', () {
      expect(hcSegmentTypeFor('some_custom_uuid'), ExerciseSegmentType.otherWorkout);
    });
  });

  group('buildHcSegments', () {
    test('returns empty when no set has reps', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'bench_press',
            sets: [WorkoutSet(weight: 60, reps: 0, timestamp: start)],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      expect(segments, isEmpty);
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('spaces segments evenly when set timestamps are identical', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'bench_press',
            sets: [
              WorkoutSet(weight: 60, reps: 10, timestamp: start),
              WorkoutSet(weight: 70, reps: 8, timestamp: start),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      expect(segments.length, 2);
      expect(segments.first.startTime, start);
      expect(segments.first.endTime, start.add(const Duration(minutes: 15)));
      expect(segments.last.endTime, start.add(const Duration(minutes: 30)));
      expect(segments.first.repetitions, 10);
      expect(segments.first.weight, const Mass.kilograms(60));
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('never emits overlapping segments for distinct timestamps', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 5, timestamp: start.add(const Duration(minutes: 5))),
              WorkoutSet(weight: 90, reps: 5, timestamp: start.add(const Duration(minutes: 12))),
              WorkoutSet(weight: 100, reps: 3, timestamp: start.add(const Duration(minutes: 20))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      for (var i = 0; i < segments.length - 1; i++) {
        expect(segments[i].endTime.isAfter(segments[i + 1].startTime), isFalse);
        expect(segments[i].endTime.isAfter(segments[i].startTime), isTrue);
      }
      expect(segments.first.startTime.isBefore(start), isFalse);
      expect(segments.last.endTime.isAfter(start.add(const Duration(minutes: 30))), isFalse);
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('omits weight when the set weight is zero', () {
      final session = _session(
        start: start,
        durationMinutes: 20,
        exercises: [
          ExerciseLog(
            exerciseId: 'pull_ups',
            sets: [
              WorkoutSet(weight: 0, reps: 8, timestamp: start.add(const Duration(minutes: 4))),
              WorkoutSet(weight: 0, reps: 6, timestamp: start.add(const Duration(minutes: 10))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 20));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      expect(segments, isNotEmpty);
      expect(segments.every((s) => s.weight == null), isTrue);
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('emits rest segments between work segments', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 5, timeTaken: 30, timestamp: start.add(const Duration(minutes: 5))),
              WorkoutSet(weight: 90, reps: 5, timeTaken: 30, timestamp: start.add(const Duration(minutes: 12))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      final rests = segments.where((s) => s.segmentType == ExerciseSegmentType.rest).toList();
      expect(rests.length, 2);
      expect(rests.every((s) => s.repetitions == null && s.weight == null), isTrue);
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('sizes a work segment from timeTaken', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 5, timeTaken: 45, timestamp: start.add(const Duration(minutes: 5))),
              WorkoutSet(weight: 90, reps: 5, timeTaken: 45, timestamp: start.add(const Duration(minutes: 12))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      final work = segments.firstWhere((s) => s.segmentType == ExerciseSegmentType.squat);
      expect(work.duration, const Duration(seconds: 45));
      expect(work.endTime, start.add(const Duration(minutes: 5)));
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('estimates work duration from reps when timeTaken is missing', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 12, timestamp: start.add(const Duration(minutes: 5))),
              WorkoutSet(weight: 90, reps: 12, timestamp: start.add(const Duration(minutes: 12))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      final work = segments.firstWhere((s) => s.segmentType == ExerciseSegmentType.squat);
      expect(work.duration, const Duration(seconds: 36));
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('skips rest segments shorter than 30 seconds', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 5, timeTaken: 20, timestamp: start.add(const Duration(seconds: 25))),
              WorkoutSet(weight: 90, reps: 5, timeTaken: 20, timestamp: start.add(const Duration(seconds: 60))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      expect(segments.any((s) => s.segmentType == ExerciseSegmentType.rest), isFalse);
      expect(segments.length, 2);
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('omits every weight when includeWeight is false', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 5, timeTaken: 30, timestamp: start.add(const Duration(minutes: 5))),
              WorkoutSet(weight: 90, reps: 5, timeTaken: 30, timestamp: start.add(const Duration(minutes: 12))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
        includeWeight: false,
      );

      expect(segments, isNotEmpty);
      expect(segments.every((s) => s.weight == null), isTrue);
      expect(segments.any((s) => s.repetitions == 5), isTrue);
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('falls back to even spacing when the first set lands on the session start', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [WorkoutSet(weight: 80, reps: 5, timeTaken: 20, timestamp: start)],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      expect(segments, isNotEmpty);
      expect(segments.first.startTime, start);
      expect(segments.last.endTime, start.add(const Duration(minutes: 30)));
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('does not fall back to even spacing when the last set lands on the session end', () {
      final session = _session(
        start: start,
        durationMinutes: 30,
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [
              WorkoutSet(weight: 80, reps: 5, timeTaken: 20, timestamp: start.add(const Duration(minutes: 5))),
              WorkoutSet(weight: 90, reps: 5, timeTaken: 20, timestamp: start.add(const Duration(minutes: 30))),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 30));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      expect(segments.any((s) => s.segmentType == ExerciseSegmentType.rest), isTrue);
      expect(segments.first.endTime, isNot(start.add(const Duration(minutes: 15))));
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });

    test('uses effective weight (not raw assistance) for an assisted-bodyweight set', () {
      final session = _session(
        start: start,
        durationMinutes: 20,
        exercises: [
          ExerciseLog(
            exerciseId: 'pull_ups',
            sets: [
              WorkoutSet(
                weight: 40,
                reps: 8,
                timestamp: start.add(const Duration(minutes: 4)),
                assistWeight: 40,
                extraWeight: 0,
                bodyWeightAtLog: 70,
              ),
            ],
          ),
        ],
      );

      final sessionEnd = start.add(const Duration(minutes: 20));
      final segments = buildHcSegments(
        session: session,
        sessionStart: start,
        sessionEnd: sessionEnd,
      );

      final work = segments.firstWhere((s) => s.segmentType == ExerciseSegmentType.pullUp);
      expect(work.weight, const Mass.kilograms(30));
      _expectValidHcRecord(segments: segments, sessionStart: start, sessionEnd: sessionEnd);
    });
  });

  group('buildHcNotes', () {
    test('lists each exercise by name with numbered sets', () {
      final session = _session(
        start: start,
        durationMinutes: 40,
        exercises: [
          ExerciseLog(
            exerciseId: 'bench_press',
            sets: [
              WorkoutSet(weight: 60, reps: 10, timestamp: start),
              WorkoutSet(weight: 72.5, reps: 8, timestamp: start.add(const Duration(minutes: 4))),
            ],
          ),
          ExerciseLog(
            exerciseId: 'lat_pulldown',
            sets: [WorkoutSet(weight: 50, reps: 12, timestamp: start.add(const Duration(minutes: 9)))],
          ),
        ],
      );

      final notes = buildHcNotes(
        session: session,
        exerciseNames: const {'bench_press': 'Bench Press', 'lat_pulldown': 'Lat Pulldown'},
      );

      expect(notes, contains('Bench Press: 1) 60kg × 10, 2) 72.5kg × 8'));
      expect(notes, contains('Lat Pulldown: 1) 50kg × 12'));
    });

    test('keeps the user session notes on the first line', () {
      final session = _session(
        start: start,
        durationMinutes: 20,
        notes: 'Felt strong',
        exercises: [
          ExerciseLog(
            exerciseId: 'squat',
            sets: [WorkoutSet(weight: 100, reps: 5, timestamp: start)],
          ),
        ],
      );

      final notes = buildHcNotes(session: session, exerciseNames: const {'squat': 'Squat'});

      expect(notes!.startsWith('Felt strong'), isTrue);
      expect(notes, contains('Squat: 1) 100kg × 5'));
    });

    test('renders bodyweight sets without a weight prefix', () {
      final session = _session(
        start: start,
        durationMinutes: 15,
        exercises: [
          ExerciseLog(
            exerciseId: 'pull_ups',
            sets: [WorkoutSet(weight: 0, reps: 8, timestamp: start)],
          ),
        ],
      );

      final notes = buildHcNotes(session: session, exerciseNames: const {'pull_ups': 'Pull Ups'});

      expect(notes, contains('Pull Ups: 1) × 8'));
    });

    test('uses effective weight (not raw assistance) for an assisted-bodyweight set', () {
      final session = _session(
        start: start,
        durationMinutes: 15,
        exercises: [
          ExerciseLog(
            exerciseId: 'pull_ups',
            sets: [
              WorkoutSet(
                weight: 40,
                reps: 8,
                timestamp: start,
                assistWeight: 40,
                extraWeight: 0,
                bodyWeightAtLog: 70,
              ),
            ],
          ),
        ],
      );

      final notes = buildHcNotes(session: session, exerciseNames: const {'pull_ups': 'Pull Ups'});

      expect(notes, contains('Pull Ups: 1) 30kg × 8'));
    });

    test('falls back to the exercise id when no name is known', () {
      final session = _session(
        start: start,
        durationMinutes: 15,
        exercises: [
          ExerciseLog(
            exerciseId: 'custom_abc',
            sets: [WorkoutSet(weight: 20, reps: 10, timestamp: start)],
          ),
        ],
      );

      final notes = buildHcNotes(session: session, exerciseNames: const {});

      expect(notes, contains('custom_abc: 1) 20kg × 10'));
    });

    test('returns null when the session has no notes and no sets', () {
      final session = _session(start: start, durationMinutes: 10, exercises: []);

      expect(buildHcNotes(session: session, exerciseNames: const {}), isNull);
    });

    test('truncates to maxLength with an ellipsis', () {
      final session = _session(
        start: start,
        durationMinutes: 60,
        exercises: List.generate(
          30,
          (i) => ExerciseLog(
            exerciseId: 'ex_$i',
            sets: [WorkoutSet(weight: 100, reps: 10, timestamp: start.add(Duration(minutes: i)))],
          ),
        ),
      );

      final notes = buildHcNotes(session: session, exerciseNames: const {}, maxLength: 100);

      expect(notes!.length, 100);
      expect(notes.endsWith('…'), isTrue);
    });
  });
}
