import 'dart:async';
import 'dart:developer';
import 'dart:isolate';
import 'package:async/async.dart';
import 'package:worker_manager/src/scheduling/runnable.dart';
import 'package:worker_manager/worker_manager.dart';
import '../worker/worker.dart';
import '../scheduling/task.dart';

class WorkerImpl implements Worker {
  late Isolate _isolate;
  late ReceivePort _receivePort;
  late SendPort _sendPort;
  late StreamSubscription _portSub;
  late Completer<Object> _result;

  Function? _onUpdateProgress;
  int? _runnableNumber;
  Capability? _currentResumeCapability;
  var _paused = false;

  @override
  int? get runnableNumber => _runnableNumber;

  @override
  Future<void> initialize() async {
    final initCompleter = Completer<bool>();
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_anotherIsolate, _receivePort.sendPort);
    _portSub = _receivePort.listen((message) {
      if (message is ValueResult) {
        _result.complete(message.value);
        _runnableNumber = null;
        _onUpdateProgress = null;
      } else if (message is ErrorResult) {
        _result.completeError(message.error);
        _runnableNumber = null;
        _onUpdateProgress = null;
      } else if (message is SendPort) {
        _sendPort = message;
        initCompleter.complete(true);
        _runnableNumber = null;
        _onUpdateProgress = null;
      } else {
        _onUpdateProgress?.call(message);
      }
    });
    await initCompleter.future;
  }

  // dart --enable-experiment=variance
  // need invariant support to apply onUpdateProgress generic type
  // inout T
  @override
  Future<O> work<A, B, C, D, O, T>(Task<A, B, C, D, O, T> task) async {
    try {
      _runnableNumber = task.number;
      _onUpdateProgress = task.onUpdateProgress;
      _result = Completer<Object>();
      final message = Message(_execute, task.runnable);
      log('WorkerImpl::work:message: ${message.runtimeType}');
      log('WorkerImpl::work:message: $message');
      try {
        _sendPort.send(message);
      } catch (ex) {
        log('WorkerImpl::work:_sendPort::Exception = $ex');
      }
      final resultValue = await (_result.future as Future<O>);
      return resultValue;
    } catch (e, s) {
      log('WorkerImpl::work:catch = $e | strace: $s');
      throw Exception(e);
    }
  }

  static FutureOr _execute(runnable) => runnable();

  static void _anotherIsolate(SendPort sendPort) {
    try {
      final receivePort = ReceivePort();
      sendPort.send(receivePort.sendPort);
      receivePort.listen((message) async {
        try {
          final currentMessage = message as Message;
          final function = currentMessage.function;
          final argument = currentMessage.argument as Runnable;
          argument.sendPort = TypeSendPort(sendPort);
          final result = await function(argument);
          sendPort.send(Result.value(result));
        } catch (error) {
          log('WorkerImpl::_anotherIsolate: Exception = $error');
          try {
            sendPort.send(Result.error(error));
          } catch (error) {
            sendPort.send(Result.error(
                'cant send error with too big stackTrace, error is : ${error.toString()}'));
          }
        }
      });
    } catch (e) {
      log('WorkerImpl::_anotherIsolate: Exception_2 = $e');
    }
  }

  @override
  Future<void> kill() {
    _paused = false;
    _currentResumeCapability = null;
    _isolate.kill(priority: Isolate.immediate);
    return _portSub.cancel();
  }

  @override
  void pause() {
    if (!_paused) {
      _paused = true;
      _currentResumeCapability ??= Capability();
      _isolate.pause(_currentResumeCapability);
    }
  }

  @override
  void resume() {
    if (_paused) {
      _paused = false;
      final checkedCapability = _currentResumeCapability;
      if (checkedCapability != null) {
        _isolate.resume(checkedCapability);
      }
    }
  }

  @override
  bool get paused => _paused;
}

class Message {
  final Function function;
  final Object argument;

  Message(this.function, this.argument);

  FutureOr call() async => await function(argument);
}
