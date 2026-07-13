using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Newtonsoft.Json;
using ToolkitGUI.Models;
using ToolkitGUI.Services;

namespace ToolkitGUI.ViewModels
{
    // ─── Startup Manager ─────────────────────────────────────────────────────────

    public class StartupManagerViewModel : INotifyPropertyChanged
    {
        public const string TabStartupItems = "StartupItems";
        public const string TabDrivers = "Drivers";
        public const string TabExtensions = "Extensions";
        public const string TabServices = "Services";

        private bool _isLoading;
        private string _statusText = "Ready";
        private string _activeTab = TabStartupItems;
        private string _filterText = string.Empty;
        private bool _includeWindowsScheduledTasks;
        private bool _showSuspiciousOnly;

        public ObservableCollection<StartupEntry> StartupEntries { get; } = new();
        public ObservableCollection<StartupEntry> FilteredEntries { get; } = new();
        public ObservableCollection<ServiceEntry> Services { get; } = new();
        public ObservableCollection<ServiceEntry> FilteredServices { get; } = new();

        public bool IsLoading
        {
            get => _isLoading;
            set { _isLoading = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsIdle)); }
        }

        public bool IsIdle => !_isLoading;

        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        public string ActiveTab
        {
            get => _activeTab;
            set { _activeTab = value; OnPropertyChanged(); }
        }

        public string FilterText
        {
            get => _filterText;
            set { _filterText = value; OnPropertyChanged(); ApplyFilter(); }
        }

        public bool IncludeWindowsScheduledTasks
        {
            get => _includeWindowsScheduledTasks;
            set { _includeWindowsScheduledTasks = value; OnPropertyChanged(); }
        }

        public bool ShowSuspiciousOnly
        {
            get => _showSuspiciousOnly;
            set { _showSuspiciousOnly = value; OnPropertyChanged(); ApplyFilter(); }
        }

        private static string ScriptPath => WorkflowViewModelBase_GetScriptPath("StartupManager.ps1");

        public ICommand RefreshCommand   => new RelayCommand(async () => await RefreshAsync());
        public ICommand EnableCommand    => new RelayCommand<StartupEntry>(async e => await ToggleEntryAsync(e, true));
        public ICommand DisableCommand   => new RelayCommand<StartupEntry>(async e => await ToggleEntryAsync(e, false));
        public ICommand DeleteCommand    => new RelayCommand<StartupEntry>(async e => await DeleteEntryAsync(e));
        public ICommand ResetCommand     => new RelayCommand<StartupEntry>(async e => await ResetEntryAsync(e));
        public ICommand UndoCommand      => new RelayCommand<StartupEntry>(async e => await UndoEntryAsync(e));
        public ICommand StartSvcCommand  => new RelayCommand<ServiceEntry>(async s => await ServiceActionAsync(s, "StartService"));
        public ICommand StopSvcCommand   => new RelayCommand<ServiceEntry>(async s => await ServiceActionAsync(s, "StopService"));
        public ICommand RestartSvcCommand=> new RelayCommand<ServiceEntry>(async s => await ServiceActionAsync(s, "RestartService"));
        public ICommand SetStartTypeCommand => new RelayCommand<ServiceEntry>(async s => await SetStartTypeAsync(s));

        public async Task LoadStartupItemsAsync()
        {
            await LoadStartupCategoryAsync("ListStartupItems", "user logon entries");
        }

        public async Task LoadDriversAsync()
        {
            await LoadStartupCategoryAsync("ListDrivers", "driver entries");
        }


        public async Task LoadExtensionsAsync()
        {
            await LoadStartupCategoryAsync("ListExtensions", "extension entries");
        }

        public async Task LoadStartupAsync()
        {
            await LoadStartupItemsAsync();
        }

        private async Task LoadStartupCategoryAsync(string action, string statusLabel)
        {
            IsLoading = true;
            StatusText = $"Loading {statusLabel}...";
            try
            {
                var includeWindowsTasks = string.Equals(action, "ListStartupItems", StringComparison.OrdinalIgnoreCase)
                    && IncludeWindowsScheduledTasks;
                var includeArg = includeWindowsTasks ? " -IncludeWindowsScheduledTasks" : string.Empty;
                var (json, psErr) = await PowerShellService.QueryAsync($"& '{ScriptPath}' -Action {action}{includeArg}");
                if (!string.IsNullOrEmpty(psErr)) { StatusText = $"PS Error: {psErr}"; return; }
                var entries = string.IsNullOrWhiteSpace(json) ? null
                    : JsonConvert.DeserializeObject<StartupEntry[]>(
                        json.TrimStart().StartsWith("[") ? json : $"[{json}]");
                System.Windows.Application.Current.Dispatcher.Invoke(() =>
                {
                    StartupEntries.Clear();
                    if (entries != null)
                        foreach (var e in entries) StartupEntries.Add(e);
                    ApplyFilter();
                    StatusText = $"{StartupEntries.Count} {statusLabel} loaded";
                });
            }
            catch (Exception ex) { StatusText = $"Error: {ex.Message}"; }
            finally { IsLoading = false; }
        }

        public async Task LoadServicesAsync()
        {
            IsLoading = true;
            StatusText = "Loading services...";
            try
            {
                var (json, psErr) = await PowerShellService.QueryAsync($"& '{ScriptPath}' -Action ListServices");
                if (!string.IsNullOrEmpty(psErr) && string.IsNullOrWhiteSpace(json))
                {
                    StatusText = $"PS Error: {psErr}";
                    return;
                }

                var svcs = string.IsNullOrWhiteSpace(json) ? null
                    : JsonConvert.DeserializeObject<ServiceEntry[]>(
                        json.TrimStart().StartsWith("[") ? json : $"[{json}]");
                System.Windows.Application.Current.Dispatcher.Invoke(() =>
                {
                    Services.Clear();
                    if (svcs != null)
                        foreach (var s in svcs.OrderBy(x => x.DisplayName)) Services.Add(s);
                    ApplyFilter();
                    StatusText = string.IsNullOrWhiteSpace(psErr)
                        ? $"{Services.Count} services loaded"
                        : $"{Services.Count} services loaded (with access warnings)";
                });
            }
            catch (Exception ex) { StatusText = $"Error: {ex.Message}"; }
            finally { IsLoading = false; }
        }

        private async Task RefreshAsync()
        {
            switch (ActiveTab)
            {
                case TabDrivers:
                    await LoadDriversAsync();
                    break;
                case TabExtensions:
                    await LoadExtensionsAsync();
                    break;
                case TabServices:
                    await LoadServicesAsync();
                    break;
                default:
                    await LoadStartupItemsAsync();
                    break;
            }
        }

        private void ApplyFilter()
        {
            var q = (FilterText ?? string.Empty).ToLowerInvariant();

            FilteredEntries.Clear();
            foreach (var e in StartupEntries)
            {
                if (ShowSuspiciousOnly && !e.IsHijackSuspicious)
                    continue;

                var name = e.Name ?? string.Empty;
                var publisher = e.Publisher ?? string.Empty;
                var filePath = e.FilePath ?? string.Empty;
                var source = e.Source ?? string.Empty;

                var user = e.User ?? string.Empty;
                var signed = e.SignedDisplay ?? string.Empty;
                var analysis = e.AnalysisDetail ?? string.Empty;
                var sourceGroup = e.SourceGroup ?? string.Empty;
                var correlation = e.CorrelationSummary ?? string.Empty;

                if (string.IsNullOrEmpty(q) || name.ToLower().Contains(q)
                    || publisher.ToLower().Contains(q) || filePath.ToLower().Contains(q)
                    || source.ToLower().Contains(q) || user.ToLower().Contains(q)
                    || signed.ToLower().Contains(q) || analysis.ToLower().Contains(q)
                    || sourceGroup.ToLower().Contains(q) || correlation.ToLower().Contains(q))
                    FilteredEntries.Add(e);
            }

            FilteredServices.Clear();
            foreach (var s in Services)
            {
                var displayName = s.DisplayName ?? string.Empty;
                var serviceName = s.ServiceName ?? string.Empty;
                var user = s.User ?? string.Empty;
                var signed = s.SignedDisplay ?? string.Empty;
                var analysis = s.AnalysisDetail ?? string.Empty;
                var filePath = s.FilePath ?? string.Empty;

                if (string.IsNullOrEmpty(q) || displayName.ToLower().Contains(q)
                    || serviceName.ToLower().Contains(q) || user.ToLower().Contains(q)
                    || signed.ToLower().Contains(q) || analysis.ToLower().Contains(q)
                    || filePath.ToLower().Contains(q))
                    FilteredServices.Add(s);
            }
        }

        private async Task ToggleEntryAsync(StartupEntry? e, bool enable)
        {
            if (e == null) return;
            if ((enable && !e.SupportsEnable) || (!enable && !e.SupportsDisable))
            {
                StatusText = $"Action not supported for {e.Name}";
                return;
            }

            var action = enable ? "Enable" : "Disable";
            if (!enable && !DestructiveActionDialog.Confirm(
                    "Startup Manager",
                    $"{action} startup entry \"{e.Name}\"?",
                    "This changes how Windows starts programs or services and may affect system behavior.",
                    defaultNo: true))
            {
                StatusText = $"{action} cancelled for {e.Name}";
                return;
            }

            var actionArgs = BuildStartupActionArgs(e, action);
            var result = await PowerShellService.ExecuteAsync(
                $"& '{ScriptPath}' {actionArgs}");
            if (!result.Success)
            {
                StatusText = $"{action} failed: {FormatExecError(result)}";
                return;
            }

            await RefreshAsync();

            StartupEntry? updated;
            if (!string.IsNullOrWhiteSpace(e.RegistryKey))
            {
                updated = StartupEntries.FirstOrDefault(x =>
                    string.Equals(x.Name, e.Name, StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(x.RegistryKey, e.RegistryKey, StringComparison.OrdinalIgnoreCase));
            }
            else
            {
                updated = StartupEntries.FirstOrDefault(x =>
                    string.IsNullOrWhiteSpace(x.RegistryKey) &&
                    string.Equals(x.Name, e.Name, StringComparison.OrdinalIgnoreCase) &&
                    x.IsEnabled == enable);
            }

            if (updated == null || updated.IsEnabled != enable)
            {
                StatusText = $"{action} verification could not be confirmed for {e.Name}";
                return;
            }

            StatusText = $"{action}d: {e.Name}";
        }

        private async Task DeleteEntryAsync(StartupEntry? e)
        {
            if (e == null) return;
            if (!e.SupportsDelete)
            {
                StatusText = $"Delete is not supported for {e.Name}";
                return;
            }

            if (!DestructiveActionDialog.Confirm(
                    "Startup Manager",
                    $"Delete startup entry \"{e.Name}\"?",
                    "This permanently removes the startup entry. You may need to re-create it manually to restore autostart.",
                    defaultNo: true))
            {
                StatusText = $"Delete cancelled for {e.Name}";
                return;
            }

            var actionArgs = BuildStartupActionArgs(e, "Delete");
            var result = await PowerShellService.ExecuteAsync(
                $"& '{ScriptPath}' {actionArgs}");
            if (!result.Success)
            {
                StatusText = $"Delete failed: {FormatExecError(result)}";
                return;
            }

            await RefreshAsync();

            if (!string.IsNullOrWhiteSpace(e.RegistryKey))
            {
                var stillExists = StartupEntries.Any(x =>
                    string.Equals(x.Name, e.Name, StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(x.RegistryKey, e.RegistryKey, StringComparison.OrdinalIgnoreCase));
                if (stillExists)
                {
                    StatusText = $"Delete verification failed for {e.Name}";
                    return;
                }
            }
            else
            {
                var stillExists = StartupEntries.Any(x =>
                    string.IsNullOrWhiteSpace(x.RegistryKey) &&
                    string.Equals(x.Name, e.Name, StringComparison.OrdinalIgnoreCase));
                if (stillExists)
                {
                    StatusText = $"Delete verification failed for {e.Name}";
                    return;
                }
            }

            StatusText = $"Deleted: {e.Name}";
        }

        private async Task ResetEntryAsync(StartupEntry? e)
        {
            if (e == null) return;
            if (!e.SupportsReset)
            {
                StatusText = $"Reset is not available for {e.Name}";
                return;
            }

            var defaultHint = string.Equals(e.Name, "Userinit", StringComparison.OrdinalIgnoreCase)
                ? "%SystemRoot%\\system32\\userinit.exe,"
                : "explorer.exe";
            var confirm = MessageBox.Show(
                $"Reset Winlogon {e.Name} to the Windows default?\n\nCurrent:\n{e.FilePath}\n\nDefault:\n{defaultHint}",
                "Startup Manager",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
            {
                StatusText = $"Reset cancelled for {e.Name}";
                return;
            }

            var actionArgs = BuildWinlogonActionArgs(e, "ResetWinlogonEntry");
            var result = await PowerShellService.ExecuteAsync($"& '{ScriptPath}' {actionArgs}");
            if (!result.Success)
            {
                StatusText = $"Reset failed: {FormatExecError(result)}";
                return;
            }

            await RefreshAsync();
            StatusText = $"Reset applied: {e.Name} (Undo available until you close this session or undo)";
        }

        private async Task UndoEntryAsync(StartupEntry? e)
        {
            if (e == null) return;
            if (!e.SupportsUndo)
            {
                StatusText = $"Undo is not available for {e.Name}";
                return;
            }

            var confirm = MessageBox.Show(
                $"Restore the previous Winlogon {e.Name} value from backup?\n\nThis re-applies the value that was saved immediately before the last reset.",
                "Startup Manager",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
            {
                StatusText = $"Undo cancelled for {e.Name}";
                return;
            }

            var actionArgs = BuildWinlogonActionArgs(e, "UndoWinlogonEntry");
            var result = await PowerShellService.ExecuteAsync($"& '{ScriptPath}' {actionArgs}");
            if (!result.Success)
            {
                StatusText = $"Undo failed: {FormatExecError(result)}";
                return;
            }

            await RefreshAsync();
            StatusText = $"Undo applied: {e.Name}";
        }

        private static string EscapePs(string value)
        {
            return (value ?? string.Empty).Replace("'", "''");
        }

        private static string BuildWinlogonActionArgs(StartupEntry entry, string action)
        {
            var valueName = string.IsNullOrWhiteSpace(entry.ValueName) ? entry.Name : entry.ValueName;
            var args = $"-Action {action} -Category '{EscapePs(entry.Category)}' -RowType '{EscapePs(entry.RowType)}' -EntryName '{EscapePs(entry.Name)}'";

            if (!string.IsNullOrWhiteSpace(entry.RegistryPath))
                args += $" -RegistryPath '{EscapePs(entry.RegistryPath)}'";

            if (!string.IsNullOrWhiteSpace(valueName))
                args += $" -ValueName '{EscapePs(valueName)}'";

            return args;
        }

        private static string BuildStartupActionArgs(StartupEntry entry, string action)
        {
            if (string.Equals(entry.RowType, "WinlogonValue", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Winlogon entries use ResetWinlogonEntry or UndoWinlogonEntry.");
            }

            if (!string.IsNullOrWhiteSpace(entry.RowType)
                && !string.Equals(entry.RowType, "FileStartupItem", StringComparison.OrdinalIgnoreCase))
            {
                var entryAction = action == "Enable" ? "EnableEntry" : action == "Disable" ? "DisableEntry" : "DeleteEntry";
                var entryArgs = $"-Action {entryAction} -Category '{EscapePs(entry.Category)}' -RowType '{EscapePs(entry.RowType)}' -EntryName '{EscapePs(entry.Name)}'";

                if (!string.IsNullOrWhiteSpace(entry.ServiceName))
                    entryArgs += $" -ServiceName '{EscapePs(entry.ServiceName)}'";

                if (!string.IsNullOrWhiteSpace(entry.RegistryPath))
                    entryArgs += $" -RegistryPath '{EscapePs(entry.RegistryPath)}'";

                if (!string.IsNullOrWhiteSpace(entry.SourceGroup))
                    entryArgs += $" -SourceGroup '{EscapePs(entry.SourceGroup)}'";

                var valueName = string.IsNullOrWhiteSpace(entry.ValueName) ? entry.Name : entry.ValueName;
                if (!string.IsNullOrWhiteSpace(valueName))
                    entryArgs += $" -ValueName '{EscapePs(valueName)}'";

                if (string.Equals(entry.RowType, "ScheduledTask", StringComparison.OrdinalIgnoreCase)
                    && !string.IsNullOrWhiteSpace(entry.ActionStatePayload))
                {
                    entryArgs += $" -ActionStatePayload '{EscapePs(entry.ActionStatePayload)}'";
                }
                else if (string.Equals(entry.RowType, "DriverService", StringComparison.OrdinalIgnoreCase)
                    && !string.IsNullOrWhiteSpace(entry.OriginalData))
                {
                    entryArgs += $" -ActionStatePayload '{EscapePs(entry.OriginalData)}'";
                }

                return entryArgs;
            }

            var args = $"-Action {action} -EntryName '{EscapePs(entry.Name)}'";
            var registryKey = string.IsNullOrWhiteSpace(entry.RegistryKey) ? entry.RegistryPath : entry.RegistryKey;
            if (!string.IsNullOrWhiteSpace(registryKey))
            {
                args += $" -EntryKey '{EscapePs(registryKey)}'";
            }
            else
            {
                args += $" -EntryPath '{EscapePs(entry.FilePath)}'";
            }

            return args;
        }

        private static string NormalizePath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return string.Empty;
            try
            {
                return Path.GetFullPath(path).TrimEnd('\\');
            }
            catch
            {
                return path.TrimEnd('\\');
            }
        }

        private async Task ServiceActionAsync(ServiceEntry? s, string action)
        {
            if (s == null) return;
            var escapedServiceName = EscapePs(s.ServiceName);

            StatusText = $"{action}: {s.ServiceName}...";
            var previousStatus = s.Status;
            var result = await PowerShellService.ExecuteAsync(
                $"& '{ScriptPath}' -Action {action} -ServiceName '{escapedServiceName}'");
            if (!result.Success)
            {
                var errorText = FormatExecError(result);
                var (category, message) = ClassifyServiceFailure(errorText);
                if (category == "AlreadyInDesiredState")
                {
                    StatusText = $"No change needed: {message}";
                    await LoadServicesAsync();
                    return;
                }

                StatusText = $"{action} failed ({category}): {message}";
                MessageBox.Show(
                    $"{action} failed for '{s.ServiceName}'.\n\nReason: {message}",
                    "Service Action Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var newStatus = string.Empty;
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(300);
                var (statusResult, queryErr) = await PowerShellService.QueryAsync(
                    $"(Get-Service -Name '{escapedServiceName}' -ErrorAction SilentlyContinue).Status.ToString()");
                if (!string.IsNullOrWhiteSpace(queryErr)) continue;

                newStatus = statusResult.Trim();
                if (string.IsNullOrWhiteSpace(newStatus)) continue;
                if (!string.Equals(newStatus, previousStatus, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(action, "RestartService", StringComparison.OrdinalIgnoreCase))
                {
                    break;
                }
            }

            if (!string.IsNullOrWhiteSpace(newStatus))
            {
                s.Status = newStatus;
            }

            await LoadServicesAsync();

            if (string.IsNullOrWhiteSpace(newStatus))
            {
                StatusText = $"{action} completed, but status verification timed out for {s.ServiceName}.";
                return;
            }

            StatusText = $"Done — {s.ServiceName} is now {newStatus}";
        }

        private async Task SetStartTypeAsync(ServiceEntry? s)
        {
            if (s == null) return;
            var escapedServiceName = EscapePs(s.ServiceName);

            var result = await PowerShellService.ExecuteAsync(
                $"& '{ScriptPath}' -Action SetStartType -ServiceName '{escapedServiceName}' -StartType '{EscapePs(s.StartupType)}'");
            if (!result.Success)
            {
                var errorText = FormatExecError(result);
                var (category, message) = ClassifyServiceFailure(errorText);
                if (category == "AlreadyInDesiredState")
                {
                    StatusText = $"No change needed: {message}";
                    await LoadServicesAsync();
                    return;
                }

                StatusText = $"Set start type failed ({category}): {message}";
                MessageBox.Show(
                    $"Set Type failed for '{s.ServiceName}'.\n\nReason: {message}",
                    "Set Start Type Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var (newType, queryErr) = await PowerShellService.QueryAsync(
                $"(Get-Service -Name '{escapedServiceName}' -ErrorAction SilentlyContinue).StartType.ToString()");
            if (!string.IsNullOrWhiteSpace(queryErr) || string.IsNullOrWhiteSpace(newType))
            {
                StatusText = $"Start type set command completed, but verification failed for {s.ServiceName}";
                return;
            }

            s.StartupType = NormalizeServiceStartupType(newType.Trim());
            await LoadServicesAsync();
            StatusText = $"Start type set: {s.ServiceName} → {s.StartupType}";
        }

        private static (string Category, string Message) ClassifyServiceFailure(string rawError)
        {
            var text = rawError ?? string.Empty;

            if (text.IndexOf("ACCESS_DENIED", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("access is denied", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("cannot be configured", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("cannot open", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return ("AccessDenied", "Windows denied this change in the current context. Run CDE elevated (high integrity) and retry.");
            }

            if (text.IndexOf("SERVICE_NOT_FOUND", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("cannot find any service", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("does not exist as an installed service", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return ("ServiceNotFound", "The selected service was not found on this machine. Refresh and select a valid row.");
            }

            if (text.IndexOf("ALREADY_IN_DESIRED_STATE", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("already", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return ("AlreadyInDesiredState", "The service is already in the requested state.");
            }

            if (text.IndexOf("PROTECTED_OR_UNSUPPORTED", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("cannot be stopped", StringComparison.OrdinalIgnoreCase) >= 0 ||
                text.IndexOf("not supported", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return ("ProtectedOrUnsupported", "This service does not support that operation in the current context.");
            }

            return ("ExecutionError", text.Trim());
        }

        private static string NormalizeServiceStartupType(string startupType)
        {
            if (string.IsNullOrWhiteSpace(startupType)) return "Manual";

            if (string.Equals(startupType, "Auto", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(startupType, "Automatic", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(startupType, "AutomaticDelayedStart", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(startupType, "Boot", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(startupType, "System", StringComparison.OrdinalIgnoreCase))
            {
                return "Automatic";
            }

            if (string.Equals(startupType, "Manual", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(startupType, "Demand", StringComparison.OrdinalIgnoreCase))
            {
                return "Manual";
            }

            if (string.Equals(startupType, "Disabled", StringComparison.OrdinalIgnoreCase))
            {
                return "Disabled";
            }

            return "Manual";
        }

        private static string FormatExecError(PowerShellExecutionResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.Error)) return result.Error;
            if (!string.IsNullOrWhiteSpace(result.ExceptionMessage)) return result.ExceptionMessage;
            if (!string.IsNullOrWhiteSpace(result.Output)) return result.Output;
            return "Unknown execution error";
        }

        // ─── Context-menu jump actions (no Enable/Disable/Delete) ─────────────────

        public string? TryResolveEntryFilePath(StartupEntry? entry)
            => StartupCommandPathResolver.TryResolveExistingFile(entry?.FilePath);

        public string? TryResolveServiceFilePath(ServiceEntry? service)
            => StartupCommandPathResolver.TryResolveExistingFile(service?.FilePath);

        public void OpenEntryFileLocation(StartupEntry entry)
            => OpenResolvedFileLocation(TryResolveEntryFilePath(entry), entry.FilePath);

        public void OpenServiceFileLocation(ServiceEntry service)
            => OpenResolvedFileLocation(TryResolveServiceFilePath(service), service.FilePath);

        public void CopyEntryFilePath(StartupEntry entry)
        {
            var path = TryResolveEntryFilePath(entry) ?? entry.FilePath;
            CopyTextToClipboard(path, "File path copied.");
        }

        public void CopyEntryCommandLine(StartupEntry entry)
            => CopyTextToClipboard(entry.FilePath, "Command line copied.");

        public void CopyServiceFilePath(ServiceEntry service)
        {
            var path = TryResolveServiceFilePath(service) ?? service.FilePath;
            CopyTextToClipboard(path, "File path copied.");
        }

        public void CopyServiceName(ServiceEntry service)
            => CopyTextToClipboard(service.ServiceName, "Service name copied.");

        public void CopyEntryRegistryPath(StartupEntry entry)
        {
            var path = GetBestRegistryPath(entry);
            if (string.IsNullOrWhiteSpace(path))
            {
                MessageBox.Show("This entry has no registry path.", "Startup Manager",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            CopyTextToClipboard(path, "Registry path copied.");
        }

        public void OpenEntryInRegistryEditor(StartupEntry entry)
        {
            var path = GetBestRegistryPath(entry);
            if (string.IsNullOrWhiteSpace(path))
            {
                MessageBox.Show("This entry has no registry path.", "Startup Manager",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            try
            {
                var lastKey = ToRegeditLastKey(path);
                using (var key = Registry.CurrentUser.CreateSubKey(
                           @"Software\Microsoft\Windows\CurrentVersion\Applets\Regedit"))
                {
                    key?.SetValue("LastKey", lastKey);
                }

                Process.Start(new ProcessStartInfo
                {
                    FileName = "regedit.exe",
                    UseShellExecute = true
                });
                StatusText = "Opened Registry Editor.";
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Open in Registry Editor",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        public async Task ScanEntryWithCstAsync(StartupEntry entry)
        {
            await ScanStartupEntryWithCstAsync(entry, service: null);
        }

        public async Task ScanServiceWithCstAsync(ServiceEntry service)
        {
            await ScanStartupEntryWithCstAsync(entry: null, service);
        }

        private Task ScanStartupEntryWithCstAsync(StartupEntry? entry, ServiceEntry? service)
        {
            string displayName;
            string commandLine;
            IReadOnlyList<string> resolvedPaths;
            object metadataEntry;

            if (entry is not null)
            {
                displayName = entry.Name;
                commandLine = entry.FilePath ?? string.Empty;
                resolvedPaths = StartupCommandPathResolver.CollectExistingFiles(entry.FilePath);
                metadataEntry = new
                {
                    name = entry.Name,
                    commandLine,
                    resolvedPaths,
                    rowType = entry.RowType,
                    sourceGroup = entry.SourceGroup,
                    category = entry.Category,
                    registryPath = GetBestRegistryPath(entry) ?? string.Empty,
                    valueName = string.IsNullOrWhiteSpace(entry.ValueName) ? entry.Name : entry.ValueName,
                    user = entry.User,
                    publisher = entry.Publisher,
                    isSigned = entry.IsSigned,
                    riskLevel = entry.RiskLevel,
                    analysisDetail = entry.AnalysisDetail,
                    isHijackSuspicious = entry.IsHijackSuspicious,
                    deviationReason = entry.DeviationReason,
                    correlationSummary = entry.CorrelationSummary
                };
            }
            else if (service is not null)
            {
                displayName = service.DisplayName ?? service.ServiceName;
                commandLine = service.FilePath ?? string.Empty;
                resolvedPaths = StartupCommandPathResolver.CollectExistingFiles(service.FilePath);
                metadataEntry = new
                {
                    name = service.ServiceName,
                    commandLine,
                    resolvedPaths,
                    rowType = "Service",
                    sourceGroup = "Services",
                    category = "Services",
                    registryPath = string.Empty,
                    valueName = service.ServiceName,
                    user = service.User,
                    publisher = string.Empty,
                    isSigned = service.IsSigned,
                    riskLevel = service.HasAnalysisWarning ? "Warning" : "Unknown",
                    analysisDetail = service.AnalysisDetail,
                    isHijackSuspicious = false,
                    deviationReason = string.Empty,
                    correlationSummary = string.Empty
                };
            }
            else
            {
                return Task.CompletedTask;
            }

            IsLoading = true;
            StatusText = $"Running CST startup-entry scan on {displayName}...";
            string? metaPath = null;
            try
            {
                var cstDir = ReportPathHelper.GetCstDataRoot();
                Directory.CreateDirectory(cstDir);
                metaPath = Path.Combine(cstDir, $"startup_entry_scan_{DateTime.UtcNow:yyyyMMdd_HHmmss_fff}.json");
                var payload = new { startupEntry = metadataEntry, scanOptions = new { maxMinutes = 3 } };
                File.WriteAllText(metaPath, JsonConvert.SerializeObject(payload, Formatting.Indented));

                var script = WorkflowViewModelBase_GetScriptPath("ProcessAnalyzer.ps1");
                var owner = Application.Current?.Windows.OfType<Window>()
                    .FirstOrDefault(window => window.IsActive);
                var primaryPath = resolvedPaths.Count > 0 ? resolvedPaths[0] : commandLine;
                var parameters = $"-Action StartupEntryCstScan -StartupEntryMetadataPath \"{metaPath}\"";

                ProcessAnalyzerCstResultService.ShowLiveScan(
                    owner,
                    displayName,
                    primaryPath,
                    "Startup entry scan — File / Command line / Persistence",
                    isStartupEntryScan: true,
                    script,
                    parameters,
                    (presentation, rawOutput) =>
                    {
                        var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(rawOutput)
                            ?? FindLatestCstArtifactPath();
                        WorkOrderService.TryRecordCstScanRun(
                            artifactPath, primaryPath, presentation.Verdict, presentation.ReportPdfPath);
                        StatusText = "CST startup-entry scan completed.";
                    },
                    onFinished: () =>
                    {
                        try
                        {
                            if (!string.IsNullOrWhiteSpace(metaPath) && File.Exists(metaPath))
                                File.Delete(metaPath);
                        }
                        catch { }
                    });
            }
            catch (Exception ex)
            {
                StatusText = $"CST scan error: {ex.Message}";
                MessageBox.Show(ex.Message, "CST Scan", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsLoading = false;
            }

            return Task.CompletedTask;
        }

        public void ShowEntryDetails(StartupEntry entry)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"Name: {entry.Name}");
            sb.AppendLine($"Source: {entry.SourceGroup}");
            sb.AppendLine($"Category / type: {entry.Category} / {entry.RowType}");
            sb.AppendLine($"User: {entry.User}");
            sb.AppendLine($"Publisher: {entry.Publisher}");
            sb.AppendLine($"Signed: {entry.SignedDisplay}");
            sb.AppendLine($"Risk: {entry.RiskLevel}");
            sb.AppendLine($"Enabled: {entry.IsEnabled}");
            if (!string.IsNullOrWhiteSpace(entry.AnalysisDetail))
                sb.AppendLine($"Analysis: {entry.AnalysisDetail}");
            if (!string.IsNullOrWhiteSpace(entry.CorrelationSummary))
                sb.AppendLine($"Related: {entry.CorrelationSummary}");
            if (!string.IsNullOrWhiteSpace(entry.DeviationReason))
                sb.AppendLine($"Deviation: {entry.DeviationReason}");
            sb.AppendLine();
            sb.AppendLine("Command / path:");
            sb.AppendLine(entry.FilePath);
            var resolved = TryResolveEntryFilePath(entry);
            if (!string.IsNullOrWhiteSpace(resolved) &&
                !string.Equals(resolved, entry.FilePath, StringComparison.OrdinalIgnoreCase))
            {
                sb.AppendLine();
                sb.AppendLine("Resolved file:");
                sb.AppendLine(resolved);
            }

            var reg = GetBestRegistryPath(entry);
            if (!string.IsNullOrWhiteSpace(reg))
            {
                sb.AppendLine();
                sb.AppendLine("Registry:");
                sb.AppendLine(reg);
                if (!string.IsNullOrWhiteSpace(entry.ValueName))
                    sb.AppendLine($"Value name: {entry.ValueName}");
            }

            MessageBox.Show(sb.ToString(), "Startup entry details",
                MessageBoxButton.OK, MessageBoxImage.Information);
        }

        public void ShowServiceDetails(ServiceEntry service)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"Service: {service.ServiceName}");
            sb.AppendLine($"Display name: {service.DisplayName}");
            sb.AppendLine($"Status: {service.Status}");
            sb.AppendLine($"Startup type: {service.StartupType}");
            sb.AppendLine($"User: {service.User}");
            sb.AppendLine($"Signed: {service.SignedDisplay}");
            if (!string.IsNullOrWhiteSpace(service.AnalysisDetail))
                sb.AppendLine($"Analysis: {service.AnalysisDetail}");
            if (!string.IsNullOrWhiteSpace(service.Description))
            {
                sb.AppendLine();
                sb.AppendLine("Description:");
                sb.AppendLine(service.Description);
            }

            sb.AppendLine();
            sb.AppendLine("Image path:");
            sb.AppendLine(service.FilePath);
            var resolved = TryResolveServiceFilePath(service);
            if (!string.IsNullOrWhiteSpace(resolved) &&
                !string.Equals(resolved, service.FilePath, StringComparison.OrdinalIgnoreCase))
            {
                sb.AppendLine();
                sb.AppendLine("Resolved file:");
                sb.AppendLine(resolved);
            }

            MessageBox.Show(sb.ToString(), "Service details",
                MessageBoxButton.OK, MessageBoxImage.Information);
        }

        public void OpenMalwareCleanup()
            => NavigationService.Request("MalwareCleanup");

        public void OpenProcessAnalyzer()
            => NavigationService.Request("ProcessAnalyzer");

        private async Task ScanPathWithCstAsync(string? path, string displayName)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                MessageBox.Show(
                    "No accessible file path to scan for this entry.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            IsLoading = true;
            StatusText = $"Running CST scan on {Path.GetFileName(path)}...";
            try
            {
                var script = WorkflowViewModelBase_GetScriptPath("ProcessAnalyzer.ps1");
                var escapedPath = path.Replace("'", "''");
                var result = await PowerShellService.ExecuteAsync(
                    $"& '{script}' -Action CstScan -TargetPath '{escapedPath}'");

                if (!result.Success)
                {
                    StatusText = $"CST scan failed: {FormatExecError(result)}";
                    MessageBox.Show(FormatExecError(result), "CST Scan",
                        MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                StatusText = "CST scan completed.";
                var owner = Application.Current?.Windows.OfType<Window>()
                    .FirstOrDefault(window => window.IsActive);
                if (ProcessAnalyzerCstResultService.TryBuildPresentation(
                        result.Output, path, displayName, out var presentation, out _))
                {
                    var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(result.Output)
                        ?? FindLatestCstArtifactPath();
                    ProcessAnalyzerCstResultService.TryEnsureOperatorPdf(presentation, out _, out _);
                    WorkOrderService.TryRecordCstScanRun(
                        artifactPath, path, presentation.Verdict, presentation.ReportPdfPath);
                }

                ProcessAnalyzerCstResultService.TryShowResults(result.Output, path, displayName, owner);
            }
            catch (Exception ex)
            {
                StatusText = $"CST scan error: {ex.Message}";
                MessageBox.Show(ex.Message, "CST Scan", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsLoading = false;
            }
        }

        private void OpenResolvedFileLocation(string? resolvedPath, string? rawPath)
        {
            if (string.IsNullOrWhiteSpace(resolvedPath) || !File.Exists(resolvedPath))
            {
                var hint = string.IsNullOrWhiteSpace(rawPath) ? "No path is available." : rawPath;
                MessageBox.Show(
                    $"No accessible file path for this entry.\n\n{hint}",
                    "Open file location",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"/select,\"{resolvedPath}\"",
                    UseShellExecute = true
                });
                StatusText = "Opened file location.";
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Open file location",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void CopyTextToClipboard(string? text, string successStatus)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                MessageBox.Show("Nothing to copy.", "Startup Manager",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            try
            {
                Clipboard.SetText(text);
                StatusText = successStatus;
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Copy", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private static string? GetBestRegistryPath(StartupEntry entry)
        {
            if (!string.IsNullOrWhiteSpace(entry.RegistryPath))
                return entry.RegistryPath.Trim();
            if (!string.IsNullOrWhiteSpace(entry.RegistryKey))
                return entry.RegistryKey.Trim();
            if (!string.IsNullOrWhiteSpace(entry.Source)
                && (entry.Source.StartsWith("HK", StringComparison.OrdinalIgnoreCase)
                    || entry.Source.StartsWith("HKEY_", StringComparison.OrdinalIgnoreCase)))
                return entry.Source.Trim();
            return null;
        }

        private static string ToRegeditLastKey(string registryPath)
        {
            var path = registryPath.Trim().TrimStart('\\');
            path = path
                .Replace("HKCU\\", "HKEY_CURRENT_USER\\", StringComparison.OrdinalIgnoreCase)
                .Replace("HKLM\\", "HKEY_LOCAL_MACHINE\\", StringComparison.OrdinalIgnoreCase)
                .Replace("HKU\\", "HKEY_USERS\\", StringComparison.OrdinalIgnoreCase)
                .Replace("HKCR\\", "HKEY_CLASSES_ROOT\\", StringComparison.OrdinalIgnoreCase);

            if (!path.StartsWith("HKEY_", StringComparison.OrdinalIgnoreCase)
                && !path.StartsWith("Computer\\", StringComparison.OrdinalIgnoreCase))
            {
                // Leave as-is; Regedit LastKey still often works with HK* forms on modern Windows.
            }

            if (!path.StartsWith("Computer\\", StringComparison.OrdinalIgnoreCase))
                path = "Computer\\" + path;

            return path;
        }

        private static string? FindLatestCstArtifactPath()
        {
            var cstDir = ReportPathHelper.GetCstDataRoot();
            if (!Directory.Exists(cstDir))
                return null;

            return Directory.GetFiles(cstDir, "CST_Result_*.json")
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

        private static string WorkflowViewModelBase_GetScriptPath(string name) =>
            WorkflowViewModelBase.GetScriptPath(name);
    }

    // ─── Temp File Cleaner ───────────────────────────────────────────────────────

    public class TempFileCleanerViewModel : WorkflowViewModelBase
    {
        public ObservableCollection<TempFolderNode> Folders { get; } = new();
        public ObservableCollection<DriveSelectionItem> AvailableDrives { get; } = new();
        public ObservableCollection<TempCleanerLiveFindingGroupViewModel> LiveFindingGroups { get; } = new();

        private readonly HashSet<string> _lastScannedPaths = new(StringComparer.OrdinalIgnoreCase);

        private static string ScriptPath => GetScriptPath("TempFileCleaner.ps1");

        public ICommand ScanCommand  => new RelayCommand(async () => await ScanAsync());
        public ICommand CleanCommand => new RelayCommand(async () => await CleanAsync());

        public TempFileCleanerViewModel()
        {
            InitializeDrives();
        }

        private void InitializeDrives()
        {
            AvailableDrives.Clear();

            var systemRoot = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)) ?? "C:\\";
            var systemRootTrimmed = systemRoot.TrimEnd('\\');

            foreach (var drive in DriveInfo.GetDrives()
                         .Where(d => d.IsReady && d.DriveType != DriveType.CDRom)
                         .OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase))
            {
                var root = drive.RootDirectory.FullName;
                var rootTrimmed = root.TrimEnd('\\');
                var freeText = string.Empty;
                try
                {
                    freeText = $" ({SizeDisplayFormatter.FormatBytes(drive.AvailableFreeSpace)} free)";
                }
                catch
                {
                }

                AvailableDrives.Add(new DriveSelectionItem
                {
                    RootPath = root,
                    DisplayName = $"{rootTrimmed}{freeText}",
                    IsSelected = string.Equals(rootTrimmed, systemRootTrimmed, StringComparison.OrdinalIgnoreCase)
                });
            }
        }

        private List<string> GetSelectedDriveRoots()
        {
            return AvailableDrives
                .Where(d => d.IsSelected)
                .Select(d => d.RootPath)
                .Where(p => !string.IsNullOrWhiteSpace(p))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        public async Task ScanAsync()
        {
            var selectedDrives = GetSelectedDriveRoots();
            if (selectedDrives.Count == 0)
            {
                StatusText = "Select at least one drive to scan.";
                return;
            }

            IsRunning = true;
            StatusText = "Scanning...";
            LogText = string.Empty;
            Folders.Clear();
            _lastScannedPaths.Clear();

            var drivesFile = Path.Combine(Path.GetTempPath(), $"cde_tempcleaner_drives_{Guid.NewGuid():N}.json");
            File.WriteAllText(drivesFile, JsonConvert.SerializeObject(selectedDrives));

            try
            {
                var (json, psErr) = await PowerShellService.QueryAsync($"& '{ScriptPath}' -Action Scan -DrivesFile '{drivesFile.Replace("'", "''")}'");
                if (!string.IsNullOrEmpty(psErr)) { StatusText = $"PS Error: {psErr}"; return; }
                if (!string.IsNullOrWhiteSpace(json))
                {
                    var flat = JsonConvert.DeserializeObject<TempFolder[]>(
                        json.TrimStart().StartsWith("[") ? json : $"[{json}]");
                    if (flat != null)
                    {
                        foreach (var row in flat)
                        {
                            if (!string.IsNullOrWhiteSpace(row.Path))
                            {
                                try
                                {
                                    _lastScannedPaths.Add(Path.GetFullPath(row.Path).TrimEnd('\\'));
                                }
                                catch
                                {
                                    _lastScannedPaths.Add(row.Path.TrimEnd('\\'));
                                }
                            }
                        }

                        // Group results by profile/user first, then category-like leaf rows.
                        var grouped = flat
                            .GroupBy(f => string.IsNullOrWhiteSpace(f.ProfileGroup)
                                ? (string.IsNullOrWhiteSpace(f.UserAccount) ? "Other Directories" : f.UserAccount)
                                : f.ProfileGroup)
                            .OrderByDescending(g => g.Sum(x => x.Bytes));

                        foreach (var group in grouped)
                        {
                            var parent = new TempFolderNode
                            {
                                DisplayName = group.Key,
                                Category    = "ProfileGroup",
                                IsParent    = true,
                                FileCount   = group.Sum(x => x.FileCount),
                                Bytes       = group.Sum(x => x.Bytes)
                            };

                            foreach (var f in group.OrderByDescending(x => x.Bytes))
                            {
                                var driveTag = string.IsNullOrWhiteSpace(f.DriveLetter) ? string.Empty : $" ({f.DriveLetter})";
                                var child = new TempFolderNode
                                {
                                    DisplayName  = $"{f.Category}{driveTag}",
                                    Path         = f.Path,
                                    Category     = f.Category,
                                    UserAccount  = f.UserAccount,
                                    DriveLetter  = f.DriveLetter,
                                    DiscoverySource = f.DiscoverySource,
                                    IsProtected  = f.IsProtected,
                                    ProtectionReason = f.ProtectionReason,
                                    FileCount    = f.FileCount,
                                    Bytes        = f.Bytes,
                                    IsParent     = false,
                                    IsSelected   = false
                                };
                                parent.Children.Add(child);
                            }

                            parent.SetInitialSelected(false);
                            Folders.Add(parent);
                        }
                    }
                }
                var allLeaves  = Folders.SelectMany(p => p.Children).ToList();
                var totalBytes = allLeaves.Sum(f => f.Bytes);
                StatusText = $"{allLeaves.Count} locations found  |  {SizeDisplayFormatter.FormatBytes(totalBytes)} total";
            }
            catch (Exception ex) { StatusText = $"Error: {ex.Message}"; }
            finally
            {
                try { File.Delete(drivesFile); } catch { }
                IsRunning = false;
            }
        }

        private async Task CleanAsync()
        {
            if (_lastScannedPaths.Count == 0)
            {
                StatusText = "Run a scan before cleaning.";
                return;
            }

            var selected = Folders
                .SelectMany(p => p.Children.Where(c => c.IsSelected).Select(c => c.Path))
                .Distinct()
                .ToList();
            if (selected.Count == 0) { StatusText = "No locations selected"; return; }

            var totalBytes = Folders.SelectMany(p => p.Children.Where(c => c.IsSelected)).Sum(c => c.Bytes);
            if (!DestructiveActionDialog.Confirm(
                    "Temp File Cleaner",
                    $"Clean {selected.Count} selected location(s) (~{SizeDisplayFormatter.FormatBytes(totalBytes)})?",
                    "Files in the selected folders will be permanently deleted. Protected paths are skipped by the script.",
                    defaultNo: true))
            {
                StatusText = "Clean cancelled";
                return;
            }

            // Write selected paths to a temp file
            // Windows command-line quote-stripping when passed to powershell.exe -File.
            var tempFile = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"cde_tempcleaner_{Guid.NewGuid():N}.json");
            System.IO.File.WriteAllText(tempFile, JsonConvert.SerializeObject(selected));

            var whitelistFile = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"cde_tempcleaner_whitelist_{Guid.NewGuid():N}.json");
            System.IO.File.WriteAllText(whitelistFile, JsonConvert.SerializeObject(_lastScannedPaths.ToList()));

            try
            {
                await RunWorkflowAsync(
                    ScriptPath,
                    $"-Action Clean -PathsFile \"{tempFile}\" -WhitelistFile \"{whitelistFile}\"",
                    "Temporary File Cleanup",
                    "Remove the selected temporary locations and review the cleanup results in a dedicated execution window.");

                LoadCleanupStructuredResults();
            }
            finally
            {
                try { System.IO.File.Delete(tempFile); } catch { }
                try { System.IO.File.Delete(whitelistFile); } catch { }
            }

            // Re-scan after clean
            await ScanAsync();
        }

        private void LoadCleanupStructuredResults()
        {
            LiveFindingGroups.Clear();
            if (string.IsNullOrWhiteSpace(ReportJsonPath) || !File.Exists(ReportJsonPath))
            {
                return;
            }

            try
            {
                var json = File.ReadAllText(ReportJsonPath);
                var report = System.Text.Json.JsonSerializer.Deserialize<WorkflowExecutionReport>(json, new System.Text.Json.JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });

                var steps = report?.Steps
                    ?.Where(step => string.Equals(step.Name, "Folder Cleanup", StringComparison.OrdinalIgnoreCase))
                    .ToList();

                if (steps == null || !steps.Any())
                {
                    return;
                }

                var group = new TempCleanerLiveFindingGroupViewModel("Folder Cleanup Results");
                foreach (var step in steps)
                {
                    var severity = string.Equals(step.Status, "Pass", StringComparison.OrdinalIgnoreCase)
                        ? "Cleaned"
                        : "Skipped";

                    var location = string.IsNullOrWhiteSpace(step.Detail) ? "(No folder path reported)" : step.Detail;
                    var name = Path.GetFileName(location.TrimEnd('\\'));
                    if (string.IsNullOrWhiteSpace(name))
                    {
                        name = location;
                    }

                    group.AddFinding(new TempCleanerLiveFindingItemViewModel
                    {
                        Name = name,
                        Type = "Folder",
                        Severity = severity,
                        Location = location,
                        Evidence = string.IsNullOrWhiteSpace(step.Output) ? "No cleanup detail provided." : step.Output,
                        Detector = "TempFileCleaner",
                        SeverityBrush = string.Equals(step.Status, "Pass", StringComparison.OrdinalIgnoreCase)
                            ? new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E))
                            : new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00))
                    });
                }

                LiveFindingGroups.Add(group);
            }
            catch
            {
                // Leave structured findings empty if parsing fails; fallback text remains in execution window.
            }
        }
    }

    public sealed class TempCleanerLiveFindingGroupViewModel : INotifyPropertyChanged
    {
        private int _count;

        public TempCleanerLiveFindingGroupViewModel(string type)
        {
            Type = type;
            StatusBrush = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
        }

        public string Type { get; }
        public string Title => $"{Type} ({Count})";
        public int Count
        {
            get => _count;
            private set
            {
                if (_count == value) return;
                _count = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(Title));
            }
        }

        public Brush StatusBrush { get; }
        public ObservableCollection<TempCleanerLiveFindingItemViewModel> Findings { get; } = new();

        public void AddFinding(TempCleanerLiveFindingItemViewModel finding)
        {
            Findings.Add(finding);
            Count = Findings.Count;
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }

    public sealed class TempCleanerLiveFindingItemViewModel
    {
        public string Name { get; init; } = string.Empty;
        public string Type { get; init; } = string.Empty;
        public string Severity { get; init; } = string.Empty;
        public string Location { get; init; } = string.Empty;
        public string Evidence { get; init; } = string.Empty;
        public string Detector { get; init; } = string.Empty;
        public Brush SeverityBrush { get; init; } = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
    }

    // ─── Uninstall Manager ───────────────────────────────────────────────────────

    public class UninstallManagerViewModel : INotifyPropertyChanged
    {
        private bool _isLoading;
        private string _statusText = "Ready";
        private string _filterText = string.Empty;

        public ObservableCollection<InstalledProgram> Programs { get; } = new();
        public ObservableCollection<InstalledProgram> FilteredPrograms { get; } = new();

        public bool IsLoading
        {
            get => _isLoading;
            set { _isLoading = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsIdle)); }
        }
        public bool IsIdle => !_isLoading;

        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        public string FilterText
        {
            get => _filterText;
            set { _filterText = value; OnPropertyChanged(); ApplyFilter(); }
        }

        private static string ScriptPath => WorkflowViewModelBase.GetScriptPath("UninstallManager.ps1");

        public ICommand RefreshCommand      => new RelayCommand(async () => await LoadAsync());
        public ICommand UninstallCommand    => new RelayCommand<InstalledProgram>(async p => await UninstallAsync(p));
        public ICommand ForceRemoveCommand  => new RelayCommand<InstalledProgram>(async p => await ForceRemoveAsync(p));

        public async Task LoadAsync()
        {
            IsLoading = true;
            StatusText = "Loading installed programs...";
            try
            {
                var (json, psErr) = await PowerShellService.QueryAsync($"& '{ScriptPath}' -Action List");
                if (!string.IsNullOrEmpty(psErr)) { StatusText = $"PS Error: {psErr}"; IsLoading = false; return; }
                var progs = string.IsNullOrWhiteSpace(json) ? null
                    : JsonConvert.DeserializeObject<InstalledProgram[]>(
                        json.TrimStart().StartsWith("[") ? json : $"[{json}]");
                System.Windows.Application.Current.Dispatcher.Invoke(() =>
                {
                    Programs.Clear();
                    if (progs != null)
                        foreach (var p in progs) Programs.Add(p);
                    ApplyFilter();
                    StatusText = $"{Programs.Count} programs installed";
                });
            }
            catch (Exception ex) { StatusText = $"Error: {ex.Message}"; }
            finally { IsLoading = false; }
        }

        private async Task UninstallAsync(InstalledProgram? p)
        {
            if (p == null) return;
            StatusText = $"Launching uninstaller for {p.Name}...";
            var escaped = p.UninstallStr.Replace("'", "''");
            var result = await PowerShellService.ExecuteAsync($"& '{ScriptPath}' -Action Uninstall -UninstallStr '{escaped}'");
            if (!result.Success)
            {
                StatusText = $"Uninstall failed: {FormatExecError(result)}";
                return;
            }

            StatusText = $"Uninstaller launched: {p.Name}";
        }

        private async Task ForceRemoveAsync(InstalledProgram? p)
        {
            if (p == null) return;

            if (!DestructiveActionDialog.Confirm(
                    "Uninstall Manager",
                    $"Force remove registry entry for \"{p.Name}\"?",
                    "This deletes the uninstall registry key only. Program files may remain on disk.",
                    defaultNo: true))
            {
                StatusText = "Force remove cancelled";
                return;
            }

            var escaped = p.UninstallKey.Replace("'", "''");
            var result = await PowerShellService.ExecuteAsync($"& '{ScriptPath}' -Action ForceRemove -UninstallKey '{escaped}'");
            if (!result.Success)
            {
                StatusText = $"Force remove failed: {FormatExecError(result)}";
                return;
            }

            Programs.Remove(p);
            FilteredPrograms.Remove(p);
            StatusText = $"Force removed: {p.Name}";
        }

        private static string FormatExecError(PowerShellExecutionResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.Error)) return result.Error;
            if (!string.IsNullOrWhiteSpace(result.ExceptionMessage)) return result.ExceptionMessage;
            if (!string.IsNullOrWhiteSpace(result.Output)) return result.Output;
            return "Unknown execution error";
        }

        private void ApplyFilter()
        {
            var q = FilterText.ToLowerInvariant();
            FilteredPrograms.Clear();
            foreach (var p in Programs)
                if (string.IsNullOrEmpty(q) || p.Name.ToLower().Contains(q)
                    || p.Publisher.ToLower().Contains(q)) FilteredPrograms.Add(p);
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    // ─── Fast Fixes ──────────────────────────────────────────────────────────────

    public class FastFixesViewModel : WorkflowViewModelBase
    {
        private string _selectedCategory = "All";
        private static readonly Regex SfcProgressTokenRegex = new(@"SFC_PROGRESS\s*:\s*(?<percent>\d{1,3})", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex SfcVerificationRegex = new(@"Verification\s*(?<percent>\d{1,3})\s*%\s*complete", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex SfcVerificationCompactRegex = new(@"verification(?<percent>\d{1,3})%complete", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private int _sfcProgressLogIndex = -1;
        private System.Windows.Threading.DispatcherTimer? _sfcSmoothTimer;
        private int _sfcTargetPercent;
        private double _sfcDisplayPercent;
        private static readonly HashSet<string> WinPeUnavailableFixes = new(StringComparer.OrdinalIgnoreCase)
        {
            "DisableIPv6",
            "ResetWindowsUpdate",
            "ClearEventLogs",
            "EnableWuauserv",
            "EnableBits",
            "EnableDefender",
            "ResetEdge",
            "ResetChrome",
            "FixBrowserAssoc",
            "DisableAnimations",
            "CleanStartMenu",
            "SetHighPerf"
        };

        public ObservableCollection<FastFix> AllFixes   { get; } = new();
        public ObservableCollection<FastFix> ShownFixes { get; } = new();
        public ObservableCollection<string>  Categories { get; } = new();

        public string SelectedCategory
        {
            get => _selectedCategory;
            set { _selectedCategory = value; OnPropertyChanged(); ApplyFilter(); }
        }

        private static string ScriptPath => GetScriptPath("FastFixes.ps1");

        public ICommand LoadFixesCommand => new RelayCommand(async () => await LoadFixesAsync());
        public ICommand ApplyFixCommand  => new RelayCommand<FastFix>(async f => await ApplyFixAsync(f));

        private static bool IsWinPeMode()
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\MiniNT");
                if (key != null) return true;
            }
            catch
            {
                // Ignore registry lookup failures and continue with fallbacks.
            }

            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
            return systemRoot.StartsWith(@"X:\\", StringComparison.OrdinalIgnoreCase);
        }

        public async Task LoadFixesAsync()
        {
            IsRunning = true;
            StatusText = "Loading fixes...";
            try
            {
                var (json, psErr) = await PowerShellService.QueryAsync($"& '{ScriptPath}' -Action List");
                if (!string.IsNullOrEmpty(psErr)) { StatusText = $"PS Error: {psErr}"; return; }
                AllFixes.Clear();
                Categories.Clear();
                Categories.Add("All");

                if (!string.IsNullOrWhiteSpace(json))
                {
                    var isWinPe = IsWinPeMode();
                    var fixes = JsonConvert.DeserializeObject<FastFix[]>(
                        json.TrimStart().StartsWith("[") ? json : $"[{json}]");
                    if (fixes != null)
                    {
                        foreach (var f in fixes)
                        {
                            if (isWinPe && WinPeUnavailableFixes.Contains(f.Key))
                            {
                                f.IsApplicable = false;
                                f.ActionLabel = "N/A";
                                f.AvailabilityNote = "Not applicable in WinPE.";
                            }
                            AllFixes.Add(f);
                        }
                        foreach (var cat in fixes.Select(f => f.Category).Distinct().OrderBy(c => c))
                            Categories.Add(cat);
                    }
                }
                ApplyFilter();
                StatusText = $"{AllFixes.Count} fixes available";
            }
            catch (Exception ex) { StatusText = $"Error: {ex.Message}"; }
            finally { IsRunning = false; }
        }

        private async Task ApplyFixAsync(FastFix? fix)
        {
            if (fix == null) return;

            if (!EnvironmentCapabilityService.IsActionSupported("FastFixes", "Apply"))
            {
                StatusText = EnvironmentCapabilityService.GetUnavailableReason("FastFixes", "Apply");
                return;
            }

            if (!fix.IsApplicable)
            {
                StatusText = fix.AvailabilityNote ?? "This fix is not applicable in the current environment.";
                return;
            }

            if (!string.Equals(fix.Risk, "Safe", StringComparison.OrdinalIgnoreCase)
                && !DestructiveActionDialog.Confirm(
                    "Fast Fixes",
                    $"Apply \"{fix.Name}\"?",
                    fix.Description,
                    defaultNo: true))
            {
                StatusText = $"Cancelled: {fix.Name}";
                return;
            }

            StatusText = $"Applying: {fix.Name}...";
            _sfcProgressLogIndex = -1;
            _sfcTargetPercent = 0;
            _sfcDisplayPercent = 0;
            StartSfcSmoothTimer(fix.Key);
            try
            {
                await RunWorkflowAsync(
                    ScriptPath,
                    $"-Action Apply -FixKey {fix.Key}",
                    fix.Name,
                    fix.Description);
            }
            finally
            {
                StopSfcSmoothTimer();
            }
        }

        private void StartSfcSmoothTimer(string fixKey)
        {
            if (!string.Equals(fixKey, "RepairSfc", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            StopSfcSmoothTimer();
            _sfcSmoothTimer = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(120)
            };
            _sfcSmoothTimer.Tick += SfcSmoothTimer_Tick;
            _sfcSmoothTimer.Start();
        }

        private void StopSfcSmoothTimer()
        {
            if (_sfcSmoothTimer == null)
            {
                return;
            }

            _sfcSmoothTimer.Stop();
            _sfcSmoothTimer.Tick -= SfcSmoothTimer_Tick;
            _sfcSmoothTimer = null;
        }

        private void SfcSmoothTimer_Tick(object? sender, EventArgs e)
        {
            // sfc.exe only reports coarse checkpoints when its output is redirected.
            // Climb the displayed bar one percent at a time toward the latest real
            // checkpoint so no integer is skipped, but never overrun the real value.
            if (_sfcDisplayPercent >= _sfcTargetPercent)
            {
                return;
            }

            _sfcDisplayPercent = Math.Min(_sfcDisplayPercent + 1, _sfcTargetPercent);
            var shown = (int)Math.Floor(_sfcDisplayPercent);
            if (shown > Progress)
            {
                Progress = shown;
            }

            ProgressPercentText = $"{shown}%";
            ProgressCaption = "Execution is in progress";
            PhaseText = $"SFC verification {shown}% complete";
        }

        protected override bool HandleLiveWorkflowOutput(string line)
        {
            if (!TryGetSfcProgressPercent(line, out var percent))
            {
                return false;
            }

            var progressLine = $"[{DateTime.Now:HH:mm:ss}] Verification {percent}% complete.";
            App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_sfcProgressLogIndex >= 0 && _sfcProgressLogIndex < LogLines.Count)
                {
                    LogLines[_sfcProgressLogIndex] = progressLine;
                }
                else
                {
                    _sfcProgressLogIndex = LogLines.Count;
                    LogLines.Add(progressLine);
                }

                if (int.TryParse(percent, out var parsedPercent))
                {
                    var bounded = Math.Clamp(parsedPercent, 0, 100);
                    if (bounded > _sfcTargetPercent)
                    {
                        _sfcTargetPercent = bounded;
                    }

                    if (_sfcSmoothTimer == null)
                    {
                        // No smoothing active (non-SFC path) -> apply checkpoint directly.
                        if (bounded > Progress)
                        {
                            Progress = bounded;
                        }

                        ProgressPercentText = $"{bounded}%";
                        ProgressCaption = "Execution is in progress";
                        PhaseText = $"SFC verification {bounded}% complete";
                    }
                }

                LogText = string.Join(Environment.NewLine, LogLines);
            }));

            return true;
        }

        private static bool TryGetSfcProgressPercent(string line, out string percent)
        {
            percent = string.Empty;

            var tokenMatch = SfcProgressTokenRegex.Match(line ?? string.Empty);
            if (tokenMatch.Success)
            {
                percent = tokenMatch.Groups["percent"].Value;
                return true;
            }

            var normalized = NormalizeSfcProgressLine(line);
            var match = SfcVerificationRegex.Match(normalized);
            if (match.Success)
            {
                percent = match.Groups["percent"].Value;
                return true;
            }

            var compact = Regex.Replace(line ?? string.Empty, @"[^A-Za-z0-9%]", string.Empty);
            var compactMatch = SfcVerificationCompactRegex.Match(compact);
            if (!compactMatch.Success)
            {
                return false;
            }

            percent = compactMatch.Groups["percent"].Value;
            return true;
        }

        private static string NormalizeSfcProgressLine(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                return string.Empty;
            }

            var normalized = Regex.Replace(line, @"(?<=\p{L})\s+(?=\p{L})", string.Empty);
            normalized = Regex.Replace(normalized, @"\s+%", "%");
            normalized = Regex.Replace(normalized, @"\s+", " ");
            return normalized.Trim();
        }

        private void ApplyFilter()
        {
            ShownFixes.Clear();
            foreach (var f in AllFixes)
                if (_selectedCategory == "All" || f.Category == _selectedCategory)
                    ShownFixes.Add(f);
        }
    }

    // ─── Shared Relay Commands ────────────────────────────────────────────────────

    public class RelayCommand : ICommand
    {
        private readonly Func<Task> _execute;
        public RelayCommand(Func<Task> execute) => _execute = execute;
        public bool CanExecute(object? _) => true;
        public async void Execute(object? _)
        {
            try
            {
                await _execute();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Action failed: {ex.Message}", "CDE", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
#pragma warning disable CS0067
        public event EventHandler? CanExecuteChanged;
#pragma warning restore CS0067
    }

    public class RelayCommand<T> : ICommand
    {
        private readonly Func<T?, Task> _execute;
        public RelayCommand(Func<T?, Task> execute) => _execute = execute;
        public bool CanExecute(object? _) => true;
        public async void Execute(object? p)
        {
            try
            {
                await _execute(p is T t ? t : default);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Action failed: {ex.Message}", "CDE", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
#pragma warning disable CS0067
        public event EventHandler? CanExecuteChanged;
#pragma warning restore CS0067
    }
}
