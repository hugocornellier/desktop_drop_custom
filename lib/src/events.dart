import 'package:desktop_drop/src/drop_item.dart';
import 'package:flutter/painting.dart';

abstract class DropEvent {
  Offset location;

  DropEvent(this.location);

  @override
  String toString() {
    return '$runtimeType($location)';
  }
}

class DropEnterEvent extends DropEvent {
  DropEnterEvent({required Offset location}) : super(location);
}

class DropExitEvent extends DropEvent {
  DropExitEvent({required Offset location}) : super(location);
}

class DropUpdateEvent extends DropEvent {
  DropUpdateEvent({required Offset location}) : super(location);
}

class DropDoneEvent extends DropEvent {
  final List<DropItem> files;

  DropDoneEvent({
    required Offset location,
    required this.files,
  }) : super(location);

  @override
  String toString() {
    return '$runtimeType($location, $files)';
  }
}

/// Event fired immediately when files are dropped, before processing begins.
///
/// This allows the app to show instant feedback (e.g., "Preparing import...")
/// while the native code processes the dropped files in the background.
/// The [itemCount] indicates how many items are being processed.
/// The actual file data will arrive later in [DropDoneEvent].
class DropReceivedEvent extends DropEvent {
  final int itemCount;

  DropReceivedEvent({
    required Offset location,
    required this.itemCount,
  }) : super(location);

  @override
  String toString() {
    return '$runtimeType($location, itemCount: $itemCount)';
  }
}
