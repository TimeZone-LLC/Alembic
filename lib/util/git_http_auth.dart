import 'dart:convert';

/// Git config key whose value is sent as an extra HTTP header on requests to
/// github.com only, so the token is never offered to any other host.
const String gitHubHttpAuthConfigKey = 'http.https://github.com/.extraHeader';

final RegExp _httpsUserInfoPattern = RegExp(r'^(https?://)[^@/]+@');

/// Builds the process environment that authenticates a single git invocation
/// against GitHub with [token]. Git treats `GIT_CONFIG_*` as command-scoped
/// configuration, so nothing here is written to `.git/config` and the remote
/// URL stays credential-free.
Map<String, String> gitHubTokenEnvironment(String token) {
  final String basic = base64Encode(utf8.encode('x-access-token:$token'));
  return <String, String>{
    'GIT_CONFIG_COUNT': '1',
    'GIT_CONFIG_KEY_0': gitHubHttpAuthConfigKey,
    'GIT_CONFIG_VALUE_0': 'Authorization: Basic $basic',
    'GIT_TERMINAL_PROMPT': '0',
  };
}

/// Returns [url] with any `user:password@` userinfo removed. Remotes that are
/// not HTTP(S) URLs, such as SSH remotes, are returned unchanged.
String stripUrlCredentials(String url) {
  final String trimmed = url.trim();
  return trimmed.replaceFirstMapped(
    _httpsUserInfoPattern,
    (Match match) => match.group(1)!,
  );
}
