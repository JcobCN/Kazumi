// DanDanPlay API credentials for the client signature flow.
// CI can override these values with --dart-define. The defaults keep local,
// fork, and self-built releases able to access DanDanPlay too.
const _defaultDandanAppId = 'qb998n8g3u';
const _defaultDandanKey = '4y2waS6A6yb4uw7Dhd9pmdTzvrF7YUsg';

const dandanAppId = String.fromEnvironment(
  'DANDANAPI_APPID',
  defaultValue: _defaultDandanAppId,
);
const dandanKey = String.fromEnvironment(
  'DANDANAPI_KEY',
  defaultValue: _defaultDandanKey,
);

const Map<String, String> dandanCredentials = {
  'id': dandanAppId,
  'value': dandanKey,
};

