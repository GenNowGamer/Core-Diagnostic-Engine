using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Input;
using System.Windows;

namespace ToolkitGUI.Models
{
    /// <summary>Represents a single runnable diagnostic/repair tool in a category view.</summary>
    public sealed class ToolItem : INotifyPropertyChanged
    {
        private bool _isRunning;
        private bool _isEnabled = true;
        private string _statusText = "Ready";
        private string _actionButtonLabel = "▶  Run";

        public string Name { get; }
        public string Description { get; }
        public string ToolKey { get; }
        public ICommand RunCommand { get; }

        public string ActionButtonLabel
        {
            get => _actionButtonLabel;
            set { _actionButtonLabel = value; OnPropertyChanged(); }
        }

        public bool IsRunning
        {
            get => _isRunning;
            set
            {
                _isRunning = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsIdle));
                ((ToolAsyncCommand)RunCommand).Refresh();
            }
        }

        public bool IsEnabled
        {
            get => _isEnabled;
            set
            {
                _isEnabled = value;
                OnPropertyChanged();
                ((ToolAsyncCommand)RunCommand).Refresh();
            }
        }

        public bool IsIdle => !_isRunning;

        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        public ToolItem(string name, string description, string toolKey, Func<ToolItem, Task> runAction)
        {
            Name = name;
            Description = description;
            ToolKey = toolKey;
            RunCommand = new ToolAsyncCommand(() => runAction(this), () => !_isRunning && _isEnabled);
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    internal sealed class ToolAsyncCommand : ICommand
    {
        private readonly Func<Task> _execute;
        private readonly Func<bool> _canExecute;

        public ToolAsyncCommand(Func<Task> execute, Func<bool> canExecute)
        {
            _execute = execute;
            _canExecute = canExecute;
        }

        public bool CanExecute(object? p) => _canExecute();

        public async void Execute(object? p)
        {
            Refresh();
            try { await _execute(); }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Action failed: {ex.Message}", "CDE", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally { Refresh(); }
        }

        public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);

        public event EventHandler? CanExecuteChanged;
    }
}
