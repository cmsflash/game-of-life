import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:game_engine/game_engine.dart';

const cap = 20000;
const baseSeed = 6100000;
const players = ['D3', 'F1B4', 'F2B8'];
const engine = GameEngine();
typedef Doc = Map<String, dynamic>;

void require(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Object? canonical(Object? v) {
  if (v is Map<String, dynamic>) {
    final keys = v.keys.toList()..sort();
    return {for (final k in keys) k: canonical(v[k])};
  }
  if (v is List) return v.map(canonical).toList();
  return v;
}

Set<String> checkConfig(Doc config) {
  final normalized = {...config}..remove('configHash')..remove('runnerVersion');
  require(sha256.convert(utf8.encode(jsonEncode(canonical(normalized)))).toString() == config['configHash'], 'config hash');
  require(config['runnerVersion'] == 'budgetedSearchTournamentV1' && config['evaluationVersion'] == 'terminalUtilityV1', 'runner/evaluation');
  require(config['safetyMaxPlies'] == cap && config['baseSeed'] == baseSeed && config['gamesPerCell'] == 10 && config['transitionBudget'] == 100000, 'study settings');
  final specs = {'D3': [3,64,8], 'F1B4': [8,1,4], 'F2B8': [8,2,8]};
  require(config['profiles'].length == 3, 'profile count');
  for (final p in config['profiles']) {
    final expected = specs.remove(p['id']);
    require(expected != null && p['maxDepth'] == expected[0] && p['fullWidthDepth'] == expected[1] && p['beamWidth'] == expected[2], 'profile ${p['id']}');
  }
  final expected = {for (final b in players) for (final w in players) if (b != w) '${b}__${w}'};
  require(config['pairings'].length == expected.length && expected.containsAll([for (final p in config['pairings']) '${p['black']}__${p['white']}']) && {for (final p in config['pairings']) '${p['black']}__${p['white']}'}.length == expected.length, 'ordered pairings');
  return {for (final p in expected) for (var t = 0; t < 10; t++) '${p}__$t.json'};
}

Doc replay(String name, Doc game, Doc config, List<int> bytes) {
  final black = game['blackProfile'];
  final white = game['whiteProfile'];
  final trial = game['trial'];
  require(name == '${black}__${white}__$trial.json', '$name game identity');
  final seed = baseSeed + 2 * (trial as int);
  require(game['blackTieBreakSeed'] == seed && game['whiteTieBreakSeed'] == seed + 1, '$name seed pair');
  for (final k in ['runnerVersion','studyId','sourceRevision','evaluationVersion','configHash']) {
    require(game[k] == config[k], '$name $k');
  }
  final moves = game['moves'] as List;
  final ply = game['plies'] as int;
  require(game['error'] == null && moves.length == ply && ply > 0 && ply <= cap, '$name stopping/length');
  var state = engine.initialState(GameRules.standard());
  for (final move in moves) {
    final result = engine.applyMove(state, GameMove(player: Player.fromJson(move['player']), row: move['row'], column: move['column'], expectedRevision: state.revision));
    state = result.state;
  }
  final saved = GameState.fromJson(game['state']);
  require(state == saved && state.stateHash == game['finalStateHash'] && state.positionHash == game['finalPositionHash'] && state.blackPopulation == game['blackPopulation'] && state.whitePopulation == game['whitePopulation'], '$name endpoint');
  final natural = !state.isActive;
  require(game['complete'] == natural && game['truncated'] == !natural && (natural || ply == cap) && game['status'] == (natural ? 'complete' : 'truncated'), '$name status');
  require(game['winner'] == state.outcome?.winner?.name && game['outcomeReason'] == state.outcome?.reason.name, '$name outcome');
  return {'game': name.substring(0, name.length - 5), 'black': black, 'white': white, 'trial': trial, 'blackSeed': seed, 'whiteSeed': seed + 1, 'plies': ply, 'status':game['status'], 'winner':game['winner'], 'reason':game['outcomeReason'], 'positionHash':state.positionHash, 'stateHash':state.stateHash, 'checkpointSha256':sha256.convert(bytes).toString()};
}

Future<void> main(List<String> args) async {
  final root = Directory(args[0]);
  final target = Directory(args[1]);
  final configFile = File('${root.path}/config.json');
  final games = Directory('${root.path}/games');
  while (!configFile.existsSync() || !games.existsSync()) {
    await Future<void>.delayed(const Duration(seconds: 15));
  }
  final config = jsonDecode(configFile.readAsStringSync()) as Doc;
  final expected = checkConfig(config);
  final verified = <String,Doc>{};
  while (true) {
    var changed = false;
    for (final file in games.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      require(expected.contains(name), 'unexpected file $name');
      if (verified.containsKey(name)) continue;
      // A bounded prefix read avoids repeated decoding of growing per-move arrays.
      final input = file.openSync();
      late final String prefix;
      try { prefix = utf8.decode(input.readSync(4096), allowMalformed:true); } finally { input.closeSync(); }
      final status = RegExp(r'"status"\s*:\s*"([^"]+)"').firstMatch(prefix)?.group(1);
      require(['active','complete','truncated'].contains(status), '$name status $status');
      if (status == 'active') continue;
      final bytes = file.readAsBytesSync();
      verified[name] = replay(name, jsonDecode(utf8.decode(bytes)) as Doc, config, bytes);
      changed = true;
    }
    if (changed) {
      final all = verified.length == expected.length;
      if (all) {
        require(jsonEncode(canonical(jsonDecode(configFile.readAsStringSync()))) == jsonEncode(canonical(config)), 'config changed');
        for (final name in expected) {
          final bytes = File('${games.path}/$name').readAsBytesSync();
          require(sha256.convert(bytes).toString() == verified[name]!['checkpointSha256'], '$name changed after replay');
        }
      }
      final records = [for (final name in (verified.keys.toList()..sort())) verified[name]!];
      final result = {'status':all ? 'final':'partial', 'verifiedAtUtc':DateTime.now().toUtc().toIso8601String(), 'configHash':config['configHash'], 'canonicalEngineRevision':'730171a1cd01a8ddefaf98bd5a164971dd8983a3', 'scheduledGames':expected.length, 'verifiedGames':records.length, 'verifiedPlies':records.fold<int>(0,(n,r)=>n+(r['plies'] as int)), 'naturalResults':records.where((r)=>r['status']=='complete').length, 'unfinishedAt20000':records.where((r)=>r['status']=='truncated').length, 'games':records};
      final out = '${target.path}/${all ? 'final' : 'partial'}-replay.json';
      File('$out.tmp').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(result)}\n', flush:true);
      File('$out.tmp').renameSync(out);
      stdout.writeln('${result['verifiedAtUtc']} verified ${records.length}/60 and ${result['verifiedPlies']} legal moves');
      if (all) return;
    }
    await Future<void>.delayed(const Duration(seconds: 90));
  }
}
