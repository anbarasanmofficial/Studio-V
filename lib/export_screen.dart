import 'package:flutter/material.dart';
import 'package:video_editor/video_editor.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'video_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class ExportScreen extends StatefulWidget {
  final VideoEditorController controller;
  final List<File>? clips;
  const ExportScreen({super.key, required this.controller, this.clips});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  String selectedQuality = "720p";
  double progress = 0.0;
  bool isExporting = false;
  String? lastMessage;
  bool mergeAllClips = true;
  String? outputDir;
  late final TextEditingController nameController;
  bool useSystemSaveAs = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: "export_${DateTime.now().millisecondsSinceEpoch}");
    mergeAllClips = (widget.clips?.length ?? 1) > 1;
    _initOutputDir();
  }

  Future<void> _initOutputDir() async {
    final dir = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    setState(() => outputDir = dir.path);
  }

  Future<bool> _hasStoragePermission() async {
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    final manage = await Permission.manageExternalStorage.request();
    return manage.isGranted;
  }

  Future<bool> _isDirWritable(String dirPath) async {
    try {
      final d = Directory(dirPath);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      final test = File('${d.path}/.wtest_${DateTime.now().millisecondsSinceEpoch}');
      await test.writeAsString('ok');
      await test.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _finalOutputPathStrict() async {
    if (outputDir == null) {
      await _pickOutputDir();
      if (outputDir == null) return null;
    }
    await _hasStoragePermission();
    final ok = await _isDirWritable(outputDir!);
    if (!ok) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(duration: Duration(milliseconds: 500), content: Text('Selected folder is not writable. Please choose another.')));
      await _pickOutputDir();
      if (outputDir == null) return null;
      final retryOk = await _isDirWritable(outputDir!);
      if (!retryOk) return null;
    }
    final rawName = nameController.text.trim().isEmpty ? "export_${DateTime.now().millisecondsSinceEpoch}" : nameController.text.trim();
    final sanitized = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return "${outputDir!}/$sanitized.mp4";
  }

  List<int> _sizeForQuality(String q) {
    if (q == '480p') return [854, 480];
    if (q == '1080p') return [1920, 1080];
    return [1280, 720];
  }

  int _targetBitrateKbps(String q) {
    switch (q) {
      case '480p':
        return 2500;
      case '1080p':
        return 8000;
      case '720p':
      default:
        return 5000;
    }
  }

  String _estimateSize() {
    final duration = widget.controller.videoDuration.inSeconds;
    if (duration <= 0) return '—';
    final kbps = _targetBitrateKbps(selectedQuality);
    final totalKB = duration * kbps / 8; // kbps -> kBps
    final totalMB = totalKB / 1024;
    if (totalMB >= 1024) return "~${(totalMB / 1024).toStringAsFixed(1)} GB";
    return "~${totalMB.toStringAsFixed(1)} MB";
  }

  Future<void> _pickOutputDir() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    setState(() => outputDir = path);
  }

  Future<void> _export() async {
    if (isExporting) return;
    setState(() {
      isExporting = true;
      progress = 0.0;
      lastMessage = null;
    });

    try {
      String inputPath = widget.controller.file.path;
      if (mergeAllClips && widget.clips != null && widget.clips!.length > 1) {
        final tmpBase = await getApplicationDocumentsDirectory();
        final tmpMerge = "${tmpBase.path}/to_export_merge_${DateTime.now().millisecondsSinceEpoch}.mp4";
        await VideoUtils.mergeVideos(widget.clips!, tmpMerge);
        inputPath = tmpMerge;
      }

      // Always export to a temp file first
      final tmp = await getTemporaryDirectory();
      final rawName = nameController.text.trim().isEmpty ? "export_${DateTime.now().millisecondsSinceEpoch}" : nameController.text.trim();
      final sanitized = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final tempOut = "${tmp.path}/$sanitized.mp4";

      final config = await VideoFFmpegVideoEditorConfig(widget.controller).getExecuteConfig();
      final size = _sizeForQuality(selectedQuality);

      // Avoid splitting config.command; use -s to set size to avoid -vf conflicts
      final cmd = '-y -i "$inputPath" ${config.command} -s ${size[0]}x${size[1]} "$tempOut"';

      await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          if (ReturnCode.isSuccess(rc)) {
            if (!mounted) return;
            setState(() {
              progress = 1.0;
              isExporting = false;
            });
            if (!mounted) return;
            await _postExportDelivery(tempOut);
          } else {
            if (!mounted) return;
            setState(() {
              isExporting = false;
            });
            final logs = await session.getAllLogsAsString();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(duration: Duration(milliseconds: 500), content: Text("Export failed. See logs for details.")),
            );
            if (mounted) setState(() => lastMessage = logs);
          }
        },
        (log) {
          if (!mounted) return;
          setState(() => lastMessage = log.getMessage());
        },
        (statistics) {
          if (!mounted) return;
          final time = statistics.getTime();
          final totalMs = widget.controller.videoDuration.inMilliseconds;
          if (totalMs > 0) {
            final p = (time / totalMs).clamp(0.0, 1.0);
            setState(() => progress = p);
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isExporting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(milliseconds: 500), content: Text("Export error: $e")),
      );
    }
  }

  Future<void> _saveAsMove(String sourcePath) async {
    try {
      final suggestedName = nameController.text.trim().isEmpty ? "export_${DateTime.now().millisecondsSinceEpoch}.mp4" : '${nameController.text.trim()}.mp4';
      final dest = await FilePicker.platform.saveFile(dialogTitle: 'Save Video As', fileName: suggestedName, type: FileType.custom, allowedExtensions: ['mp4']);
      if (dest == null) return; // user canceled
      await _copyFileChunked(File(sourcePath), File(dest));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(milliseconds: 500), content: Text('Saved to: $dest')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(milliseconds: 500), content: Text('Save As failed: $e')));
    } finally {
      useSystemSaveAs = false;
    }
  }

  Future<void> _copyFileChunked(File src, File dst) async {
    final inStream = src.openRead();
    final outStream = await dst.openWrite();
    await inStream.pipe(outStream);
    await outStream.close();
  }

  Future<void> _postExportDelivery(String sourcePath) async {
    // 1) Try copying to chosen folder
    if (outputDir != null) {
      final ok = await _isDirWritable(outputDir!);
      if (ok) {
        try {
          final dest = File('${outputDir!}/${nameController.text.trim().isEmpty ? 'export' : nameController.text.trim()}.mp4');
          await _copyFileChunked(File(sourcePath), dest);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(milliseconds: 500), content: Text('Saved to: ${dest.path}')));
          return;
        } catch (_) {
          // fall through
        }
      }
    }
    // 2) System Save As dialog
    final saved = await _saveAsDialog(sourcePath);
    if (saved) return;
    // 3) If everything fails
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(duration: Duration(milliseconds: 500), content: Text('Unable to save. Please try a different folder.')));
  }

  Future<bool> _saveAsDialog(String sourcePath) async {
    try {
      final suggestedName = nameController.text.trim().isEmpty ? "export_${DateTime.now().millisecondsSinceEpoch}.mp4" : '${nameController.text.trim()}.mp4';
      final dest = await FilePicker.platform.saveFile(dialogTitle: 'Save Video As', fileName: suggestedName, type: FileType.custom, allowedExtensions: ['mp4']);
      if (dest == null) return false;
      await _copyFileChunked(File(sourcePath), File(dest));
      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(milliseconds: 500), content: Text('Saved to: $dest')));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final chips = ['480p', '720p', '1080p'];

    return Scaffold(
      appBar: AppBar(title: const Text("Export",style: TextStyle(color: Colors.white),),backgroundColor: Colors.black,),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: Colors.black.withOpacity(0.25),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Quality", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: chips.map((q) {
                          final selected = q == selectedQuality;
                          return ChoiceChip(
                            label: Text(q),
                            selected: selected,
                            onSelected: isExporting ? null : (_) => setState(() => selectedQuality = q),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Estimated size:', style: TextStyle(color: Colors.white70)),
                          const SizedBox(width: 8),
                          Text(_estimateSize(), style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Switch(
                            value: mergeAllClips,
                            onChanged: isExporting || (widget.clips == null || widget.clips!.length <= 1)
                                ? null
                                : (v) => setState(() => mergeAllClips = v),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Merge ${widget.clips?.length ?? 1} clips before export',
                              style: const TextStyle(color: Colors.white70),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                color: Colors.black.withOpacity(0.25),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Output", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: nameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'File name',
                          labelStyle: TextStyle(color: Colors.white70),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white30)),
                          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.blue)),
                        ),
                        enabled: !isExporting,
                      ),
                      const SizedBox(height: 12),
                      Row(
          children: [
                          Expanded(
                            child: Text(
                              outputDir ?? 'Picking default app directory...',
                              style: const TextStyle(color: Colors.white70),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: isExporting ? null : _pickOutputDir,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Change'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (isExporting)
                Card(
                  color: Colors.black.withOpacity(0.25),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 8),
                        Text(
                          'Exporting... ${(progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (lastMessage != null)
                          Text(
                            lastMessage!,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () {
                              FFmpegKit.cancel();
                            },
                            icon: const Icon(Icons.close),
                            label: const Text('Cancel'),
                          ),
                        )
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: isExporting ? null : _export,
              icon: const Icon(Icons.download),
              label: const Text("Export"),
                ),
              ),
              if (!isExporting)
                TextButton.icon(
                  onPressed: () => setState(() => useSystemSaveAs = true),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Use system Save As on export'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
