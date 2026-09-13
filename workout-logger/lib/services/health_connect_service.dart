import 'dart:math' show max;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:health_connector/health_connector.dart';

import '../models/models.dart';
import 'interfaces/health_connect_service_interface.dart';
import 'utils/hc_session_builder.dart';

class HealthConnectService implements IHealthConnectService {
  HealthConnector? _connector;

  static const _statusDeadline = Duration(seconds: 5);
  static const _queryDeadline = Duration(seconds: 10);
  static const _hrQueryDeadline = Duration(seconds: 20);

  Future<HealthConnector?> _getConnector() async {
    try {
      _connector ??= await HealthConnector.create().timeout(_statusDeadline);
      return _connector;
    } catch (e) {
      debugPrint('[HC] _getConnector failed: $e');
      return null;
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final status = await HealthConnector.getHealthPlatformStatus().timeout(_statusDeadline);
      debugPrint('[HC] isAvailable: platform status = $status');
      return status == HealthPlatformStatus.available;
    } catch (e) {
      debugPrint('[HC] isAvailable: exception = $e');
      return false;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    try {
      final connector = await _getConnector();
      if (connector == null) return false;
      final results = await connector.requestPermissions([
        HealthDataType.exerciseSession.writePermission,
        HealthDataType.exerciseSession.readPermission,
      ]);
      return results.every((r) => r.status == PermissionStatus.granted);
    } catch (e) {
      debugPrint('Health Connect requestPermissions failed: $e');
      return false;
    }
  }

  @override
  Future<bool> hasPermissions() async {
    try {
      final connector = await _getConnector();
      if (connector == null) return false;
      final status = await connector.getPermissionStatus(
        HealthDataType.exerciseSession.writePermission,
      ).timeout(_statusDeadline);
      return status == PermissionStatus.granted;
    } catch (_) {
      return false;
    }
  }

  static final Map<HealthReadType, HealthDataPermission> _readPermissions = {
    HealthReadType.sleep: HealthDataType.sleepSession.readPermission,
    // heartRateSeries maps to Android HeartRateRecord (series with samples).
    // heartRate is iOS-only and throws UNSUPPORTED_OPERATION on Health Connect.
    HealthReadType.heartRate: HealthDataType.heartRateSeries.readPermission,
    HealthReadType.restingHeartRate:
        HealthDataType.restingHeartRate.readPermission,
    HealthReadType.hrv: HealthDataType.heartRateVariabilityRMSSD.readPermission,
  };

  @override
  Future<bool> requestReadPermissions() async {
    debugPrint('[HC] requestReadPermissions: requesting ${_readPermissions.length} permissions individually');
    final connector = await _getConnector();
    if (connector == null) return false;
    var anyGranted = false;
    for (final entry in _readPermissions.entries) {
      try {
        final results = await connector.requestPermissions([entry.value]);
        final granted = results.any((r) => r.status == PermissionStatus.granted);
        debugPrint('[HC] requestReadPermissions: ${entry.key} → granted=$granted');
        if (granted) anyGranted = true;
      } catch (e) {
        debugPrint('[HC] requestReadPermissions: ${entry.key} unsupported, skipping ($e)');
      }
    }
    debugPrint('[HC] requestReadPermissions: anyGranted = $anyGranted');
    return anyGranted;
  }

  @override
  Future<Set<HealthReadType>> grantedReadTypes() async {
    final connector = await _getConnector();
    if (connector == null) return {};
    final granted = <HealthReadType>{};
    for (final entry in _readPermissions.entries) {
      try {
        final status = await connector.getPermissionStatus(entry.value).timeout(_statusDeadline);
        debugPrint('[HC] grantedReadTypes: ${entry.key} → $status');
        if (status == PermissionStatus.granted) granted.add(entry.key);
      } catch (e) {
        debugPrint('[HC] grantedReadTypes: ${entry.key} unsupported, skipping ($e)');
      }
    }
    debugPrint('[HC] grantedReadTypes: result = $granted');
    return granted;
  }

  @override
  Future<List<SleepPeriod>> readSleepSessions(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final connector = await _getConnector();
      if (connector == null) return const [];
      final response = await connector.readRecords(
        HealthDataType.sleepSession.readInTimeRange(
          startTime: start,
          endTime: end,
        ),
      ).timeout(_queryDeadline);
      final result = response.records.map((r) {
        // Tally stage durations from embedded SleepStageSamples and build
        // an ordered stage timeline for HR segment colouring.
        var light = 0, deep = 0, rem = 0, awake = 0;
        final timeline = <SleepStageInterval>[];
        var cursor = r.startTime;
        for (final s in r.samples) {
          final segEnd = cursor.add(s.duration);
          final mins = s.duration.inMinutes;
          switch (s.stageType) {
            case SleepStage.light:
            case SleepStage.sleeping: // generic "asleep" — count as light
              light += mins;
              timeline.add(SleepStageInterval(start: cursor, end: segEnd, stage: 'light'));
            case SleepStage.deep:
              deep += mins;
              timeline.add(SleepStageInterval(start: cursor, end: segEnd, stage: 'deep'));
            case SleepStage.rem:
              rem += mins;
              timeline.add(SleepStageInterval(start: cursor, end: segEnd, stage: 'rem'));
            case SleepStage.awake:
            case SleepStage.outOfBed:
            case SleepStage.inBed:
              awake += mins;
              timeline.add(SleepStageInterval(start: cursor, end: segEnd, stage: 'awake'));
            case SleepStage.unknown:
              break;
          }
          cursor = segEnd;
        }
        final hasStages = r.samples.isNotEmpty;
        final period = SleepPeriod(
          start: r.startTime,
          end: r.endTime,
          lightMinutes: hasStages ? light : null,
          deepMinutes: hasStages ? deep : null,
          remMinutes: hasStages ? rem : null,
          awakeMinutes: hasStages ? awake : null,
          stageTimeline: timeline,
        );
        debugPrint('[HC]   sleep ${r.startTime.toLocal().hour}:${r.startTime.toLocal().minute.toString().padLeft(2, '0')}'
            '→${r.endTime.toLocal().hour}:${r.endTime.toLocal().minute.toString().padLeft(2, '0')}'
            ' actual=${period.minutes}min'
            '${hasStages ? " (L=$light D=$deep R=$rem A=$awake)" : " (no stages)"}');
        return period;
      }).toList();
      debugPrint('[HC] readSleepSessions [$start → $end]: ${result.length} records');
      return result;
    } catch (e) {
      debugPrint('[HC] readSleepSessions failed: $e');
      return const [];
    }
  }

  @override
  Future<List<HealthSample>> readRestingHeartRate(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final connector = await _getConnector();
      if (connector == null) return const [];
      final response = await connector.readRecords(
        HealthDataType.restingHeartRate.readInTimeRange(
          startTime: start,
          endTime: end,
        ),
      ).timeout(_queryDeadline);
      final result = response.records
          .map((r) => HealthSample(time: r.time, value: r.rate.inPerMinute))
          .toList();
      debugPrint('[HC] readRestingHeartRate [$start → $end]: ${result.length} records');
      return result;
    } catch (e) {
      debugPrint('[HC] readRestingHeartRate failed: $e');
      return const [];
    }
  }

  @override
  Future<List<HealthSample>> readHrvRmssd(DateTime start, DateTime end) async {
    try {
      final connector = await _getConnector();
      if (connector == null) return const [];
      final response = await connector.readRecords(
        HealthDataType.heartRateVariabilityRMSSD.readInTimeRange(
          startTime: start,
          endTime: end,
        ),
      ).timeout(_queryDeadline);
      final result = response.records
          .map((r) => HealthSample(time: r.time, value: r.rmssd.inMilliseconds))
          .toList();
      debugPrint('[HC] readHrvRmssd [$start → $end]: ${result.length} records');
      return result;
    } catch (e) {
      debugPrint('[HC] readHrvRmssd failed: $e');
      return const [];
    }
  }

  @override
  Future<List<HealthSample>> readHeartRateSamples(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final connector = await _getConnector();
      if (connector == null) return const [];
      // heartRateSeries = Android HeartRateRecord (container with BPM samples).
      // heartRate is iOS-only and throws UNSUPPORTED_OPERATION on Health Connect.
      final response = await connector.readRecords(
        HealthDataType.heartRateSeries.readInTimeRange(
          startTime: start,
          endTime: end,
          pageSize: 5000,
        ),
      ).timeout(_hrQueryDeadline);
      final samples = response.records
          .expand(
            (r) => r.samples.map(
              (s) => HealthSample(time: s.time, value: s.rate.inPerMinute),
            ),
          )
          .toList();
      debugPrint('[HC] readHeartRateSamples [$start → $end]: '
          '${response.records.length} series records, ${samples.length} samples');
      return samples;
    } catch (e) {
      debugPrint('[HC] readHeartRateSamples failed: $e');
      return const [];
    }
  }

  static bool _segmentWeightUnsupported = false;

  @visibleForTesting
  static void resetSegmentWeightSupport() => _segmentWeightUnsupported = false;

  /// Runs [write] with segment weights, retrying once without them when the
  /// device's Health Connect module predates SDK Extension 21. Without this
  /// the whole session — reps, segments and all — would fail to sync there.
  @visibleForTesting
  static Future<bool> writeWithWeightFallback(
    Future<void> Function({required bool includeWeight}) write,
  ) async {
    try {
      await write(includeWeight: !_segmentWeightUnsupported);
      return true;
    } on UnsupportedOperationException catch (e) {
      if (_segmentWeightUnsupported) {
        debugPrint('[HC] write failed without segment weight: $e');
        return false;
      }
      _segmentWeightUnsupported = true;
      debugPrint('[HC] segment weight unsupported, retrying without it: $e');
      try {
        await write(includeWeight: false);
        return true;
      } catch (retryError) {
        debugPrint('[HC] weightless retry failed: $retryError');
        return false;
      }
    }
  }

  @override
  Future<bool> syncWorkoutSession(
    WorkoutSession session, {
    String? title,
    Map<String, String>? exerciseNames,
  }) async {
    try {
      final connector = await _getConnector();
      if (connector == null) return false;

      final sessionStart = session.date;
      final durationMinutes = max(session.duration, 1);
      final sessionEnd = sessionStart.add(Duration(minutes: durationMinutes));

      Future<void> write({required bool includeWeight}) async {
        final record = ExerciseSessionRecord(
          startTime: sessionStart,
          endTime: sessionEnd,
          exerciseType: ExerciseType.strengthTraining,
          metadata: Metadata.manualEntry(clientRecordId: 'workout_${session.id}'),
          title: title?.isNotEmpty == true ? title : null,
          notes: buildHcNotes(
            session: session,
            exerciseNames: exerciseNames ?? const {},
          ),
          events: buildHcSegments(
            session: session,
            sessionStart: sessionStart,
            sessionEnd: sessionEnd,
            includeWeight: includeWeight,
          ),
        );
        await connector.writeRecords([record]).timeout(_queryDeadline);
      }

      return await writeWithWeightFallback(write);
    } catch (e) {
      debugPrint('Health Connect sync failed: $e');
      return false;
    }
  }
}
