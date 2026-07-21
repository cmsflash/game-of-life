import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:game_cli/game_cli.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln(
      'Life Duel JSONL CLI\n'
      'Usage: game_cli [--jsonl|--once]\n\n'
      'Reads one JSON request per stdin line and writes one JSON response per '
      'stdout line. Operations: initial, applyMove, evolve, legalMoves, replay.',
    );
    return;
  }
  final runOnce = arguments.length == 1 && arguments.single == '--once';
  if (arguments.isNotEmpty &&
      !(arguments.length == 1 &&
          (arguments.single == '--jsonl' || arguments.single == '--once'))) {
    stderr.writeln('Unknown arguments. Use --help for usage.');
    exitCode = 64;
    return;
  }

  final cli = GameCli();
  if (runOnce) {
    final input = await utf8.decoder.bind(stdin).join();
    if (input.trim().isNotEmpty) {
      stdout.writeln(cli.handleLine(input.trim()));
    }
    return;
  }
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(cli.handleLine(line));
  }
}
