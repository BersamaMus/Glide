import 'package:flutter/material.dart';

import '../services/update_check.dart';
import '../theme.dart';

/// The Settings tab: whether Glide looks for a new version, and which
/// version this is.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Null until they've been read.
  bool? _checkForUpdates;
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await UpdateCheck.enabled;
    if (mounted) setState(() => _checkForUpdates = on);
    try {
      final version = await UpdateCheck.currentVersion;
      if (mounted) setState(() => _version = version);
    } on Object {
      // Left out: the switch still works.
    }
  }

  void _setCheckForUpdates(bool on) {
    setState(() => _checkForUpdates = on);
    UpdateCheck.setEnabled(on);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            SwitchListTile(
              title: const Text('Check for updates'),
              subtitle: const Text(
                'Each time Glide opens, it asks GitHub whether a newer version is out. Nothing about you or your pictures is sent',
              ),
              activeThumbColor: AppColors.onAccent,
              activeTrackColor: AppColors.accent,
              value: _checkForUpdates ?? true,
              onChanged: _checkForUpdates == null ? null : _setCheckForUpdates,
            ),
            const Divider(),
            ListTile(
              title: Text(_version == null ? 'Glide' : 'Glide $_version'),
              subtitle: Text(
                'Shows the pictures already on this device. It only goes online to check for updates',
                style: text.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
