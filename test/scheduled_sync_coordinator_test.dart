import 'dart:async';

import 'package:GitSync/api/scheduled_sync_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeScheduledSyncService implements ScheduledSyncService {
  final controllers = <String, StreamController<Map<String, dynamic>?>>{};
  final invocations = <(String, Map<String, dynamic>?)>[];
  bool startResult = true;
  int startCount = 0;
  void Function(String method, Map<String, dynamic>? args)? onInvoke;

  @override
  Future<bool> start() async {
    startCount++;
    return startResult;
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) => controllers.putIfAbsent(method, () => StreamController.broadcast()).stream;

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    invocations.add((method, args));
    onInvoke?.call(method, args);
  }

  void emit(String method, Map<String, dynamic> args) {
    controllers.putIfAbsent(method, () => StreamController.broadcast()).add(args);
  }

  Future<void> close() async {
    for (final controller in controllers.values) {
      await controller.close();
    }
  }
}

void main() {
  late FakeScheduledSyncService service;
  late ScheduledSyncCoordinator coordinator;

  setUp(() {
    service = FakeScheduledSyncService();
    coordinator = ScheduledSyncCoordinator(
      service,
      requestId: () => 'request-1',
      readinessProbeInterval: const Duration(milliseconds: 20),
      startupTimeout: const Duration(milliseconds: 200),
      completionTimeout: const Duration(seconds: 1),
    );
  });

  tearDown(() => service.close());

  test('waits for service readiness and sync completion', () async {
    final run = coordinator.run(repoIndex: 7);

    await Future<void>.delayed(Duration.zero);
    expect(service.startCount, 1);
    expect(service.invocations.single.$1, ScheduledSyncCoordinator.pingEvent);
    expect(service.invocations.where((call) => call.$1 == ScheduledSyncCoordinator.syncEvent), isEmpty);

    service.emit(ScheduledSyncCoordinator.readyEvent, {'requestId': 'request-1'});
    await Future<void>.delayed(Duration.zero);

    final syncCall = service.invocations.singleWhere((call) => call.$1 == ScheduledSyncCoordinator.syncEvent);
    expect(syncCall.$2, {'requestId': 'request-1', 'repoIndex': 7});

    var completed = false;
    run.whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    service.emit(ScheduledSyncCoordinator.completeEvent, {'requestId': 'request-1', 'success': true});
    await run;
    expect(completed, isTrue);
  });

  test('fails when the service does not become ready', () async {
    await expectLater(coordinator.run(repoIndex: 0), throwsA(isA<ScheduledSyncException>()));

    expect(service.invocations.where((call) => call.$1 == ScheduledSyncCoordinator.syncEvent), isEmpty);
  });

  test('retries the readiness probe while the service isolate starts', () async {
    var pingCount = 0;
    service.onInvoke = (method, args) {
      if (method == ScheduledSyncCoordinator.pingEvent && ++pingCount == 2) {
        scheduleMicrotask(() => service.emit(ScheduledSyncCoordinator.readyEvent, {'requestId': 'request-1'}));
      }
      if (method == ScheduledSyncCoordinator.syncEvent) {
        scheduleMicrotask(() => service.emit(ScheduledSyncCoordinator.completeEvent, {'requestId': 'request-1', 'success': true}));
      }
    };

    await coordinator.run(repoIndex: 0);

    expect(pingCount, 2);
  });

  test('propagates a failed scheduled sync result', () async {
    final run = coordinator.run(repoIndex: 0);
    await Future<void>.delayed(Duration.zero);
    service.emit(ScheduledSyncCoordinator.readyEvent, {'requestId': 'request-1'});
    await Future<void>.delayed(Duration.zero);
    service.emit(ScheduledSyncCoordinator.completeEvent, {'requestId': 'request-1', 'success': false, 'error': 'sync failed'});

    await expectLater(run, throwsA(isA<ScheduledSyncException>().having((error) => error.message, 'message', 'sync failed')));
  });

  test('queued sync completion stays pending until that repo is completed', () async {
    final completions = ScheduledSyncCompletionQueue();
    var completed = false;
    final queued = completions.waitFor(7)..whenComplete(() => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    completions.complete(8);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    completions.complete(7);
    await queued;
    expect(completed, isTrue);
  });

  test('queued sync completion propagates cancellation errors', () async {
    final completions = ScheduledSyncCompletionQueue();
    final queued = completions.waitFor(7);
    final error = ScheduledSyncException('Repository is not configured');

    completions.completeError(7, error, StackTrace.current);

    await expectLater(queued, throwsA(same(error)));
  });
}
