// Health Connect session builder.
//
// Pure functions turning a WorkoutSession into Health Connect segments.
// Kept out of HealthConnectService so segment layout is unit-testable
// without a platform channel.

import 'package:health_connector/health_connector.dart';

import '../../models/models.dart';

/// RepForge exercise IDs → Health Connect ExerciseSegmentType values.
/// Unmapped IDs (custom exercises) fall back to otherWorkout.
const _segmentTypeMap = <String, ExerciseSegmentType>{
  'bench_press': ExerciseSegmentType.benchPress,
  'incline_bench_press': ExerciseSegmentType.benchPress,
  'dumbbell_bench_press': ExerciseSegmentType.benchPress,
  'incline_dumbbell_press': ExerciseSegmentType.benchPress,
  'close_grip_bench': ExerciseSegmentType.benchPress,
  'push_ups': ExerciseSegmentType.weightlifting,
  'dips': ExerciseSegmentType.weightlifting,
  'cable_fly': ExerciseSegmentType.weightlifting,
  'pec_deck': ExerciseSegmentType.weightlifting,
  'lat_pulldown': ExerciseSegmentType.latPullDown,
  'pull_ups': ExerciseSegmentType.pullUp,
  'chin_ups': ExerciseSegmentType.pullUp,
  'barbell_row': ExerciseSegmentType.weightlifting,
  'dumbbell_row': ExerciseSegmentType.dumbbellRow,
  'seated_cable_row': ExerciseSegmentType.weightlifting,
  't_bar_row': ExerciseSegmentType.weightlifting,
  'deadlift': ExerciseSegmentType.deadlift,
  'romanian_deadlift': ExerciseSegmentType.deadlift,
  'face_pull': ExerciseSegmentType.weightlifting,
  'overhead_press': ExerciseSegmentType.barbellShoulderPress,
  'dumbbell_shoulder_press': ExerciseSegmentType.shoulderPress,
  'lateral_raise': ExerciseSegmentType.dumbbellLateralRaise,
  'front_raise': ExerciseSegmentType.dumbbellFrontRaise,
  'rear_delt_fly': ExerciseSegmentType.weightlifting,
  'shrugs': ExerciseSegmentType.weightlifting,
  'squat': ExerciseSegmentType.squat,
  'leg_press': ExerciseSegmentType.legPress,
  'leg_extension': ExerciseSegmentType.legExtension,
  'leg_curl': ExerciseSegmentType.legCurl,
  'lunges': ExerciseSegmentType.lunge,
  'hip_thrust': ExerciseSegmentType.hipThrust,
  'calf_raise': ExerciseSegmentType.weightlifting,
  'bicep_curl': ExerciseSegmentType.armCurl,
  'hammer_curl': ExerciseSegmentType.armCurl,
  'preacher_curl': ExerciseSegmentType.armCurl,
  'concentration_curl': ExerciseSegmentType.armCurl,
  'tricep_pushdown': ExerciseSegmentType.weightlifting,
  'skull_crushers': ExerciseSegmentType.weightlifting,
  'overhead_tricep_extension': ExerciseSegmentType.doubleArmTricepsExtension,
  'plank': ExerciseSegmentType.plank,
  'crunches': ExerciseSegmentType.crunch,
  'cable_crunch': ExerciseSegmentType.crunch,
  'russian_twist': ExerciseSegmentType.crunch,
  'leg_raises': ExerciseSegmentType.legRaise,
};

/// The Health Connect segment type for a RepForge exercise ID.
ExerciseSegmentType hcSegmentTypeFor(String exerciseId) =>
    _segmentTypeMap[exerciseId] ?? ExerciseSegmentType.otherWorkout;

const _minWorkSeconds = 10;
const _maxWorkSeconds = 180;
const _minRestSeconds = 30;
const _secondsPerRep = 3;

/// Builds non-overlapping segments for [session] inside
/// [sessionStart]–[sessionEnd].
///
/// Each set becomes a work segment ending at its recorded timestamp and
/// starting [WorkoutSet.timeTaken] seconds earlier (estimated from reps when
/// unrecorded); gaps of at least 30 seconds between work segments become
/// explicit rest segments. Health Connect permits gaps, so shorter gaps are
/// simply left unmarked.
///
/// Falls back to an evenly-spaced layout with no rest segments when the
/// recorded timestamps cannot produce a valid layout (duplicate timestamps on
/// legacy data, or a first set clamped onto [sessionStart]), since
/// zero-duration or overlapping segments make Health Connect reject the whole
/// record.
///
/// Pass [includeWeight] as false on devices that reject segment weights.
List<ExerciseSessionSegmentEvent> buildHcSegments({
  required WorkoutSession session,
  required DateTime sessionStart,
  required DateTime sessionEnd,
  bool includeWeight = true,
}) {
  final allSets = <(ExerciseSegmentType, WorkoutSet)>[];
  for (final log in session.exercises) {
    final type = hcSegmentTypeFor(log.exerciseId);
    for (final set in log.sets) {
      if (set.reps > 0) allSets.add((type, set));
    }
  }
  if (allSets.isEmpty) return [];

  allSets.sort((a, b) => a.$2.timestamp.compareTo(b.$2.timestamp));

  final clamped = allSets.map((entry) {
    var ts = entry.$2.timestamp;
    if (ts.isBefore(sessionStart)) ts = sessionStart;
    if (ts.isAfter(sessionEnd)) ts = sessionEnd;
    return (entry.$1, entry.$2, ts);
  }).toList();

  Mass? massOf(WorkoutSet set) => includeWeight && set.effectiveWeight > 0
      ? Mass.kilograms(set.effectiveWeight)
      : null;

  final uniqueTimestamps = clamped.map((s) => s.$3).toSet();
  if (uniqueTimestamps.length < clamped.length ||
      clamped.first.$3 == sessionStart) {
    final totalMs = sessionEnd.difference(sessionStart).inMilliseconds;
    final slotMs = totalMs ~/ clamped.length;
    return List.generate(clamped.length, (i) {
      final segStart = sessionStart.add(Duration(milliseconds: slotMs * i));
      final segEnd = i < clamped.length - 1
          ? sessionStart.add(Duration(milliseconds: slotMs * (i + 1)))
          : sessionEnd;
      return ExerciseSessionSegmentEvent(
        startTime: segStart,
        endTime: segEnd,
        segmentType: clamped[i].$1,
        repetitions: clamped[i].$2.reps,
        weight: massOf(clamped[i].$2),
      );
    });
  }

  final segments = <ExerciseSessionSegmentEvent>[];
  var cursor = sessionStart;
  for (final (type, set, ts) in clamped) {
    final workSeconds = (set.timeTaken ?? set.reps * _secondsPerRep)
        .clamp(_minWorkSeconds, _maxWorkSeconds)
        .toInt();
    var workStart = ts.subtract(Duration(seconds: workSeconds));
    if (workStart.isBefore(cursor)) workStart = cursor;
    if (!workStart.isBefore(ts)) continue;

    if (workStart.difference(cursor).inSeconds >= _minRestSeconds) {
      segments.add(ExerciseSessionSegmentEvent(
        startTime: cursor,
        endTime: workStart,
        segmentType: ExerciseSegmentType.rest,
      ));
    }
    segments.add(ExerciseSessionSegmentEvent(
      startTime: workStart,
      endTime: ts,
      segmentType: type,
      repetitions: set.reps,
      weight: massOf(set),
    ));
    cursor = ts;
  }
  return segments;
}

/// Composes the Health Connect session notes: the user's own notes first,
/// then one line per exercise with numbered sets. Health Connect has no
/// per-segment label, so this is the only place the real exercise names and
/// set order survive the export.
String? buildHcNotes({
  required WorkoutSession session,
  required Map<String, String> exerciseNames,
  int maxLength = 2000,
}) {
  final lines = <String>[];
  final userNotes = session.notes?.trim();
  if (userNotes != null && userNotes.isNotEmpty) lines.add(userNotes);

  for (final log in session.exercises) {
    final sets = log.sets.where((s) => s.reps > 0).toList();
    if (sets.isEmpty) continue;
    final name = exerciseNames[log.exerciseId] ?? log.exerciseId;
    final entries = <String>[];
    for (var i = 0; i < sets.length; i++) {
      final set = sets[i];
      final weight =
          set.effectiveWeight > 0 ? '${_formatKg(set.effectiveWeight)}kg ' : '';
      entries.add('${i + 1}) $weight× ${set.reps}');
    }
    lines.add('$name: ${entries.join(', ')}');
  }

  if (lines.isEmpty) return null;
  final text = lines.join('\n');
  if (text.length <= maxLength) return text;
  return '${text.substring(0, maxLength - 1)}…';
}

String _formatKg(double kg) {
  final rounded = (kg * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}
