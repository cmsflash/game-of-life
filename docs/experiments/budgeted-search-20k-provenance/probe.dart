import 'dart:convert';
import 'dart:io';
import 'package:game_ai/experimental_search.dart';
import 'package:game_engine/game_engine.dart';

void main(List<String> args) {
  const engine = GameEngine();
  final data = args[0];
  final benchmark = args.length > 1 && args[1] == 'benchmark';
  final positions = <String, GameState>{'opening': engine.initialState()};
  for (final spec in [
    ('D2__D3__0', 100), ('D2__D3__0', 1200),
    ('D2__F2B8__0', 4200), ('F2B4__D2__0', -1), ('D2__F1B8__1', -1),
  ]) {
    final j = jsonDecode(File('$data/games/${spec.$1}.json').readAsStringSync()) as Map<String,dynamic>;
    var s = spec.$2 < 0 ? GameState.fromJson(j['state']) : engine.initialState();
    if (spec.$2 >= 0) {
      for (final m in (j['moves'] as List).take(spec.$2)) {
        s = engine.applyMove(s, GameMove(player:s.toMove!,row:m['row'] as int,column:m['column'] as int,expectedRevision:s.revision)).state;
      }
    }
    positions['${spec.$1}@${s.ply}'] = s;
  }
  const profiles = [
    ('D1',1,64,8),('D2',2,64,8),('D3',3,64,8),('D4',4,64,8),('D5',5,64,8),('D8',8,64,8),
    ('F1B4',8,1,4),('F1B8',8,1,8),('F2B4',8,2,4),('F2B8',8,2,8),
  ];
  final rows = <Map<String,Object?>>[];
  final watch = Stopwatch()..start();
  for (final entry in positions.entries) {
    if (benchmark && !entry.key.contains('@1200') && !entry.key.contains('@4200')) continue;
    for (final p in profiles) {
      if (benchmark && ['D1','D2','D3','D4','D5','F1B8','F2B4'].contains(p.$1)) continue;
      for (final seed in [6000000,6000003]) {
        final d = BudgetedSearchAgent(maxDepth:p.$2,transitionBudget:100000,fullWidthDepth:p.$3,beamWidth:p.$4,tieBreakSeed:seed).chooseMove(entry.value);
        rows.add({'position':entry.key,'profile':p.$1,'seed':seed,'decision':d.toJson()..remove('elapsedMicroseconds'),'microseconds':d.elapsedMicroseconds});
      }
    }
  }
  watch.stop();
  stdout.writeln(jsonEncode({'cases':rows,'wallMicroseconds':watch.elapsedMicroseconds}));
}
