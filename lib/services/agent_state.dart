import 'package:flutter/foundation.dart';

import 'ssh_service.dart';

/// Shared notifier for the current `ssh-agent` service state.
///
/// The Service tab writes it after every status read; the Keys tab listens so
/// that Load/Unload and the Loaded Keys card stay correct when the agent is
/// started or stopped from the other tab, without the two tabs having to know
/// about each other's widget subtree.
///
/// It lives here rather than in `main.dart` so that a controller under
/// `lib/features/` can publish to it without importing the UI entrypoint,
/// which would be a circular dependency.
final ValueNotifier<SshServiceState?> agentServiceState =
    ValueNotifier<SshServiceState?>(null);
