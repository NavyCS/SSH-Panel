import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../features/service/service_controller.dart';
import '../../services/ssh_service.dart';

/// Read-only pill showing the `ssh-agent` service state.
///
/// The badge used to be a plain [ShadBadge] whatever the state, so "Running"
/// and "Stopped" were drawn identically and the row gave nothing away at a
/// glance -- the distinction only existed in toasts, which are transient.
///
/// The states are separated by weight rather than by inventing a colour:
///
/// * running              solid, the most prominent variant
/// * a transition state   secondary: present, but clearly not settled
/// * stopped / unknown    outline, recessive
///
/// shadcn ships no "success" variant, and the app deliberately hardcodes no
/// colours of its own, so a green would mean introducing a palette decision
/// that belongs to whoever owns the design.
class AgentStatusBadge extends StatelessWidget {
  const AgentStatusBadge({super.key, required this.state});

  /// The state to display. `null` means it could not be read.
  final SshServiceState? state;

  String get _label =>
      state == null ? 'Unknown' : ServiceController.statusLabel(state!);

  @override
  Widget build(BuildContext context) {
    final badge = switch (state) {
      SshServiceState.running => ShadBadge(child: Text(_label)),
      SshServiceState.startPending ||
      SshServiceState.stopPending ||
      SshServiceState.continuePending =>
        ShadBadge.secondary(child: Text(_label)),
      _ => ShadBadge.outline(child: Text(_label)),
    };

    return Semantics(
      label: 'Agent status: $_label',
      child: badge,
    );
  }
}