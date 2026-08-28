enum SyncToastStatus { syncing, queued, noChanges, synced }

class SyncToastTrigger {
  final String description;
  final bool contextualizeResult;

  const SyncToastTrigger(this.description, {this.contextualizeResult = false});

  const SyncToastTrigger.scheduled() : this('Scheduled sync', contextualizeResult: true);

  factory SyncToastTrigger.appOpened(String applicationLabel) => SyncToastTrigger('$applicationLabel opened');

  factory SyncToastTrigger.appClosed(String applicationLabel) => SyncToastTrigger('$applicationLabel closed');

  String message(SyncToastStatus status) {
    final suffix = switch (status) {
      SyncToastStatus.syncing => 'Syncing',
      SyncToastStatus.queued => 'Sync queued',
      SyncToastStatus.noChanges => 'No changes',
      SyncToastStatus.synced => 'Synced',
    };
    return '$description · $suffix';
  }
}
