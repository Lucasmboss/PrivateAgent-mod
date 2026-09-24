import 'dart:async';

/// One-shot cancellation, safe to share across a task's remote calls.
class RemoteCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  Future<void> delay(Duration duration) async {
    final completer = Completer<void>();
    final timer = Timer(duration, () => completer.complete());
    final remove = onCancel(() {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
      remove();
    }
  }
}