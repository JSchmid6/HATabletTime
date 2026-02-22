import "package:flutter/material.dart";
import "models/account_config.dart";
import "screens/home_screen.dart";
import "screens/setup_wizard.dart";
import "services/secure_storage.dart";

class HaTabletTimeApp extends StatelessWidget {
  const HaTabletTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Zeitkonto",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1976D2)),
        useMaterial3: true,
      ),
      home: const _StartupRouter(),
    );
  }
}

class _StartupRouter extends StatefulWidget {
  const _StartupRouter();
  @override
  State<_StartupRouter> createState() => _StartupRouterState();
}

class _StartupRouterState extends State<_StartupRouter> {
  AccountConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SecureStorage.loadConfig().then((c) {
      setState(() { _config = c; _loading = false; });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_config == null) {
      return SetupWizard(onComplete: (config) => setState(() => _config = config));
    }
    return HomeScreen(config: _config!);
  }
}
