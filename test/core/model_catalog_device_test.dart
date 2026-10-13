// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:ramble_voice/core/models/model_catalog.dart';

void main() {
  const gb = 1 << 30;

  test('a Snapdragon 8 Elite with FastRPC gets the NPU build', () {
    final v = ModelCatalog.availableOn(const DeviceInfo(soc: 'SM8750', ramBytes: 12 * gb, fastRpc: true));
    expect(v, contains(ModelCatalog.e2bNpuSm8750));
    expect(v, contains(ModelCatalog.e12b));
  });

  test('other chips never see an NPU build; 8 GB phones do not see 12B', () {
    final v = ModelCatalog.availableOn(const DeviceInfo(soc: 'SM8650', ramBytes: 8 * gb, fastRpc: true));
    expect(v.any((m) => m.usesNpu), isFalse);
    expect(v, isNot(contains(ModelCatalog.e12b)));
    expect(v, containsAll([ModelCatalog.e4b, ModelCatalog.e2b]));
  });

  test('a 16 GB phone reporting a little less still gets 12B', () {
    final v = ModelCatalog.availableOn(const DeviceInfo(soc: 'SM8650', ramBytes: 15 * gb, fastRpc: true));
    expect(v, contains(ModelCatalog.e12b));
  });

  test('desktops get every non-NPU model', () {
    expect(ModelCatalog.availableOn(null), [ModelCatalog.e4b, ModelCatalog.e2b, ModelCatalog.e12b]);
  });
}
