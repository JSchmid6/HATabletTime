import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "app.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const HaTabletTimeApp());
}
