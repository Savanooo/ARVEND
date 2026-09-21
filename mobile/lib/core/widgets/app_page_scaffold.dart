import 'package:flutter/material.dart';

/// Ekranların ortak `Scaffold` + `AppBar` iskeleti -- her ekranın kendi
/// `Scaffold(appBar: AppBar(...))` tekrarı yerine.
class AppPageScaffold extends StatelessWidget {
  const AppPageScaffold({
    super.key,
    required this.title,
    this.actions,
    this.bottom,
    required this.body,
    this.floatingActionButton,
  });

  final Widget title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget body;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: title, actions: actions, bottom: bottom),
      body: body,
      floatingActionButton: floatingActionButton,
    );
  }
}
