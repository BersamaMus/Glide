import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

import '../services/browser.dart';
import '../services/places.dart';
import '../theme.dart';
import '../widgets/picture_actions.dart';
import '../widgets/picture_grid.dart';
import '../widgets/preview_pane.dart';

/// From this window width up, the tabs run down the side and the preview
/// pane sits beside the grid. Narrower (a phone), the tabs are in a drawer
/// and a picture opens on its own page.
const wideLayoutWidth = 840.0;

enum _Tab {
  pictures('Pictures', Icons.photo_library_outlined, Icons.photo_library_rounded),
  drives('Drives', Icons.storage_outlined, Icons.storage_rounded),
  memories('Memories', Icons.auto_awesome_outlined, Icons.auto_awesome_rounded),
  external('External', Icons.usb_outlined, Icons.usb_rounded),
  phone('Phone', Icons.smartphone_outlined, Icons.smartphone_rounded),
  settings('Settings', Icons.settings_outlined, Icons.settings_rounded);

  const _Tab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.open});

  /// A folder or picture to start with, rather than Pictures.
  final String? open;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _browser = Browser(_home);
  var _tab = _Tab.pictures;

  /// What the Pictures tab shows: on a PC, the Pictures folder; on a phone,
  /// every picture in its gallery.
  static Location get _home => Platform.isAndroid ? const AndroidGallery() : PhotoLibrary(picturesFolder);

  /// On a phone, back in the app: the gallery's looked at again, for access
  /// given in Settings meanwhile, or pictures taken.
  AppLifecycleListener? _lifecycle;

  /// Drives and phones are Windows' (Android's are on the way). Memories is
  /// on both: on a phone, of the gallery's pictures; on a PC, of those in
  /// Pictures and on the drives inside it.
  static final _tabs = [
    for (final tab in _Tab.values)
      if (Platform.isWindows || const {_Tab.pictures, _Tab.memories, _Tab.settings}.contains(tab)) tab,
  ];

  /// The tabs down the side, with Settings kept apart at the bottom.
  static final _railTabs = _tabs.where((t) => t != _Tab.settings).toList();

  /// The drive the Drives tab, and the External tab, showed last.
  PhotoLibrary? _lastInternal;
  PhotoLibrary? _lastExternal;

  /// What's plugged in, by what tells each apart (a drive's root and label,
  /// a phone's serial): counted on the External and Phone tabs, and said
  /// when something new is.
  var _externals = <String, PhotoLibrary>{};
  var _phones = <String, Phone>{};

  /// The drives inside the PC, as last looked.
  var _internals = <PhotoLibrary>[];

  /// Whether the drives and phones have been looked for yet: until then, a
  /// tab asks for them itself.
  var _devicesKnown = false;
  Timer? _watcher;

  @override
  void initState() {
    super.initState();
    _browser.addListener(_noteDrive);
    // Finding and sorting a drive's or phone's pictures can take a while:
    // said when it's done.
    _browser.onFinished = (message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    };
    _openFirst();
    if (Platform.isAndroid) {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          if (_browser.location case AndroidGallery() || Memories()) {
            _browser.refresh();
          }
        },
      );
    }
    if (Platform.isWindows) {
      _watch(quietly: true);
      _watcher = Timer.periodic(const Duration(seconds: 3), (_) => _watch());
    }
  }

  void _noteDrive() {
    if (_browser.location case PhotoLibrary(:final drive?) && final library) {
      if (drive.external) {
        _lastExternal = library;
      } else {
        _lastInternal = library;
      }
    }
  }

  /// Looks for USB drives, memory cards and phones being plugged in or taken
  /// out, offering to open what's new.
  Future<void> _watch({bool quietly = false}) async {
    // A drive spinning up, or a phone that's busy, can keep the last look
    // waiting: no more piled up behind it meanwhile.
    if (_watching) return;
    _watching = true;
    try {
      await _lookForDevices(quietly: quietly);
    } finally {
      _watching = false;
    }
  }

  var _watching = false;

  Future<void> _lookForDevices({required bool quietly}) async {
    Map<String, PhotoLibrary> externals;
    Map<String, Phone> phones;
    try {
      final drives = await PhotoLibrary.allDrives();
      externals = {
        for (final library in drives)
          if (library.drive!.external) '${library.path}|${library.drive!.label}': library,
      };
      _internals = [
        for (final library in drives)
          if (!library.drive!.external) library,
      ];
      phones = {for (final phone in await Phones.list()) phone.serial: phone};
    } on Object {
      return; // asked again shortly
    }
    if (!mounted) return;
    _devicesKnown = true;
    final newDrives = [
      for (final MapEntry(:key, :value) in externals.entries)
        if (!_externals.containsKey(key)) value,
    ];
    final newPhones = [
      for (final MapEntry(:key, :value) in phones.entries)
        if (!_phones.containsKey(key)) value,
    ];
    if (externals.length != _externals.length ||
        phones.length != _phones.length ||
        newDrives.isNotEmpty ||
        newPhones.isNotEmpty) {
      setState(() {
        _externals = externals;
        _phones = phones;
      });
    } else {
      _externals = externals;
      _phones = phones;
    }
    if (quietly) return;
    for (final library in newDrives) {
      _connected('${library.title} connected', Icons.usb_rounded, () => _selectTab(_Tab.external, library));
    }
    for (final phone in newPhones) {
      _connected('${phone.name} connected', Icons.smartphone_rounded, () => _selectTab(_Tab.phone));
    }
  }

  void _connected(String message, IconData icon, VoidCallback open) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.accent),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        action: SnackBarAction(label: 'Open', onPressed: open),
        // Gone after a while even so (with an action, it'd stay till
        // clicked): the tab's badge still says it's there.
        persist: false,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// How many of what's on a tab are plugged in: drives, or phones.
  int _count(_Tab tab) => switch (tab) {
    _Tab.external => _externals.length,
    _Tab.phone => _phones.length,
    _ => 0,
  };

  /// The tab's icon, with a badge counting what's plugged in.
  Widget _icon(_Tab tab, {required bool selected}) {
    final count = _count(tab);
    return Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      backgroundColor: AppColors.accent,
      textColor: AppColors.onAccent,
      child: Icon(selected ? tab.selectedIcon : tab.icon),
    );
  }

  Future<void> _openFirst() async {
    final path = widget.open;
    if (path != null && await FileSystemEntity.isDirectory(path)) {
      return _browser.open(PhotoLibrary(p.absolute(path)));
    }
    if (path != null && await File(path).exists()) {
      final file = p.absolute(path);
      await _browser.open(PhotoLibrary(p.dirname(file)));
      if (_browser.pictures.where((picture) => picture.id == file).firstOrNull case final picture?) {
        _browser.click(picture);
      }
      return;
    }
    await _browser.open(_browser.location);
  }

  @override
  void dispose() {
    _watcher?.cancel();
    _lifecycle?.dispose();
    _browser.removeListener(_noteDrive);
    _browser.dispose();
    super.dispose();
  }

  /// Shows [tab]: with [drive], that drive.
  Future<void> _selectTab(_Tab tab, [PhotoLibrary? drive]) async {
    setState(() => _tab = tab);
    // Drives and phones are asked for, so what's opened waits on that; it's
    // only opened if the tab's still showing by then.
    Future<void> openOnTab(Location location) async {
      if (mounted && _tab == tab) await _browser.open(location);
    }

    switch (tab) {
      case _Tab.pictures:
        await _browser.open(_home);
      case _Tab.memories:
        // Known from the last look, as on the Drives tab.
        final drives = _devicesKnown ? _internals : await PhotoLibrary.drives(external: false);
        await openOnTab(Memories([_home, ...drives]));
      case _Tab.drives || _Tab.external:
        final external = tab == _Tab.external;
        // Known from the last look (a few seconds ago), so the tab's shown
        // at once: asking again can wait on a drive spinning up.
        final drives = _devicesKnown
            ? (external ? _externals.values.toList() : _internals)
            : await PhotoLibrary.drives(external: external);
        // The one asked for, else the one looked at last while it's still
        // there, else the first.
        final last = external ? _lastExternal : _lastInternal;
        final Location? open = drive != null && drives.contains(drive)
            ? drive
            : drives.contains(last)
            ? last
            : drives.firstOrNull;
        await openOnTab(open ?? const NoExternalDrive());
      case _Tab.phone:
        // A phone that's ready, if there is one: known from the last look,
        // as asking again waits its turn behind what the phone's reading.
        await openOnTab(_devicesKnown ? PhonePhotos.firstOf(_phones.values) : await PhonePhotos.first());
      case _Tab.settings:
        _browser.clearSelection();
    }
  }

  bool get _browsing => _tab != _Tab.settings;

  Widget _page({ValueChanged<Picture>? onOpen}) => _browsing
      ? PictureGrid(browser: _browser, onOpen: onOpen)
      : const MessageView(icon: Icons.settings_rounded, text: 'Settings are on the way.');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= wideLayoutWidth ? _wideLayout() : _narrowLayout(context),
    );
  }

  /// Sidebar, grid, preview.
  Widget _wideLayout() {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _railTabs.contains(_tab) ? _railTabs.indexOf(_tab) : null,
            onDestinationSelected: (i) => _selectTab(_railTabs[i]),
            groupAlignment: -0.9,
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: IconButton(
                    tooltip: 'Settings',
                    isSelected: _tab == _Tab.settings,
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings_rounded, color: AppColors.accent),
                    color: AppColors.textSecondary,
                    onPressed: () => _selectTab(_Tab.settings),
                  ),
                ),
              ),
            ),
            destinations: [
              for (final tab in _railTabs)
                NavigationRailDestination(
                  icon: _icon(tab, selected: false),
                  selectedIcon: _icon(tab, selected: true),
                  label: Text(tab.label),
                ),
            ],
          ),
          Expanded(child: _page()),
          // As much room for the picture as for the grid.
          if (_browsing)
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(left: BorderSide(color: AppColors.divider)),
                ),
                child: PreviewPane(browser: _browser),
              ),
            ),
        ],
      ),
    );
  }

  /// A phone: tabs in a drawer; a picture opens full screen. While picking
  /// pictures (after a long press), the bar says how many, and shares or
  /// deletes them; Back stops picking.
  Widget _narrowLayout(BuildContext context) => ListenableBuilder(
    listenable: _browser,
    builder: (context, _) => PopScope(
      canPop: !_browser.picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _browser.stopPicking();
      },
      child: _narrowScaffold(context),
    ),
  );

  Widget _narrowScaffold(BuildContext context) {
    final picking = _browser.picking;
    return Scaffold(
      appBar: picking
          ? AppBar(
              leading: IconButton(
                tooltip: 'Stop selecting',
                icon: const Icon(Icons.close_rounded),
                onPressed: _browser.stopPicking,
              ),
              title: Text('${_browser.selectedCount} selected'),
              actions: [
                if (canCompare(_browser))
                  IconButton(
                    tooltip: 'Compare',
                    icon: const Icon(Icons.compare_rounded),
                    onPressed: () => compareSelection(context, _browser),
                  ),
                if (canCollage(_browser))
                  IconButton(
                    tooltip: 'Collage',
                    icon: const Icon(Icons.dashboard_outlined),
                    onPressed: () => collageSelection(context, _browser),
                  ),
                if (_browser.canShare)
                  IconButton(tooltip: 'Share', icon: const Icon(Icons.share_outlined), onPressed: _browser.shareSelection),
                if (_browser.canDelete)
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => deleteSelection(context, _browser),
                  ),
                const SizedBox(width: 4),
              ],
            )
          : AppBar(title: Text(_tab.label)),
      drawer: picking ? null : NavigationDrawer(
        selectedIndex: _tabs.indexOf(_tab),
        onDestinationSelected: (i) {
          Navigator.pop(context);
          _selectTab(_tabs[i]);
        },
        children: [
          const SizedBox(height: 16),
          for (final tab in _tabs)
            NavigationDrawerDestination(
              icon: _icon(tab, selected: false),
              selectedIcon: _icon(tab, selected: true),
              label: Text(tab.label),
            ),
        ],
      ),
      body: _page(
        onOpen: (picture) {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PictureViewer(browser: _browser),
            ),
          );
        },
      ),
    );
  }
}
