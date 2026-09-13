/// Keep this aligned with pubspec.yaml using Semantic Versioning.
const applicationVersion = '0.3.2';
const coreVersion = '0.2.0';
const protocolVersion = 'v1';

/// Supplied by the release script. Development runs deliberately show a
/// visible marker instead of pretending to be a packaged release.
const buildGitRevision =
    String.fromEnvironment('HCOM_GIT_SHA', defaultValue: '开发构建');
const buildTimestamp =
    String.fromEnvironment('HCOM_BUILD_TIME', defaultValue: '未打包');
