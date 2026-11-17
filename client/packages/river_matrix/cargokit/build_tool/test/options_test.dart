import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../lib/src/options.dart';

void main() {
  test('locked flags preserve the pinned default toolchain', () {
    final options = CargoBuildOptions.parse(
      loadYamlNode('extra_flags: ["--locked"]'),
    );
    expect(options.flags, ['--locked']);
    expect(options.toolchain, isNull);
  });

  test('an explicit toolchain still overrides the default', () {
    final options = CargoBuildOptions.parse(
      loadYamlNode('toolchain: nightly\nextra_flags: ["--locked"]'),
    );
    expect(options.toolchain, Toolchain.nightly);
  });
}
