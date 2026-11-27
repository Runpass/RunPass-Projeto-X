/// Regra de senha do corredor, no mesmo espirito do Instagram: minimo de
/// caracteres, sem exigir composicao (maiuscula/minuscula/numero/simbolo),
/// mas recusando senhas obvias ou muito comuns. A conta Cognito (RunnerPool)
/// usa a mesma politica (minimo 6, sem composicao); este bloqueio de senha
/// fraca e so client-side, pois o Cognito nao tem lista de senhas comuns sem
/// o recurso pago de seguranca avancada.
const minimumPasswordLength = 6;

const _commonPasswords = {
  '123456',
  '123456789',
  '12345678',
  '12345',
  '1234567',
  '1234',
  '000000',
  '111111',
  '654321',
  '123123',
  'qwerty',
  'qwerty123',
  'qwertyuiop',
  '1q2w3e4r',
  'password',
  'password1',
  'senha123',
  'senha',
  'abc123',
  'iloveyou',
  'admin',
  'welcome',
  'monkey',
  'dragon',
  'login',
  'letmein',
  'master',
  'football',
  'baseball',
  'starwars',
  'princess',
  'sunshine',
};

/// null quando a senha e aceita; caso contrario, a mensagem a mostrar quando
/// a pessoa tocar em "Continuar" (sem medidor de forca, sem validacao ao digitar).
String? weakPasswordReason(String password, String email) {
  if (password.length < minimumPasswordLength) {
    return 'Use pelo menos $minimumPasswordLength caracteres.';
  }
  final lower = password.toLowerCase();
  final localPart = email.split('@').first.toLowerCase();
  final isWeak =
      _commonPasswords.contains(lower) ||
      (localPart.length >= minimumPasswordLength && lower == localPart) ||
      _isSingleCharacterRepeated(lower) ||
      _isSequential(lower);
  return isWeak
      ? 'Essa senha é muito fácil de adivinhar. Escolha outra.'
      : null;
}

bool _isSingleCharacterRepeated(String value) =>
    value.split('').toSet().length == 1;

bool _isSequential(String value) {
  if (value.length < 4) return false;
  final codes = value.codeUnits;
  var ascending = true;
  var descending = true;
  for (var i = 1; i < codes.length; i++) {
    if (codes[i] != codes[i - 1] + 1) ascending = false;
    if (codes[i] != codes[i - 1] - 1) descending = false;
  }
  return ascending || descending;
}
