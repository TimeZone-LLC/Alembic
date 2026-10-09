/// Lifecycle of an app self-update.
enum UpdateStatus {
  /// No check has run yet this session.
  idle,

  /// A check is in flight.
  checking,

  /// The latest check found nothing newer.
  upToDate,

  /// A newer release is available to install.
  updateAvailable,

  /// The available release is currently downloading/installing.
  downloading,

  /// The last check or install failed.
  error,
}

/// Immutable view of the update state.
///
/// Pure data (no Flutter/Hive dependencies) so it can be unit tested in
/// isolation. UpdateController owns the current instance.
class UpdateSnapshot {
  static const String defaultReleaseUrl =
      'https://github.com/TimeZone-LLC/Alembic/releases/latest';

  final UpdateStatus status;
  final bool autoCheckEnabled;
  final String currentVersion;
  final String? latestVersion;
  final int? lastCheckedMs;

  /// Download progress in the range 0..1 while [status] is
  /// [UpdateStatus.downloading]; otherwise null.
  final double? downloadProgress;
  final String? errorMessage;
  final String releaseUrl;

  const UpdateSnapshot({
    required this.status,
    required this.autoCheckEnabled,
    required this.currentVersion,
    this.latestVersion,
    this.lastCheckedMs,
    this.downloadProgress,
    this.errorMessage,
    this.releaseUrl = defaultReleaseUrl,
  });

  /// True when a newer release exists, including while it is being installed.
  bool get updateAvailable =>
      status == UpdateStatus.updateAvailable ||
      status == UpdateStatus.downloading;

  factory UpdateSnapshot.idle({
    required bool autoCheckEnabled,
    required String currentVersion,
    int? lastCheckedMs,
  }) =>
      UpdateSnapshot(
        status: UpdateStatus.idle,
        autoCheckEnabled: autoCheckEnabled,
        currentVersion: currentVersion,
        lastCheckedMs: lastCheckedMs,
      );

  factory UpdateSnapshot.checking({
    required bool autoCheckEnabled,
    required String currentVersion,
    int? lastCheckedMs,
  }) =>
      UpdateSnapshot(
        status: UpdateStatus.checking,
        autoCheckEnabled: autoCheckEnabled,
        currentVersion: currentVersion,
        lastCheckedMs: lastCheckedMs,
      );

  factory UpdateSnapshot.upToDate({
    required bool autoCheckEnabled,
    required String currentVersion,
    int? lastCheckedMs,
  }) =>
      UpdateSnapshot(
        status: UpdateStatus.upToDate,
        autoCheckEnabled: autoCheckEnabled,
        currentVersion: currentVersion,
        lastCheckedMs: lastCheckedMs,
      );

  factory UpdateSnapshot.available({
    required bool autoCheckEnabled,
    required String currentVersion,
    required String latestVersion,
    int? lastCheckedMs,
  }) =>
      UpdateSnapshot(
        status: UpdateStatus.updateAvailable,
        autoCheckEnabled: autoCheckEnabled,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        lastCheckedMs: lastCheckedMs,
      );

  factory UpdateSnapshot.downloading({
    required bool autoCheckEnabled,
    required String currentVersion,
    required String latestVersion,
    required double progress,
    int? lastCheckedMs,
  }) =>
      UpdateSnapshot(
        status: UpdateStatus.downloading,
        autoCheckEnabled: autoCheckEnabled,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        downloadProgress: progress,
        lastCheckedMs: lastCheckedMs,
      );

  factory UpdateSnapshot.error({
    required bool autoCheckEnabled,
    required String currentVersion,
    required String message,
    String? latestVersion,
    int? lastCheckedMs,
  }) =>
      UpdateSnapshot(
        status: UpdateStatus.error,
        autoCheckEnabled: autoCheckEnabled,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        errorMessage: message,
        lastCheckedMs: lastCheckedMs,
      );

  UpdateSnapshot copyWith({
    UpdateStatus? status,
    bool? autoCheckEnabled,
    String? currentVersion,
    String? latestVersion,
    int? lastCheckedMs,
    double? downloadProgress,
    String? errorMessage,
  }) =>
      UpdateSnapshot(
        status: status ?? this.status,
        autoCheckEnabled: autoCheckEnabled ?? this.autoCheckEnabled,
        currentVersion: currentVersion ?? this.currentVersion,
        latestVersion: latestVersion ?? this.latestVersion,
        lastCheckedMs: lastCheckedMs ?? this.lastCheckedMs,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        errorMessage: errorMessage ?? this.errorMessage,
        releaseUrl: releaseUrl,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'status': status.name,
        'autoCheckEnabled': autoCheckEnabled,
        'updateAvailable': updateAvailable,
        'currentVersion': currentVersion,
        'latestVersion': latestVersion,
        'lastCheckedMs': lastCheckedMs,
        'downloadProgress': downloadProgress,
        'errorMessage': errorMessage,
        'releaseUrl': releaseUrl,
      };
}
