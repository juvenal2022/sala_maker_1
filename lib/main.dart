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
      TextEditingController(text: "12345678");

  // Controladores do painel administrativo
  final TextEditingController _targetUserController = TextEditingController();
  final TextEditingController _targetSecretController = TextEditingController();

  bool _isBusy = false;
  bool _obscureSecret = true;
  String _statusMessage = "Pronto para destrancar";
  Color _statusColor = Colors.grey;
  final List<String> _logs = [];

  bool get _isAdmin => _userIdController.text.trim() == "admin_01";

  @override
  void initState() {
    super.initState();
    _userIdController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _secretController.dispose();
    _targetUserController.dispose();
    _targetSecretController.dispose();
    super.dispose();
  }

  void _addLog(String text, {Color? color}) {
    if (!mounted) return;
    setState(() {
      final now = DateTime.now();
      final time =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      _logs.insert(0, "[$time] $text");
      _statusMessage = text;
      if (color != null) _statusColor = color;
    });
  }

  String _computeHmac(String secret, String message) {
    final keyBytes = utf8.encode(secret);
    final dataBytes = utf8.encode(message);
    return Hmac(sha256, keyBytes).convert(dataBytes).toString();
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

  /// Executa qualquer transação BLE autenticada (abertura ou comando admin)
  Future<void> _executeBleTransaction({
    required String Function(String nonce) buildPayload,
    required String successFeedback,
  }) async {
    if (_isBusy) return;

    final userId = _userIdController.text.trim();
    final secret = _secretController.text.trim();

    if (userId.isEmpty || secret.isEmpty) {
      _addLog("Preencha o ID e a chave do usuário.", color: Colors.orangeAccent);
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
          if (r.advertisementData.advName == targetDeviceName ||
              r.device.platformName == targetDeviceName) {
            if (!completer.isCompleted) completer.complete(r.device);
          }
        }
      });

      await FlutterBluePlus.startScan(
        withNames: [targetDeviceName],
        timeout: const Duration(seconds: 6),
      );

      targetDevice = await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => throw TimeoutException("Trava não encontrada."),
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
        throw Exception("Serviço BLE da trava não encontrado.");
      }

      // Lê o Nonce gerado sob demanda no onRead do ESP32
      _addLog("Obtendo desafio...", color: Colors.blueAccent);
      final nonceBytes = await txChar.read();
      final nonce = utf8.decode(nonceBytes).trim();

      if (nonce.length != 32) {
        throw Exception("Nonce inválido (${nonce.length} bytes).");
      }

      final outboundPayload = buildPayload(nonce);
      _addLog("Enviando pacote (${outboundPayload.length}B)...",
          color: Colors.blueAccent);

      await rxChar.write(
        utf8.encode(outboundPayload),
        withoutResponse: false,
      );

      _addLog(successFeedback, color: Colors.greenAccent);
    } on TimeoutException catch (e) {
      _addLog(e.message ?? "Tempo esgotado.", color: Colors.orangeAccent);
    } catch (e) {
      _addLog(
        "Erro: ${e.toString().replaceFirst('Exception: ', '')}",
        color: Colors.redAccent,
      );
    } finally {
      await FlutterBluePlus.stopScan();
      await scanSub?.cancel();
      if (targetDevice != null) {
        await Future.delayed(const Duration(milliseconds: 300));
        await targetDevice.disconnect();
      }
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _unlockDoor() {
    final userId = _userIdController.text.trim();
    final secret = _secretController.text.trim();

    _executeBleTransaction(
      buildPayload: (nonce) {
        final hmac = _computeHmac(secret, "$userId:$nonce");
        return "$userId:$hmac";
      },
      successFeedback: "Solicitação de abertura enviada por [$userId]!",
    );
  }

  void _addOrUpdateUser() {
    final adminId = _userIdController.text.trim();
    final adminSecret = _secretController.text.trim();
    final targetId = _targetUserController.text.trim();
    final targetKey = _targetSecretController.text.trim();

    if (targetId.isEmpty || targetId.length > 15 || targetId.contains(':')) {
      _addLog("ID do novo usuário inválido (1-15 chars, sem ':').",
          color: Colors.orangeAccent);
      return;
    }
    if (targetKey.length < 8 || targetKey.contains(':')) {
      _addLog("Chave inválida (mín. 8 chars, sem ':').",
          color: Colors.orangeAccent);
      return;
    }

    _executeBleTransaction(
      buildPayload: (nonce) {
        final hmac =
            _computeHmac(adminSecret, "$adminId:ADD:$targetId:$targetKey:$nonce");
        return "$adminId:ADD:$targetId:$targetKey:$hmac";
      },
      successFeedback: "Comando ADD enviado para [$targetId]!",
    );
  }

  void _removeUser() {
    final adminId = _userIdController.text.trim();
    final adminSecret = _secretController.text.trim();
    final targetId = _targetUserController.text.trim();

    if (targetId.isEmpty || targetId == "admin_01") {
      _addLog("Informe um usuário válido (diferente de admin_01).",
          color: Colors.orangeAccent);
      return;
    }

    _executeBleTransaction(
      buildPayload: (nonce) {
        final hmac = _computeHmac(adminSecret, "$adminId:DEL:$targetId:$nonce");
        return "$adminId:DEL:$targetId:$hmac";
      },
      successFeedback: "Comando DEL enviado para [$targetId]!",
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Controle de Acesso BLE'),
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
                labelText: 'Seu ID de Usuário',
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
                labelText: 'Sua Chave Secreta',
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
            const SizedBox(height: 24),
            GestureDetector(
              onTap: _isBusy ? null : _unlockDoor,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 155,
                height: 155,
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
                      size: 48,
                      color: _isBusy ? Colors.blueAccent : Colors.tealAccent,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isBusy ? "AGUARDE" : "ABRIR TRAVA",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _statusColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),

            // Painel exclusivo quando logado como admin_01
            if (_isAdmin) ...[
              const SizedBox(height: 20),
              Card(
                color: Colors.teal.withOpacity(0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.tealAccent.withOpacity(0.3)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.admin_panel_settings,
                              color: Colors.tealAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            "Administração de Usuários (NVS)",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.tealAccent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _targetUserController,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.none,
                        decoration: const InputDecoration(
                          labelText: 'ID do Usuário Alvo (máx. 15 chars)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _targetSecretController,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.none,
                        decoration: const InputDecoration(
                          labelText: 'Chave Secreta (mín. 8 chars)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isBusy ? null : _addOrUpdateUser,
                              icon: const Icon(Icons.person_add, size: 18),
                              label: const Text("Salvar"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal.shade700,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isBusy ? null : _removeUser,
                              icon: const Icon(Icons.person_remove,
                                  size: 18, color: Colors.redAccent),
                              label: const Text(
                                "Remover",
                                style: TextStyle(color: Colors.redAccent),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.redAccent),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 16),
            Container(
              height: 130,
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