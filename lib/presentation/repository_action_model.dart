import 'package:alembic/widget/repository_tile_actions.dart';
import 'package:flutter/widgets.dart' as m;

class RepositoryActionModel {
  final RepositoryTileAction action;
  final String label;
  final String description;
  final m.IconData icon;
  final bool prominent;
  final bool destructive;

  const RepositoryActionModel({
    required this.action,
    required this.label,
    required this.description,
    required this.icon,
    this.prominent = false,
    this.destructive = false,
  });
}
