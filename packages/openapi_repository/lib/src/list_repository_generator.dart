// ignore_for_file: depend_on_referenced_packages

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:build/build.dart';
import 'package:built_collection/built_collection.dart';
import 'package:mustache_template/mustache.dart';
import 'package:openapi_repository/src/templates/models.dart';
import 'package:openapi_repository/src/templates/templates.dart';
import 'package:recase/recase.dart';

import 'package:openapi_repository_annotations/openapi_repository_annotations.dart';
import 'package:source_gen/source_gen.dart';

import 'model_visitor.dart';

class OpenapiRepositoryGenerator
    extends GeneratorForAnnotation<OpenapiRepository> {
  int _defaultPageSize = 100;
  int _defaultOffset = 0;

  static const listChecker = TypeChecker.any([
    TypeChecker.fromRuntime(List),
    TypeChecker.fromRuntime(BuiltList),
  ]);

  @override
  generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element.name == null) return '';

    final parsedAnnotation = _ReaderTypes.fromReader(annotation);

    _defaultOffset = parsedAnnotation.defaultOffset;
    _defaultPageSize = parsedAnnotation.defaultPageSize;

    final baseUrl = parsedAnnotation.baseUrl;
    final liveBasePath = parsedAnnotation.liveBasePath;
    final connectTimeout = parsedAnnotation.connectTimeout;
    final receiveTimeout = parsedAnnotation.receiveTimeout;
    final sendTimeout = parsedAnnotation.sendTimeout;
    final dioInterceptor = parsedAnnotation.dioInterceptor;

    final methods = parsedAnnotation.buildForElement.methods.where((element) {
      if (element.returnType.isVoid) return false;
      if (element.returnType.isDynamic) return false;
      if (element.isStatic) return false;
      return true;
    }).toList();

    final builderData = _getBuilderString(parsedAnnotation.builderList);

    final repositoryModel = RepositoryTemplateModel(
      repositoryName: element.name!.replaceFirst(r'$', ''),
      baseUrl: baseUrl != null ? "'$baseUrl'" : "'' // TODO: Add base url",
      liveBasePath: liveBasePath != null
          ? "'$liveBasePath'"
          : "''; // TODO: Add live base path",
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      dioInterceptor: dioInterceptor?.getDisplayString(
        withNullability: false,
      ),
      accessors: methods.map((e) {
        final type = e.returnType.getDisplayString(withNullability: false);
        final methodName = e.name;
        final name = e.returnType
            .getDisplayString(withNullability: false)
            .sentenceCase
            .split(' ')
            .first
            .camelCase;
        return AccessorModel(type: type, name: name, methodName: methodName);
      }).toList(),
    );

    final template = Template(apiRepositoryTemplate);
    final buffer = StringBuffer();

    buffer.writeln(template.renderString(repositoryModel.toJson()));
    buffer.writeln(builderData);

    return buffer.toString();
  }

  String _getBuilderString(Iterable<_ListRepositoryBuilder> data) {
    final buffer = StringBuffer();
    for (final builder in data) {
      final output = _getListRepositoryFromBuilder(builder);
      if (output.isEmpty) continue;

      buffer.writeln(output);
    }
    return buffer.toString();
  }

  String _getListRepositoryFromBuilder(_ListRepositoryBuilder builder) {
    final buffer = StringBuffer();
    final classElement = builder.apiClass;

    for (final methodElement in classElement.methods) {
      final returnType = methodElement.returnType;

      if (!returnType.isDartAsyncFuture) continue;

      final methodName = methodElement.displayName;
      if (builder.ignoreEndpoints.contains('*')) {
        continue;
      } else if (builder.ignoreEndpoints.contains(methodName)) {
        continue;
      }

      if (!builder.listEndpoints.contains('*')) {
        if (!builder.listEndpoints.contains(methodName)) continue;
      }

      final apiClass =
          classElement.displayName.titleCase.split(' ').first.camelCase;

      final returnModel = _getInnerListReturnType(returnType, false);
      if (returnModel == null) continue;
      final type = returnModel.type.getDisplayString(withNullability: false);
      final methodParameters = methodElement.parameters
          .where((parameter) => ![
                'cancelToken',
                'headers',
                'extra',
                'validateStatus',
                'onSendProgress',
                'onReceiveProgress',
              ].contains(parameter.name))
          .toList();

      final optionalParams = methodParameters.where((element) {
        return element.isOptional;
      }).toList();

      buffer
        ..writeln()
        ..writeln(_buildTypeDefs(
          type: type,
          name: methodName.pascalCase,
          hasFilter: methodParameters.isNotEmpty,
        ))
        ..writeln();
      if (optionalParams.isNotEmpty) {
        buffer
          ..writeln(_buildFilterClass(
            name: methodName.pascalCase,
            parameters: methodParameters,
            defaultOffset: _defaultOffset,
            defaultPageSize: _defaultPageSize,
          ))
          ..writeln();
      }
      buffer.writeln(_buildListLoader(
        type: type,
        filterParameters: methodParameters,
        hasFilter: methodParameters.isNotEmpty,
        api: apiClass,
        methodName: methodName,
        isInline: returnModel.isInline,
      ));
    }

    return buffer.toString();
  }

  _ReturnModel? _getInnerListReturnType(DartType type, bool isInline) {
    final innerMostType = _getInnerMostType(type);
    if (listChecker.isExactlyType(type) && innerMostType != null) {
      return _ReturnModel(innerMostType, isInline);
    }

    if (type is! ParameterizedType) return null;

    List<DartType> args = type.typeArguments;
    if (args.isEmpty) {
      final innerElement = innerMostType?.element;
      if (innerMostType == null || innerElement == null) return null;

      final inlineVisitor = InlineClassVisitor();
      innerElement.visitChildren(inlineVisitor);
      if (inlineVisitor.fields.isEmpty) return null;
      final results = inlineVisitor.fields;
      return _getInnerListReturnType(results.first.type, true);
    }
    if (args.first.isVoid) return null;

    return _getInnerListReturnType(args.first, false);
  }

  DartType? _getInnerMostType(DartType type) {
    if (type is ParameterizedType && type.typeArguments.isNotEmpty) {
      final typeArgs = type.typeArguments;
      return typeArgs.first.isVoid ? null : _getInnerMostType(typeArgs.first);
    }

    return type;
  }

  String _buildListLoader({
    required String type,
    required String api,
    required String methodName,
    required bool hasFilter,
    required List<ParameterElement> filterParameters,
    bool isInline = false,
  }) {
    final listRepositoryModel = ListRepositoryTemplateModel(
      api: api,
      name: methodName.pascalCase,
      isInline: isInline,
      methodName: methodName,
      returnType: type,
      hasFilter: hasFilter,
      filterParams: hasFilter && filterParameters.isNotEmpty
          ? filterParameters.map((e) {
              return ParamModel('${e.name}: filter.${e.name}');
            }).toList()
          : [],
    );
    return Template(repositoryTemplate).renderString(
      listRepositoryModel.toJson(),
    );
  }

  String _buildTypeDefs({
    required String name,
    required String type,
    required bool hasFilter,
  }) {
    final typedefModel = TypedefTemplateModel(
      type: type,
      name: name,
      hasFilter: hasFilter,
    );
    return Template(typedefTemplate).renderString(typedefModel.toJson());
  }

  String _buildFilterClass({
    required String name,
    required List<ParameterElement> parameters,
    required int defaultOffset,
    required int defaultPageSize,
  }) {
    final filterTemplateModel = FreezedTemplateModel(
        name: name,
        isPaginated: parameters.any(
          (element) => ['offset', 'limit'].contains(element.name),
        ),
        types: parameters.map((parameter) {
          final isOffsetLimit = ['offset', 'limit'].contains(parameter.name);
          final defaultValue = isOffsetLimit && parameter.isOptional
              ? '@Default(${parameter.name == 'offset' ? defaultOffset : defaultPageSize}) '
              : '';

          final isRequired = defaultValue.isEmpty && !parameter.isOptional;
          final isNullable = defaultValue.isEmpty && parameter.isOptional;

          return TypeModel(
            isRequired: isRequired,
            isNullable: isNullable,
            defaultValue: defaultValue,
            name: parameter.name,
            type: parameter.type.getDisplayString(
              withNullability: false,
            ),
          );
        }).toList());

    return Template(freezedFilterTemplate).renderString(
      filterTemplateModel.toJson(),
    );
  }
}

class _ReturnModel {
  final DartType type;
  final bool isInline;

  const _ReturnModel(this.type, [this.isInline = false]);
}

class _ReaderTypes {
  final ClassElement buildForElement;
  final Iterable<_ListRepositoryBuilder> builderList;
  final int connectTimeout;
  final int receiveTimeout;
  final int sendTimeout;
  final int defaultOffset;
  final int defaultPageSize;
  final DartType? dioInterceptor;
  final String? liveBasePath;
  final String? baseUrl;

  const _ReaderTypes._({
    required this.buildForElement,
    this.builderList = const [],
    this.connectTimeout = 10000,
    this.receiveTimeout = 15000,
    this.sendTimeout = 15000,
    this.defaultOffset = 0,
    this.defaultPageSize = 100,
    this.dioInterceptor,
    this.liveBasePath,
    this.baseUrl,
  });

  factory _ReaderTypes.fromReader(ConstantReader reader) {
    final buildFor = reader.peek('buildFor')?.typeValue;
    final buildForElement = buildFor?.element;
    if (buildForElement == null || buildForElement is! ClassElement) {
      throw FormatException('Invalid parameter for BuildFor');
    }

    final baseUrl = reader.peek('baseUrl')?.stringValue;

    final liveBasePath = reader.peek('liveBasePath')?.stringValue;

    final defaultOffset = reader.peek('defaultOffset')?.intValue ?? 0;
    final defaultPageSize = reader.peek('defaultPageSize')?.intValue ?? 100;
    final connectTimeout = reader.peek('connectTimeout')?.intValue ?? 0;
    final receiveTimeout = reader.peek('receiveTimeout')?.intValue ?? 0;
    final sendTimeout = reader.peek('sendTimeout')?.intValue ?? 0;
    final dioInterceptor = reader.peek('dioInterceptor')?.typeValue;

    final builderList = reader.peek('builderList')?.listValue ?? [];
    final builderData = builderList.map(
      (e) => _ListRepositoryBuilder.fromDartObject(e),
    );

    return _ReaderTypes._(
      buildForElement: buildForElement,
      baseUrl: baseUrl,
      builderList: builderData,
      liveBasePath: liveBasePath,
      defaultOffset: defaultOffset,
      defaultPageSize: defaultPageSize,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      dioInterceptor: dioInterceptor,
    );
  }
}

class _ListRepositoryBuilder {
  final ClassElement apiClass;
  final List<String> listEndpoints;
  final List<String> ignoreEndpoints;

  const _ListRepositoryBuilder._(
    this.apiClass, {
    this.ignoreEndpoints = const [],
    this.listEndpoints = const [],
  });

  factory _ListRepositoryBuilder.fromDartObject(DartObject e) {
    final type = e.getField('apiClass')?.toTypeValue();
    if (type == null) {
      throw FormatException('ApiClass field must be a type');
    }

    final element = type.element;
    if (element is! ClassElement) {
      throw 'ApiClass field should be a Class Type';
    }

    final listEndpoints = e.getField('listEndpoints')?.toListValue();
    final ignoreEndpoints = e.getField('ignoreEndpoints')?.toListValue();

    final parsedEndpoints = <String>[];
    final parsedIgnoreEndpoints = <String>[];

    if (listEndpoints != null) {
      for (final endpoint in listEndpoints) {
        final value = endpoint.toStringValue();
        if (value == null) continue;
        parsedEndpoints.add(value);
      }
    }

    if (ignoreEndpoints != null) {
      for (final endpoint in ignoreEndpoints) {
        final value = endpoint.toStringValue();
        if (value == null) continue;
        parsedIgnoreEndpoints.add(value);
      }
    }

    return _ListRepositoryBuilder._(
      element,
      ignoreEndpoints: parsedIgnoreEndpoints,
      listEndpoints: parsedEndpoints,
    );
  }
}
