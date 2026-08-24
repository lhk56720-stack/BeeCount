import 'dart:io';

import 'package:beecount_extensions_bundle/beecount_extensions_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extension-disabled defaults preserve an inert collection policy', () {
    final settings = AutomationSettings.defaults();

    expect(settings.automationEnabled, isFalse);
    expect(settings.notificationEnabled, isFalse);
    expect(settings.autoPostEnabled, isFalse);
    expect(settings.enabledSourceAppIds, isEmpty);
  });

  test('host bridge imports only extension API and bundle packages', () {
    final source =
        File('lib/extensions/beecount_host_services.dart').readAsStringSync();

    expect(source, isNot(contains('beecount_automation_core')));
    expect(source, isNot(contains('beecount_automation_android')));
    expect(source, contains('beecount_extension_api'));
  });
}
