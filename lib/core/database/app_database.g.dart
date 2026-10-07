// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ConnectionProfilesTable extends ConnectionProfiles
    with TableInfo<$ConnectionProfilesTable, ConnectionProfile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConnectionProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverUrlMeta = const VerificationMeta(
    'serverUrl',
  );
  @override
  late final GeneratedColumn<String> serverUrl = GeneratedColumn<String>(
    'server_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _passwordMeta = const VerificationMeta(
    'password',
  );
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
    'password',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _keepScreenOnMeta = const VerificationMeta(
    'keepScreenOn',
  );
  @override
  late final GeneratedColumn<bool> keepScreenOn = GeneratedColumn<bool>(
    'keep_screen_on',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("keep_screen_on" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _lastUdidMeta = const VerificationMeta(
    'lastUdid',
  );
  @override
  late final GeneratedColumn<String> lastUdid = GeneratedColumn<String>(
    'last_udid',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    serverUrl,
    username,
    password,
    keepScreenOn,
    lastUdid,
    isActive,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'connection_profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConnectionProfile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('server_url')) {
      context.handle(
        _serverUrlMeta,
        serverUrl.isAcceptableOrUnknown(data['server_url']!, _serverUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_serverUrlMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    }
    if (data.containsKey('password')) {
      context.handle(
        _passwordMeta,
        password.isAcceptableOrUnknown(data['password']!, _passwordMeta),
      );
    }
    if (data.containsKey('keep_screen_on')) {
      context.handle(
        _keepScreenOnMeta,
        keepScreenOn.isAcceptableOrUnknown(
          data['keep_screen_on']!,
          _keepScreenOnMeta,
        ),
      );
    }
    if (data.containsKey('last_udid')) {
      context.handle(
        _lastUdidMeta,
        lastUdid.isAcceptableOrUnknown(data['last_udid']!, _lastUdidMeta),
      );
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConnectionProfile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConnectionProfile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      serverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_url'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      password: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password'],
      )!,
      keepScreenOn: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}keep_screen_on'],
      )!,
      lastUdid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_udid'],
      ),
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ConnectionProfilesTable createAlias(String alias) {
    return $ConnectionProfilesTable(attachedDatabase, alias);
  }
}

class ConnectionProfile extends DataClass
    implements Insertable<ConnectionProfile> {
  final int id;

  /// 展示名；为空时由 service 用服务地址的 host 兜底。
  final String name;

  /// 服务端入口（http/https）。
  final String serverUrl;

  /// Basic Auth 用户名；服务端未开鉴权时为空串。
  final String username;

  /// Basic Auth 密码（**明文**，见类文档）。
  final String password;

  /// 投流/操作期间是否保持屏幕常亮。
  final bool keepScreenOn;

  /// 该配置下上次使用的设备序列号。
  final String? lastUdid;

  /// 是否为当前生效配置；**全局最多一个为 true**，由 repository 用事务保证。
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.keepScreenOn,
    this.lastUdid,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['server_url'] = Variable<String>(serverUrl);
    map['username'] = Variable<String>(username);
    map['password'] = Variable<String>(password);
    map['keep_screen_on'] = Variable<bool>(keepScreenOn);
    if (!nullToAbsent || lastUdid != null) {
      map['last_udid'] = Variable<String>(lastUdid);
    }
    map['is_active'] = Variable<bool>(isActive);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ConnectionProfilesCompanion toCompanion(bool nullToAbsent) {
    return ConnectionProfilesCompanion(
      id: Value(id),
      name: Value(name),
      serverUrl: Value(serverUrl),
      username: Value(username),
      password: Value(password),
      keepScreenOn: Value(keepScreenOn),
      lastUdid: lastUdid == null && nullToAbsent
          ? const Value.absent()
          : Value(lastUdid),
      isActive: Value(isActive),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ConnectionProfile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConnectionProfile(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      serverUrl: serializer.fromJson<String>(json['serverUrl']),
      username: serializer.fromJson<String>(json['username']),
      password: serializer.fromJson<String>(json['password']),
      keepScreenOn: serializer.fromJson<bool>(json['keepScreenOn']),
      lastUdid: serializer.fromJson<String?>(json['lastUdid']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'serverUrl': serializer.toJson<String>(serverUrl),
      'username': serializer.toJson<String>(username),
      'password': serializer.toJson<String>(password),
      'keepScreenOn': serializer.toJson<bool>(keepScreenOn),
      'lastUdid': serializer.toJson<String?>(lastUdid),
      'isActive': serializer.toJson<bool>(isActive),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ConnectionProfile copyWith({
    int? id,
    String? name,
    String? serverUrl,
    String? username,
    String? password,
    bool? keepScreenOn,
    Value<String?> lastUdid = const Value.absent(),
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ConnectionProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    lastUdid: lastUdid.present ? lastUdid.value : this.lastUdid,
    isActive: isActive ?? this.isActive,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ConnectionProfile copyWithCompanion(ConnectionProfilesCompanion data) {
    return ConnectionProfile(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      serverUrl: data.serverUrl.present ? data.serverUrl.value : this.serverUrl,
      username: data.username.present ? data.username.value : this.username,
      password: data.password.present ? data.password.value : this.password,
      keepScreenOn: data.keepScreenOn.present
          ? data.keepScreenOn.value
          : this.keepScreenOn,
      lastUdid: data.lastUdid.present ? data.lastUdid.value : this.lastUdid,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionProfile(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('username: $username, ')
          ..write('password: $password, ')
          ..write('keepScreenOn: $keepScreenOn, ')
          ..write('lastUdid: $lastUdid, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    serverUrl,
    username,
    password,
    keepScreenOn,
    lastUdid,
    isActive,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnectionProfile &&
          other.id == this.id &&
          other.name == this.name &&
          other.serverUrl == this.serverUrl &&
          other.username == this.username &&
          other.password == this.password &&
          other.keepScreenOn == this.keepScreenOn &&
          other.lastUdid == this.lastUdid &&
          other.isActive == this.isActive &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConnectionProfilesCompanion extends UpdateCompanion<ConnectionProfile> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> serverUrl;
  final Value<String> username;
  final Value<String> password;
  final Value<bool> keepScreenOn;
  final Value<String?> lastUdid;
  final Value<bool> isActive;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const ConnectionProfilesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.serverUrl = const Value.absent(),
    this.username = const Value.absent(),
    this.password = const Value.absent(),
    this.keepScreenOn = const Value.absent(),
    this.lastUdid = const Value.absent(),
    this.isActive = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ConnectionProfilesCompanion.insert({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    required String serverUrl,
    this.username = const Value.absent(),
    this.password = const Value.absent(),
    this.keepScreenOn = const Value.absent(),
    this.lastUdid = const Value.absent(),
    this.isActive = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : serverUrl = Value(serverUrl),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ConnectionProfile> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? serverUrl,
    Expression<String>? username,
    Expression<String>? password,
    Expression<bool>? keepScreenOn,
    Expression<String>? lastUdid,
    Expression<bool>? isActive,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (serverUrl != null) 'server_url': serverUrl,
      if (username != null) 'username': username,
      if (password != null) 'password': password,
      if (keepScreenOn != null) 'keep_screen_on': keepScreenOn,
      if (lastUdid != null) 'last_udid': lastUdid,
      if (isActive != null) 'is_active': isActive,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ConnectionProfilesCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? serverUrl,
    Value<String>? username,
    Value<String>? password,
    Value<bool>? keepScreenOn,
    Value<String?>? lastUdid,
    Value<bool>? isActive,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
  }) {
    return ConnectionProfilesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      lastUdid: lastUdid ?? this.lastUdid,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (serverUrl.present) {
      map['server_url'] = Variable<String>(serverUrl.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (password.present) {
      map['password'] = Variable<String>(password.value);
    }
    if (keepScreenOn.present) {
      map['keep_screen_on'] = Variable<bool>(keepScreenOn.value);
    }
    if (lastUdid.present) {
      map['last_udid'] = Variable<String>(lastUdid.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionProfilesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('username: $username, ')
          ..write('password: $password, ')
          ..write('keepScreenOn: $keepScreenOn, ')
          ..write('lastUdid: $lastUdid, ')
          ..write('isActive: $isActive, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $RecentDevicesTable extends RecentDevices
    with TableInfo<$RecentDevicesTable, RecentDevice> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecentDevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _udidMeta = const VerificationMeta('udid');
  @override
  late final GeneratedColumn<String> udid = GeneratedColumn<String>(
    'udid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lastConnectedAtMeta = const VerificationMeta(
    'lastConnectedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastConnectedAt =
      GeneratedColumn<DateTime>(
        'last_connected_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    udid,
    displayName,
    lastConnectedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recent_devices';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecentDevice> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('udid')) {
      context.handle(
        _udidMeta,
        udid.isAcceptableOrUnknown(data['udid']!, _udidMeta),
      );
    } else if (isInserting) {
      context.missing(_udidMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('last_connected_at')) {
      context.handle(
        _lastConnectedAtMeta,
        lastConnectedAt.isAcceptableOrUnknown(
          data['last_connected_at']!,
          _lastConnectedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastConnectedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecentDevice map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecentDevice(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      udid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}udid'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      lastConnectedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_connected_at'],
      )!,
    );
  }

  @override
  $RecentDevicesTable createAlias(String alias) {
    return $RecentDevicesTable(attachedDatabase, alias);
  }
}

class RecentDevice extends DataClass implements Insertable<RecentDevice> {
  final int id;

  /// 设备序列号，唯一：同一台设备只保留一条记录（重连时更新时间）。
  final String udid;
  final String displayName;
  final DateTime lastConnectedAt;
  const RecentDevice({
    required this.id,
    required this.udid,
    required this.displayName,
    required this.lastConnectedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['udid'] = Variable<String>(udid);
    map['display_name'] = Variable<String>(displayName);
    map['last_connected_at'] = Variable<DateTime>(lastConnectedAt);
    return map;
  }

  RecentDevicesCompanion toCompanion(bool nullToAbsent) {
    return RecentDevicesCompanion(
      id: Value(id),
      udid: Value(udid),
      displayName: Value(displayName),
      lastConnectedAt: Value(lastConnectedAt),
    );
  }

  factory RecentDevice.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecentDevice(
      id: serializer.fromJson<int>(json['id']),
      udid: serializer.fromJson<String>(json['udid']),
      displayName: serializer.fromJson<String>(json['displayName']),
      lastConnectedAt: serializer.fromJson<DateTime>(json['lastConnectedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'udid': serializer.toJson<String>(udid),
      'displayName': serializer.toJson<String>(displayName),
      'lastConnectedAt': serializer.toJson<DateTime>(lastConnectedAt),
    };
  }

  RecentDevice copyWith({
    int? id,
    String? udid,
    String? displayName,
    DateTime? lastConnectedAt,
  }) => RecentDevice(
    id: id ?? this.id,
    udid: udid ?? this.udid,
    displayName: displayName ?? this.displayName,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );
  RecentDevice copyWithCompanion(RecentDevicesCompanion data) {
    return RecentDevice(
      id: data.id.present ? data.id.value : this.id,
      udid: data.udid.present ? data.udid.value : this.udid,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      lastConnectedAt: data.lastConnectedAt.present
          ? data.lastConnectedAt.value
          : this.lastConnectedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecentDevice(')
          ..write('id: $id, ')
          ..write('udid: $udid, ')
          ..write('displayName: $displayName, ')
          ..write('lastConnectedAt: $lastConnectedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, udid, displayName, lastConnectedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecentDevice &&
          other.id == this.id &&
          other.udid == this.udid &&
          other.displayName == this.displayName &&
          other.lastConnectedAt == this.lastConnectedAt);
}

class RecentDevicesCompanion extends UpdateCompanion<RecentDevice> {
  final Value<int> id;
  final Value<String> udid;
  final Value<String> displayName;
  final Value<DateTime> lastConnectedAt;
  const RecentDevicesCompanion({
    this.id = const Value.absent(),
    this.udid = const Value.absent(),
    this.displayName = const Value.absent(),
    this.lastConnectedAt = const Value.absent(),
  });
  RecentDevicesCompanion.insert({
    this.id = const Value.absent(),
    required String udid,
    this.displayName = const Value.absent(),
    required DateTime lastConnectedAt,
  }) : udid = Value(udid),
       lastConnectedAt = Value(lastConnectedAt);
  static Insertable<RecentDevice> custom({
    Expression<int>? id,
    Expression<String>? udid,
    Expression<String>? displayName,
    Expression<DateTime>? lastConnectedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (udid != null) 'udid': udid,
      if (displayName != null) 'display_name': displayName,
      if (lastConnectedAt != null) 'last_connected_at': lastConnectedAt,
    });
  }

  RecentDevicesCompanion copyWith({
    Value<int>? id,
    Value<String>? udid,
    Value<String>? displayName,
    Value<DateTime>? lastConnectedAt,
  }) {
    return RecentDevicesCompanion(
      id: id ?? this.id,
      udid: udid ?? this.udid,
      displayName: displayName ?? this.displayName,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (udid.present) {
      map['udid'] = Variable<String>(udid.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (lastConnectedAt.present) {
      map['last_connected_at'] = Variable<DateTime>(lastConnectedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecentDevicesCompanion(')
          ..write('id: $id, ')
          ..write('udid: $udid, ')
          ..write('displayName: $displayName, ')
          ..write('lastConnectedAt: $lastConnectedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConnectionProfilesTable connectionProfiles =
      $ConnectionProfilesTable(this);
  late final $RecentDevicesTable recentDevices = $RecentDevicesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    connectionProfiles,
    recentDevices,
  ];
}

typedef $$ConnectionProfilesTableCreateCompanionBuilder =
    ConnectionProfilesCompanion Function({
      Value<int> id,
      Value<String> name,
      required String serverUrl,
      Value<String> username,
      Value<String> password,
      Value<bool> keepScreenOn,
      Value<String?> lastUdid,
      Value<bool> isActive,
      required DateTime createdAt,
      required DateTime updatedAt,
    });
typedef $$ConnectionProfilesTableUpdateCompanionBuilder =
    ConnectionProfilesCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> serverUrl,
      Value<String> username,
      Value<String> password,
      Value<bool> keepScreenOn,
      Value<String?> lastUdid,
      Value<bool> isActive,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
    });

class $$ConnectionProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ConnectionProfilesTable> {
  $$ConnectionProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get keepScreenOn => $composableBuilder(
    column: $table.keepScreenOn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastUdid => $composableBuilder(
    column: $table.lastUdid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConnectionProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ConnectionProfilesTable> {
  $$ConnectionProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get keepScreenOn => $composableBuilder(
    column: $table.keepScreenOn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastUdid => $composableBuilder(
    column: $table.lastUdid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConnectionProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConnectionProfilesTable> {
  $$ConnectionProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get serverUrl =>
      $composableBuilder(column: $table.serverUrl, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get password =>
      $composableBuilder(column: $table.password, builder: (column) => column);

  GeneratedColumn<bool> get keepScreenOn => $composableBuilder(
    column: $table.keepScreenOn,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastUdid =>
      $composableBuilder(column: $table.lastUdid, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ConnectionProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConnectionProfilesTable,
          ConnectionProfile,
          $$ConnectionProfilesTableFilterComposer,
          $$ConnectionProfilesTableOrderingComposer,
          $$ConnectionProfilesTableAnnotationComposer,
          $$ConnectionProfilesTableCreateCompanionBuilder,
          $$ConnectionProfilesTableUpdateCompanionBuilder,
          (
            ConnectionProfile,
            BaseReferences<
              _$AppDatabase,
              $ConnectionProfilesTable,
              ConnectionProfile
            >,
          ),
          ConnectionProfile,
          PrefetchHooks Function()
        > {
  $$ConnectionProfilesTableTableManager(
    _$AppDatabase db,
    $ConnectionProfilesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConnectionProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConnectionProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConnectionProfilesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> serverUrl = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> password = const Value.absent(),
                Value<bool> keepScreenOn = const Value.absent(),
                Value<String?> lastUdid = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => ConnectionProfilesCompanion(
                id: id,
                name: name,
                serverUrl: serverUrl,
                username: username,
                password: password,
                keepScreenOn: keepScreenOn,
                lastUdid: lastUdid,
                isActive: isActive,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                required String serverUrl,
                Value<String> username = const Value.absent(),
                Value<String> password = const Value.absent(),
                Value<bool> keepScreenOn = const Value.absent(),
                Value<String?> lastUdid = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
              }) => ConnectionProfilesCompanion.insert(
                id: id,
                name: name,
                serverUrl: serverUrl,
                username: username,
                password: password,
                keepScreenOn: keepScreenOn,
                lastUdid: lastUdid,
                isActive: isActive,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConnectionProfilesTable, ConnectionProfile>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $ConnectionProfilesTable,
                    ConnectionProfile
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConnectionProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConnectionProfilesTable,
      ConnectionProfile,
      $$ConnectionProfilesTableFilterComposer,
      $$ConnectionProfilesTableOrderingComposer,
      $$ConnectionProfilesTableAnnotationComposer,
      $$ConnectionProfilesTableCreateCompanionBuilder,
      $$ConnectionProfilesTableUpdateCompanionBuilder,
      (
        ConnectionProfile,
        BaseReferences<
          _$AppDatabase,
          $ConnectionProfilesTable,
          ConnectionProfile
        >,
      ),
      ConnectionProfile,
      PrefetchHooks Function()
    >;
typedef $$RecentDevicesTableCreateCompanionBuilder =
    RecentDevicesCompanion Function({
      Value<int> id,
      required String udid,
      Value<String> displayName,
      required DateTime lastConnectedAt,
    });
typedef $$RecentDevicesTableUpdateCompanionBuilder =
    RecentDevicesCompanion Function({
      Value<int> id,
      Value<String> udid,
      Value<String> displayName,
      Value<DateTime> lastConnectedAt,
    });

class $$RecentDevicesTableFilterComposer
    extends Composer<_$AppDatabase, $RecentDevicesTable> {
  $$RecentDevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get udid => $composableBuilder(
    column: $table.udid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastConnectedAt => $composableBuilder(
    column: $table.lastConnectedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecentDevicesTableOrderingComposer
    extends Composer<_$AppDatabase, $RecentDevicesTable> {
  $$RecentDevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get udid => $composableBuilder(
    column: $table.udid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastConnectedAt => $composableBuilder(
    column: $table.lastConnectedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecentDevicesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecentDevicesTable> {
  $$RecentDevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get udid =>
      $composableBuilder(column: $table.udid, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastConnectedAt => $composableBuilder(
    column: $table.lastConnectedAt,
    builder: (column) => column,
  );
}

class $$RecentDevicesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecentDevicesTable,
          RecentDevice,
          $$RecentDevicesTableFilterComposer,
          $$RecentDevicesTableOrderingComposer,
          $$RecentDevicesTableAnnotationComposer,
          $$RecentDevicesTableCreateCompanionBuilder,
          $$RecentDevicesTableUpdateCompanionBuilder,
          (
            RecentDevice,
            BaseReferences<_$AppDatabase, $RecentDevicesTable, RecentDevice>,
          ),
          RecentDevice,
          PrefetchHooks Function()
        > {
  $$RecentDevicesTableTableManager(_$AppDatabase db, $RecentDevicesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecentDevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecentDevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecentDevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> udid = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<DateTime> lastConnectedAt = const Value.absent(),
              }) => RecentDevicesCompanion(
                id: id,
                udid: udid,
                displayName: displayName,
                lastConnectedAt: lastConnectedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String udid,
                Value<String> displayName = const Value.absent(),
                required DateTime lastConnectedAt,
              }) => RecentDevicesCompanion.insert(
                id: id,
                udid: udid,
                displayName: displayName,
                lastConnectedAt: lastConnectedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecentDevicesTable, RecentDevice>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $RecentDevicesTable,
                    RecentDevice
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecentDevicesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecentDevicesTable,
      RecentDevice,
      $$RecentDevicesTableFilterComposer,
      $$RecentDevicesTableOrderingComposer,
      $$RecentDevicesTableAnnotationComposer,
      $$RecentDevicesTableCreateCompanionBuilder,
      $$RecentDevicesTableUpdateCompanionBuilder,
      (
        RecentDevice,
        BaseReferences<_$AppDatabase, $RecentDevicesTable, RecentDevice>,
      ),
      RecentDevice,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConnectionProfilesTableTableManager get connectionProfiles =>
      $$ConnectionProfilesTableTableManager(_db, _db.connectionProfiles);
  $$RecentDevicesTableTableManager get recentDevices =>
      $$RecentDevicesTableTableManager(_db, _db.recentDevices);
}
