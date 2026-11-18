import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const TravaBleApp());
}

class TravaBleApp extends StatelessWidget {
  const TravaBleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Controle de Acesso BLE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LockControlPage(),
    );
  }
}

class LockControlPage extends StatefulWidget {
  const LockControlPage({super.key});

  @override
  State<LockControlPage> createState() => _LockControlPageState();
}

class _LockControlPageState extends State<LockControlPage> {
  static const String targetDeviceName = "Trava_ESP32_01";
  static const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String charTxUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a7";
  static const String charRxUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  final TextEditingController _userIdController =
      TextEditingController(text: "admin_01");
  final TextEditingController _secretController =
      TextEditingController(text: "ChaveSecretaSuperSegura2026!");

  bool _isBusy = false;
  bool _obscureSecret = true;
  String _statusMessage = "Pronto para destrancar";
  Color _statusColor = Colors.grey;
  final List<String> _logs = [];

  @override
  void dispose() {
    _userIdController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  void _addLog(String text, {Color? color}) {
    setState(() {
      final now = DateTime.now();
      final time =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      _logs.insert(0, "[$time] $text");
      _statusMessage = text;
      if (color != null) _statusColor = color;
    });
  }

  /// Calcula HMAC-SHA256(secret, "userId:nonce")
  String _computeUserHmac(String secret, String userId, String nonce) {
    final keyBytes = utf8.encode(secret);
    final dataBytes = utf8.encode("$userId:$nonce");
    final hmac = Hmac(sha256, keyBytes);
    return hmac.convert(dataBytes).toString();
  }

  Future<bool> _requestBlePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final connectOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;

      if (!scanOk || !connectOk) {
        _addLog("Permissões Bluetooth negadas.", color: Colors.redAccent);
        return false;
      }
    }
    return true;
  }

  Future<void> _unlockDoor() async {
    if (_isBusy) return;

    final userId = _userIdController.text.trim();
    final secret = _secretController.text.trim();

    if (userId.isEmpty || secret.isEmpty) {
      _addLog("Preencha o ID do usuário e a chave.", color: Colors.orangeAccent);
      return;
    }

    setState(() {
      _isBusy = true;
      _logs.clear();
    });

    BluetoothDevice? targetDevice;
    StreamSubscription<List<ScanResult>>? scanSub;

    try {
      if (!await _requestBlePermissions()) return;

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _addLog("Ligue o Bluetooth do celular.", color: Colors.orangeAccent);
        return;
      }

      _addLog("Procurando $targetDeviceName...", color: Colors.blueAccent);

      final completer = Completer<BluetoothDevice>();

      scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final advName = r.advertisementData.advName;
          final platformName = r.device.platformName;
          if (advName == targetDeviceName || platformName == targetDeviceName) {
            if (!completer.isCompleted) {
              completer.complete(r.device);
            }
          }
        }
      });

      await FlutterBluePlus.startScan(
        withNames: [targetDeviceName],
        timeout: const Duration(seconds: 6),
      );

      targetDevice = await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => throw TimeoutException("Trava não encontrada por perto."),
      );

      await FlutterBluePlus.stopScan();
      await scanSub.cancel();

      _addLog("Conectando ao ESP32...", color: Colors.blueAccent);
      await targetDevice.connect(
        timeout: const Duration(seconds: 6),
        autoConnect: false, license: License.free,
      );

      if (Platform.isAndroid) {
        await targetDevice.clearGattCache();
        await targetDevice.requestMtu(256);
      }

      _addLog("Descobrindo serviços GATT...", color: Colors.blueAccent);
      final services = await targetDevice.discoverServices();

      BluetoothCharacteristic? txChar;
      BluetoothCharacteristic? rxChar;

      for (final s in services) {
        if (s.uuid.str.toLowerCase() == serviceUuid.toLowerCase()) {
          for (final c in s.characteristics) {
            final uuid = c.uuid.str.toLowerCase();
            if (uuid == charTxUuid.toLowerCase()) txChar = c;
            if (uuid == charRxUuid.toLowerCase()) rxChar = c;
          }
        }
      }

      if (txChar == null || rxChar == null) {
        throw Exception("Características TX/RX não encontradas no ESP32.");
      }

      // 1. Lê o TX: o próprio ato de ler dispara o onRead no ESP32 e retorna o Nonce fresco
      _addLog("Solicitando e lendo desafio...", color: Colors.blueAccent);
      final nonceBytes = await txChar.read();
      final nonce = utf8.decode(nonceBytes).trim();

      if (nonce.length != 32) {
        throw Exception("Nonce inválido (${nonce.length} bytes): '$nonce'");
      }
      _addLog("Nonce OK: ${nonce.substring(0, 8)}...", color: Colors.blueAccent);

      // 2. Assina "userId:nonce" com a chave individual do usuário e envia
      final hmacHex = _computeUserHmac(secret, userId, nonce);
      final outboundPayload = "$userId:$hmacHex";
      _addLog("Enviando credencial (${outboundPayload.length}B)...", color: Colors.blueAccent);

      await rxChar.write(
        utf8.encode(outboundPayload),
        withoutResponse: false,
      );

      _addLog("Credencial enviada para [$userId]!", color: Colors.greenAccent);
    } on TimeoutException catch (e) {
      _addLog(e.message ?? "Tempo esgotado.", color: Colors.orangeAccent);
    } catch (e) {
      _addLog("Erro: ${e.toString().replaceFirst('Exception: ', '')}",
          color: Colors.redAccent);
    } finally {
      await FlutterBluePlus.stopScan();
      await scanSub?.cancel();
      if (targetDevice != null) {
        await Future.delayed(const Duration(milliseconds: 300));
        await targetDevice.disconnect();
      }
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Acesso BLE Multi-Usuário'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            TextField(
              controller: _userIdController,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'ID do Usuário',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _secretController,
              obscureText: _obscureSecret,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: 'Chave Secreta Individual',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureSecret ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                ),
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: _isBusy ? null : _unlockDoor,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 175,
                height: 175,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isBusy
                      ? Colors.blueGrey.withOpacity(0.3)
                      : Colors.teal.withOpacity(0.2),
                  border: Border.all(
                    color: _isBusy ? Colors.blueAccent : Colors.tealAccent,
                    width: 3,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isBusy ? Icons.sync : Icons.lock_open_rounded,
                      size: 56,
                      color: _isBusy ? Colors.blueAccent : Colors.tealAccent,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isBusy ? "AUTENTICANDO" : "ABRIR TRAVA",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _statusColor,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              height: 150,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _logs[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}