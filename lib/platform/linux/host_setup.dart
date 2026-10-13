// SPDX-License-Identifier: GPL-3.0-or-later

/// Optional one-time host setup for typing into other apps from a Flatpak
/// when neither the RemoteDesktop portal nor wtype is usable. Ramble Voice
/// never runs this itself: the Settings screen shows [command] for the user
/// to run in a terminal (the packaged script asks for administrator rights
/// with pkexec to install and enable ydotoold).
library;

import 'linux_environment.dart';

abstract final class HostSetup {
  static const command =
      'flatpak run --command=cat $rambleAppId /app/share/ramble-voice/host-setup.sh | bash';

  /// Whether the host-setup helper would make a difference: sandboxed, and no
  /// injector in the chain can type (ydotool needs its socket, which the
  /// script sets up).
  static bool appliesTo(LinuxEnvironment env) {
    if (!env.isFlatpak) return false;
    final chain = env.injectionChain();
    return !chain.contains(Injector.remoteDesktopPortal) && !chain.contains(Injector.wtype) && !chain.contains(Injector.ydotool);
  }

  /// Detects the session and answers [appliesTo]. Pass [env] to reuse one.
  static Future<bool> needed({LinuxEnvironment? env}) async => appliesTo(env ?? await LinuxEnvironment.detect());
}
