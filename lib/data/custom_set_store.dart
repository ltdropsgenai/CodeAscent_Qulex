import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/custom_set.dart';

/// Local persistence for user-created / imported study sets.
class CustomSetStore {
  static const _k = 'qbit_custom_sets_v1';
  final List<CustomSet> sets = [];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_k);
    sets.clear();
    if (raw != null) {
      final list = json.decode(raw) as List;
      sets.addAll(list
          .map((e) => CustomSet.fromJson((e as Map).cast<String, dynamic>())));
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_k, json.encode(sets.map((s) => s.toJson()).toList()));
  }

  Future<void> upsert(CustomSet s) async {
    final i = sets.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      sets[i] = s;
    } else {
      sets.add(s);
    }
    await _save();
  }

  Future<void> delete(String id) async {
    sets.removeWhere((x) => x.id == id);
    await _save();
  }
}
