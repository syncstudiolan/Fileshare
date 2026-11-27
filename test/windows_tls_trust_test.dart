import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/windows_tls_trust.dart';

void main() {
  group('Windows TLS failure classification', () {
    test('recognizes certificate handshake failures', () {
      expect(
        WindowsTlsTrust.isTlsFailure(HandshakeException('certificate verify failed')),
        isTrue,
      );
    });

    test('recognizes TLS protocol failures', () {
      expect(WindowsTlsTrust.isTlsFailure(TlsException('TLS protocol failure')), isTrue);
    });

    test('does not retry ordinary socket/network failures', () {
      expect(
        WindowsTlsTrust.isTlsFailure(SocketException('connection refused')),
        isFalse,
      );
    });

    test('does not retry arbitrary exceptions', () {
      expect(WindowsTlsTrust.isTlsFailure(StateError('unexpected')), isFalse);
    });
  });
}
