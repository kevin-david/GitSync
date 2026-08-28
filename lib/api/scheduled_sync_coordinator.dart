import 'dart:async';

abstract interface class ScheduledSyncService {
  Future<bool> start();

  Stream<Map<String, dynamic>?> on(String method);

  void invoke(String method, [Map<String, dynamic>? args]);
}

class ScheduledSyncException implements Exception {
  const ScheduledSyncException(this.message);

  final String message;

  @override
  String toString() => 'ScheduledSyncException: $message';
}

class ScheduledSyncCompletionQueue {
  final Map<int, List<Completer<void>>> _waiting = {};

  Future<void> waitFor(int repoIndex) {
    final completer = Completer<void>();
    _waiting.putIfAbsent(repoIndex, () => []).add(completer);
    return completer.future;
  }

  void complete(int repoIndex) {
    for (final completer in _waiting.remove(repoIndex) ?? const <Completer<void>>[]) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  void completeError(int repoIndex, Object error, StackTrace stackTrace) {
    for (final completer in _waiting.remove(repoIndex) ?? const <Completer<void>>[]) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
  }
}

class ScheduledSyncCoordinator {
  ScheduledSyncCoordinator(
    this._service, {
    String Function()? requestId,
    this.readinessProbeInterval = const Duration(milliseconds: 250),
    this.startupTimeout = const Duration(seconds: 10),
    this.completionTimeout = const Duration(minutes: 4),
  }) : _requestId = requestId ?? (() => DateTime.now().microsecondsSinceEpoch.toString());

  static const pingEvent = 'scheduledSyncPing';
  static const readyEvent = 'scheduledSyncReady';
  static const syncEvent = 'scheduledSync';
  static const completeEvent = 'scheduledSyncComplete';

  final ScheduledSyncService _service;
  final String Function() _requestId;
  final Duration readinessProbeInterval;
  final Duration startupTimeout;
  final Duration completionTimeout;

  Future<void> run({required int repoIndex}) async {
    final requestId = _requestId();
    if (!await _service.start()) {
      throw const ScheduledSyncException('Background sync service failed to start');
    }

    await _waitUntilReady(requestId);

    final completion = _service.on(completeEvent).firstWhere((event) => event?['requestId'] == requestId).timeout(completionTimeout);
    _service.invoke(syncEvent, {'requestId': requestId, 'repoIndex': repoIndex});

    try {
      final result = await completion;
      if (result?['success'] != true) {
        throw ScheduledSyncException(result?['error']?.toString() ?? 'Scheduled sync failed');
      }
    } on TimeoutException {
      throw const ScheduledSyncException('Scheduled sync timed out');
    }
  }

  Future<void> _waitUntilReady(String requestId) async {
    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final ready = _service.on(readyEvent).firstWhere((event) => event?['requestId'] == requestId).timeout(readinessProbeInterval);
      _service.invoke(pingEvent, {'requestId': requestId});
      try {
        await ready;
        return;
      } on TimeoutException {
        // The service isolate may still be starting. Probe again until the
        // startup deadline so the first message cannot be lost in that gap.
      }
    }

    throw const ScheduledSyncException('Background sync service did not become ready');
  }
}
