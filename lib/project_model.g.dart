// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'project_model.dart';

class ProjectModelAdapter extends TypeAdapter<ProjectModel> {
  @override
  final int typeId = 1;

  @override
  ProjectModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ProjectModel(
      name: fields[0] as String,
      file: File(fields[1] as String),
      description: fields[2] as String?,
      clipPaths: (fields[3] as List?)?.map((e) => e as String).toList(),
    );
  }

  @override
  void write(BinaryWriter writer, ProjectModel obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.filePath)
      ..writeByte(2)
      ..write(obj.description)
      ..writeByte(3)
      ..write(obj.clipPaths);
  }
}



