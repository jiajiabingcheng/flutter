// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/commands/logs.dart';
import 'package:test/test.dart';

import 'src/common.dart';
import 'src/context.dart';
import 'src/mocks.dart';

void main() {
  group('logs', () {
    testUsingContext('fail with a bad device id', () async {
      LogsCommand command = new LogsCommand();
      applyMocksToCommand(command);
      try {
        await createTestCommandRunner(command).run(<String>['-d', 'abc123', 'logs']);
        fail('Expect exception');
      } on ToolExit catch (e) {
        expect(e.exitCode ?? 1, 1);
      }
    });
  });
}
