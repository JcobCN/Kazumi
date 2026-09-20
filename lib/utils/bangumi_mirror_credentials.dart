// Bangumi mirror API credentials for the search signature flow.
// CI can override these values with --dart-define. The defaults keep local,
// fork, and self-built releases able to use the public Kazumi mirror too.
const _defaultBangumiMirrorAppId = 'kazumi-hh47hcih6xfodp50';
const _defaultBangumiMirrorKey =
    'EKlABDVRMb8g5OkCH78SL14riZU4zmkR8TvRmu3GORIeJcdQ';

const bangumiMirrorAppId = String.fromEnvironment(
  'KAZUMI_APPID',
  defaultValue: _defaultBangumiMirrorAppId,
);
const bangumiMirrorKey = String.fromEnvironment(
  'KAZUMI_KEY',
  defaultValue: _defaultBangumiMirrorKey,
);

const Map<String, String> bangumiMirrorCredentials = {
  'id': bangumiMirrorAppId,
  'value': bangumiMirrorKey,
};
