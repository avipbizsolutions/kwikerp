/// Build number of this app, set by GitHub Actions at build time
/// (--dart-define=BUILD_NUMBER=<run number>). 0 for a local build, which never
/// asks to be updated.
const int appBuild = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
const String appVersionLabel = appBuild == 0 ? 'dev build' : 'build $appBuild';
