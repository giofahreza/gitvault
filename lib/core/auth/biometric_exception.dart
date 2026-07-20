/// Custom exception for biometric errors.
class BiometricException implements Exception {
  final String message;
  BiometricException(this.message);

  @override
  String toString() => 'BiometricException: $message';
}
