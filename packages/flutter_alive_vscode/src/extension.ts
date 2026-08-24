import * as vscode from "vscode";

class FlutterAliveDebugAdapterFactory
  implements vscode.DebugAdapterDescriptorFactory
{
  createDebugAdapterDescriptor(
    session: vscode.DebugSession,
  ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
    const settings = vscode.workspace.getConfiguration(
      "flutterAlive",
      session.workspaceFolder?.uri,
    );
    const executable = settings.get<string>("executable", "flutter_alive");
    const flutterPath = settings.get<string>("flutterPath", "").trim();
    const attachTimeout = settings.get<number>("attachTimeout", 10);
    const attachEnabled = settings.get<boolean>("attachEnabled", true);
    const args = [
      "debug-adapter",
      `--alive-attach-timeout=${attachTimeout}`,
    ];
    if (flutterPath) {
      args.push(`--alive-flutter=${flutterPath}`);
    }
    if (!attachEnabled) {
      args.push("--alive-no-attach");
    }
    return new vscode.DebugAdapterExecutable(executable, args, {
      cwd: session.workspaceFolder?.uri.fsPath,
    });
  }
}

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory(
      "flutter_alive",
      new FlutterAliveDebugAdapterFactory(),
    ),
    vscode.commands.registerCommand(
      "flutterAlive.migrateLaunchConfiguration",
      migrateLaunchConfiguration,
    ),
  );
}

export function deactivate(): void {}

async function migrateLaunchConfiguration(): Promise<void> {
  const folders = vscode.workspace.workspaceFolders ?? [];
  if (folders.length === 0) {
    await vscode.window.showErrorMessage(
      "Open a Flutter workspace before migrating launch.json.",
    );
    return;
  }
  const folder =
    folders.length === 1
      ? folders[0]
      : await vscode.window.showWorkspaceFolderPick({
          placeHolder: "Select the Flutter workspace",
        });
  if (!folder) {
    return;
  }
  const launch = vscode.workspace.getConfiguration("launch", folder.uri);
  const configurations = launch.get<Record<string, unknown>[]>(
    "configurations",
    [],
  );
  const candidates = configurations.filter(
    (configuration) =>
      configuration.type === "dart" && configuration.request === "launch",
  );
  if (candidates.length === 0) {
    await vscode.window.showInformationMessage(
      "No Dart launch configurations were found in this workspace.",
    );
    return;
  }
  const selected = await vscode.window.showQuickPick(
    candidates.map((configuration, index) => ({
      label:
        typeof configuration.name === "string"
          ? configuration.name
          : `Dart launch ${index + 1}`,
      index,
    })),
    { placeHolder: "Select a Dart configuration to migrate" },
  );
  if (!selected) {
    return;
  }
  const source = candidates[selected.index];
  const sourceIndex = configurations.indexOf(source);
  const migrated: Record<string, unknown> = {
    ...source,
    type: "flutter_alive",
  };
  if (typeof migrated.deviceId !== "string" || !migrated.deviceId) {
    const deviceId = await vscode.window.showInputBox({
      prompt: "Physical Flutter device ID or unique prefix",
      ignoreFocusOut: true,
      validateInput: (value) => (value.trim() ? undefined : "Device ID is required"),
    });
    if (!deviceId) {
      return;
    }
    migrated.deviceId = deviceId.trim();
  }
  configurations[sourceIndex] = migrated;
  await launch.update(
    "configurations",
    configurations,
    vscode.ConfigurationTarget.WorkspaceFolder,
  );
  await vscode.window.showInformationMessage(
    `Migrated "${selected.label}" to Flutter Alive.`,
  );
}
