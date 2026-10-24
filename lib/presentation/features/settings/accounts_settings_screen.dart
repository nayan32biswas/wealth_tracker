import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/accounts.dart';
import '../../../domain/models/enums.dart';
import '../../../domain/services/money.dart';
import '../../app/providers.dart';
import '../../widgets/common.dart';

class AccountsSettingsScreen extends ConsumerWidget {
  const AccountsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? [];
    final assets = ref.watch(assetsProvider).value ?? [];
    final archived = ref.watch(archivedAssetsProvider).value ?? [];
    String count(int groupId) {
      final shown = assets.where((a) => a.groupId == groupId).length;
      final hidden = archived.where((a) => a.groupId == groupId).length;
      return '$shown accounts${hidden == 0 ? '' : ' · $hidden archived'}';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts and groups'),
        actions: [
          IconButton(
            tooltip: 'Archived accounts',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () =>
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ArchivedAccountsScreen())),
          ),
          IconButton(
            tooltip: 'Add group',
            icon: const Icon(Icons.add),
            onPressed: () => editGroup(context, ref, const AssetGroup(id: 0, name: '', type: GroupType.asset)),
          ),
        ],
      ),
      body: ReorderableTiles(
        ids: [for (final g in groups) g.id],
        onReorder: ref.read(repositoriesProvider).groups.reorder,
        children: [
          for (final g in groups)
            ListTile(
              title: Text(g.name),
              subtitle: Text('${g.isLiability ? 'Liability' : 'Asset'} · ${count(g.id)}'),
              onTap: () =>
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => GroupAccountsScreen(groupId: g.id))),
            ),
        ],
      ),
    );
  }
}

/// Returns true when the group was removed.
Future<bool> editGroup(BuildContext context, WidgetRef ref, AssetGroup group) async {
  final repo = ref.read(repositoriesProvider).groups;
  final result = await showDialog<EditResult<AssetGroup>>(
    context: context,
    builder: (_) => _GroupDialog(group, group.id == 0 ? null : 'Delete'),
  );
  if (result == null || !context.mounted) return false;
  var removed = false;
  await guarded(context, () async {
    switch (result) {
      case (DialogAction.remove, _):
        await repo.remove(group.id);
        removed = true;
      case (DialogAction.save, final edited?) when edited.id == 0:
        await repo.add(edited.name, edited.type);
      case (DialogAction.save, final edited?):
        await repo.update(edited);
      case (DialogAction.save, null):
        break;
    }
  });
  return removed;
}

class GroupAccountsScreen extends ConsumerWidget {
  const GroupAccountsScreen({super.key, required this.groupId});

  final int groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = (ref.watch(groupsProvider).value ?? []).where((g) => g.id == groupId).firstOrNull;
    if (group == null) return const Scaffold();
    final accounts = (ref.watch(assetsProvider).value ?? []).where((a) => a.groupId == groupId).toList();
    final archived = (ref.watch(archivedAssetsProvider).value ?? []).where((a) => a.groupId == groupId).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(group.name),
        actions: [
          IconButton(
            tooltip: 'Edit group',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              if (await editGroup(context, ref, group) && context.mounted) Navigator.pop(context);
            },
          ),
          IconButton(
            tooltip: 'Add account',
            icon: const Icon(Icons.add),
            onPressed: () => _editAccount(context, ref, group, Asset(id: 0, name: '', groupId: groupId)),
          ),
        ],
      ),
      body: ReorderableTiles(
        ids: [for (final a in accounts) a.id],
        onReorder: ref.read(repositoriesProvider).assets.reorder,
        // Archived accounts still belong to the group, so they are listed
        // here too: moving them out is what lets an old group be deleted.
        footer: archived.isEmpty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
                    child: Text(
                      'Archived',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                  for (final (i, a) in archived.indexed) ...[
                    if (i > 0) const RowDivider(),
                    ListTile(title: Text(a.name), onTap: () => _editAccount(context, ref, group, a)),
                  ],
                ],
              ),
        children: [
          for (final a in accounts) ListTile(title: Text(a.name), onTap: () => _editAccount(context, ref, group, a)),
        ],
      ),
    );
  }

  Future<void> _editAccount(BuildContext context, WidgetRef ref, AssetGroup group, Asset asset) async {
    final repo = ref.read(repositoriesProvider).assets;
    final entries = asset.id == 0 ? 0 : await repo.usage(asset.id);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // The label is only a forecast: remove() decides for itself whether the
    // account can go or has to be archived.
    final String? removeLabel = switch ((asset.id, entries, asset.isArchived)) {
      (0, _, _) => null,
      (_, 0, _) => 'Delete',
      (_, _, false) => 'Archive',
      _ => null,
    };
    final result = await showDialog<EditResult<Asset>>(
      context: context,
      builder: (_) => _AccountDialog(
        asset,
        group,
        ref.read(groupsProvider).value ?? [group],
        ref.read(moneyFormatProvider),
        removeLabel,
      ),
    );
    if (result == null || !context.mounted) return;
    await guarded(context, () async {
      switch (result) {
        case (DialogAction.remove, _):
          final deleted = await repo.remove(asset.id);
          if (!deleted && removeLabel == 'Delete' && !asset.isArchived) {
            messenger.showSnackBar(
              SnackBar(content: Text('${asset.name} is still linked to old entries, so it was archived instead.')),
            );
          }
        case (DialogAction.save, final edited?) when edited.id == 0:
          await repo.add(edited.name, edited.groupId, initialBalance: edited.initialBalance);
        case (DialogAction.save, final edited?):
          await repo.update(edited);
        case (DialogAction.save, null):
          break;
      }
    });
  }
}

class _GroupDialog extends StatefulWidget {
  const _GroupDialog(this.group, this.removeLabel);

  final AssetGroup group;
  final String? removeLabel;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final _name = TextEditingController(text: widget.group.name);
  late GroupType _type = widget.group.type;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog<AssetGroup>(
    title: widget.group.id == 0 ? 'New group' : 'Edit group',
    removeLabel: widget.removeLabel,
    value: () => _name.text.trim().isEmpty ? null : widget.group.copyWith(name: _name.text.trim(), type: _type),
    children: [
      TextField(
        controller: _name,
        autofocus: widget.group.id == 0,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (_) => setState(() {}),
      ),
      SegmentedButton<GroupType>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: GroupType.asset, label: Text('Asset')),
          ButtonSegment(value: GroupType.liability, label: Text('Liability')),
        ],
        selected: {_type},
        onSelectionChanged: (s) => setState(() => _type = s.single),
      ),
    ],
  );
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog(this.asset, this.group, this.groups, this.money, this.removeLabel);

  final Asset asset;
  final AssetGroup group;
  final List<AssetGroup> groups;
  final MoneyFormat money;
  final String? removeLabel;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final _name = TextEditingController(text: widget.asset.name);
  late int _groupId = widget.asset.groupId;
  // A liability's opening amount is what the user owes, stored as a
  // negative balance. The sign is shown as typed, so an overdrawn account
  // or a card in credit keeps its real value when the dialog is saved.
  int get _direction => widget.group.isLiability ? -1 : 1;

  late final _opening = TextEditingController(text: _signedText(widget.asset.initialBalance * _direction));

  String _signedText(int value) => '${value < 0 ? '-' : ''}${widget.money.editText(value.abs())}';

  Asset? _value() {
    final name = _name.text.trim();
    final text = _opening.text.trim();
    final negative = text.startsWith('-');
    final amount = text.isEmpty ? 0 : widget.money.parse(negative ? text.substring(1) : text);
    if (name.isEmpty || amount == null) return null;
    // The sign follows the group the amount was shown for, so moving to a
    // group of the other type keeps the stored balance as it was.
    return widget.asset.copyWith(
      name: name,
      groupId: _groupId,
      initialBalance: (negative ? -amount : amount) * _direction,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog<Asset>(
    title: widget.asset.id == 0 ? 'New account' : 'Edit account',
    removeLabel: widget.removeLabel,
    value: _value,
    children: [
      TextField(
        controller: _name,
        autofocus: widget.asset.id == 0,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (_) => setState(() {}),
      ),
      TextField(
        controller: _opening,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(labelText: widget.group.isLiability ? 'Amount owed' : 'Opening balance'),
        onChanged: (_) => setState(() {}),
      ),
      if (widget.asset.id != 0)
        DropdownButtonFormField<int>(
          isExpanded: true,
          initialValue: _groupId,
          decoration: const InputDecoration(labelText: 'Group'),
          items: [for (final g in widget.groups) DropdownMenuItem(value: g.id, child: Text(g.name))],
          onChanged: (id) => setState(() => _groupId = id!),
        ),
    ],
  );
}

class ArchivedAccountsScreen extends ConsumerWidget {
  const ArchivedAccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = {for (final g in ref.watch(groupsProvider).value ?? <AssetGroup>[]) g.id: g.name};
    final accounts = ref.watch(archivedAssetsProvider).value ?? [];
    final repo = ref.read(repositoriesProvider).assets;
    return DeletedList(
      title: 'Archived accounts',
      empty: 'No archived accounts',
      actionLabel: 'Unarchive',
      sections: [
        (
          'Accounts',
          [
            for (final a in accounts)
              (
                name: a.name,
                detail: groups[a.groupId],
                restore: () => repo.unarchive(a.id),
                restored: '${a.name} is back in the list',
              ),
          ],
        ),
      ],
    );
  }
}
