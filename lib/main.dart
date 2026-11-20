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
  static const String charStatusUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a9";

  final TextEditingController _userIdController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();

  final TextEditingController _targetUserController = TextEditingController();
  final TextEditingController _targetSecretController = TextEditingController();

  bool _isBusy = false;
  bool _obscureSecret = true;
  bool _obscureTargetSecret = true;
  String _statusMessage = "Pronto para destrancar";
  Color _statusColor = Colors.grey;

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

  void _setStatus(String text, Color color) {
    if (!mounted) return;
    setState(() {
      _statusMessage = text;
      _statusColor = color;
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
      ].request();

      final scanStatus = statuses[Permission.bluetoothScan];
      final connectStatus = statuses[Permission.bluetoothConnect];

      if (scanStatus == PermissionStatus.permanentlyDenied ||
          connectStatus == PermissionStatus.permanentlyDenied) {
        _setStatus("Permissão bloqueada nas configurações.", Colors.orangeAccent);
        await openAppSettings();
        return false;
      }

      if (!(scanStatus?.isGranted ?? false) ||
          !(connectStatus?.isGranted ?? false)) {
        _setStatus("Permissões Bluetooth negadas.", Colors.redAccent);
        return false;
      }
    }
    return true;
  }

  Future<void> _executeBleTransaction({
    required String userId,
    required String secret,
    required String Function(String nonce) buildPayload,
  }) async {
    if (_isBusy) return;

    if (userId.isEmpty || secret.isEmpty) {
      _setStatus("Preencha o ID e a chave do usuário.", Colors.orangeAccent);
      return;
    }

    setState(() => _isBusy = true);
    _setStatus("Conectando...", Colors.blueAccent);

    BluetoothDevice? targetDevice;
    StreamSubscription<List<ScanResult>>? scanSub;

    try {
      if (!await _requestBlePermissions()) return;

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _setStatus("Ligue o Bluetooth do celular.", Colors.orangeAccent);
        return;
      }

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

      await targetDevice.connect(
        timeout: const Duration(seconds: 6),
        autoConnect: false, 
        license: License.free,
      );

      if (Platform.isAndroid) {
        await targetDevice.clearGattCache();
        await targetDevice.requestMtu(256);
      }

      final services = await targetDevice.discoverServices();
      BluetoothCharacteristic? txChar;
      BluetoothCharacteristic? rxChar;
      BluetoothCharacteristic? statusChar;

      for (final s in services) {
        if (s.uuid.str.toLowerCase() == serviceUuid.toLowerCase()) {
          for (final c in s.characteristics) {
            final uuid = c.uuid.str.toLowerCase();
            if (uuid == charTxUuid.toLowerCase()) txChar = c;
            if (uuid == charRxUuid.toLowerCase()) rxChar = c;
            if (uuid == charStatusUuid.toLowerCase()) statusChar = c;
          }
        }
      }

      if (txChar == null || rxChar == null || statusChar == null) {
        throw Exception("Serviço BLE da trava não encontrado.");
      }

      // 1. Lê o Nonce gerado sob demanda no onRead do ESP32
      final nonceBytes = await txChar.read();
      final nonce = utf8.decode(nonceBytes).trim();

      if (nonce.length != 32) {
        throw Exception("Falha ao obter desafio do dispositivo.");
      }

      // Prepara o ouvinte de status ANTES de enviar o comando
      final statusCompleter = Completer<String>();
      final statusSub = statusChar.onValueReceived.listen((bytes) {
        if (bytes.isNotEmpty && !statusCompleter.isCompleted) {
          final val = utf8.decode(bytes).trim();
          if (val != "IDLE" && val != "PENDING") {
            statusCompleter.complete(val);
          }
        }
      });

      await statusChar.setNotifyValue(true);

      // 2. Envia o payload assinado (abertura ou comando admin)
      final outboundPayload = buildPayload(nonce);
      await rxChar.write(
        utf8.encode(outboundPayload),
        withoutResponse: false,
      );

      // 3. Aguarda a resposta real empurrada pelo ESP32 via NOTIFY
      String resultCode;
      try {
        resultCode = await statusCompleter.future.timeout(
          const Duration(seconds: 2),
        );
      } catch (_) {
        final fallbackBytes = await statusChar.read();
        resultCode = utf8.decode(fallbackBytes).trim();
      } finally {
        await statusSub.cancel();
      }

      // 3. Lê o resultado processado pelo ESP32
      await Future.delayed(const Duration(milliseconds: 50));

      switch (resultCode) {
        case "UNLOCK_OK":
          _setStatus("Trava Aberta", Colors.greenAccent);
          break;
        case "ADD_OK":
          _setStatus("Usuário Cadastrado", Colors.greenAccent);
          _targetUserController.clear();
          _targetSecretController.clear();
          break;
        case "DEL_OK":
          _setStatus("Usuário Deletado", Colors.greenAccent);
          _targetUserController.clear();
          _targetSecretController.clear();
          break;
        case "ADD_ERR":
          _setStatus("Erro ao cadastrar usuário", Colors.redAccent);
          break;
        case "DEL_ERR":
          _setStatus("Usuário não encontrado", Colors.orangeAccent);
          break;
        case "UNAUTHORIZED":
        default:
          _setStatus("Usuário não autorizado", Colors.redAccent);
          break;
      }
    } on TimeoutException catch (e) {
      _setStatus(e.message ?? "Tempo esgotado.", Colors.orangeAccent);
    } catch (e) {
      _setStatus(
        e.toString().replaceFirst('Exception: ', ''),
        Colors.redAccent,
      );
    } finally {
      await FlutterBluePlus.stopScan();
      await scanSub?.cancel();
      if (targetDevice != null) {
        await Future.delayed(const Duration(milliseconds: 250));
        await targetDevice.disconnect();
      }
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _unlockDoor() {
    final userId = _userIdController.text.trim();
    final secret = _secretController.text.trim();

    // Limpa os campos imediatamente ao clicar em ABRIR TRAVA
    _userIdController.clear();
    _secretController.clear();
    FocusScope.of(context).unfocus();

    _executeBleTransaction(
      userId: userId,
      secret: secret,
      buildPayload: (nonce) {
        final hmac = _computeHmac(secret, "$userId:$nonce");
        return "$userId:$hmac";
      },
    );
  }

  void _addOrUpdateUser() {
    final adminId = _userIdController.text.trim();
    final adminSecret = _secretController.text.trim();
    final targetId = _targetUserController.text.trim();
    final targetKey = _targetSecretController.text.trim();

    if (targetId.isEmpty || targetId.length > 15 || targetId.contains(':')) {
      _setStatus("ID inválido (1-15 chars, sem ':').", Colors.orangeAccent);
      return;
    }
    if (targetKey.length < 8 || targetKey.contains(':')) {
      _setStatus("Chave inválida (mín. 8 chars, sem ':').", Colors.orangeAccent);
      return;
    }

    _userIdController.clear();
    _secretController.clear();
    _targetUserController.clear();
    _targetSecretController.clear();
    FocusScope.of(context).unfocus();

    _executeBleTransaction(
      userId: adminId,
      secret: adminSecret,
      buildPayload: (nonce) {
        final hmac =
            _computeHmac(adminSecret, "$adminId:ADD:$targetId:$targetKey:$nonce");
        return "$adminId:ADD:$targetId:$targetKey:$hmac";
      },
    );
  }

  void _removeUser() {
    final adminId = _userIdController.text.trim();
    final adminSecret = _secretController.text.trim();
    final targetId = _targetUserController.text.trim();

    if (targetId.isEmpty || targetId == "admin_01") {
      _setStatus("Informe um usuário válido para deletar.", Colors.orangeAccent);
      return;
    }

    _userIdController.clear();
    _secretController.clear();
    _targetUserController.clear();
    _targetSecretController.clear();
    FocusScope.of(context).unfocus();

    _executeBleTransaction(
      userId: adminId,
      secret: adminSecret,
      buildPayload: (nonce) {
        final hmac = _computeHmac(adminSecret, "$adminId:DEL:$targetId:$nonce");
        return "$adminId:DEL:$targetId:$hmac";
      },
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
            const SizedBox(height: 32),
            GestureDetector(
              onTap: _isBusy ? null : _unlockDoor,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 170,
                height: 170,
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
                      size: 52,
                      color: _isBusy ? Colors.blueAccent : Colors.tealAccent,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isBusy ? "AGUARDE" : "ABRIR TRAVA",
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
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _statusColor,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            if (_isAdmin) ...[
              const SizedBox(height: 28),
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
                        obscureText: _obscureTargetSecret,
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
          ],
        ),
      ),
    );
  }
}