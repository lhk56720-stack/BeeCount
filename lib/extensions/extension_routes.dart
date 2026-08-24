import 'package:beecount_extensions_bundle/beecount_extensions_bundle.dart';
import 'package:flutter/material.dart';

import 'extension_bootstrap.dart';

Future<void> openAutomationSettings(BuildContext context) async {
  final controller = BeeCountExtensionBootstrap.controller;
  if (controller == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('自动记账服务尚未初始化')),
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AutomationSettingsPage(controller: controller),
    ),
  );
}
