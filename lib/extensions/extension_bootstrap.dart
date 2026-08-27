import 'dart:async';

import 'package:beecount_extensions_bundle/beecount_extensions_bundle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'beecount_host_services.dart';

/// Process-wide extension composition. The host remains usable if this
/// bootstrap cannot initialize; all extension capabilities default off.
final class BeeCountExtensionBootstrap {
  BeeCountExtensionBootstrap._();

  static AutomationBundleController? _controller;

  static AutomationBundleController? get controller => _controller;

  static Future<void> initialize(ProviderContainer container) async {
    if (_controller != null) return;
    final controller = AutomationBundleController(
      host: BeeCountHostServicesFactory(container).create(),
    );
    await controller.initialize();
    _controller = controller;
    WidgetsBinding.instance.addObserver(
      _AutomationLifecycleObserver(controller),
    );
  }
}

final class _AutomationLifecycleObserver with WidgetsBindingObserver {
  _AutomationLifecycleObserver(this._controller);

  final AutomationBundleController _controller;
  Future<void>? _pendingRefresh;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _pendingRefresh != null) return;
    _pendingRefresh = _controller.refresh().whenComplete(() {
      _pendingRefresh = null;
    });
    unawaited(_pendingRefresh);
  }
}
