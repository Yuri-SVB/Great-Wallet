import 'package:flutter/material.dart';

import '../core/great_wall_core.dart';
import '../setup/orbit_setup_screen.dart';
import '../setup/setup_screen.dart';
import 'orbit_harness_screen.dart';

/// The great-wallet modes (ARCHITECTURE.md §"7. great-wallet"). **Setup** (the
/// legacy 0.3.0 chain) and **Orbit** (the 0.4.0 flow) are implemented; Train /
/// Accelerate / Inherit depend on libraries (celestial-peace-nf-core,
/// jade-clock, phoenix-scroll) still in development.
///
/// [orbit] is the 0.4.0 orbit destination: a **Setup** tab ([OrbitSetupScreen],
/// the coercion-resistant multi-board flow) plus a **Harness** tab
/// ([OrbitHarnessScreen], a dev end-to-end runner). It is separate from the
/// legacy Setup, which stays as a fallback (soft flip).
enum WalletMode {
  setup('Setup', Icons.auto_awesome_mosaic),
  train('Train', Icons.school),
  accelerate('Accelerate', Icons.bolt),
  inherit('Inherit', Icons.account_tree),
  orbit('Orbit', Icons.blur_circular);

  const WalletMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Top-level navigation shell that switches between the four modes.
class ModeShell extends StatefulWidget {
  const ModeShell({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<ModeShell> createState() => _ModeShellState();
}

class _ModeShellState extends State<ModeShell> {
  WalletMode _mode = WalletMode.setup;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Great Wallet — ${_mode.label}')),
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _mode.index,
            onDestinationSelected: (int i) =>
                setState(() => _mode = WalletMode.values[i]),
            labelType: NavigationRailLabelType.all,
            destinations: <NavigationRailDestination>[
              for (final WalletMode m in WalletMode.values)
                NavigationRailDestination(
                  icon: Icon(m.icon),
                  label: Text(m.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_mode) {
      case WalletMode.setup:
        return SetupScreen(core: widget.core);
      case WalletMode.orbit:
        return _OrbitModeTabs(core: widget.core);
      case WalletMode.train:
      case WalletMode.accelerate:
      case WalletMode.inherit:
        return _comingSoon(_mode);
    }
  }

  Widget _comingSoon(WalletMode mode) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(mode.icon, size: 48),
            const SizedBox(height: 16),
            Text('${mode.label} mode is in development.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'This integration pass wires Setup (great-wall-core + '
              'great-wall-ux). The remaining modes depend on libraries that '
              'are not yet public.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// The Orbit mode body: a **Setup** tab (the production 0.4.0 coercion-resistant
/// flow) and a **Harness** tab (a dev end-to-end runner). Kept in one mode so
/// the nav rail stays uncluttered and the two orbit surfaces sit together.
class _OrbitModeTabs extends StatelessWidget {
  const _OrbitModeTabs({required this.core});

  final GreatWallCore core;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: <Widget>[
          const TabBar(
            tabs: <Widget>[
              Tab(text: 'Setup'),
              Tab(text: 'Harness (dev)'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                OrbitSetupScreen(core: core),
                OrbitHarnessScreen(core: core),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
