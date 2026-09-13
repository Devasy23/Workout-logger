// Main App Entry Point
//
// Following Dependency Inversion Principle: we create concrete implementations
// here at the composition root and inject them into high-level modules.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'services/debug_log_buffer.dart';
import 'services/storage_service.dart';
import 'services/sqlite_storage_service.dart';
import 'services/storage_backend_resolver.dart';
import 'services/ai/sql_query_service.dart';
import 'services/ml_service.dart';
import 'services/ai/gemini_ai_service.dart';
import 'services/ai/coach_tool_service.dart';
import 'services/health_connect_service.dart';
import 'services/health_data_sync_service.dart';
import 'services/interfaces/storage_service_interface.dart';
import 'services/interfaces/ml_service_interface.dart';
import 'services/interfaces/health_connect_service_interface.dart';
import 'services/workout_provider.dart';
import 'services/settings_provider.dart';
import 'services/managers/program_manager.dart';
import 'services/managers/history_manager.dart';
import 'services/managers/health_sync_manager.dart';
import 'services/managers/pr_manager.dart';
import 'services/managers/readiness_manager.dart';
import 'services/managers/health_history_manager.dart';
import 'services/managers/conversation_manager.dart';
import 'theme/app_theme.dart';
import 'genui/a2ui.dart';
import 'theme/a2ui_app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/widgets/rf_widgets.dart';

/// Resolved once in main() before runApp(). Read lazily by
/// WorkoutLoggerApp._storageService's static initializer, which only runs
/// on first access (during build()) — by then this is already set.
IStorageService? _resolvedStorageService;

/// One-time, flag-gated, reversible Hive -> SQLite cutover. See
/// docs/superpowers/specs/2026-08-08-sqlite-migration-and-coach-sql-tool-design.md §6.
Future<void> _resolveStorageBackend() async {
  // Hive must be initialized before the cutover check itself, since the
  // migration flag below is read directly from the Hive 'settings' box.
  await Hive.initFlutter();
  final settingsBox = await Hive.openBox<String>('settings');
  final alreadyMigrated = settingsBox.get(storageMigratedFlagKey) == 'true';

  if (alreadyMigrated) {
    final sqlite = SqliteStorageService();
    try {
      await sqlite.init();
    } catch (e, st) {
      debugPrint('SQLite init failed, staying on Hive: $e\n$st');
      final hiveStorage = StorageService();
      await hiveStorage.init();
      _resolvedStorageService = hiveStorage;
      return;
    }
    _resolvedStorageService = sqlite;
    return;
  }

  final hiveStorage = StorageService();
  await hiveStorage.init();
  final sqliteStorage = SqliteStorageService();

  try {
    await sqliteStorage.init();
  } catch (e, st) {
    debugPrint('SQLite init failed, staying on Hive: $e\n$st');
    _resolvedStorageService = hiveStorage;
    return;
  }

  _resolvedStorageService = await resolveStorageBackend(
    hiveStorage: hiveStorage,
    sqliteStorage: sqliteStorage,
    alreadyMigrated: false,
  );
}

void main() async {
  DebugLogBuffer.attach();
  WidgetsFlutterBinding.ensureInitialized();

  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Enable edge-to-edge: draw behind status bar AND nav bar
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Keep all system overlays transparent; content uses SafeArea for insets
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  await _resolveStorageBackend();

  runApp(const WorkoutLoggerApp());
}

class WorkoutLoggerApp extends StatelessWidget {
  // Singleton instances created once at app startup
  // This ensures the same instances are used throughout the app lifecycle
  static final IStorageService _storageService = _resolvedStorageService ?? StorageService();
  static final IMLService _mlService = MLService();
  static final IHealthConnectService _healthConnectService = HealthConnectService();
  static final ProgramManager _programManager = ProgramManager(_storageService);
  static final SettingsProvider _settingsProvider = SettingsProvider(_storageService);
  /// HealthSyncManager reads the in-memory settings flag; storage is used
  /// only for a one-time exercise-name lookup used in the Health Connect notes.
  static final HealthSyncManager _healthSyncManager =
      HealthSyncManager(_healthConnectService, _settingsProvider, storage: _storageService);
  // HistoryManager is the single owner of session history + HC sync trigger.
  static final HistoryManager _historyManager =
      HistoryManager(_storageService, healthSyncManager: _healthSyncManager);
  static final PRManager _prManager = PRManager(_storageService);
  // ReadinessManager reads HC sleep/heart data; gated by the in-memory
  // readiness setting so refresh() is a no-op until the user opts in.
  static final ReadinessManager _readinessManager =
      ReadinessManager(_healthConnectService, _storageService, _settingsProvider);
  // Serves arbitrary-range sleep/HR data to the detail screens.
  static final HealthHistoryManager _healthHistoryManager =
      HealthHistoryManager(_healthConnectService, _storageService);
  // Populates the SQLite health tables the coach's run_sql_query tool joins
  // against workout data. Null under the pre-migration Hive fallback path —
  // there's no live SQLite database file to sync into. Mirrors the
  // sqlQuery ? ... : null guard used for CoachToolService below.
  static final HealthDataSyncService? _healthDataSyncService =
      _storageService is SqliteStorageService
          ? HealthDataSyncService(
              healthConnectService: _healthConnectService,
              storage: _storageService as SqliteStorageService,
            )
          : null;
  static final GeminiAiService _geminiService =
      GeminiAiService(storage: _storageService);
  static final ConversationManager _conversationManager =
      ConversationManager(_storageService);

  const WorkoutLoggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Composition Root: Provide the singleton implementations
    // This is the only place where we reference concrete implementations.
    // All other code depends on abstractions (interfaces).
    return MultiProvider(
      providers: [
        // Provide the storage service interface for direct access if needed
        Provider<IStorageService>.value(value: _storageService),
        // Provide the ML service interface for direct access if needed
        Provider<IMLService>.value(value: _mlService),
        // IHealthConnectService stays in tree for ProfileScreen permission flow
        Provider<IHealthConnectService>.value(value: _healthConnectService),
        // ProgramManager passed to tree directly
        ChangeNotifierProvider<ProgramManager>.value(value: _programManager),
        // SettingsProvider for user preferences (weight unit, increments)
        ChangeNotifierProvider<SettingsProvider>.value(value: _settingsProvider),
        // HistoryManager is the single source of truth for session history.
        // Provided as ChangeNotifier so HistoryScreen rebuilds on sync badge changes.
        ChangeNotifierProvider<HistoryManager>.value(value: _historyManager),
        ChangeNotifierProvider<PRManager>.value(value: _prManager),
        ChangeNotifierProvider<ReadinessManager>.value(value: _readinessManager),
        Provider<HealthHistoryManager>.value(value: _healthHistoryManager),
        Provider<HealthDataSyncService?>.value(value: _healthDataSyncService),
        // GeminiAiService is the single AI backend instance. It's a ChangeNotifier
        // (settings UI watches isConfigured/model), so it's provided as such.
        // Consumers that should depend on the abstraction (the coach ViewModel,
        // program generator) receive it typed as IAiService at construction —
        // the future firebase_ai swap point — without a separate provider.
        ChangeNotifierProvider<GeminiAiService>.value(value: _geminiService),
        ChangeNotifierProvider<ConversationManager>.value(
          value: _conversationManager,
        ),
        // WorkoutProvider receives dependencies via constructor injection
        ChangeNotifierProvider(
          create: (_) => WorkoutProvider(
            _storageService,
            mlService: _mlService,
            historyManager: _historyManager,
            programManager: _programManager,
          ),
        ),
        // CoachToolService backs AI tool calls; reads from WorkoutProvider + PRManager.
        // run_sql_query is only offered once the app has cut over to SQLite —
        // it needs a live database file to open a read-only connection against.
        Provider<CoachToolService>(
          create: (ctx) => CoachToolService(
            workoutProvider: ctx.read<WorkoutProvider>(),
            prManager: ctx.read<PRManager>(),
            healthHistory: ctx.read<HealthHistoryManager>(),
            sqlQuery: _storageService is SqliteStorageService
                ? SqlQueryService((_storageService as SqliteStorageService).databasePath)
                : null,
          ),
        ),
      ],
      child: A2UiThemeProvider(
        theme: repforgeA2UiTheme,
        child: MaterialApp(
          title: 'Workout Logger',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.darkTheme,
          // Above the Navigator, so every route feeds the ambient glow.
          builder: (context, child) =>
              AmbientMotionScope(child: child ?? const SizedBox.shrink()),
          home: const AppInitializer(),
        ),
      ),
    );
  }
}

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer> {
  bool _initialized = false;
  bool _needsNamePrompt = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Capture all providers synchronously before any awaits.
    final provider = context.read<WorkoutProvider>();
    final settings = context.read<SettingsProvider>();
    final historyManager = context.read<HistoryManager>();
    final prManager = context.read<PRManager>();
    final gemini = context.read<GeminiAiService>();
    final readiness = context.read<ReadinessManager>();
    final healthDataSync = context.read<HealthDataSyncService?>();

    try {
      await provider.init();
      await settings.init();
      gemini.init(
        settings.geminiApiKey,
        model: settings.geminiModel,
        maxToolRounds: settings.geminiMaxToolRounds,
        thinkingLevel: settings.geminiThinkingLevel,
      );
      try {
        await gemini.loadUsage();
      } catch (e, st) {
        debugPrint('gemini.loadUsage failed: $e\n$st');
      }
      await historyManager.loadSessions();
      await prManager.load();
      await prManager.backfillFromSessions(historyManager.sessions);

      final version = await settings.getCurrentVersion();
      final needsName = settings.userName == null || settings.userName!.isEmpty;
      final versionChanged = !needsName &&
          settings.lastSeenVersion != null &&
          settings.lastSeenVersion != version;

      // Fire-and-forget readiness refresh — must run after settings.init()
      // so the opt-in flag is loaded; never blocks or fails app init.
      readiness.refresh();

      // Fire-and-forget: populates the SQLite tables run_sql_query joins
      // against. No-op under the pre-migration Hive fallback (null there).
      // Errors are swallowed here since main.dart discards the returned
      // Future — sync() has no caller to propagate a failure to.
      unawaited(
        healthDataSync?.sync().catchError(
          (Object e, StackTrace st) =>
              debugPrint('healthDataSync.sync failed: $e\n$st'),
        ),
      );

      if (!mounted) return;
      setState(() {
        _initialized = true;
        _needsNamePrompt = needsName;
      });

      if (!needsName && versionChanged) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          await showVersionUpdateSheet(context, version);
          if (mounted) await settings.markVersionSeen(version);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              Text(
                'Failed to initialize app',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _initialized = false;
                  });
                  _initializeApp();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.fitness_center,
                size: 64,
                color: AppTheme.primaryColor,
              ),
              const SizedBox(height: 24),
              Text(
                'Workout Logger',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(color: AppTheme.primaryColor),
            ],
          ),
        ),
      );
    }

    if (_needsNamePrompt) {
      return WelcomePage(
        onComplete: () => setState(() => _needsNamePrompt = false),
      );
    }

    return const HomeScreen();
  }
}
