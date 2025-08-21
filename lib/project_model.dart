import 'dart:io';
import 'package:hive/hive.dart';

part 'project_model.g.dart';

@HiveType(typeId: 1)
class ProjectModel extends HiveObject {
  @HiveField(0)
  String name;

  // We store only the file path for persistence
  @HiveField(1)
  String filePath;

  // Optional user-provided description of the project
  @HiveField(2)
  String? description;

  // Ordered list of clip paths that make up the timeline for this project
  @HiveField(3)
  List<String> clipPaths;

  ProjectModel({required this.name, required File file, this.description, List<String>? clipPaths})
      : filePath = file.path,
        clipPaths = clipPaths ?? <String>[];

  File get file => File(filePath);
}
