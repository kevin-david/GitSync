import 'dart:async';
import 'dart:io';

import 'package:GitSync/api/manager/storage.dart';
import 'package:GitSync/api/scheduled_sync_coordinator.dart';
import 'package:GitSync/api/sync_toast_trigger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:GitSync/api/manager/repo_manager.dart';
import 'package:GitSync/type/git_provider.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';
import '../api/helper.dart';
import '../api/logger.dart';
import '../api/manager/git_manager.dart';
import '../api/manager/settings_manager.dart';
import '../constant/strings.dart';

ServiceInstance? serviceInstance;

class ServiceStrings {
  final String syncStartPull;
  final String syncStartPush;
  final String syncNotRequired;
  final String syncComplete;
  final String syncInProgress;
  final String syncScheduled;
  final String detectingChanges;
  final String ongoingMergeConflict;
  final String networkStallRetry;
  final String networkUnavailableRetry;
  final String networkStallManual;
  final String networkUnavailableManual;
  final String networkRetryComplete;

  const ServiceStrings({
    required this.syncStartPull,
    required this.syncStartPush,
    required this.syncNotRequired,
    required this.syncComplete,
    required this.syncInProgress,
    required this.syncScheduled,
    required this.detectingChanges,
    required this.ongoingMergeConflict,
    required this.networkStallRetry,
    required this.networkUnavailableRetry,
    required this.networkStallManual,
    required this.networkUnavailableManual,
    required this.networkRetryComplete,
  });

  factory ServiceStrings.fromMap(Map<String, dynamic> map) {
    return ServiceStrings(
      syncStartPull: map['syncStartPull'] ?? '',
      syncStartPush: map['syncStartPush'] ?? '',
      syncNotRequired: map['syncNotRequired'] ?? '',
      syncComplete: map['syncComplete'] ?? '',
      syncInProgress: map['syncInProgress'] ?? '',
      syncScheduled: map['syncScheduled'] ?? '',
      detectingChanges: map['detectingChanges'] ?? '',
      ongoingMergeConflict: map['ongoingMergeConflict'] ?? '',
      networkStallRetry: map['networkStallRetry'] ?? '',
      networkUnavailableRetry: map['networkUnavailableRetry'] ?? '',
      networkStallManual: map['networkStallManual'] ?? '',
      networkUnavailableManual: map['networkUnavailableManual'] ?? '',
      networkRetryComplete: map['networkRetryComplete'] ?? '',
    );
  }

  Map<String, String> toMap() {
    return {
      'syncStartPull': syncStartPull,
      'syncStartPush': syncStartPush,
      'syncNotRequired': syncNotRequired,
      'syncComplete': syncComplete,
      'syncInProgress': syncInProgress,
      'syncScheduled': syncScheduled,
      'detectingChanges': detectingChanges,
      'ongoingMergeConflict': ongoingMergeConflict,
      'networkStallRetry': networkStallRetry,
      'networkUnavailableRetry': networkUnavailableRetry,
      'networkStallManual': networkStallManual,
      'networkUnavailableManual': networkUnavailableManual,
      'networkRetryComplete': networkRetryComplete,
    };
  }
}

class GitsyncService {
  static const ACCESSIBILITY_EVENT = "ACCESSIBILITY_EVENT";
  static const FORCE_SYNC = "FORCE_SYNC";
  static const MANUAL_SYNC = "MANUAL_SYNC";
  static const INTENT_SYNC = "INTENT_SYNC";
  static const TILE_SYNC = "TILE_SYNC";
  static const UPDATE_SERVICE_STRINGS = "UPDATE_SERVICE_STRINGS";
  static const MERGE = "MERGE";
  static const MERGE_COMPLETE = "MERGE_COMPLETE";
  static const repoIndex = "repoIndex";

  static RepoManager repoManager = RepoManager();

  ServiceStrings s = ServiceStrings(
    syncStartPull: "Syncing changes…",
    syncStartPush: "Syncing local changes…",
    syncNotRequired: "Sync not required!",
    syncComplete: "Repository synced!",
    syncInProgress: "Sync In Progress",
    syncScheduled: "Sync Scheduled",
    detectingChanges: "Detecting Changes…",
    ongoingMergeConflict: "Ongoing merge conflict",
    networkStallRetry: "Poor network — will retry shortly",
    networkUnavailableRetry: "Network unavailable — will retry when reconnected",
    networkStallManual: "Poor network — please try again",
    networkUnavailableManual: "Network unavailable — please try again",
    networkRetryComplete: "Queued operation completed",
  );

  final Set<int> scheduledIndices = {};
  final ScheduledSyncCompletionQueue _scheduledSyncCompletions = ScheduledSyncCompletionQueue();
  final Map<int, SyncToastTrigger> _queuedSyncToastTriggers = {};
  bool isSyncing = false;

  static const String _widgetStatusKey = 'forceSyncWidget_status';
  // Must point at the Receiver (registered in AndroidManifest.xml), not the
  // GlanceAppWidget class. updateWidget resolves this FQN via Class.forName
  // and queries AppWidgetManager.getAppWidgetIds for that component.
  static const String _widgetQualifiedName = 'com.viscouspot.gitsync.widget.ForceSyncWidgetReceiver';
  // Matches the `kind` declared in ios/ForceSyncWidget/ForceSyncWidget.swift.
  // Used by WidgetCenter.shared.reloadTimelines(ofKind:) on iOS.
  static const String _widgetIOSName = 'ForceSyncWidget';

  int _syncGeneration = 0;
  Timer? _widgetRevertTimer;

  Future<void> _updateForceSyncWidget(String status) async {
    try {
      await HomeWidget.saveWidgetData(_widgetStatusKey, status);
      await HomeWidget.updateWidget(qualifiedAndroidName: _widgetQualifiedName, iOSName: _widgetIOSName);
    } catch (e) {
      // Widget not placed or platform doesn't support it — logged for diagnosis.
      print('ForceSyncWidget update failed: $e');
    }
  }

  Future<void> _finishWidget(String terminal) async {
    final int gen = _syncGeneration;
    await _updateForceSyncWidget(terminal);
    _widgetRevertTimer?.cancel();
    if (Platform.isIOS) {
      // iOS runs _sync inline in the widget-callback isolate which tears
      // down when backgroundCallback returns — the async Timer used on
      // Android would never fire. Await the revert inline instead.
      await Future.delayed(const Duration(seconds: 2));
      if (_syncGeneration == gen && !isSyncing) {
        await _updateForceSyncWidget('idle');
      }
    } else {
      _widgetRevertTimer = Timer(const Duration(seconds: 2), () {
        if (_syncGeneration == gen && !isSyncing) {
          _updateForceSyncWidget('idle');
        }
      });
    }
  }

  Future<void> resetForceSyncWidget() async {
    _widgetRevertTimer?.cancel();
    await _updateForceSyncWidget('idle');
  }

  Future<void> initialise(Function(ServiceInstance) onServiceStart, Function() callbackDispatcher) async {
    final service = FlutterBackgroundService();

    Workmanager().initialize(callbackDispatcher, isInDebugMode: kDebugMode);

    await service.configure(
      androidConfiguration: AndroidConfiguration(autoStart: true, acquireWakeLock: false, isForegroundMode: false, onStart: onServiceStart),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onServiceStart,
        onBackground: (service) {
          onServiceStart(service);
          return true;
        },
      ),
    );
  }

  void initialiseStrings(Map<String, dynamic> stringMap) {
    s = ServiceStrings.fromMap(stringMap);
  }

  Future<void> debouncedSync(
    int repomanRepoindex, [
    bool forced = false,
    bool immediate = false,
    String? syncMessage,
    int retryCount = 0,
    SyncToastTrigger? toastTrigger,
  ]) async {
    await _scheduleSync(repomanRepoindex, forced, immediate, syncMessage, retryCount, toastTrigger: toastTrigger);
  }

  Future<void> runScheduledSync(int repomanRepoindex) async {
    final result = await _scheduleSync(
      repomanRepoindex,
      true,
      true,
      null,
      0,
      toastTrigger: const SyncToastTrigger.scheduled(),
      trackQueuedCompletion: true,
    );
    final queuedCompletion = result.$2;
    if (queuedCompletion != null) await queuedCompletion;
  }

  Future<(bool, Future<void>?)> _scheduleSync(
    int repomanRepoindex,
    bool forced,
    bool immediate,
    String? syncMessage,
    int retryCount, {
    SyncToastTrigger? toastTrigger,
    bool trackQueuedCompletion = false,
  }) async {
    final settingsManager = SettingsManager();
    await settingsManager.reinit(repoIndex: repomanRepoindex);

    if (scheduledIndices.contains(repomanRepoindex)) {
      if (toastTrigger != null) _queuedSyncToastTriggers.putIfAbsent(repomanRepoindex, () => toastTrigger);
      await _displaySyncMessage(settingsManager, toastTrigger?.message(SyncToastStatus.queued) ?? s.syncInProgress);
      return (false, trackQueuedCompletion ? _scheduledSyncCompletions.waitFor(repomanRepoindex) : null);
    } else {
      if (isSyncing) {
        scheduledIndices.add(repomanRepoindex);
        if (toastTrigger != null) _queuedSyncToastTriggers.putIfAbsent(repomanRepoindex, () => toastTrigger);
        Logger.gmLog(type: LogType.Sync, "Sync Scheduled");
        await _displaySyncMessage(settingsManager, toastTrigger?.message(SyncToastStatus.queued) ?? s.syncScheduled);
        return (false, trackQueuedCompletion ? _scheduledSyncCompletions.waitFor(repomanRepoindex) : null);
      } else {
        if (toastTrigger != null) {
          await _displaySyncMessage(settingsManager, toastTrigger.message(SyncToastStatus.syncing));
        }
        if (immediate) {
          await _sync(repomanRepoindex, forced, syncMessage, retryCount, toastTrigger);
          return (true, null);
        }
        debounce(repomanRepoindex.toString(), 500, () => _sync(repomanRepoindex, forced, syncMessage, retryCount, toastTrigger));
        return (true, null);
      }
    }
  }

  Future<void> _drainScheduledSyncs(Set<int> repoIndices) async {
    for (final repoIndex in repoIndices) {
      Logger.gmLog(type: LogType.Sync, "Scheduled Sync Starting");
      try {
        await _sync(repoIndex, false, null, 0, _queuedSyncToastTriggers.remove(repoIndex));
        _scheduledSyncCompletions.complete(repoIndex);
      } catch (error, stackTrace) {
        _scheduledSyncCompletions.completeError(repoIndex, error, stackTrace);
      }
    }
  }

  void _cancelScheduledSync(int repoIndex, String reason) {
    scheduledIndices.remove(repoIndex);
    _queuedSyncToastTriggers.remove(repoIndex);
    _scheduledSyncCompletions.completeError(repoIndex, ScheduledSyncException(reason), StackTrace.current);
  }

  Future<void> _displaySyncMessage(SettingsManager? settingsManager, String message) async {
    if (settingsManager == null || await settingsManager.getBool(StorageKey.setman_syncMessageEnabled)) {
      if (Platform.isIOS) {
        final active = await Logger.notificationsPlugin.getActiveNotifications();
        final alreadyShowing = active.any((n) => n.id == syncStatusNotificationId);

        final darwinDetails = DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: !alreadyShowing,
        );
        await Logger.notificationsPlugin.show(syncStatusNotificationId, appName, message, NotificationDetails(iOS: darwinDetails));
      } else {
        await Fluttertoast.showToast(msg: message, toastLength: Toast.LENGTH_LONG, gravity: null);
      }
    }
  }

  Future<void> _sync(int repomanRepoindex, [bool forced = false, String? syncMessage, int retryCount = 0, SyncToastTrigger? toastTrigger]) async {
    _syncGeneration++;
    final int myGen = _syncGeneration;
    String terminal = 'success';
    try {
      isSyncing = true;
      await _updateForceSyncWidget('syncing');

      Logger.gmLog(type: LogType.Sync, "Sync started for repo $repomanRepoindex (forced: $forced)");

      final settingsManager = SettingsManager();
      await settingsManager.reinit(repoIndex: repomanRepoindex);

      final provider = await settingsManager.getGitProvider();

      final remotesList = await GitManager.listRemotes(repomanRepoindex, 3);
      if (remotesList.isEmpty) {
        Logger.gmLog(type: LogType.Sync, "No remote configured, skipping sync");
        _cancelScheduledSync(repomanRepoindex, 'No remote configured');
        terminal = 'error';
        return;
      }

      if (provider == GitProvider.SSH
          ? (await settingsManager.getGitSshAuthCredentials()).$2.isEmpty
          : (await settingsManager.getGitHttpAuthCredentials()).$2.isEmpty) {
        Logger.gmLog(type: LogType.Sync, "Credentials Not Found");
        _displaySyncMessage(null, "Credentials not found");
        _cancelScheduledSync(repomanRepoindex, 'Credentials not found');
        terminal = 'error';
        return;
      }
      if ((await GitManager.getConflicting(repomanRepoindex, 3)).isNotEmpty) {
        _displaySyncMessage(null, s.ongoingMergeConflict);
        _cancelScheduledSync(repomanRepoindex, 'Ongoing merge conflict');
        terminal = 'error';
        return;
      }

      if (forced && toastTrigger == null) {
        await _displaySyncMessage(settingsManager, s.detectingChanges);
      }
      Logger.gmLog(type: LogType.Sync, "Start Sync $repomanRepoindex");

      bool? pullResult = false;
      bool? pushResult = false;
      bool innerError = false;

      await () async {
        final gitDirPath = (await settingsManager.getGitDirPath())?.$1;

        if (gitDirPath == null) {
          Logger.gmLog(type: LogType.Sync, "Repository Not Found");
          _displaySyncMessage(null, repositoryNotFound);
          innerError = true;
          return;
        }

        bool synced = false;

        final optimisedSyncFlag = await settingsManager.getBool(StorageKey.setman_optimisedSyncExperimental);
        int? recommendedAction = await GitManager.getRecommendedAction(priority: 3, repoIndex: repomanRepoindex);

        if (optimisedSyncFlag && recommendedAction == -1) return;

        if (!optimisedSyncFlag || [0, 1, 2, 3].contains(recommendedAction)) {
          Logger.gmLog(type: LogType.Sync, "Start Pull Repo");
          pullResult = await GitManager.backgroundDownloadChanges(repomanRepoindex, settingsManager, () async {
            synced = true;
            await _displaySyncMessage(settingsManager, s.syncStartPull);
          });

          switch (pullResult) {
            case null:
              {
                Logger.gmLog(type: LogType.Sync, "Pull Repo Failed");
                innerError = true;
                return;
              }
            case true:
              {
                Logger.gmLog(type: LogType.Sync, "Pull Complete");
              }
            case false:
              {
                Logger.gmLog(type: LogType.Sync, "Pull Not Required");
              }
          }
        }

        if ((await GitManager.getConflicting(repomanRepoindex, 3)).isNotEmpty) {
          _displaySyncMessage(null, s.ongoingMergeConflict);
          innerError = true;
          return;
        }

        recommendedAction = await GitManager.getRecommendedAction(priority: 3, repoIndex: repomanRepoindex);
        if (optimisedSyncFlag && recommendedAction == -1) return;

        if (!optimisedSyncFlag || [2, 3].contains(recommendedAction)) {
          Logger.gmLog(type: LogType.Sync, "Start Push Repo");
          pushResult = await GitManager.backgroundUploadChanges(
            repomanRepoindex,
            settingsManager,
            () async {
              if (!synced) {
                await _displaySyncMessage(settingsManager, s.syncStartPush);
              }
            },
            null,
            syncMessage,
            () => debouncedSync(repomanRepoindex),
          );

          switch (pushResult) {
            case null:
              {
                Logger.gmLog(type: LogType.Sync, "Push Repo Failed");
                innerError = true;
                return;
              }
            case true:
              {
                Logger.gmLog(type: LogType.Sync, "Push Complete");
              }
            case false:
              {
                Logger.gmLog(type: LogType.Sync, "Push Not Required");
              }
          }
        }
      }();

      if (innerError) {
        terminal = 'error';
      }

      if (pushResult == null || pullResult == null) {
        Logger.gmLog(type: LogType.Sync, "Sync failed");
      } else if (pushResult == true || pullResult == true) {
        await GitManager.getRecentCommits(repoIndex: repomanRepoindex);
        await _displaySyncMessage(
          settingsManager,
          toastTrigger?.contextualizeResult == true ? toastTrigger!.message(SyncToastStatus.synced) : s.syncComplete,
        );
        Logger.dismissError(null);
        Logger.gmLog(type: LogType.Sync, "Sync Complete!");
      } else {
        if (forced) {
          await _displaySyncMessage(
            settingsManager,
            toastTrigger?.contextualizeResult == true ? toastTrigger!.message(SyncToastStatus.noChanges) : s.syncNotRequired,
          );
        }
        Logger.dismissError(null);
        Logger.gmLog(type: LogType.Sync, "Sync Complete!");
      }

      await GitManager.getRecentCommits(priority: 3, repoIndex: repomanRepoindex);
    } on OperationNotExecuted {
    } catch (e, st) {
      if (!await handleIfNetworkError(e, LogType.Sync, {"repoman_repoIndex": "$repomanRepoindex", "retryCount": retryCount})) {
        Logger.logError(LogType.SyncException, e, st);
        terminal = 'error';
      }
    } finally {
      isSyncing = false;
      if (myGen == _syncGeneration) {
        await _finishWidget(terminal);
      }
      if (scheduledIndices.isNotEmpty) {
        final toSync = scheduledIndices.toSet();
        scheduledIndices.clear();
        unawaited(_drainScheduledSyncs(toSync));
      }
    }
  }

  void merge(int repomanRepoindex, String commitMessage, List<String> conflictingPaths) async {
    final settingsManager = SettingsManager();
    await settingsManager.reinit(repoIndex: repomanRepoindex);

    bool? pushResult = false;

    try {
      if (await settingsManager.getClientModeEnabled()) {
        pushResult = await GitManager.backgroundStageAndCommit(repomanRepoindex, settingsManager, conflictingPaths, commitMessage);
      } else {
        pushResult = await GitManager.backgroundUploadChanges(
          repomanRepoindex,
          settingsManager,
          () {
            _displaySyncMessage(null, resolvingMerge);
          },
          conflictingPaths,
          commitMessage,
          () => debouncedSync(repomanRepoindex),
        );
      }
    } catch (e) {
      if (await handleIfNetworkError(e, LogType.Sync, {"repoman_repoIndex": "$repomanRepoindex", "retryCount": 0})) {
        serviceInstance?.invoke(MERGE_COMPLETE);
        return;
      }
      rethrow;
    }

    switch (pushResult) {
      case null:
        {
          Logger.gmLog(type: LogType.Sync, "Merge Failed");
          serviceInstance?.invoke(MERGE_COMPLETE);
          return;
        }
      case true:
        Logger.gmLog(type: LogType.Sync, "Merge Complete");
      case false:
        Logger.gmLog(type: LogType.Sync, "Merge Not Required");
    }

    if (!await settingsManager.getClientModeEnabled()) {
      debouncedSync(repomanRepoindex, true);
    }

    serviceInstance?.invoke(MERGE_COMPLETE);
  }

  String lastOpenPackageName = conflictSeparator;
  String lastOpenPackageNameExcludingInputs = conflictSeparator;
  String lastOpenApplicationLabelExcludingInputs = conflictSeparator;

  void accessibilityEvent(String packageName, String applicationLabel, List<String> enabledInputMethods) async {
    enabledInputMethods = [...enabledInputMethods];
    final repoNamesLength = (await repoManager.getStringList(StorageKey.repoman_repoNames)).length;
    for (var index = 0; index < repoNamesLength; index++) {
      final settingsManager = await SettingsManager().reinit(repoIndex: index);

      final syncClosed = await settingsManager.getBool(StorageKey.setman_syncOnAppClosed);
      final syncOpened = await settingsManager.getBool(StorageKey.setman_syncOnAppOpened);

      final packageNames = await settingsManager.getApplicationPackages();

      if ((!syncOpened && !syncClosed) || packageNames.isEmpty) continue;

      if (packageNames.contains(lastOpenPackageNameExcludingInputs) &&
          !packageNames.contains(packageName) &&
          !enabledInputMethods.contains(packageName)) {
        Logger.gmLog(type: LogType.AccessibilityService, "Application Closed $lastOpenPackageNameExcludingInputs $index");
        if (syncClosed) {
          debouncedSync(index, false, false, null, 0, SyncToastTrigger.appClosed(lastOpenApplicationLabelExcludingInputs));
        }
      }

      if (!packageNames.contains(lastOpenPackageNameExcludingInputs) &&
          packageNames.contains(packageName) &&
          !enabledInputMethods.contains(packageName)) {
        Logger.gmLog(type: LogType.AccessibilityService, "Application Opened $packageName $index");
        if (syncOpened) {
          debouncedSync(index, false, false, null, 0, SyncToastTrigger.appOpened(applicationLabel));
        }
      }
    }

    lastOpenPackageName = packageName;
    if (!enabledInputMethods.contains(packageName)) {
      lastOpenPackageNameExcludingInputs = packageName;
      lastOpenApplicationLabelExcludingInputs = applicationLabel;
    }
  }
}
