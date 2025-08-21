import 'package:flutter/material.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'enhanced_editor_screen.dart';
import 'project_model.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(ProjectModelAdapter());
  }
  await Hive.openBox<ProjectModel>('projects');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final Box<ProjectModel> _box;

  List<ProjectModel> get recentProjects =>
      _box.values.toList().reversed.toList();

  @override
  void initState() {
    super.initState();
    _box = Hive.box<ProjectModel>('projects');
  }

  Future<File> _savePlatformFileToTemp(PlatformFile pf) async {
    final dir = await getTemporaryDirectory();
    final ext = (pf.extension != null && pf.extension!.isNotEmpty)
        ? '.${pf.extension}'
        : '';
    final path =
        '${dir.path}/pick_${DateTime.now().millisecondsSinceEpoch}$ext';
    if (pf.path != null) {
      return File(pf.path!);
    }
    throw Exception('No data available for picked file');
  }

  Future<void> _startCreateProject() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;

      final files = <File>[];
      for (final pf in result.files) {
        try {
          files.add(await _savePlatformFileToTemp(pf));
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(duration: const Duration(milliseconds: 500), content: Text('Failed to load file ${pf.name}: $e')),
            );
          }
          return;
        }
      }

      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(duration: Duration(milliseconds: 500), content: Text('No valid video files selected')),
          );
        }
        return;
      }

      final defaultName = "Project ${recentProjects.length + 1}";
      final nameController = TextEditingController(text: defaultName);
      final descController = TextEditingController();

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Create Project',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Project Name',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white30)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.blue)),
                ),
              ),
              SizedBox(height: 12),
              TextField(
                controller: descController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white30)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.blue)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      try {
        final first = files.first;
        final project = ProjectModel(
          name: nameController.text.trim().isEmpty
              ? defaultName
              : nameController.text.trim(),
          file: first,
          description: descController.text.trim().isEmpty
              ? null
              : descController.text.trim(),
          clipPaths: files.map((f) => f.path).toList(),
        );
        await _box.add(project);

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => EnhancedEditorScreen(
              file: first,
              clips: files,
              projectName: project.name,
              projectDescription: project.description,
            ),
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(duration: const Duration(milliseconds: 500), content: Text('Failed to create project: $e')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 500), content: Text('Failed to start project creation: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Studio V",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: 'Create Project',
            onPressed: _startCreateProject,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
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
        child: Padding(
          padding: EdgeInsets.all(size.width * 0.04),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: Colors.black.withOpacity(0.2),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text("Create",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _startCreateProject,
                        icon: const Icon(Icons.workspace_premium),
                        label: const Text("Create Project (Pick Videos)"),
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "Recent Projects",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: recentProjects.isEmpty
                    ? const Center(
                        child: Text("No recent projects",
                            style: TextStyle(color: Colors.white70)))
                    : ListView.builder(
                        itemCount: recentProjects.length,
                        itemBuilder: (context, index) {
                          final project = recentProjects[index];
                          return Card(
                            color: Colors.black.withOpacity(0.25),
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: ListTile(
                              leading: const Icon(Icons.movie,
                                  color: Colors.white70),
                              title: Text(project.name,
                                  style: const TextStyle(color: Colors.white)),
                              subtitle: Text(
                                project.description?.isNotEmpty == true
                                    ? project.description!
                                    : project.file.path,
                                style: const TextStyle(color: Colors.white54),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.open_in_new,
                                    color: Colors.white70),
                                onPressed: () {
                                  try {
                                    final clips = <File>[];

                                    // Check if main file exists
                                    if (!project.file.existsSync()) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(duration: const Duration(milliseconds: 500),
                                            content: Text(
                                                'Project file not found: ${project.file.path}')),
                                      );
                                      return;
                                    }

                                    clips.add(project.file);

                                    // Add additional clips if they exist
                                    if (project.clipPaths.isNotEmpty) {
                                      for (final path in project.clipPaths) {
                                        final file = File(path);
                                        if (file.existsSync()) {
                                          clips.add(file);
                                        }
                                      }
                                    }

                                    if (clips.isEmpty) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(duration: Duration(milliseconds: 500),
                                            content: Text(
                                                'No valid project files found')),
                                      );
                                      return;
                                    }

                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => EnhancedEditorScreen(
                                          file: clips.first,
                                          clips: clips,
                                          projectName: project.name,
                                          projectDescription:
                                              project.description,
                                        ),
                                      ),
                                    );
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(duration: const Duration(milliseconds: 500),
                                          content: Text(
                                              'Failed to open project: $e')),
                                    );
                                  }
                                },
                              ),
                              onTap: () {
                                try {
                                  final clips = <File>[];

                                  // Check if main file exists
                                  if (!project.file.existsSync()) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(duration: const Duration(milliseconds: 500),
                                          content: Text(
                                              'Project file not found: ${project.file.path}')),
                                    );
                                    return;
                                  }

                                  clips.add(project.file);

                                  // Add additional clips if they exist
                                  if (project.clipPaths.isNotEmpty) {
                                    for (final path in project.clipPaths) {
                                      final file = File(path);
                                      if (file.existsSync()) {
                                        clips.add(file);
                                      }
                                    }
                                  }

                                  if (clips.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(duration: Duration(milliseconds: 500),
                                          content: Text(
                                              'No valid project files found')),
                                    );
                                    return;
                                  }

                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => EnhancedEditorScreen(
                                        file: clips.first,
                                        clips: clips,
                                        projectName: project.name,
                                        projectDescription: project.description,
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(duration: const Duration(milliseconds: 500),
                                        content:
                                            Text('Failed to open project: $e')),
                                  );
                                }
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
