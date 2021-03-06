// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../cache.dart';
import '../device.dart';
import '../globals.dart';
import '../ios/mac.dart';
import '../resident_runner.dart';
import '../run_cold.dart';
import '../run_hot.dart';
import '../runner/flutter_command.dart';
import 'daemon.dart';

abstract class RunCommandBase extends FlutterCommand {
  // Used by run and drive commands.
  RunCommandBase() {
    addBuildModeFlags(defaultToRelease: false);
    argParser.addFlag('trace-startup',
        negatable: true,
        defaultsTo: false,
        help: 'Start tracing during startup.');
    argParser.addOption('route',
        help: 'Which route to load when running the app.');
    usesTargetOption();
    usesPortOptions();
    usesPubOption();
  }

  bool get traceStartup => argResults['trace-startup'];
  String get route => argResults['route'];

  void usesPortOptions() {
    argParser.addOption('observatory-port',
        help: 'Listen to the given port for an observatory debugger connection.\n'
              'Specifying port 0 will find a random free port.\n'
              'Defaults to the first available port after $kDefaultObservatoryPort.'
    );
    argParser.addOption('diagnostic-port',
        help: 'Listen to the given port for a diagnostic connection.\n'
              'Specifying port 0 will find a random free port.\n'
              'Defaults to the first available port after $kDefaultDiagnosticPort.'
    );
  }

  int get observatoryPort {
    if (argResults['observatory-port'] != null) {
      try {
        return int.parse(argResults['observatory-port']);
      } catch (error) {
        throwToolExit('Invalid port for `--observatory-port`: $error');
      }
    }
    return null;
  }

  int get diagnosticPort {
    if (argResults['diagnostic-port'] != null) {
      try {
        return int.parse(argResults['diagnostic-port']);
      } catch (error) {
        throwToolExit('Invalid port for `--diagnostic-port`: $error');
      }
    }
    return null;
  }
}

class RunCommand extends RunCommandBase {
  @override
  final String name = 'run';

  @override
  final String description = 'Run your Flutter app on an attached device.';

  RunCommand({ bool verboseHelp: false }) {
    argParser.addFlag('full-restart',
        defaultsTo: true,
        help: 'Stop any currently running application process before running the app.');
    argParser.addFlag('start-paused',
        defaultsTo: false,
        negatable: false,
        help: 'Start in a paused mode and wait for a debugger to connect.');
    argParser.addFlag('build',
        defaultsTo: true,
        help: 'If necessary, build the app before running.');
    argParser.addOption('use-application-binary',
        hide: !verboseHelp,
        help: 'Specify a pre-built application binary to use when running.');
    argParser.addOption('snapshotter',
        hide: !verboseHelp,
        help: 'Specify the path to the sky_snapshot binary.');
    argParser.addOption('packages',
        hide: !verboseHelp,
        help: 'Specify the path to the .packages file.');
    argParser.addOption('project-root',
        hide: !verboseHelp,
        help: 'Specify the project root directory.');
    argParser.addOption('project-assets',
        hide: !verboseHelp,
        help: 'Specify the project assets relative to the root directory.');
    argParser.addFlag('machine',
        hide: !verboseHelp,
        help: 'Handle machine structured JSON command input\n'
              'and provide output and progress in machine friendly format.');
    argParser.addFlag('hot',
        negatable: true,
        defaultsTo: kHotReloadDefault,
        help: 'Run with support for hot reloading.');
    argParser.addOption('pid-file',
        help: 'Specify a file to write the process id to.\n'
              'You can send SIGUSR1 to trigger a hot reload\n'
              'and SIGUSR2 to trigger a full restart.');
    argParser.addFlag('resident',
        negatable: true,
        defaultsTo: true,
        hide: !verboseHelp,
        help: 'Stay resident after launching the application.');

    // Hidden option to enable a benchmarking mode. This will run the given
    // application, measure the startup time and the app restart time, write the
    // results out to 'refresh_benchmark.json', and exit. This flag is intended
    // for use in generating automated flutter benchmarks.
    argParser.addFlag('benchmark', negatable: false, hide: !verboseHelp);

    commandValidator = () {
      if (!runningWithPrebuiltApplication)
        commonCommandValidator();

      // When running with a prebuilt application, no command validation is
      // necessary.
    };
  }

  Device device;

  @override
  String get usagePath {
    String command = shouldUseHotMode() ? 'hotrun' : name;

    if (device == null)
      return command;

    // Return 'run/ios'.
    return '$command/${getNameForTargetPlatform(device.platform)}';
  }

  @override
  void printNoConnectedDevices() {
    super.printNoConnectedDevices();
    if (getCurrentHostPlatform() == HostPlatform.darwin_x64 &&
        Xcode.instance.isInstalledAndMeetsVersionCheck) {
      printStatus('');
      printStatus('To run on a simulator, launch it first: open -a Simulator.app');
      printStatus('');
      printStatus('If you expected your device to be detected, please run "flutter doctor" to diagnose');
      printStatus('potential issues, or visit https://flutter.io/setup/ for troubleshooting tips.');
    }
  }

  @override
  bool get shouldRunPub {
    // If we are running with a prebuilt application, do not run pub.
    if (runningWithPrebuiltApplication)
      return false;

    return super.shouldRunPub;
  }

  bool shouldUseHotMode() {
    bool hotArg = argResults['hot'] ?? false;
    final bool shouldUseHotMode = hotArg;
    return (getBuildMode() == BuildMode.debug) && shouldUseHotMode;
  }

  bool get runningWithPrebuiltApplication =>
      argResults['use-application-binary'] != null;

  bool get stayResident => argResults['resident'];

  @override
  Future<Null> verifyThenRunCommand() async {
    commandValidator();
    device = await findTargetDevice();
    if (device == null)
      throwToolExit(null);
    return super.verifyThenRunCommand();
  }

  @override
  Future<Null> runCommand() async {

    Cache.releaseLockEarly();

    // Enable hot mode by default if `--no-hot` was not passed and we are in
    // debug mode.
    final bool hotMode = shouldUseHotMode();

    if (argResults['machine']) {
      Daemon daemon = new Daemon(stdinCommandStream, stdoutCommandResponse,
          notifyingLogger: new NotifyingLogger(), logToStdout: true);
      AppInstance app;
      try {
        app = daemon.appDomain.startApp(
          device, fs.currentDirectory.path, targetFile, route,
          getBuildMode(), argResults['start-paused'], hotMode,
          applicationBinary: argResults['use-application-binary'],
          projectRootPath: argResults['project-root'],
          packagesFilePath: argResults['packages'],
          projectAssets: argResults['project-assets']);
      } catch (error) {
        throwToolExit(error.toString());
      }
      int result = await app.runner.waitForAppToFinish();
      if (result != 0)
        throwToolExit(null, exitCode: result);
      return null;
    }

    if (device.isLocalEmulator && !isEmulatorBuildMode(getBuildMode()))
      throwToolExit('${toTitleCase(getModeName(getBuildMode()))} mode is not supported for emulators.');

    DebuggingOptions options;

    if (getBuildMode() == BuildMode.release) {
      options = new DebuggingOptions.disabled(getBuildMode());
    } else {
      options = new DebuggingOptions.enabled(
        getBuildMode(),
        startPaused: argResults['start-paused'],
        observatoryPort: observatoryPort,
        diagnosticPort: diagnosticPort,
      );
    }

    if (hotMode) {
      if (!device.supportsHotMode)
        throwToolExit('Hot mode is not supported by this device. Run with --no-hot.');
    }

    String pidFile = argResults['pid-file'];
    if (pidFile != null) {
      // Write our pid to the file.
      fs.file(pidFile).writeAsStringSync(pid.toString());
    }
    ResidentRunner runner;

    if (hotMode) {
      runner = new HotRunner(
        device,
        target: targetFile,
        debuggingOptions: options,
        benchmarkMode: argResults['benchmark'],
        applicationBinary: argResults['use-application-binary'],
        projectRootPath: argResults['project-root'],
        packagesFilePath: argResults['packages'],
        projectAssets: argResults['project-assets'],
        stayResident: stayResident,
      );
    } else {
      runner = new ColdRunner(
        device,
        target: targetFile,
        debuggingOptions: options,
        traceStartup: traceStartup,
        applicationBinary: argResults['use-application-binary'],
        stayResident: stayResident,
      );
    }

    int result = await runner.run(
      route: route,
      shouldBuild: !runningWithPrebuiltApplication && argResults['build'],
    );
    if (result != 0)
      throwToolExit(null, exitCode: result);
  }
}
