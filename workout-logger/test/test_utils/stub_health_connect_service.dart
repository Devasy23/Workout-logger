import 'package:repforge/models/models.dart';
import 'package:repforge/services/interfaces/health_connect_service_interface.dart';

class StubHcService implements IHealthConnectService {
  final List<SleepPeriod> sleepPeriods;
  final List<HealthSample> hrSamples;
  final List<HealthSample> restingHrSamples;

  const StubHcService({
    this.sleepPeriods = const [],
    this.hrSamples = const [],
    this.restingHrSamples = const [],
  });

  @override
  Future<List<SleepPeriod>> readSleepSessions(DateTime start, DateTime end) async => List.from(sleepPeriods);
  @override
  Future<List<HealthSample>> readHeartRateSamples(DateTime start, DateTime end) async => List.from(hrSamples);
  @override
  Future<List<HealthSample>> readRestingHeartRate(DateTime start, DateTime end) async => List.from(restingHrSamples);
  @override
  Future<Set<HealthReadType>> grantedReadTypes() async => {HealthReadType.heartRate, HealthReadType.sleep, HealthReadType.restingHeartRate};
  @override
  Future<List<HealthSample>> readHrvRmssd(DateTime start, DateTime end) async => const [];
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
