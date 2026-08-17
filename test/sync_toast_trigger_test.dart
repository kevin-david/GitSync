import 'package:GitSync/api/sync_toast_trigger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scheduled sync contextualizes progress and terminal states', () {
    const trigger = SyncToastTrigger.scheduled();

    expect(trigger.message(SyncToastStatus.syncing), 'Scheduled sync · Syncing');
    expect(trigger.message(SyncToastStatus.queued), 'Scheduled sync · Sync queued');
    expect(trigger.message(SyncToastStatus.noChanges), 'Scheduled sync · No changes');
    expect(trigger.message(SyncToastStatus.synced), 'Scheduled sync · Synced');
    expect(trigger.contextualizeResult, isTrue);
  });

  test('app triggers identify the app without replacing terminal messages', () {
    final opened = SyncToastTrigger.appOpened('Obsidian');
    final closed = SyncToastTrigger.appClosed('Obsidian');

    expect(opened.message(SyncToastStatus.syncing), 'Obsidian opened · Syncing');
    expect(closed.message(SyncToastStatus.syncing), 'Obsidian closed · Syncing');
    expect(opened.contextualizeResult, isFalse);
    expect(closed.contextualizeResult, isFalse);
  });
}
