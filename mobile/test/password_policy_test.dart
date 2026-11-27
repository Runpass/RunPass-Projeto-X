import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/password_policy.dart';

void main() {
  test(
    'accepts a short password without composition rules, like Instagram',
    () {
      expect(weakPasswordReason('corrida', 'runner@example.test'), isNull);
    },
  );

  test('rejects passwords shorter than the minimum', () {
    expect(weakPasswordReason('abc12', 'runner@example.test'), isNotNull);
  });

  test('rejects common and obvious passwords', () {
    for (final weak in [
      '123456',
      'password',
      'qwerty123',
      '111111',
      '123456789',
    ]) {
      expect(
        weakPasswordReason(weak, 'runner@example.test'),
        isNotNull,
        reason: '$weak should be rejected',
      );
    }
  });

  test('rejects sequential and repeated characters', () {
    expect(weakPasswordReason('abcdef', 'runner@example.test'), isNotNull);
    expect(weakPasswordReason('fedcba', 'runner@example.test'), isNotNull);
    expect(weakPasswordReason('aaaaaa', 'runner@example.test'), isNotNull);
  });

  test('rejects the e-mail local part as the password', () {
    expect(weakPasswordReason('corredor', 'corredor@example.test'), isNotNull);
  });

  test('is case-sensitive, like Instagram', () {
    expect(weakPasswordReason('Corrida1', 'runner@example.test'), isNull);
  });
}
