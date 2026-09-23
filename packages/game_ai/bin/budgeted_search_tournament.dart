import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:game_ai/experimental_search.dart';
import 'package:game_ai/game_ai.dart';
import 'package:game_engine/game_engine.dart';

const _runnerVersion = 'budgetedSearchTournamentV1';

Future<void> main(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }
    final config = _Config.parse(
      _object(
        jsonDecode(await File(options.configPath!).readAsString()),
        'config',
      ),
    );
    _prepareOutput(config, options);
    final specs = [
      for (var trial = 0; trial < config.gamesPerCell; trial++)
        for (final pairing in config.pairings)
          _GameSpec(pairing.black, pairing.white, trial),
    ];
    final results = <String, Map<String, Object?>>{};
    final pending = <_GameSpec>[];
    for (final spec in specs) {
      final document = _readGame(config, options.outputDir!, spec);
      if (document != null) results[spec.key] = _compact(document);
      if (document == null || !_finished(document)) pending.add(spec);
    }
    void writeSummary() => _atomicWrite(
      File('${options.outputDir}/summary.json'),
      _summary(config, specs, results),
    );
    writeSummary();
    var next = 0;
    var failed = false;
    Future<void> worker() async {
      while (next < pending.length) {
        final spec = pending[next++];
        try {
          results[spec.key] = await Isolate.run(
            _Invocation(config, options.outputDir!, spec).call,
          );
          final game = results[spec.key]!;
          final finishedCount = results.values.where(_finished).length;
          stderr.writeln(
            'Finished $finishedCount/${specs.length}: ${spec.black} vs '
            '${spec.white}, trial ${spec.trial}, ${game['status']} '
            'at ${game['plies']} plies (${game['winner'] ?? 'no winner'}).',
          );
        } catch (error, stack) {
          failed = true;
          stderr.writeln('Game ${spec.key} failed: $error\n$stack');
          final saved = _readGame(config, options.outputDir!, spec);
          results[spec.key] = saved == null
              ? {
                  ..._identity(config, spec),
                  'status': 'error',
                  'error': '$error',
                }
              : _compact(saved);
        }
        writeSummary();
      }
    }

    await Future.wait(
      List.generate(
        math.min(options.concurrency, pending.length),
        (_) => worker(),
      ),
    );
    writeSummary();
    stdout.writeln('Summary: ${options.outputDir}/summary.json');
    if (failed) exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    stderr.write(_usage);
    exitCode = 64;
  } catch (error, stack) {
    stderr.writeln('error: $error\n$stack');
    exitCode = 1;
  }
}

void _prepareOutput(_Config config, _Options options) {
  final directory = Directory(options.outputDir!);
  final configFile = File('${directory.path}/config.json');
  final hasFiles = directory.existsSync() && directory.listSync().isNotEmpty;
  if (hasFiles && !options.resume) {
    throw const FormatException('output directory is not empty; use --resume');
  }
  if (hasFiles) {
    if (!configFile.existsSync()) {
      throw const FormatException(
        'cannot resume an output directory without config.json',
      );
    }
    final saved = _object(
      jsonDecode(configFile.readAsStringSync()),
      'saved config',
    );
    if (jsonEncode(_canonical(saved)) !=
        jsonEncode(_canonical(config.document))) {
      throw const FormatException(
        'resume configuration, source revision, or evaluation version does not match',
      );
    }
  } else {
    directory.createSync(recursive: true);
    _atomicWrite(configFile, config.document);
  }
  Directory('${directory.path}/games').createSync(recursive: true);
}

final class _Invocation {
  const _Invocation(this.config, this.outputDir, this.spec);
  final _Config config;
  final String outputDir;
  final _GameSpec spec;

  Map<String, Object?> call() => _runGame(config, outputDir, spec);
}

Map<String, Object?> _runGame(
  _Config config,
  String outputDir,
  _GameSpec spec,
) {
  const engine = GameEngine();
  final saved = _readGame(config, outputDir, spec);
  var state = saved == null
      ? engine.initialState(GameRules.standard())
      : GameState.fromJson(saved['state']);
  final moves = saved == null
      ? <Map<String, Object?>>[]
      : (saved['moves']! as List<Object?>)
            .map((move) => _object(move, 'saved move'))
            .toList();
  final previousElapsed = saved?['elapsedMicroseconds'] as int? ?? 0;
  final watch = Stopwatch()..start();
  final black = config.agent(spec.black, config.baseSeed + spec.trial * 2);
  final white = config.agent(spec.white, config.baseSeed + spec.trial * 2 + 1);
  Map<String, Object?> document({String? error, String? stack}) {
    final complete = !state.isActive;
    final truncated = state.isActive && state.ply >= config.safetyMaxPlies;
    final outcome = state.outcome;
    return {
      ..._identity(config, spec),
      'status': error != null
          ? 'error'
          : complete
          ? 'complete'
          : truncated
          ? 'truncated'
          : 'active',
      'complete': complete,
      'truncated': truncated,
      'plies': state.ply,
      'winner': outcome?.winner?.name,
      'outcomeReason': outcome?.reason.name,
      'blackPopulation': state.blackPopulation,
      'whitePopulation': state.whitePopulation,
      'finalPositionHash': state.positionHash,
      'finalStateHash': state.stateHash,
      'elapsedMicroseconds': previousElapsed + watch.elapsedMicroseconds,
      'searchTotals': _searchTotals(moves),
      'error': ?error,
      'stackTrace': ?stack,
      'state': state.toJson(),
      'moves': moves,
    };
  }

  void checkpoint() => _atomicWrite(_gameFile(outputDir, spec), document());

  try {
    checkpoint();
    while (state.isActive && state.ply < config.safetyMaxPlies) {
      final decision = (state.toMove == Player.black ? black : white)
          .chooseMove(state);
      final move = decision.move;
      final next = engine.applyMove(state, move).state;
      moves.add({
        'player': move.player.name,
        'row': move.row,
        'column': move.column,
        'score': decision.score,
        'completedDepth': decision.completedDepth,
        'attemptedDepth': decision.attemptedDepth,
        'maxVisitedPly': decision.maxVisitedPly,
        'successorEvaluations': decision.successorEvaluations,
        'nodesVisited': decision.nodesVisited,
        'cacheHits': decision.cacheHits,
        'cutoffs': decision.cutoffs,
        'elapsedMicroseconds': decision.elapsed.inMicroseconds,
        'budgetExhausted': decision.budgetExhausted,
      });
      state = next;
      if (state.ply % 25 == 0) checkpoint();
      if (state.ply % 100 == 0) {
        stderr.writeln(
          '${spec.black} vs ${spec.white}, trial ${spec.trial}: '
          '${state.ply} plies (Black ${state.blackPopulation}, White ${state.whitePopulation}).',
        );
      }
    }
    watch.stop();
    final result = document();
    _atomicWrite(_gameFile(outputDir, spec), result);
    return _compact(result);
  } catch (error, stack) {
    watch.stop();
    _atomicWrite(
      _gameFile(outputDir, spec),
      document(error: '$error', stack: '$stack'),
    );
    rethrow;
  }
}

Map<String, Object?>? _readGame(
  _Config config,
  String outputDir,
  _GameSpec spec,
) {
  final file = _gameFile(outputDir, spec);
  if (!file.existsSync()) return null;
  final document = _object(
    jsonDecode(file.readAsStringSync()),
    'game checkpoint',
  );
  for (final entry in _identity(config, spec).entries) {
    if (document[entry.key] != entry.value) {
      throw FormatException(
        'game checkpoint ${spec.key} has mismatched ${entry.key}',
      );
    }
  }
  final state = GameState.fromJson(document['state']);
  final moves = document['moves'];
  if (moves is! List ||
      moves.length != state.ply ||
      document['plies'] != state.ply ||
      state.rules != GameRules.standard() ||
      state.ply > config.safetyMaxPlies ||
      document['complete'] != !state.isActive ||
      document['truncated'] !=
          (state.isActive && state.ply >= config.safetyMaxPlies) ||
      document['blackPopulation'] != state.blackPopulation ||
      document['whitePopulation'] != state.whitePopulation ||
      document['finalPositionHash'] != state.positionHash ||
      document['finalStateHash'] != state.stateHash ||
      document['winner'] != state.outcome?.winner?.name ||
      document['outcomeReason'] != state.outcome?.reason.name) {
    throw FormatException(
      'game checkpoint ${spec.key} has inconsistent state/history',
    );
  }
  final expectedStatus = !state.isActive
      ? 'complete'
      : state.ply >= config.safetyMaxPlies
      ? 'truncated'
      : 'active';
  if (document['status'] != expectedStatus && document['status'] != 'error') {
    throw FormatException(
      'game checkpoint ${spec.key} has inconsistent status',
    );
  }
  _integer(
    document['elapsedMicroseconds'],
    'checkpoint elapsedMicroseconds',
    minimum: 0,
  );
  if (document['status'] == 'error') {
    _string(document['error'], 'checkpoint error');
  }
  const engine = GameEngine();
  var replay = engine.initialState(GameRules.standard());
  final parsedMoves = <Map<String, Object?>>[];
  for (final value in moves) {
    final move = _object(value, 'saved move');
    _keys(move, {
      'player',
      'row',
      'column',
      'score',
      'completedDepth',
      'attemptedDepth',
      'maxVisitedPly',
      'successorEvaluations',
      'nodesVisited',
      'cacheHits',
      'cutoffs',
      'elapsedMicroseconds',
      'budgetExhausted',
    }, 'saved move');
    final player = Player.fromJson(move['player']);
    final profileId = player == Player.black ? spec.black : spec.white;
    final profile = config.profiles.singleWhere((item) => item.id == profileId);
    final completedDepth = _integer(
      move['completedDepth'],
      'move completedDepth',
      minimum: 1,
      maximum: profile.maxDepth,
    );
    final attemptedDepth = _integer(
      move['attemptedDepth'],
      'move attemptedDepth',
      minimum: completedDepth,
      maximum: profile.maxDepth,
    );
    if (attemptedDepth > completedDepth + 1 ||
        move['budgetExhausted'] is! bool) {
      throw FormatException(
        'game checkpoint ${spec.key} has invalid search diagnostics',
      );
    }
    _integer(
      move['maxVisitedPly'],
      'move maxVisitedPly',
      minimum: 0,
      maximum: attemptedDepth,
    );
    _integer(
      move['score'],
      'move score',
      minimum: -terminalScore,
      maximum: terminalScore,
    );
    _integer(
      move['successorEvaluations'],
      'move successorEvaluations',
      minimum: 1,
      maximum: config.transitionBudget,
    );
    for (final field in [
      'nodesVisited',
      'cacheHits',
      'cutoffs',
      'elapsedMicroseconds',
    ]) {
      _integer(move[field], 'move $field', minimum: 0);
    }
    final placement = GameMove(
      player: player,
      row: _integer(
        move['row'],
        'move row',
        minimum: 0,
        maximum: GameRules.rows - 1,
      ),
      column: _integer(
        move['column'],
        'move column',
        minimum: 0,
        maximum: GameRules.columns - 1,
      ),
      expectedRevision: replay.revision,
    );
    if (!engine.validateMove(replay, placement).isValid) {
      throw FormatException(
        'game checkpoint ${spec.key} contains an illegal move at ply ${replay.ply}',
      );
    }
    replay = engine.applyMove(replay, placement).state;
    parsedMoves.add(move);
  }
  if (replay != state ||
      jsonEncode(_canonical(document['searchTotals'])) !=
          jsonEncode(_canonical(_searchTotals(parsedMoves)))) {
    throw FormatException(
      'game checkpoint ${spec.key} has inconsistent replay or search totals',
    );
  }
  return document;
}

Map<String, Object?> _identity(_Config config, _GameSpec spec) => {
  'runnerVersion': _runnerVersion,
  'studyId': config.studyId,
  'sourceRevision': config.sourceRevision,
  'evaluationVersion': evaluationVersion,
  'configHash': config.hash,
  'blackProfile': spec.black,
  'whiteProfile': spec.white,
  'trial': spec.trial,
  'blackTieBreakSeed': config.baseSeed + spec.trial * 2,
  'whiteTieBreakSeed': config.baseSeed + spec.trial * 2 + 1,
};

Map<String, Object?> _compact(Map<String, Object?> document) => {
  for (final entry in document.entries)
    if (entry.key != 'state' &&
        entry.key != 'moves' &&
        entry.key != 'stackTrace')
      entry.key: entry.value,
};

bool _finished(Map<String, Object?> game) =>
    game['status'] == 'complete' || game['status'] == 'truncated';

Map<String, Object?> _searchTotals(List<Map<String, Object?>> moves) {
  final depths = <String, int>{};
  var successors = 0;
  var nodes = 0;
  var hits = 0;
  var cutoffs = 0;
  var elapsed = 0;
  var exhausted = 0;
  var maxVisitedPly = 0;
  for (final move in moves) {
    final depth = '${move['completedDepth']}';
    depths.update(depth, (count) => count + 1, ifAbsent: () => 1);
    successors += move['successorEvaluations']! as int;
    nodes += move['nodesVisited']! as int;
    hits += move['cacheHits']! as int;
    cutoffs += move['cutoffs']! as int;
    elapsed += move['elapsedMicroseconds']! as int;
    maxVisitedPly = math.max(maxVisitedPly, move['maxVisitedPly']! as int);
    if (move['budgetExhausted']! as bool) exhausted++;
  }
  return {
    'moves': moves.length,
    'successorEvaluations': successors,
    'nodesVisited': nodes,
    'cacheHits': hits,
    'cutoffs': cutoffs,
    'elapsedMicroseconds': elapsed,
    'budgetExhaustedMoves': exhausted,
    'maxVisitedPly': maxVisitedPly,
    'completedDepthHistogram': depths,
  };
}

Map<String, Object?> _summary(
  _Config config,
  List<_GameSpec> specs,
  Map<String, Map<String, Object?>> results,
) {
  final games = [for (final spec in specs) ?results[spec.key]];
  final completed = games.where((game) => game['complete'] == true).length;
  final truncated = games.where((game) => game['truncated'] == true).length;
  final finished = games.where(_finished).length;
  return {
    'runnerVersion': _runnerVersion,
    'studyId': config.studyId,
    'sourceRevision': config.sourceRevision,
    'evaluationVersion': evaluationVersion,
    'configHash': config.hash,
    'victoryRule': 'elimination',
    'opening': 'centered2x2Diagonal',
    'transitionBudget': config.transitionBudget,
    'safetyMaxPlies': config.safetyMaxPlies,
    'plannedGames': specs.length,
    'recordedGames': games.length,
    'completedGames': completed,
    'truncatedGames': truncated,
    'pendingGames': specs.length - finished,
    'failedGames': games.where((game) => game['status'] == 'error').length,
    'blackWins': games.where((game) => game['winner'] == 'black').length,
    'whiteWins': games.where((game) => game['winner'] == 'white').length,
    'draws': games
        .where((game) => game['complete'] == true && game['winner'] == null)
        .length,
    'runComplete': finished == specs.length,
    'totalPlies': games.fold<int>(
      0,
      (sum, game) => sum + (game['plies'] as int? ?? 0),
    ),
    'elapsedGameMicroseconds': games.fold<int>(
      0,
      (sum, game) => sum + (game['elapsedMicroseconds'] as int? ?? 0),
    ),
    'games': games,
  };
}

File _gameFile(String directory, _GameSpec spec) =>
    File('$directory/games/${spec.black}__${spec.white}__${spec.trial}.json');

void _atomicWrite(File file, Map<String, Object?> document) {
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync('${jsonEncode(document)}\n', flush: true);
  temporary.renameSync(file.path);
}

final class _GameSpec {
  const _GameSpec(this.black, this.white, this.trial);
  final String black;
  final String white;
  final int trial;
  String get key => '$black|$white|$trial';
}

final class _Profile {
  const _Profile(this.id, this.maxDepth, this.fullWidthDepth, this.beamWidth);
  final String id;
  final int maxDepth;
  final int fullWidthDepth;
  final int beamWidth;

  Map<String, Object?> toJson() => {
    'id': id,
    'maxDepth': maxDepth,
    'fullWidthDepth': fullWidthDepth,
    'beamWidth': beamWidth,
  };
}

final class _Config {
  _Config({
    required this.studyId,
    required this.sourceRevision,
    required this.baseSeed,
    required this.gamesPerCell,
    required this.safetyMaxPlies,
    required this.transitionBudget,
    required this.profiles,
    required this.pairings,
  });
  final String studyId;
  final String sourceRevision;
  final int baseSeed;
  final int gamesPerCell;
  final int safetyMaxPlies;
  final int transitionBudget;
  final List<_Profile> profiles;
  final List<({String black, String white})> pairings;

  Map<String, Object?> get normalized => {
    'studyId': studyId,
    'sourceRevision': sourceRevision,
    'evaluationVersion': evaluationVersion,
    'baseSeed': baseSeed,
    'gamesPerCell': gamesPerCell,
    'safetyMaxPlies': safetyMaxPlies,
    'transitionBudget': transitionBudget,
    'profiles': profiles.map((profile) => profile.toJson()).toList(),
    'pairings': pairings
        .map((pair) => {'black': pair.black, 'white': pair.white})
        .toList(),
  };
  late final String hash = sha256
      .convert(utf8.encode(jsonEncode(_canonical(normalized))))
      .toString();
  Map<String, Object?> get document => {
    ...normalized,
    'runnerVersion': _runnerVersion,
    'configHash': hash,
  };

  BudgetedSearchAgent agent(String id, int seed) {
    final profile = profiles.singleWhere((profile) => profile.id == id);
    return BudgetedSearchAgent(
      name: id,
      maxDepth: profile.maxDepth,
      fullWidthDepth: profile.fullWidthDepth,
      beamWidth: profile.beamWidth,
      transitionBudget: transitionBudget,
      tieBreakSeed: seed,
    );
  }

  factory _Config.parse(Map<String, Object?> json) {
    _keys(json, {
      'studyId',
      'sourceRevision',
      'evaluationVersion',
      'baseSeed',
      'gamesPerCell',
      'safetyMaxPlies',
      'transitionBudget',
      'profiles',
      'pairings',
    }, 'config');
    if (json['evaluationVersion'] != evaluationVersion) {
      throw const FormatException(
        'config evaluationVersion must be $evaluationVersion',
      );
    }
    final profiles = <_Profile>[];
    final ids = <String>{};
    for (final value in _nonemptyList(json['profiles'], 'profiles')) {
      final item = _object(value, 'profile');
      _keys(item, {'id', 'maxDepth', 'fullWidthDepth', 'beamWidth'}, 'profile');
      final id = _string(item['id'], 'profile.id');
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(id) ||
          id.contains('__') ||
          !ids.add(id)) {
        throw const FormatException(
          'profile IDs must be unique safe filename components without __',
        );
      }
      profiles.add(
        _Profile(
          id,
          _integer(
            item['maxDepth'],
            'profile.maxDepth',
            minimum: 1,
            maximum: 64,
          ),
          _integer(
            item['fullWidthDepth'],
            'profile.fullWidthDepth',
            minimum: 1,
            maximum: 64,
          ),
          _integer(
            item['beamWidth'],
            'profile.beamWidth',
            minimum: 1,
            maximum: GameRules.cellCount,
          ),
        ),
      );
    }
    final pairings = <({String black, String white})>[];
    final pairs = <String>{};
    for (final value in _nonemptyList(json['pairings'], 'pairings')) {
      final item = _object(value, 'pairing');
      _keys(item, {'black', 'white'}, 'pairing');
      final black = _string(item['black'], 'pairing.black');
      final white = _string(item['white'], 'pairing.white');
      if (!ids.contains(black) ||
          !ids.contains(white) ||
          !pairs.add('$black|$white')) {
        throw const FormatException(
          'pairings must reference known profiles without duplicate pairs',
        );
      }
      pairings.add((black: black, white: white));
    }
    return _Config(
      studyId: _string(json['studyId'], 'studyId'),
      sourceRevision: _string(json['sourceRevision'], 'sourceRevision'),
      baseSeed: _integer(json['baseSeed'], 'baseSeed', minimum: 0),
      gamesPerCell: _integer(json['gamesPerCell'], 'gamesPerCell', minimum: 1),
      safetyMaxPlies: _integer(
        json['safetyMaxPlies'],
        'safetyMaxPlies',
        minimum: 1,
      ),
      transitionBudget: _integer(
        json['transitionBudget'],
        'transitionBudget',
        minimum: GameRules.cellCount,
      ),
      profiles: profiles,
      pairings: pairings,
    );
  }
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$name must be a JSON object');
  }
  return value.cast<String, Object?>();
}

void _keys(Map<String, Object?> value, Set<String> expected, String name) {
  if (value.length != expected.length || !expected.every(value.containsKey)) {
    throw FormatException('$name requires exactly: ${expected.join(', ')}');
  }
}

String _string(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a nonempty string');
  }
  return value;
}

int _integer(Object? value, String name, {required int minimum, int? maximum}) {
  if (value is! int ||
      value < minimum ||
      (maximum != null && value > maximum)) {
    throw FormatException(
      '$name must be an integer >= $minimum${maximum == null ? '' : ' and <= $maximum'}',
    );
  }
  return value;
}

List<Object?> _nonemptyList(Object? value, String name) {
  if (value is! List || value.isEmpty) {
    throw FormatException('$name must be a nonempty list');
  }
  return value.cast<Object?>();
}

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

final class _Options {
  const _Options(
    this.configPath,
    this.outputDir,
    this.concurrency,
    this.resume,
    this.help,
  );
  final String? configPath;
  final String? outputDir;
  final int concurrency;
  final bool resume;
  final bool help;

  factory _Options.parse(List<String> arguments) {
    String? config;
    String? output;
    var concurrency = 6;
    var resume = false;
    var help = false;
    for (final argument in arguments) {
      if (argument.startsWith('--config=')) {
        config = argument.substring('--config='.length);
      } else if (argument.startsWith('--output-dir=')) {
        output = argument.substring('--output-dir='.length);
      } else if (argument.startsWith('--concurrency=')) {
        concurrency =
            int.tryParse(argument.substring('--concurrency='.length)) ?? 0;
      } else if (argument == '--resume') {
        resume = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else {
        throw FormatException('unsupported argument: $argument');
      }
    }
    if (!help &&
        (config == null ||
            config.isEmpty ||
            output == null ||
            output.isEmpty)) {
      throw const FormatException('--config and --output-dir are required');
    }
    if (concurrency < 1) {
      throw const FormatException('--concurrency must be positive');
    }
    return _Options(config, output, concurrency, resume, help);
  }
}

const _usage = '''
Run a reproducible, equal-transition-budget elimination tournament.

Usage:
  dart run bin/budgeted_search_tournament.dart --config=PATH --output-dir=DIR [options]

Options:
  --concurrency=N  Simultaneous games (default: 6).
  --resume         Continue saved states with identical configuration.
  -h, --help       Show this help.
''';
