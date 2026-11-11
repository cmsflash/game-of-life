import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:game_ai/experimental_search.dart';
import 'package:game_engine/game_engine.dart';
import 'verify.dart' show checkConfig, require, baseSeed;

const metrics = ['score','completedDepth','attemptedDepth','maxVisitedPly','successorEvaluations','nodesVisited','cacheHits','cutoffs','budgetExhausted'];
typedef Doc = Map<String,dynamic>;
Doc read(String path) => jsonDecode(File(path).readAsStringSync()) as Doc;

Doc sampleGame(String path, Doc config, Doc? boundary) {
  final file = File(path);
  final raw = file.readAsBytesSync();
  final g = jsonDecode(utf8.decode(raw)) as Doc;
  final name = file.uri.pathSegments.last;
  final count = g['plies'] as int;
  final moves = g['moves'] as List;
  final boundaryPly = boundary?['plies'] as int? ?? 0;
  require((g['status']=='complete'||(g['status']=='truncated'&&count==20000)) && count>0 && count<=20000 && count==moves.length && boundaryPly<=count,'$name unfinished or bad count');
  require(name=='${g['blackProfile']}__${g['whiteProfile']}__${g['trial']}.json' && g['configHash']==config['configHash'],'$name identity');
  final cases = <int>{};
  if(count<=8) { cases.addAll(List.generate(count,(i)=>i)); } else {
    for(final start in [count~/4,count~/2,(count*3)~/4,count-2]) { cases.addAll([start,start+1]); }
  }
  final profiles = {for(final p in config['profiles']) p['id']:p};
  final agents = <Player,BudgetedSearchAgent>{};
  for(final side in Player.values){
    final id=g['${side.name}Profile'];final p=profiles[id];final seed=baseSeed+2*(g['trial'] as int)+(side==Player.black?0:1);
    require(seed==g['${side.name}TieBreakSeed'],'$name seed');
    agents[side]=BudgetedSearchAgent(name:id,maxDepth:p['maxDepth'],transitionBudget:config['transitionBudget'],fullWidthDepth:p['fullWidthDepth'],beamWidth:p['beamWidth'],tieBreakSeed:seed);
  }
  const engine=GameEngine();var state=engine.initialState(GameRules.standard());
  final rows=<Doc>[];
  final colors=<String>{};var after=0;
  for(var i=0;i<count;i++){
    if(boundary!=null&&i==boundaryPly) require(state.stateHash==boundary['stateHash'],'$name prefix changed at native switch');
    final m=moves[i];final player=Player.fromJson(m['player']);final move=GameMove(player:player,row:m['row'],column:m['column'],expectedRevision:i);
    if(cases.contains(i)){
      final found=agents[player]!.chooseMove(state);final data=found.toJson();
      require(found.move==move,'$name ply ${i+1} chose ${found.move.toJson()} vs saved ${move.toJson()}');
      for(final field in metrics) { require(data[field]==m[field],'$name ply ${i+1} $field original=${data[field]} recorded=${m[field]}'); }
      require(m.length==metrics.length+4 && ['player','row','column',...metrics,'elapsedMicroseconds'].every(m.containsKey),'$name unexpected recorded schema');
      rows.add({'ply':i+1,'player':player.name,'row':m['row'],'column':m['column'],for(final field in metrics) field:data[field]});
      colors.add(player.name);if(i>=boundaryPly)after++;
    }
    state=engine.applyMove(state,move).state;
  }
  if(boundary!=null&&count==boundaryPly)require(state.stateHash==boundary['stateHash'],'$name already-completed state changed');
  require(state==GameState.fromJson(g['state'])&&state.stateHash==g['finalStateHash']&&state.positionHash==g['finalPositionHash'],'$name endpoint mismatch');
  require(colors.length==2 || count==1,'$name both colors');
  return {'game':name,'plies':count,'finalStateHash':state.stateHash,'checkpointSha256':sha256.convert(raw).toString(),'nativeStartsAfterPly':boundaryPly,'testedDecisionNumbers':rows.map((r)=>r['ply']).toList(),'testedBlack':rows.where((r)=>r['player']=='black').length,'testedWhite':rows.where((r)=>r['player']=='white').length,'testedNative':after,'testedOriginalSegment':rows.length-after,'originalDecisionDigest':sha256.convert(utf8.encode(jsonEncode(rows))).toString()};
}

Future<void> main(List<String> args) async {
  final root=args[0],boundaries=read(args[1]),target=args[2];final config=read('$root/config.json'); final names=checkConfig(config).toList()..sort();
  final done=<String,Doc>{};
  while(done.length<names.length){
    final eligible=<String>[];
    for(final name in names){
      if(done.containsKey(name))continue;final f=File('$root/games/$name');if(!f.existsSync())continue;
      final h=f.openSync();late final String prefix;try{prefix=utf8.decode(h.readSync(2048),allowMalformed:true);}finally{h.closeSync();}
      if(RegExp(r'"status"\s*:\s*"(complete|truncated)"').hasMatch(prefix)) eligible.add(name);
    }
    var index=0;
    Future<void> worker()async{while(index<eligible.length){final name=eligible[index++];final boundary=boundaries[name] as Doc?;
      done[name]=await Isolate.run(()=>sampleGame('$root/games/$name',config,boundary));stdout.writeln('${DateTime.now().toUtc().toIso8601String()} ${done.length}/60 $name matched');}}
    await Future.wait(List.generate(3,(_)=>worker()));
    if(done.length<names.length){await Future.delayed(const Duration(seconds:15));}
  }
  final games=[for(final n in names)done[n]!];
  for(final g in games){require(sha256.convert(File('$root/games/${g['game']}').readAsBytesSync()).toString()==g['checkpointSha256'],'Checkpoint changed after sampling');}
  int sum(String key)=>games.fold(0,(s,g)=>s+(g[key] as int));
  final report={'status':'verified','verifiedAtUtc':DateTime.now().toUtc().toIso8601String(),'canonicalGameAiAndEngineRevision':'730171a1cd01a8ddefaf98bd5a164971dd8983a3','configHash':config['configHash'],'schedule':'60 ordered match games, all fresh seeds','method':'Every game replayed from the opening with the original Dart canonical engine. Compute original unoptimized budgeted agent decisions at adjacent plies starting at one quarter, one half and three quarters of the final trajectory, plus its last two. Check every ply for trajectories of eight or fewer moves. Record samples as one-based ply numbers. Wall-clock duration is excluded.','checkedFields':['player','row','column',...metrics],'matchedGames':games.length,'matchedDecisions':sum('testedBlack')+sum('testedWhite'),'matchedBlack':sum('testedBlack'),'matchedWhite':sum('testedWhite'),'matchedNative':sum('testedNative'),'matchedBeforeNative':sum('testedOriginalSegment'),'games':games};
  final out=File('$target/decision-sample.json.tmp');out.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n',flush:true);out.renameSync('$target/decision-sample.json');
  stdout.writeln('Done: ${report['matchedDecisions']} decisions matched.');
}
