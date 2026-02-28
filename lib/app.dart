import "package:flutter/foundation.dart" show debugPrint;
import "package:flutter/material.dart";
import "models/account_config.dart";
import "screens/home_screen.dart";
import "screens/setup_wizard.dart";
import "services/ha_client.dart";
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
    _load();
  }

  Future<void> _load() async {
    var c = await SecureStorage.loadConfig();
    // Auto-migrate http:// → https:// if the https version is reachable.
    if (c != null && c.haUrl.startsWith('http://')) {
      final httpsUrl = c.haUrl.replaceFirst('http://', 'https://');
      debugPrint('[App] stored URL is http://, testing $httpsUrl ...');
      final err = await HaClient.validateHaUrl(httpsUrl);
      debugPrint('[App] validateHaUrl($httpsUrl) => ${err ?? 'OK'}');
      if (err == null) {
        c = c.copyWith(haUrl: httpsUrl);
        await SecureStorage.saveConfig(c);
        debugPrint('[App] migrated URL to $httpsUrl');
      }
    } else {
      debugPrint('[App] using stored URL: ${c?.haUrl}');
    }
    setState(() { _config = c; _loading = false; });
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
