/*
 * @Description: quickjs engine
 * @Author: ekibun
 * @Date: 2020-08-08 08:29:09
 * @LastEditors: ekibun
 * @LastEditTime: 2020-10-06 23:47:13
 */
part of '../flutter_qjs.dart';

/// Handler function to manage js module.
typedef _JsModuleHandler = String Function(String name);

/// Handler to manage unhandled promise rejection.
typedef _JsHostPromiseRejectionHandler = void Function(dynamic reason);

const _releaseFuncName = '__release__';

/// Quickjs engine for flutter.
class FlutterQjs {
  Pointer<JSRuntime>? _rt;
  Pointer<JSContext>? _ctx;

  bool _isActived = true;
  final Map<int, Timer> _timerMap = {};

  /// Max stack size for quickjs.
  final int? stackSize;

  /// Max stack size for quickjs.
  final int? timeout;

  /// Max memory for quickjs.
  final int? memoryLimit;

  /// Message Port for event loop. Close it to stop dispatching event loop.
  ReceivePort port = ReceivePort();

  /// Handler function to manage js module.
  final _JsModuleHandler? moduleHandler;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  final _internalModule = <String, String>{};

  void setInternalModule(String moduleName, String code) {
    _internalModule[moduleName] = code;
  }

  FlutterQjs({
    this.moduleHandler,
    this.stackSize,
    this.timeout,
    this.memoryLimit,
    this.hostPromiseRejectionHandler,
  });

  _ensureEngine() {
    if (_rt != null) return;
    final rt = jsNewRuntime((ctx, type, ptr) {
      try {
        switch (type) {
          case JSChannelType.METHON:
            final pdata = ptr.cast<Pointer<JSValue>>();
            final argc = (pdata + 1).value.cast<Int32>().value;
            final pargs = [];
            for (var i = 0; i < argc; ++i) {
              pargs.add(_jsToDart(
                ctx,
                Pointer.fromAddress(
                  (pdata + 2).value.address + sizeOfJSValue * i,
                ),
              ));
            }
            final JSInvokable func = _jsToDart(
              ctx,
              (pdata + 3).value,
            );
            return _dartToJs(
                ctx,
                func.invoke(
                  pargs,
                  _jsToDart(ctx, (pdata + 0).value),
                ));
          case JSChannelType.MODULE:
            if (moduleHandler == null) throw JSError('No ModuleHandler');
            final ret = moduleHandler!(
              ptr.cast<Utf8>().toDartString(),
            ).toNativeUtf8();
            Future.microtask(() {
              malloc.free(ret);
            });
            return ret.cast();
          case JSChannelType.PROMISE_TRACK:
            final err = _parseJSException(ctx, ptr);
            if (hostPromiseRejectionHandler != null) {
              hostPromiseRejectionHandler!(err);
            } else {
              print('unhandled promise rejection: $err');
            }
            return nullptr;
          case JSChannelType.FREE_OBJECT:
            final rt = ctx.cast<JSRuntime>();
            _DartObject.fromAddress(rt, ptr.address)?.free();
            return nullptr;
        }
        throw JSError('call channel with wrong type');
      } catch (e) {
        if (type == JSChannelType.FREE_OBJECT) {
          print('DartObject release error: $e');
          return nullptr;
        }
        if (type == JSChannelType.MODULE) {
          print('host Promise Rejection Handler error: $e');
          return nullptr;
        }
        final throwObj = _dartToJs(ctx, e);
        final err = jsThrow(ctx, throwObj);
        jsFreeValue(ctx, throwObj);
        if (type == JSChannelType.MODULE) {
          jsFreeValue(ctx, err);
          return nullptr;
        }
        return err;
      }
    }, timeout ?? 0, port);
    final stackSize = this.stackSize ?? 0;
    if (stackSize > 0) jsSetMaxStackSize(rt, stackSize);
    final memoryLimit = this.memoryLimit ?? 0;
    if (memoryLimit > 0) jsSetMemoryLimit(rt, memoryLimit);
    _rt = rt;
    _ctx = jsNewContext(rt);
    _polyfill();
  }

  /// Free Runtime and Context which can be recreate when evaluate again.
  close() {
    if (!_isActived) {
      return;
    }
    _isActived = false;
    _internalModule.clear();
    evaluate('$_releaseFuncName()');

    final rt = _rt;
    final ctx = _ctx;
    _rt = null;
    _ctx = null;
    if (ctx != null) jsFreeContext(ctx);
    if (rt == null) return;
    _executePendingJob();
    try {
      jsFreeRuntime(rt);
    } on String catch (e) {
      throw JSError(e);
    }
  }

  void _executePendingJob() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null || ctx == null) return;
    while (true) {
      int err = jsExecutePendingJob(rt);
      if (err <= 0) {
        if (err < 0) print(_parseJSException(ctx));
        break;
      }
    }
  }

  void _polyfill() {
    JSInvokable invokable = evaluate(
      '''(handlers) => {
      let cachedModules = {};

      this.__require__ = (filePath, dirname) => {
        let moduleString = null;
        let modulePath = filePath;

        if (handlers['isInternalModule'](filePath)) {
          if (cachedModules[filePath] != null) {
            return cachedModules[filePath].exports;
          }
          moduleString = handlers['importInternalModule'](filePath);
        } else {
          modulePath = handlers['resolvePath'](dirname, filePath);
          if (cachedModules[modulePath] != null) {
            return cachedModules[modulePath].exports;
          }
          moduleString = handlers['importModule'](modulePath);
        }

        if (moduleString == null) {
          throw new Error('Module "' + filePath + '" not found')
        }
        
        const func = new Function('return ' + moduleString);
        const mod = func()
        cachedModules[modulePath] = mod
        return mod.exports
      };

      let timerId = 0;
      let timerCallbackMap = {};

      this.setTimeout = (callback, duration) => {
        let id = timerId++;
        timerCallbackMap[id] = callback;
        handlers['setTimeout'](id, duration);
        return id;
      };

      this.__trigger_timer__ = (timerId) => {
        let func = timerCallbackMap[timerId];
        if (typeof func === 'function') {
          func();
          delete timerCallbackMap[timerId];
        }
      };

      this.clearTimeout = (timerId) => {
        delete timerCallbackMap[timerId];
        handlers['clearTimeout'](timerId);
      };

      this.console = {
        log: (...args) => {
          let stringArgs = args.map(e => String(e));
          handlers['consoleLog'](stringArgs);
        },
        error: (...args) => {
          let stringArgs = args.map(e => String(e));
          handlers['consoleError'](stringArgs);
        },
      };

      this.$_releaseFuncName = () => {
        for (let key in handlers) {
          delete handlers[key]
        }
        for (let key in cachedModules) {
          delete cachedModules[key]
        }
        for (let key in timerCallbackMap) {
          delete timerCallbackMap[key]
        }
        this.setTimeout = 
          this.clearTimeout =
          this.console =
          this.__require__ =
          this.__trigger_timer__ = null
      };
    }''',
    );

    invokable.invoke([
      {
        'setTimeout': _setTimeout,
        'clearTimeout': _clearTimeout,
        'consoleLog': (List args) {
          if (consoleMessage != null) {
            consoleMessage!('log', args.join(' '));
          }
        },
        'consoleError': (List args) {
          if (consoleMessage != null) {
            consoleMessage!('error', args.join(' '));
          }
        },
        'resolvePath': _resolvePath,
        'isInternalModule': _isInternalModule,
        'importInternalModule': _importInternalModule,
        'importModule': _importModule,
      },
    ]);

    invokable.free();
  }

  void _setTimeout(int timerId, [int? duration]) {
    _timerMap[timerId] = Timer(
      Duration(milliseconds: duration ?? 0),
      () async {
        _timerMap.remove(timerId);
        if (!_isActived) {
          return;
        }
        try {
          evaluate('__trigger_timer__($timerId)');
        } on JSError catch (e) {
          if (consoleMessage != null) {
            consoleMessage!(
              'error',
              'Failed trigger timeout'
                  ' > error: ${e.message}\n'
                  ' > stack: ${e.stack}',
            );
          }
        }
      },
    );
  }

  void _clearTimeout(int timerId) {
    var timer = _timerMap[timerId];
    if (timer != null) {
      if (timer.isActive) {
        timer.cancel();
      }
      _timerMap.remove(timerId);
    }
  }

  void Function(String level, String message)? consoleMessage;

  // void _consoleLog(List args) {}

  // void _consoleError(List args) {}

  String _resolvePath(String dirname, String filePath) {
    return path.canonicalize(
      path.join(dirname, filePath, '.js'),
    );
  }

  bool _isInternalModule(String moduleName) {
    return _internalModule.containsKey(moduleName);
  }

  String? _importInternalModule(String moduleName) {
    return _internalModule[moduleName];
  }

  String? _importModule(String filePath) {
    final file = File(filePath);
    if (file.existsSync()) {
      final code = file.readAsStringSync();
      return _createModule(
        code: code,
        dirname: path.dirname(filePath),
      );
    }
    return null;
  }

  String _createModule({
    required String code,
    required String dirname,
  }) {
    return ''';(function () {
      var m = {};
      var e = {};
      m.exports = e;
      function r(filePath) {
        return __require__(filePath, '$dirname');
      }
      (function (module, exports, require) {
        $code;
      })(m, e, r)
      return m;
    })();''';
  }

  /// Dispatch JavaScript Event loop.
  Future<void> dispatch() async {
    await for (final _ in port) {
      _executePendingJob();
    }
  }

  /// Evaluate js script.
  dynamic evaluate(
    String command, {
    String? name,
    int? evalFlags,
  }) {
    _ensureEngine();
    final ctx = _ctx!;
    final jsval = jsEval(
      ctx,
      command,
      name ?? '<eval>',
      evalFlags ?? JSEvalFlag.GLOBAL,
    );
    if (jsIsException(jsval) != 0) {
      jsFreeValue(ctx, jsval);
      throw _parseJSException(ctx);
    }
    final result = _jsToDart(ctx, jsval);
    jsFreeValue(ctx, jsval);
    return result;
  }
}
